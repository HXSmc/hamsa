import Foundation

/// T10a: snippet search on the Mac. Mirrors brain `store.search`: reciprocal-rank fusion of
/// BM25 (FTS5), chunk vectors and Claude-written chunk questions (ADR 004). Vectors live in memory.
public final class LocalIndex: @unchecked Sendable {
    public struct Hit: Equatable, Sendable {
        public let chunkID: Int
        public let path: String
        public let heading: String
        public let text: String
        public let score: Double
    }

    static let rrfK = 60.0
    /// (bm25, chunk vectors, generated questions) per asker language; same as brain store.WEIGHTS.
    static let weights: [String: (Double, Double, Double)] = ["ar": (0.5, 0, 1), "en": (1, 0.5, 1), "mixed": (1, 0.5, 1)]

    /// Same rule as brain chunk.detect_lang: Arabic vs Latin letter counts.
    public static func lang(_ s: String) -> String {
        var ar = 0, en = 0
        for u in s.unicodeScalars {
            if (0x0600...0x06FF).contains(u.value) { ar += 1 } else if (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) { en += 1 }
        }
        if ar > 0, en > 0, Double(min(ar, en)) / Double(max(ar, en)) > 0.2 { return "mixed" }
        return ar > en ? "ar" : "en"
    }
    let db: SQLiteDB
    let projectID: String
    let dim: Int
    public let chunkIDs: [Int]
    let chunkVecs: [Float]      // row-major, chunkIDs.count x dim
    public let questionChunkIDs: [Int]
    let questionVecs: [Float]

    public init(path: String, projectID: String, dim: Int = 384) throws {
        db = try SQLiteDB(path: path)
        self.projectID = projectID
        self.dim = dim
        let inProject = "JOIN chunks c ON c.id = v.chunk_id JOIN sources s ON s.id = c.source_id WHERE s.project_id = ?"
        var ids: [Int] = [], vecs: [Float] = []
        try db.query("SELECT v.chunk_id, v.embedding FROM chunk_vectors v \(inProject)", [projectID]) {
            ids.append($0.int(0)); vecs += $0.floats(1)
        }
        chunkIDs = ids; chunkVecs = vecs
        var qids: [Int] = [], qvecs: [Float] = []
        // Older indexes have no chunk_questions table; search still works without it.
        try? db.query("SELECT v.chunk_id, v.embedding FROM chunk_questions v \(inProject)", [projectID]) {
            qids.append($0.int(0)); qvecs += $0.floats(1)
        }
        questionChunkIDs = qids; questionVecs = qvecs
    }

    /// Indices of the `n` highest dot products of `q` against `mat` rows.
    static func topRows(_ mat: [Float], dim: Int, _ q: [Float], n: Int) -> [Int] {
        let rows = mat.count / dim
        var scores = [Float](repeating: 0, count: rows)
        mat.withUnsafeBufferPointer { m in
            for r in 0..<rows {
                var s: Float = 0
                let base = r * dim
                for j in 0..<dim { s += m[base + j] * q[j] }
                scores[r] = s
            }
        }
        return scores.indices.sorted { scores[$0] > scores[$1] }.prefix(n).map { $0 }
    }

    static func ftsQuery(_ q: String) -> String {
        let cleaned = String(q.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").filter { $0.count > 1 }.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    public func search(_ q: String, queryVector qv: [Float], k: Int = 5, pool: Int = 30) throws -> [Hit] {
        let (wBM25, wChunk, wQ) = Self.weights[Self.lang(q)]!
        var ranks: [Int: Double] = [:]
        func add(_ ids: [Int], _ w: Double) {
            guard w > 0 else { return }
            for (r, id) in ids.enumerated() { ranks[id, default: 0] += w / (Self.rrfK + Double(r)) }
        }
        let fq = Self.ftsQuery(q)
        if !fq.isEmpty {
            var bm: [Int] = []
            try db.query("""
                SELECT f.rowid FROM chunks_fts f JOIN chunks c ON c.id = f.rowid JOIN sources s ON s.id = c.source_id
                WHERE chunks_fts MATCH ? AND s.project_id = ? ORDER BY bm25(chunks_fts) LIMIT ?
                """, [fq, projectID, pool]) { bm.append($0.int(0)) }
            add(bm, wBM25)
        }
        add(Self.topRows(chunkVecs, dim: dim, qv, n: pool).map { chunkIDs[$0] }, wChunk)
        if !questionVecs.isEmpty {
            var seen: [Int] = []
            for r in Self.topRows(questionVecs, dim: dim, qv, n: questionChunkIDs.count) {
                let id = questionChunkIDs[r]
                if !seen.contains(id) { seen.append(id) }
                if seen.count == pool { break }
            }
            add(seen, wQ)
        }
        let top = ranks.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(k)
        return try top.map { id, score in
            var hit: Hit?
            try db.query("SELECT s.path, c.heading, c.text FROM chunks c JOIN sources s ON s.id = c.source_id WHERE c.id = ?", [id]) {
                hit = Hit(chunkID: id, path: $0.text(0), heading: $0.text(1), text: $0.text(2), score: score)
            }
            return hit!
        }
    }
}
