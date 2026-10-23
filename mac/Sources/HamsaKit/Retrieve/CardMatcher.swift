import Foundation

/// T10b: match a (partial) question against prepared cards. Fires only when the best card is both
/// close enough (`minScore`) and clearly ahead of the runner-up (`minMargin`); 03-tdd "Question detector".
/// Defaults from the 40-question T05 set vs 66 Taweed cards (~8/10 shown cards correct); T09 recalibrates on calls 1-3.
public final class CardMatcher: @unchecked Sendable {
    public struct Card: Equatable, Sendable {
        public let id: Int
        public let questionEN: String
        public let questionAR: String
        public let answerEN: String
        public let answerAR: String
        public let sourceChunkIDs: [Int]
    }

    public struct Match: Equatable, Sendable {
        public let card: Card
        public let score: Float
        public let margin: Float
    }

    public var minScore: Float
    public var minMargin: Float
    let dim: Int
    let cards: [Int: Card]
    let rowCardIDs: [Int]
    let vecs: [Float]

    public init(path: String, projectID: String, dim: Int = 384, minScore: Float = 0.90, minMargin: Float = 0.02) throws {
        let db = try SQLiteDB(path: path)
        self.dim = dim
        self.minScore = minScore
        self.minMargin = minMargin
        var cards: [Int: Card] = [:]
        try db.query("""
            SELECT id, question_en, question_ar, answer_en, answer_ar_sa, source_chunk_ids FROM cards
            WHERE project_id = ? AND status = 'active'
            """, [projectID]) {
            let src = (try? JSONDecoder().decode([Int].self, from: Data($0.text(5).utf8))) ?? []
            cards[$0.int(0)] = Card(id: $0.int(0), questionEN: $0.text(1), questionAR: $0.text(2),
                                    answerEN: $0.text(3), answerAR: $0.text(4), sourceChunkIDs: src)
        }
        var ids: [Int] = [], vecs: [Float] = []
        try db.query("SELECT card_id, embedding FROM card_vectors ORDER BY card_id, n") {
            if cards[$0.int(0)] != nil { ids.append($0.int(0)); vecs += $0.floats(1) }
        }
        self.cards = cards
        rowCardIDs = ids
        self.vecs = vecs
    }

    public var count: Int { cards.count }

    /// Best card for `qv`, or nil when no card is confident and distinct enough.
    public func match(_ qv: [Float]) -> Match? {
        var best: [Int: Float] = [:]  // best row score per card
        vecs.withUnsafeBufferPointer { m in
            for r in 0..<rowCardIDs.count {
                var s: Float = 0
                for j in 0..<dim { s += m[r * dim + j] * qv[j] }
                if s > best[rowCardIDs[r], default: -1] { best[rowCardIDs[r]] = s }
            }
        }
        let ranked = best.sorted { $0.value > $1.value }
        guard let top = ranked.first, let card = cards[top.key] else { return nil }
        let margin = top.value - (ranked.dropFirst().first?.value ?? -1)
        guard top.value >= minScore, margin >= minMargin else { return nil }
        return Match(card: card, score: top.value, margin: margin)
    }
}
