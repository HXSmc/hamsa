#if canImport(Darwin)
import ArgumentParser
import Foundation
import HamsaKit

/// T11 acceptance: drives `AnswerLLM.stream` (the product path, with its fallback chain) on questions with
/// >= 3 context snippets, and cancels each run right after the first token (a newer question replaced it).
/// `HAMSA_DISABLE_PROVIDER=groq` (comma list) simulates a missing key; the Keychain is never touched for it.
extension BenchLLM {
    /// ADR 002: primary Groq qwen3.8-27b, last-resort Gemini.
    static let chain: [(provider: String, model: String, extra: [String: any Sendable])] = [
        ("groq", "qwen/qwen3.8-27b", ["reasoning_effort": "none"]),
        ("gemini", "gemini-3.5-flash", ["reasoning_effort": "minimal"]),
    ]
    static let cancelBudgetMs = 200.0

    static func ms(since t: ContinuousClock.Instant) -> Double {
        let c = t.duration(to: .now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    /// Real chunks: Arabic generated questions from the index, searched with their stored e5 vectors (no Core ML).
    func indexCases(_ path: String) throws -> [(question: String, snippets: [String])] {
        let path = NSString(string: path).expandingTildeInPath
        let idx = try LocalIndex(path: path, projectID: project)
        var qs: [(String, [Float])] = []
        try SQLiteDB(path: path).query("SELECT q, embedding FROM chunk_questions WHERE lang = 'ar' ORDER BY id LIMIT ?", [max(n, 1)]) {
            qs.append(($0.text(0), $0.floats(1)))
        }
        return try qs.map { q, v in (q, try idx.search(q, queryVector: v, k: 3).map { "\($0.heading)\n\($0.text)" }) }
    }

    func runWithContext() async throws {
        let disabled = Set((ProcessInfo.processInfo.environment["HAMSA_DISABLE_PROVIDER"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let cases: [(question: String, snippets: [String])]
        var chain = Self.chain
        if let index {
            cases = try indexCases(index)
            chain.removeAll { $0.provider == "gemini" }  // real notes never go to Gemini's free tier (ADR 002 decision 3)
        } else {
            // Synthetic fixture: each question gets its own 2 notes plus the next item's 2 as distractors.
            let items = try loadItems()
            cases = items.indices.map { (items[$0].question, items[$0].snippets + items[($0 + 1) % items.count].snippets) }
        }
        guard !cases.isEmpty, cases.allSatisfy({ $0.snippets.count >= 3 }) else { throw ValidationError("need >= 3 snippets per question") }

        let providers = chain.map { row -> LLMProvider in
            let key = disabled.contains(row.provider) ? "" : (Self.keychainKey(row.provider) ?? "")
            if key.isEmpty {
                print("provider=\(row.provider) no key (\(disabled.contains(row.provider) ? "HAMSA_DISABLE_PROVIDER" : "no Keychain item"))")
            }
            return LLMProvider(name: row.provider, baseURL: URL(string: Self.baseURLs[row.provider]!)!, model: row.model,
                               apiKey: key, extra: row.extra)
        }
        let llm = AnswerLLM(providers: providers)
        let primary = chain[0].provider
        // 4100 ms (15/min) hit Groq 429 on 4 of 50 runs (8k tokens/min); ADR 002 ran at 6000.
        let gap = paceMs ?? 6000
        print("== with-context: chain=\(chain.map { "\($0.provider)/\($0.model)" }.joined(separator: ",")) "
            + "context=\(index.map { "index:\($0)" } ?? "fixture:llm-ar") snippets_min=\(cases.map(\.snippets.count).min()!) n=\(n)")

        var ttfts: [Double] = [], cancels: [Double] = [], used: [String: Int] = [:]
        var errors = 0, primaryErrors = 0
        var lastStart: ContinuousClock.Instant?
        for i in 0..<max(n, 0) {
            if let lastStart {
                let wait = Double(gap) - Self.ms(since: lastStart)
                if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait))) }
            }
            let c = cases[i % cases.count]
            let t0 = ContinuousClock.now
            lastStart = t0
            let (first, gotFirst) = AsyncStream.makeStream(of: (provider: String, ms: Double).self)
            let task = Task { () -> String? in
                defer { gotFirst.finish() }
                do {
                    for try await (p, _) in llm.stream(question: c.question, snippets: c.snippets, styleLines: [], confidential: false) {
                        gotFirst.yield((p, Self.ms(since: t0)))
                    }
                    return nil
                } catch { return "\(error)" }
            }
            var hit: (provider: String, ms: Double)?
            for await f in first { hit = f; break }
            var line = "run=\(i) "
            if let hit {
                let tc = ContinuousClock.now
                task.cancel()
                _ = await task.value
                let cancelMs = Self.ms(since: tc)
                ttfts.append(hit.ms); cancels.append(cancelMs)
                used[hit.provider, default: 0] += 1
                if hit.provider != primary { primaryErrors += 1 }
                line += "provider_used=\(hit.provider) ttft_ms=\(Int(hit.ms.rounded())) cancel_ms=\(Int(cancelMs.rounded()))"
            } else {
                errors += 1; primaryErrors += 1
                line += "provider_used=none error=\(await task.value ?? "no content")"
            }
            print(line)
        }

        func fmt(_ v: [Double], _ p: Double) -> String { v.isEmpty ? "NA" : String(Int(Probe.percentile(v, p).rounded())) }
        let ok = cancels.filter { $0 <= Self.cancelBudgetMs }.count
        let cancelPct = cancels.isEmpty ? 0 : ok * 100 / cancels.count
        let p50 = ttfts.isEmpty ? Double.infinity : Probe.percentile(ttfts, 50)
        print("")
        print("n=\(n) ttft_p50_ms=\(fmt(ttfts, 50)) ttft_p90_ms=\(fmt(ttfts, 90)) cancel_ok=\(cancelPct)% "
            + "cancel_p90_ms=\(fmt(cancels, 90)) errors=\(errors) primary=\(primary) primary_errors=\(primaryErrors) "
            + "provider_used=\(used.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
        let pass = p50 <= 600 && cancelPct == 100 && errors == 0 && primaryErrors == 0
        print("gate ttft_p50_ms<=600 cancel_ok=100% errors=0 primary_errors=0: \(pass ? "PASS" : "FAIL")")
    }
}
#endif
