import ArgumentParser
import Foundation
import HamsaBench
import HamsaKit
#if os(macOS)
import CoreML
#endif

// Owner: T05b (T10a/T10b add their own files here).
@main
struct BenchMatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: HamsaBench.banner("bench-match"), subcommands: [Search.self, Parity.self])
}

/// T10a parity with the brain: each case line is {"q": "...", "qvec": [384 floats], "brain_top": [chunk ids]};
/// prints top-5 overlap + latency.
struct Search: ParsableCommand {
    @Argument var index: String
    @Argument var project: String
    @Argument var cases: String

    struct Case: Decodable { let q: String; let qvec: [Float]; let brain_top: [Int] }

    func run() throws {
        let t0 = Date()
        let idx = try LocalIndex(path: index, projectID: project)
        print("load_ms=\(Int(Date().timeIntervalSince(t0) * 1000)) chunks=\(idx.chunkIDs.count) questions=\(idx.questionChunkIDs.count)")
        let cs = try String(contentsOfFile: cases, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
        var overlap = 0.0, same1 = 0, times: [Double] = []
        for c in cs {
            let t = Date()
            let hits = try idx.search(c.q, queryVector: c.qvec)
            times.append(Date().timeIntervalSince(t) * 1000)
            overlap += Double(Set(hits.map(\.chunkID)).intersection(c.brain_top).count) / Double(max(c.brain_top.count, 1))
            if hits.first?.chunkID == c.brain_top.first { same1 += 1 }
        }
        times.sort()
        print("cases=\(cs.count) top5_overlap=\(String(format: "%.2f", overlap / Double(cs.count))) top1_same=\(same1)/\(cs.count) t1_p50_ms=\(String(format: "%.1f", times[times.count / 2]))")
    }
}

/// T05b: Swift e5 vectors vs the vectors the brain stored in index.sqlite. Half the cases are chunks
/// ("passage: heading\ntext"), half generated questions ("query: q"), picked by an even stride over id order.
struct Parity: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Swift/Core ML e5 vs brain vectors: cosine, top-5 overlap, RSS, latency.")

    @Option(help: "Number of strings (half chunks, half questions).") var n = 200
    @Option(help: "Brain index (hamsa-cli sync puts it here).") var index = "~/Library/Application Support/Hamsa/index.sqlite"
    @Option(help: "Model folder (E5Small.mlmodelc + tokenizer files); default: EmbedMath.defaultModelDir().") var model: String?
    @Option(help: "Optional JSONL of reference token ids ({\"kind\",\"id\",\"ids\"}) to check the tokenizer.") var ids: String?
    @Option(help: "ane (CPU+Neural Engine) | cpu | all") var units = "ane"

    struct Item { let kind: String; let id: Int; let lang: String; let text: String; let brain: [Float] }

    static func pick(_ db: SQLiteDB, _ sql: String, kind: String, n: Int, prefix: String) throws -> [Item] {
        var all: [Item] = []
        try db.query(sql) { r in
            all.append(Item(kind: kind, id: r.int(0), lang: r.text(1), text: prefix + r.text(2), brain: r.floats(3)))
        }
        guard all.count > n else { return all }
        return (0..<n).map { all[$0 * all.count / n] }
    }

