#if os(macOS)
import ArgumentParser
import AVFoundation
import Foundation
import HamsaKit

/// T08: replay a call through the live STT path (one supervised Dictation worker per channel) into live.sqlite.
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replay them.wav [+ me.wav] in real time through live STT into live.sqlite; print lag + row counts.")

    @Option(help: "WAV to replay: first = them, second (optional) = me. With one WAV, labels' audio.me is used if present.")
    var replay: [String]
    @Option(help: "Labels JSON (CallLabels format, HamsaKit/STT/CallLabels.swift).") var labels: String?
    @Option(help: "live.sqlite path.") var db: String = "~/Library/Application Support/Hamsa/live.sqlite"
    @Option(help: "Dictation language of THEM (ar|en).") var themLang: String = "ar"
    @Option(help: "Dictation language of ME (ar|en).") var meLang: String = "en"
    @Option(help: "Kill the THEM worker once after N seconds (restart check).") var killAfter: Double?

    func run() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26, *) else { throw ValidationError("DictationTranscriber needs macOS 26") }
        try await live()
        #else
        throw ValidationError("built without the macOS 26 SDK")
        #endif
    }

    static func path(_ p: String) -> URL { URL(fileURLWithPath: NSString(string: p).expandingTildeInPath) }
    static func locale(_ lang: String) -> Locale { Locale(identifier: lang == "en" ? "en_US" : "ar_SA") }
    static func pct(_ xs: [Int], _ p: Double) -> Int { xs.isEmpty ? -1 : xs.sorted()[min(xs.count - 1, Int(Double(xs.count) * p))] }

    #if compiler(>=6.2)
    @available(macOS 26, *)
    func live() async throws {
        guard (1...2).contains(replay.count) else { throw ValidationError("--replay takes 1 or 2 WAVs") }
        let lab = try labels.map { try CallLabels.load(Self.path($0)) }
        var wavs = replay.map(Self.path)
        if wavs.count == 1, let me = lab?.audio["me"], let l = labels {
            let u = Self.path(l).deletingLastPathComponent().appendingPathComponent(me)
            if FileManager.default.fileExists(atPath: u.path) { wavs.append(u); print("me channel from labels: \(u.lastPathComponent)") }
        }
        let channels = Array(zip(["them", "me"], wavs))

        let dbURL = Self.path(db)
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try LiveStore(path: dbURL.path)
        let meeting = UUID().uuidString
        try await store.startMeeting(id: meeting, title: "replay \(wavs[0].lastPathComponent)", app: "replay",
                                     audioDir: wavs[0].deletingLastPathComponent().path)

        let clock = ContinuousClock()
        let t0 = clock.now
        let now: @Sendable () -> Int = { let c = t0.duration(to: clock.now).components; return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000) }
        let log = Log()
        var feeds: [(relay: LiveRelay<PCMChunk>, chunks: [PCMChunk], sec: Double)] = []
        var sups: [String: STTSupervisor] = [:]
        for (ch, url) in channels {
            let lang = ch == "them" ? themLang : meLang
            let loc = Self.locale(lang)
            print("\(ch): \(url.lastPathComponent) dictation \(loc.identifier) asset \(try await BenchDictation.ensureAsset(loc))")
            let format = try await LiveDictation.format(locale: loc, considering: AVAudioFile(forReading: url).processingFormat)
            let relay = LiveRelay<PCMChunk>()
            feeds.append((relay, try LiveDictation.chunks(url: url, format: format), 0.1))
            sups[ch] = STTSupervisor(name: ch) { g in
                if g > 1 { await store.closeOpen(meeting: meeting, channel: ch) }
                try await LiveDictation.work(channel: ch, locale: loc, lang: lang, format: format, relay: relay, generation: g,
                                             now: now, ready: { log.ready(ch, g, now()) }) { u in
                    log.add(u)
                    do { try await store.write(u, meeting: meeting) } catch { log.error("\(ch) write: \(error)") }
                }
            }
        }
        for s in sups.values { await s.start() }
        if let k = killAfter, let s = sups["them"] {
            Task { try? await Task.sleep(for: .seconds(k)); log.killed(now()); await s.kill() }
        }
        // Feeders: push 100 ms chunks on the wall clock (keeps going across worker restarts).
        await withTaskGroup(of: Void.self) { group in
            for f in feeds {
                group.addTask {
                    for (i, c) in f.chunks.enumerated() {
                        let wait = Double(i) * f.sec - Double(now()) / 1000
                        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                        f.relay.push(c, frames: Int(c.buffer.frameLength))
                    }
                    f.relay.finish()
                }
            }
        }
        for s in sups.values { await s.wait() }
        try await store.endMeeting(id: meeting)
        try await report(store: store, meeting: meeting, log: log, labels: lab, channels: channels.map(\.0), sups: sups)
    }

    @available(macOS 26, *)
    func report(store: LiveStore, meeting: String, log: Log, labels: CallLabels?, channels: [String], sups: [String: STTSupervisor]) async throws {
        let ups = log.updates
        if labels?.provisional == true { print("PROVISIONAL: labels are synthetic (TTS), not a real call") }
        var allLags: [Int] = []
        for ch in channels {
            // Same method as T02 (BenchWER.wordLags): per final, its words vs the partials since the previous final.
            var pending: [(time: Double, text: String)] = [], lags: [Int] = [], gen = 0
            for u in ups where u.channel == ch {
                if u.generation != gen { pending = []; gen = u.generation }
                pending.append((Double(u.arrivalMs), u.text))
                guard u.isFinal else { continue }
                lags += BenchWER.wordLags(finalWords: u.words.map { ($0.word, Double($0.endMs)) }, hyps: pending).map { Int($0) }
                pending = []
            }
            allLags += lags
            print("channel=\(ch) partial_lag_p50_ms=\(Self.pct(lags, 0.5)) partial_lag_p95_ms=\(Self.pct(lags, 0.95)) lag_words=\(lags.count)")
            if let labels {
                let ref = labels.reference(channel: ch)
                let hyp = try await store.finalText(meeting: meeting, channel: ch)
                let e = BenchWER.errors(ref: ref, hyp: hyp)
                print(String(format: "channel=%@ wer=%.3f ref_words=%d", ch, e.refWords == 0 ? 0 : Double(e.errors) / Double(e.refWords), e.refWords))
            }
        }
        print("partial_lag_p50_ms=\(Self.pct(allLags, 0.5)) partial_lag_p95_ms=\(Self.pct(allLags, 0.95)) lag_words=\(allLags.count)")

        if let labels {
            // Question end → first partial on that channel containing the question's last word.
            var qLags: [Int] = [], missed = 0
            for q in labels.questions where channels.contains(q.channel) {
                guard let last = BenchWER.words(q.text).last,
                      let u = ups.first(where: { $0.channel == q.channel && $0.arrivalMs >= Int(q.start * 1000) && BenchWER.words($0.text).contains(last) })
                else { missed += 1; continue }
                qLags.append(u.arrivalMs - Int(q.end * 1000))
            }
            print("questions=\(qLags.count + missed) question_end_lag_p50_ms=\(Self.pct(qLags, 0.5)) question_end_lag_p95_ms=\(Self.pct(qLags, 0.95)) missed=\(missed)")
        }
        let counts = try await store.counts(meeting: meeting)
        for ch in ["them", "me"] {
            let c = counts[ch] ?? (0, 0)
            print("live.sqlite meeting=\(meeting.prefix(8)) channel=\(ch) rows=\(c.final + c.partial) final=\(c.final) partial=\(c.partial)")
        }
        if let k = log.killedAt {
            let back = log.readies.filter { $0.ch == "them" && $0.gen > 1 }.first.map { $0.ms - k }
            let sup = await sups["them"]?.restartLatencies.first.map { Int($0.components.attoseconds / 1_000_000_000_000_000) + Int($0.components.seconds) * 1000 }
            print("kill at_ms=\(k) worker_restart_ms=\(sup ?? -1) analyzer_ready_ms=\(back ?? -1) generations=\(await sups["them"]?.generation ?? 0)")
        }
        for e in log.errors { print("WARN: \(e)") }
    }
    #endif
}

/// Results + events of one replay, written from worker tasks.
final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var updates: [STTUpdate] = []
    private(set) var readies: [(ch: String, gen: Int, ms: Int)] = []
    private(set) var killedAt: Int?
    private(set) var errors: [String] = []
    func add(_ u: STTUpdate) { lock.lock(); updates.append(u); lock.unlock() }
    func ready(_ ch: String, _ gen: Int, _ ms: Int) { lock.lock(); readies.append((ch, gen, ms)); lock.unlock() }
    func killed(_ ms: Int) { lock.lock(); killedAt = ms; lock.unlock() }
    func error(_ e: String) { lock.lock(); errors.append(e); lock.unlock() }
}
#endif
