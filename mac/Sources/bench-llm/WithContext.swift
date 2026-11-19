#if canImport(Darwin)
import ArgumentParser
import Foundation
@_spi(Bench) import HamsaKit

/// T11 acceptance: drives `AnswerLLM.stream` (the product path, with its fallback chain) on questions with
/// >= 3 context snippets, and cancels each run right after the first token (a newer question replaced it).
/// `HAMSA_DISABLE_PROVIDER=groq` (comma list) simulates a missing key; the Keychain is never touched for it.
/// Sees every request AnswerLLM starts, so `cancel_ok` is measured on the wire: after a cancel every request
/// must reach `.completed` within 200 ms and no new (fallback) request may start. (Tasks made by the async
/// `bytes(for:)` API report `didCreateTask` to the session delegate but not `didCompleteWithError`, so state is polled.)
final class TaskWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [URLSessionTask] = []
    var created: Int { lock.withLock { tasks.count } }
    var allCompleted: Bool { lock.withLock { tasks.allSatisfy { $0.state == .completed } } }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { lock.withLock { tasks.append(task) } }
}

extension BenchLLM {
    /// ADR 002: primary Groq qwen3.8-27b, last-resort Gemini. Rows (and their `extra`) come from `table`.
    static let chainModels = [("groq", "qwen/qwen3.8-27b"), ("gemini", "gemini-3.5-flash")]
    static let fixtureFile = "../bench/llm-ar.jsonl"
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
        let chain = try Self.chainModels.map { m in
            guard let row = Self.table.first(where: { $0.provider == m.0 && $0.model == m.1 }) else {
                throw ValidationError("chain model \(m.0)/\(m.1) is not in BenchLLM.table")
            }
            return row
        }
        // Only the synthetic fixture may go to a provider without notes consent (Gemini free tier, ADR 002 decision 3).
        let synthetic = index == nil && arFile == Self.fixtureFile
        if !synthetic, !disabled.contains("gemini") {
            throw ValidationError("real notes (--index / --ar-file) would reach Gemini's free tier: add HAMSA_DISABLE_PROVIDER=gemini")
        }
        let cases: [(question: String, snippets: [String])]
        if let index {
            cases = try indexCases(index)
        } else {
            // Fixture: each question gets its own 2 notes plus the next item's 2 as distractors.
            let items = try loadItems()
            cases = items.indices.map { (items[$0].question, items[$0].snippets + items[($0 + 1) % items.count].snippets) }
        }
        guard !cases.isEmpty, cases.allSatisfy({ $0.snippets.count >= 3 }) else { throw ValidationError("need >= 3 snippets per question") }

        let providers = chain.map { row -> LLMProvider in
            let key = disabled.contains(row.provider) ? "" : (Self.keychainKey(row.provider) ?? "")
            if key.isEmpty {
                print("provider=\(row.provider) no key (\(disabled.contains(row.provider) ? "HAMSA_DISABLE_PROVIDER" : "no Keychain item"))")
            }
            // The table's max_tokens (400) is for the Arabic check; the product keeps AnswerLLM's 160.
            return LLMProvider(name: row.provider, baseURL: URL(string: Self.baseURLs[row.provider]!)!, model: row.model,
                               apiKey: key, mayReceiveNotes: row.provider != "gemini", extra: row.extra.filter { $0.key != "max_tokens" })
        }
        let watch = TaskWatch()
        let llm = AnswerLLM(providers: providers, session: URLSession(configuration: .default, delegate: watch, delegateQueue: nil))
        // First provider that will actually be tried; with groq disabled the run is judged on gemini.
        // The relaxed fallback gate is only for a deliberate HAMSA_DISABLE_PROVIDER run, never a missing primary key.
        let isTruePrimary = !disabled.contains(chain[0].provider)
        if isTruePrimary, providers[0].apiKey.isEmpty {
            throw ValidationError("no Keychain item for primary \(chain[0].provider); to test fallback set HAMSA_DISABLE_PROVIDER=\(chain[0].provider)")
        }
        guard let primary = providers.first(where: { !$0.apiKey.isEmpty })?.name else { throw ValidationError("no provider has a key") }
        // 4100 ms (15/min) hit Groq 429 on 4 of 50 runs (8k tokens/min); ADR 002 ran at 6000.
        let gap = paceMs ?? 6000
        print("== with-context: chain=\(chain.map { "\($0.provider)/\($0.model)" }.joined(separator: ",")) primary=\(primary) "
            + "context=\(index.map { "index:\($0)" } ?? "fixture:\(arFile)") notes_consent=\(synthetic) snippets_min=\(cases.map(\.snippets.count).min()!) n=\(n)")

