#if os(macOS)
import ArgumentParser
import Foundation
import HamsaKit

/// T02: STT benchmark. `--engine all` re-runs this binary once per engine so peak RSS is per engine.
@main
struct BenchWERCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "WER + partial lag + memory per STT engine.")

    @Option(help: "Clip folder: *.wav + same-name .txt reference. Language = 'en' if the file or a parent folder is named en*, else 'ar'.")
    var set: String
    @Option(help: "all | dictation | whisperkit") var engine: String = "all"
    @Option(help: "WhisperKit model (argmaxinc/whisperkit-coreml).") var model: String = "large-v3-v20240930_626MB"
    @Option(help: "WhisperKit re-decode step, seconds.") var step: Double = 1.0
    @Option(help: "Write results into this ADR between bench-wer markers for --label.") var adr: String?
    @Option(help: "Name of this run in the ADR (e.g. idle, cpu-load).") var label: String = "idle"

    struct Result: Codable {
        var engine: String, wer_ar: Double?, wer_en: Double?, lag_p50_ms: Double?, lag_p95_ms: Double?, lag_words: Int
        var rss_mb: Double, daemon_rss_mb: Double?, pageouts_growth: Int, clips: Int, seconds: Double, note: String
    }

    func clips() throws -> [(wav: URL, ref: String, lang: String)] {
        let root = URL(fileURLWithPath: set)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw ValidationError("no set \(set)") }
        var out: [(URL, String, String)] = []
        for case let u as URL in e where u.pathExtension == "wav" {
            let txt = u.deletingPathExtension().appendingPathExtension("txt")
            guard let ref = try? String(contentsOf: txt, encoding: .utf8) else { continue }
            let rel = u.path.dropFirst(root.path.count).split(separator: "/")
            out.append((u, ref, rel.contains { $0.hasPrefix("en") } ? "en" : "ar"))
        }
        return out.sorted { $0.0.path < $1.0.path }
    }

    func run() async throws {
        if engine == "all" {
            var results: [Result] = []
            for e in ["dictation", "whisperkit"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                p.arguments = ["--set", set, "--engine", e, "--model", model, "--step", "\(step)"]
                let pipe = Pipe()
                p.standardOutput = pipe
                try p.run()
                var out = Data()
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    if line.hasPrefix("RESULT ") { out = Data(line.dropFirst(7).utf8) } else { print(line) }
                }
                p.waitUntilExit()
                if let r = try? JSONDecoder().decode(Result.self, from: out) { results.append(r) }
            }
            report(results)
        } else {
            let r = try await runOne()
            let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
            print("RESULT " + String(decoding: try enc.encode(r), as: UTF8.self))
            if CommandLine.arguments.contains("--adr") { report([r]) }
        }
    }

    func runOne() async throws -> Result {
        let clips = try clips()
        guard !clips.isEmpty else { throw ValidationError("no clips with .txt in \(set)") }
        let pageouts0 = Self.pageouts()
        let start = ContinuousClock.now
        var pairs: [String: [(ref: String, hyp: String)]] = [:]
        var lags: [Double] = []
        var note = ""
        let daemon = DaemonRSS()
        switch engine {
        case "dictation":
            guard #available(macOS 26, *) else { throw ValidationError("DictationTranscriber needs macOS 26") }
            daemon.start()
            for lang in Set(clips.map(\.lang)).sorted() {
                print("dictation \(lang): asset \(try await BenchDictation.ensureAsset(Self.locale(lang)))")
            }
            for c in clips {
                let r = try await BenchDictation.run(url: c.wav, locale: Self.locale(c.lang))
                pairs[c.lang, default: []].append((c.ref, r.text)); lags += r.lags
                Self.log(c.wav, c.ref, r)
            }
            note = "in-process RSS excludes the speech daemon; daemon_rss_mb = peak summed RSS of *speech*/*dictation* processes"
        case "whisperkit":
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/hamsa/whisperkit")
            let t0 = ContinuousClock.now
            let w = try await BenchWhisper(model: model, downloadBase: base)
            print("whisperkit \(model): loaded in \(t0.duration(to: .now))")
            for c in clips {
                let r = try await w.run(url: c.wav, language: c.lang, step: step)
                pairs[c.lang, default: []].append((c.ref, r.text)); lags += r.lags
                Self.log(c.wav, c.ref, r)
            }
            note = "model \(model), step \(step) s, growing-window re-decode, simulated real-time clock"
        default: throw ValidationError("unknown engine \(engine)")
        }
        let secs = start.duration(to: .now).components
        return Result(engine: engine, wer_ar: pairs["ar"].map { BenchWER.wer($0) }, wer_en: pairs["en"].map { BenchWER.wer($0) },
                      lag_p50_ms: lags.isEmpty ? nil : Probe.percentile(lags, 50) * 1000,
                      lag_p95_ms: lags.isEmpty ? nil : Probe.percentile(lags, 95) * 1000, lag_words: lags.count,
                      rss_mb: Self.peakRSSMB(), daemon_rss_mb: daemon.stop(), pageouts_growth: Self.pageouts() - pageouts0,
                      clips: clips.count, seconds: Double(secs.seconds), note: note)
    }

    static func locale(_ lang: String) -> Locale { Locale(identifier: lang == "en" ? "en_US" : "ar_SA") }

    static func log(_ wav: URL, _ ref: String, _ r: BenchClip) {
        let e = BenchWER.errors(ref: ref, hyp: r.text)
        print("\(wav.deletingPathExtension().pathComponents.suffix(2).joined(separator: "/"))  err=\(e.errors)/\(e.refWords)  hyp=\(r.text)")
    }

    static func peakRSSMB() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_maxrss) / 1_048_576  // bytes on macOS
    }

    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    static func pageouts() -> Int {
        let line = shell("/usr/bin/vm_stat", []).split(separator: "\n").first { $0.hasPrefix("Pageouts") } ?? ""
        return Int(line.filter(\.isNumber)) ?? 0
    }

    /// Samples system speech daemons' RSS every 0.5 s (Dictation runs out of process).
    final class DaemonRSS: @unchecked Sendable {
        private var peak = 0.0, task: Task<Void, Never>?, started = false
        private let lock = NSLock()
        func start() {
            started = true
            task = Task.detached { [self] in
                while !Task.isCancelled {
                    var kb = 0.0
                    for l in BenchWERCLI.shell("/bin/ps", ["-A", "-o", "rss=,comm="]).split(separator: "\n") {
                        let low = l.lowercased()
                        if low.contains("speech") || low.contains("dictation") { kb += Double(l.split(separator: " ").first ?? "0") ?? 0 }
                    }
                    lock.withLock { peak = max(peak, kb / 1024) }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        func stop() -> Double? { task?.cancel(); guard started else { return nil }; lock.lock(); defer { lock.unlock() }; return peak }
    }

    func report(_ rs: [Result]) {
        func f(_ v: Double?, _ d: Int = 3) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "n/a" }
        var md = "### Run `\(label)` (\(rs.first.map { _ in ISO8601DateFormatter().string(from: Date()) } ?? ""), set `\(set)`) — PROVISIONAL\n\n"
        md += "| engine | wer_ar | wer_en | lag_p50_ms | lag_p95_ms | lag words | rss_mb (in-proc) | daemon rss_mb | pageouts_growth | clips | wall s |\n"
        md += "|---|---|---|---|---|---|---|---|---|---|---|\n"
        for r in rs {
            md += "| \(r.engine) | \(f(r.wer_ar)) | \(f(r.wer_en)) | \(f(r.lag_p50_ms, 0)) | \(f(r.lag_p95_ms, 0)) | \(r.lag_words) | \(f(r.rss_mb, 0)) | \(f(r.daemon_rss_mb, 0)) | \(r.pageouts_growth) | \(r.clips) | \(f(r.seconds, 0)) |\n"
        }
        md += "\n" + rs.map { "- \($0.engine): \($0.note)" }.joined(separator: "\n") + "\n"
        let pass = { (r: Result) in (r.wer_ar ?? 1) <= 0.30 && (r.wer_en ?? 1) <= 0.15 && (r.lag_p50_ms ?? 1e9) <= 700 && r.rss_mb <= 900 && r.pageouts_growth == 0 }
        md += rs.map { "- gate (wer_ar<=0.30 wer_en<=0.15 lag_p50<=700 rss<=900 pageouts=0) \($0.engine): \(pass($0) ? "PASS" : "FAIL")" }.joined(separator: "\n") + "\n"
        print(md)
        guard let adr else { return }
        let begin = "<!-- bench-wer:\(label):begin -->", end = "<!-- bench-wer:\(label):end -->"
        var doc = (try? String(contentsOfFile: adr, encoding: .utf8)) ?? "# ADR 001 — STT engine (T02)\n\n"
        let block = "\(begin)\n\(md)\(end)"
        if let a = doc.range(of: begin), let b = doc.range(of: end) { doc.replaceSubrange(a.lowerBound..<b.upperBound, with: block) }
        else { doc += "\n\(block)\n" }
        try? doc.write(toFile: adr, atomically: true, encoding: .utf8)
    }
}

#else
@main
struct BenchWERCLI {
    static func main() { print("bench-wer: macOS only (Speech + WhisperKit/CoreML)") }
}
#endif