    static func pct(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    func run() async throws {
        #if os(macOS)
        let db = try SQLiteDB(path: NSString(string: index).expandingTildeInPath)
        let chunks = try Self.pick(db, "SELECT c.id, c.lang, c.heading || char(10) || c.text, v.embedding FROM chunks c JOIN chunk_vectors v ON v.chunk_id = c.id ORDER BY c.id",
                                   kind: "chunk", n: n / 2, prefix: "passage: ")
        let questions = try Self.pick(db, "SELECT id, lang, q, embedding FROM chunk_questions ORDER BY id",
                                      kind: "question", n: n - chunks.count, prefix: "query: ")
        var matIDs: [Int] = [], mat: [[Float]] = []
        try db.query("SELECT chunk_id, embedding FROM chunk_vectors ORDER BY chunk_id") { mat.append($0.floats(1)); matIDs.append($0.int(0)) }
        func top5(_ v: [Float]) -> Set<Int> {
            Set(mat.indices.map { ($0, EmbedMath.dot(mat[$0], v)) }.sorted { $0.1 > $1.1 }.prefix(5).map { matIDs[$0.0] })
        }
        var refIDs: [String: [Int]] = [:]
        if let ids {
            struct Ref: Decodable { let kind: String; let id: Int; let ids: [Int] }
            for line in try String(contentsOfFile: ids, encoding: .utf8).split(separator: "\n") {
                let r = try JSONDecoder().decode(Ref.self, from: Data(line.utf8))
                refIDs["\(r.kind)/\(r.id)"] = r.ids
            }
        }

        let cu: MLComputeUnits = ["cpu": .cpuOnly, "all": .all][units] ?? .cpuAndNeuralEngine
        let before = Footprint.now()
        let t0 = Date()
        let emb = try await E5Embedder.load(dir: model.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? EmbedMath.defaultModelDir(), units: cu)
        let firstCall = Date()
        _ = try emb.query("warm up")
        let firstMS = Date().timeIntervalSince(firstCall) * 1000
        let loadMS = Date().timeIntervalSince(t0) * 1000

        var cos: [String: [Double]] = [:], overlap: [String: [Double]] = [:], ms: [String: [Double]] = [:]
        var tokSame = 0, tokChecked = 0, worst: (Double, String) = (2, "")
        // Live path first (short questions), then long passages: the 256/512 buckets allocate
        // large activation buffers, so the two footprints are reported separately.
        var afterQuestions = Footprint.now()
        for (i, it) in (questions + chunks).enumerated() {
            if i == questions.count { afterQuestions = Footprint.now() }
            if let ref = refIDs["\(it.kind)/\(it.id)"] {
                tokChecked += 1
                if emb.tokenIDs(it.text) == ref { tokSame += 1 }
            }
            let t = Date()
            let v = try emb.embed(prefixed: it.text)
            let dt = Date().timeIntervalSince(t) * 1000
            let c = Double(EmbedMath.cosine(v, it.brain))
            let o = Double(top5(v).intersection(top5(it.brain)).count) / 5
            for key in ["all", it.kind, "\(it.kind)-\(it.lang)"] {
                cos[key, default: []].append(c); overlap[key, default: []].append(o); ms[key, default: []].append(dt)
            }
            if c < worst.0 { worst = (c, "\(it.kind)/\(it.id)") }
        }
        let after = Footprint.now()
        func f(_ x: Double, _ d: Int = 3) -> String { String(format: "%.\(d)f", x) }
        print("index=\(index) chunks_matrix=\(mat.count) units=\(units) load_ms=\(f(loadMS, 0)) first_call_ms=\(f(firstMS, 0))")
        for key in cos.keys.sorted() {
            let c = cos[key]!, o = overlap[key]!
            print("\(key): n=\(c.count) cosine_min=\(f(c.min()!, 4)) cosine_mean=\(f(c.reduce(0, +) / Double(c.count), 4)) top5_overlap=\(f(o.reduce(0, +) / Double(o.count))) embed_ms_p50=\(f(Self.pct(ms[key]!, 0.5), 1)) p95=\(f(Self.pct(ms[key]!, 0.95), 1))")
        }
        if tokChecked > 0 { print("tokenizer_exact=\(tokSame)/\(tokChecked)") }
        print("worst=\(worst.1) cosine=\(f(worst.0, 4))")
        let modelMB = afterQuestions.current - before.current
        print("footprint_mb before_model=\(f(before.current, 0)) after_questions=\(f(afterQuestions.current, 0)) after_long_passages=\(f(after.current, 0)) peak=\(f(after.peak, 0))")
        print("model_rss_mb live (tokenizer + model, questions only)=\(f(modelMB, 0)) with 512-token passages=\(f(after.current - before.current, 0))")
        let all = cos["all"]!, ov = overlap["all"]!
        let shortP50 = Self.pct(ms["question"] ?? ms["all"]!, 0.5)
        let pass = all.min()! >= 0.99 && ov.reduce(0, +) / Double(ov.count) >= 0.95 && modelMB <= 300 && shortP50 <= 30
        print("cosine_min=\(f(all.min()!, 4)) top5_overlap=\(f(ov.reduce(0, +) / Double(ov.count))) model_rss_mb=\(f(modelMB, 0)) embed_ms_p50=\(f(shortP50, 1)) (short strings = questions) \(pass ? "PASS" : "FAIL")")
        #else
        print("bench-match parity needs macOS (Core ML)")
        #endif
    }
}

#if os(macOS)
/// phys_footprint (what Activity Monitor calls Memory) in MB: current and lifetime peak.
enum Footprint {
    static func now() -> (current: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}
#endif