        var ttfts: [Double] = [], teardowns: [Double] = [], used: [String: Int] = [:]
        var errors = 0, primaryErrors = 0, cancelOK = 0
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
                    for try await (p, _) in llm.stream(question: c.question, snippets: c.snippets, styleLines: [], confidential: false,
                                                       notesConsent: synthetic) {
                        gotFirst.yield((p, Self.ms(since: t0)))
                    }
                    return nil
                } catch { return "\(error)" }
            }
            var hit: (provider: String, ms: Double)?
            for await f in first { hit = f; break }
            var line = "run=\(i) "
            if let hit {
                let createdAtCancel = watch.created
                let tc = ContinuousClock.now
                task.cancel()
                _ = await task.value
                // Poll (2 ms, max 1 s) until every request is completed, then 50 ms more so a fallback request would show up.
                while !watch.allCompleted, Self.ms(since: tc) < 1000 { try? await Task.sleep(for: .milliseconds(2)) }
                let teardownMs = watch.allCompleted ? Self.ms(since: tc) : .infinity
                try? await Task.sleep(for: .milliseconds(50))
                let fallbacks = watch.created - createdAtCancel
                let ok = fallbacks == 0 && teardownMs <= Self.cancelBudgetMs
                if ok { cancelOK += 1 }
                ttfts.append(hit.ms); teardowns.append(teardownMs)
                used[hit.provider, default: 0] += 1
                if hit.provider != primary { primaryErrors += 1 }
                line += "provider_used=\(hit.provider) ttft_ms=\(Int(hit.ms.rounded())) teardown_ms=\(teardownMs.isFinite ? String(Int(teardownMs.rounded())) : ">1000") "
                    + "fallback_requests=\(fallbacks) cancel_ok=\(ok)"
            } else {
                errors += 1; primaryErrors += 1
                line += "provider_used=none error=\(await task.value ?? "no content")"
            }
            print(line)
        }

        func fmt(_ v: [Double], _ p: Double) -> String {
            guard !v.isEmpty else { return "NA" }
            let x = Probe.percentile(v, p)
            return x.isFinite ? String(Int(x.rounded())) : ">1000"
        }
        let cancelPct = teardowns.isEmpty ? 0 : cancelOK * 100 / teardowns.count
        let p50 = ttfts.isEmpty ? Double.infinity : Probe.percentile(ttfts, 50)
        print("")
        print("n=\(n) ttft_p50_ms=\(fmt(ttfts, 50)) ttft_p90_ms=\(fmt(ttfts, 90)) cancel_ok=\(cancelPct)% "
            + "teardown_p90_ms=\(fmt(teardowns, 90)) errors=\(errors) primary=\(primary) primary_errors=\(primaryErrors) "
            + "provider_used=\(used.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
        let base = cancelPct == 100 && errors == 0 && primaryErrors == 0
        if isTruePrimary {
            print("gate ttft_p50_ms<=600 cancel_ok=100% errors=0 primary_errors=0: \(base && p50 <= 600 ? "PASS" : "FAIL")")
        } else {
            // Fallback run (primary disabled): judged on routing, cancel and errors; the 600 ms target is for the primary.
            print("gate fallback=\(primary) cancel_ok=100% errors=0 primary_errors=0: \(base ? "PASS" : "FAIL")")
        }
    }
}
#endif
