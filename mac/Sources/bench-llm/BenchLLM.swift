#if canImport(Darwin)
import ArgumentParser
import Foundation
import HamsaKit

/// T03: TTFT and Arabic quality per provider/model. Keys come from the Keychain (service "hamsa", account = provider).
@main
struct BenchLLM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Time-to-first-token and Saudi-Arabic answer check for the LLM providers.")

    @Option(name: [.customLong("n"), .customShort("n")], help: "Requests per model for the TTFT run.") var n: Int = 50
    @Option(help: "Comma list of providers.") var providers: String = "groq,gemini"
    @Option(help: "Optional override, comma list of provider:model.") var models: String?
    @Option(help: "Arabic question set (JSONL).") var arFile: String = "../bench/llm-ar.jsonl"
    @Option(help: "Minimum ms between requests to one provider (default: groq 2100, gemini 4100).") var paceMs: Int?
    @Option(help: "Write every sample to this JSONL file.") var out: String?

    // Edit here: one row per model. `extra` is merged into the request body (overrides max_tokens).
    static let baseURLs: [String: String] = [
        "groq": "https://api.groq.com/openai/v1",
        "gemini": "https://generativelanguage.googleapis.com/v1beta/openai",
    ]
    static let defaultPaceMs: [String: Int] = ["groq": 2100, "gemini": 4100]
    static let table: [(provider: String, model: String, extra: [String: any Sendable])] = [
        ("groq", "openai/gpt-oss-120b", ["reasoning_effort": "low", "include_reasoning": false, "max_tokens": 400]),
        ("groq", "qwen/qwen3.8-27b", ["reasoning_effort": "none", "max_tokens": 400]),
        ("groq", "allam-2-7b", ["max_tokens": 400]),
        ("gemini", "gemini-3.5-flash-lite", ["reasoning_effort": "minimal", "max_tokens": 400]),
        ("gemini", "gemini-3.5-flash", ["reasoning_effort": "minimal", "max_tokens": 400]),
    ]

    struct Item: Decodable { let question: String; let snippets: [String]; let expected: String }

    static func keychainKey(_ provider: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "hamsa", "-a", provider, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let key = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func loadItems() throws -> [Item] {
        let fm = FileManager.default
        guard let path = [arFile, "bench/llm-ar.jsonl", "../bench/llm-ar.jsonl"].first(where: { fm.fileExists(atPath: $0) })
        else { throw ValidationError("cannot find \(arFile)") }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
    }

    func jsonLine(_ obj: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: d, encoding: .utf8) ?? ""
    }

    func run() async throws {
        let wanted = providers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for w in wanted where Self.baseURLs[w] == nil { throw ValidationError("unknown provider \(w)") }
        var rows = Self.table.filter { wanted.contains($0.provider) }
        if let models {
            rows = try models.split(separator: ",").map { spec -> (provider: String, model: String, extra: [String: any Sendable]) in
                let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, Self.baseURLs[parts[0]] != nil else { throw ValidationError("bad --models entry \(spec)") }
                let known = Self.table.first { $0.provider == parts[0] && $0.model == parts[1] }
                return (parts[0], parts[1], known?.extra ?? ["max_tokens": 400])
            }
        }
        let items = try loadItems()
        guard !items.isEmpty else { throw ValidationError("empty Arabic set") }

        var keys: [String: String] = [:]
        for p in Set(rows.map(\.provider)).sorted() {
            if let k = Self.keychainKey(p) { keys[p] = k } else { print("skip provider=\(p): no Keychain item (service hamsa, account \(p))") }
        }

        var lastSent: [String: ContinuousClock.Instant] = [:]
        var samples: [String] = []
        var summaries: [(provider: String, model: String, p50: Double?, line: String)] = []

        for row in rows {
            guard let key = keys[row.provider], let base = URL(string: Self.baseURLs[row.provider]!) else { continue }
            let llm = AnswerLLM(providers: [])
            let prov = LLMProvider(name: row.provider, baseURL: base, model: row.model, apiKey: key)
            let gap = paceMs ?? Self.defaultPaceMs[row.provider] ?? 2000
            var limitsPrinted = false

            /// One paced request.
            func send(_ item: Item) async -> (ttftMs: Double?, text: String, error: String?, limits: [String: String]) {
                if let last = lastSent[row.provider] {
                    let c = last.duration(to: .now).components
                    let elapsed = Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
                    if elapsed < gap { try? await Task.sleep(for: .milliseconds(gap - elapsed)) }
                }
                lastSent[row.provider] = .now
                let msgs = AnswerPrompt.messages(question: item.question, snippets: item.snippets, styleLines: [])
                let r = await Probe.timeToFirstToken(llm, prov, messages: msgs, extra: row.extra)
                if r.error == nil, !limitsPrinted {
                    limitsPrinted = true
                    let kv = r.limits.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                    print("limits provider=\(row.provider) model=\(row.model) \(kv)")
                }
                return r
            }

            print("== \(row.provider)/\(row.model): \(n) TTFT requests")
            var ttfts: [Double] = []
            var errors = 0
            for i in 0..<max(n, 0) {
                let r = await send(items[i % items.count])
                if let t = r.ttftMs, r.error == nil { ttfts.append(t) } else { errors += 1; print("  error #\(i): \(r.error ?? "?")") }
                samples.append(jsonLine(["provider": row.provider, "model": row.model, "kind": "ttft",
                                         "ttft_ms": r.ttftMs ?? -1, "error": r.error ?? ""]))
            }

            print("== \(row.provider)/\(row.model): Arabic check")
            var pass = 0
            for item in items.prefix(10) {
                let r = await send(item)
                let ok = r.error == nil && Probe.passes(answer: r.text, expected: item.expected)
                if ok { pass += 1 } else {
                    let shown = String((r.error.map { "[\($0)] " } ?? "") + r.text.replacingOccurrences(of: "\n", with: " / ")).prefix(120)
                    print("  FAIL expected=\(item.expected) answer=\(shown)")
                }
                samples.append(jsonLine(["provider": row.provider, "model": row.model, "kind": "ar", "pass": ok,
                                         "ttft_ms": r.ttftMs ?? -1, "error": r.error ?? "", "text": r.text]))
            }
            print("ar_pass=\(pass)/\(min(items.count, 10))")

            let p50 = ttfts.isEmpty ? nil : Probe.percentile(ttfts, 50)
            let p90 = ttfts.isEmpty ? nil : Probe.percentile(ttfts, 90)
            func fmt(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "NA" }
            summaries.append((row.provider, row.model, p50,
                "provider=\(row.provider) model=\(row.model) n=\(n) ttft_p50_ms=\(fmt(p50)) ttft_p90_ms=\(fmt(p90)) errors=\(errors) ar_pass=\(pass)/\(min(items.count, 10))"))
        }

        print("")
        summaries.forEach { print($0.line) }
        if let best = summaries.compactMap({ s in s.p50.map { (s, $0) } }).min(by: { $0.1 < $1.1 }) {
            print("gate ttft_p50_ms<=600: \(best.1 <= 600 ? "PASS" : "FAIL") (best=\(best.0.provider)/\(best.0.model))")
        } else {
            print("gate ttft_p50_ms<=600: FAIL (best=none)")
        }
        if let out { try samples.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8) }
    }
}

#else
@main
struct BenchLLM {
    static func main() { print("bench-llm: macOS only (streams via URLSession.bytes)") }
}
#endif
