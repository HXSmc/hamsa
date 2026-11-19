import ArgumentParser
import Foundation
import HamsaKit

#if os(macOS)
import AppKit
import AVFoundation

/// T12: latency KPIs of the live answer path (03-tdd "Latency definitions"). Replays a labelled call through
/// STT -> LivePipeline in real time, optionally with the overlay up (`--ui`: t_shown_ms = text committed to the
/// overlay window), then prints one KPI line computed from the `latency_events` view of this run's meeting.
@main
struct BenchLatency: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replay a call through the live pipeline (+ overlay) and print first-text / T2 first-token p50s.")

    @Option(help: "THEM wav of the call (the labels' ME wav is replayed alongside).") var replay: String?
    @Option(help: "Labels JSON (CallLabels).") var labels: String?
    @Flag(help: "Show the answer overlay; t_shown_ms is taken when text is committed to it.") var ui = false
    @Option(help: "live.sqlite to write (default: a bench file, never the app's live.sqlite).") var db = Self.defaultDB
    @Option(help: "Local index (T10a).") var index = "~/Library/Application Support/Hamsa/index.sqlite"
    @Option(help: "Prepared cards (T10b).") var cards = "~/Library/Application Support/Hamsa/cards.sqlite"
    @Option(help: "Project id in the index / cards.") var project = "taweed"
    @Option(help: "Dictation language of THEM (ar|en).") var themLang = "ar"
    @Option(help: "Dictation language of ME (ar|en).") var meLang = "en"
    @Option(help: "Alone: render the overlay states from a fixture to PNGs here and exit. With --replay --ui: also save live frames here.")
    var snapshot: String?

    /// Bench meetings end as `queued`; kept out of the app's live.sqlite so the summarizer never picks them up.
    static let defaultDB = "~/Library/Application Support/Hamsa/bench-live.sqlite"

    static func path(_ p: String) -> URL { URL(fileURLWithPath: NSString(string: p).expandingTildeInPath) }
    static func ms(_ d: Duration) -> Int { Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000) }
    static func nonEmpty(_ u: URL) -> Bool { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int ?? 0) > 0 }

    @MainActor
    func run() async throws {
        if let dir = snapshot, replay == nil { return try Self.renderFixtures(Self.path(dir)) }
        #if compiler(>=6.2)
        guard #available(macOS 26, *) else { throw ValidationError("DictationTranscriber needs macOS 26") }
        try await bench()
        #else
        throw ValidationError("built without the macOS 26 SDK")
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26, *) @MainActor
    func bench() async throws {
        guard let replay, let labels else { throw ValidationError("give --replay and --labels (or --snapshot <dir> alone)") }
        let lab = try CallLabels.load(Self.path(labels))
        var wavs = [Self.path(replay)]
        if let me = lab.audio["me"] {
            let u = Self.path(labels).deletingLastPathComponent().appendingPathComponent(me)
            if FileManager.default.fileExists(atPath: u.path) { wavs.append(u) }
        }

        let dbURL = Self.path(db)
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try LiveStore(path: dbURL.path)
        let meeting = UUID().uuidString
        try await store.startMeeting(id: meeting, title: "bench-latency \(wavs[0].lastPathComponent)", app: "bench")
        let embedder: (any Embedder)?
        do { embedder = try await E5Embedder.load() } catch { embedder = nil; print("# WARN: no e5 embedder (\(error)): T0/T1 off") }
        let idxURL = Self.path(index), cardsURL = Self.path(cards)
        let idx = Self.nonEmpty(idxURL) ? try LocalIndex(path: idxURL.path, projectID: project) : nil
        let cardMatcher = Self.nonEmpty(cardsURL) ? try CardMatcher(path: cardsURL.path, projectID: project) : nil
        print("# index=\(idx.map { "\($0.chunkIDs.count) chunks" } ?? "none") cards=\(cardMatcher.map { "\($0.count)" } ?? "none (T0 off)")")
        let chain = PipelineProviders.chain(key: PipelineProviders.keychainKey)
        print("# llm chain=\(chain.map { "\($0.name)\($0.apiKey.isEmpty ? "(no key)" : "")" }.joined(separator: ","))")
        let llm = AnswerLLM(providers: chain)

        // Pipeline clock = audio timeline (ms since the first chunk was pushed), the clock of STTUpdate times.
        let clock = ContinuousClock()
        let start = clock.now
        let wall: @Sendable () -> Int = { Self.ms(start.duration(to: clock.now)) }
        let audioZero = Box()
        let now: @Sendable () -> Int = { let n = wall(); return n - (audioZero.value ?? n) }

        var overlay: OverlayController?
        if ui {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.finishLaunching()
            let o = OverlayController()
            o.show()
            o.model.aiOff = try await store.privacy(meeting: meeting).confidential  // read only, never written
            overlay = o
            print("# overlay window=\(o.panel.windowNumber) kCGWindowSharingState=\(o.sharingState.map(String.init) ?? "not listed")")
        }
        var shown: LivePipeline.Shown?
        if let o = overlay { shown = { e in await o.commit(e) } }
        let pipeline = LivePipeline(store: store, meeting: meeting, embedder: embedder, index: idx, cards: cardMatcher, llm: llm,
                                    shown: shown, now: now)
        let frames = snapshot.map(Self.path)
        if let frames { try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true) }
        let consumer = Task { @MainActor in
            var last = ""
            for await e in pipeline.events {
                guard let o = overlay else { continue }
                o.model.apply(e)
                let key = "\(o.model.questionID ?? 0)-\(o.model.state.rawValue)"
                if let frames, key != last {  // one frame per question and state, for the evidence folder
                    last = key
                    do { try o.capture(to: frames.appendingPathComponent("live-q\(key).png")) } catch { print("# WARN: frame \(key): \(error)") }
                }
            }
        }

        var relays: [LiveRelay<PCMChunk>] = [], sups: [STTSupervisor] = [], feeds: [[PCMChunk]] = []
        for (i, ch) in ["them", "me"].prefix(wavs.count).enumerated() {
            let lang = ch == "them" ? themLang : meLang
            let loc = Locale(identifier: lang == "en" ? "en_US" : "ar_SA")
            _ = try await BenchDictation.ensureAsset(loc)
            let format = try await LiveDictation.format(locale: loc, considering: AVAudioFile(forReading: wavs[i]).processingFormat)
            let relay = LiveRelay<PCMChunk>()
            relays.append(relay)
            feeds.append(try LiveDictation.chunks(url: wavs[i], format: format))
            sups.append(STTSupervisor(name: ch) { [overlay] g in
                if g > 1 {
                    await store.closeOpen(meeting: meeting, channel: ch)
                    await MainActor.run { overlay?.model.sttRestarted = true }
                }
                try await LiveDictation.work(channel: ch, locale: loc, lang: lang, format: format, relay: relay, generation: g,
                                             now: now) { await pipeline.ingest($0) }
            })
        }
        for s in sups { await s.start() }

        // Real-time feed: 100 ms chunks on the wall clock.
        let feeders = zip(relays, feeds).map { relay, chunks in
            Task.detached {
                let t0 = wall()
                audioZero.setOnce(t0)
                for (i, c) in chunks.enumerated() {
                    let wait = t0 + i * 100 - wall()
                    if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
                    relay.push(c, frames: Int(c.buffer.frameLength))
                }
            }
        }
        for f in feeders { await f.value }
        try? await Task.sleep(for: .seconds(3))  // last finals
        relays.forEach { $0.finish() }
        for s in sups { await s.wait() }
        await pipeline.finish()
        await consumer.value
        try await store.endMeeting(id: meeting)
        if let o = overlay { print("# overlay kCGWindowSharingState at end=\(o.sharingState.map(String.init) ?? "not listed")"); o.close() }

        let s = await pipeline.stats
        print("# meeting=\(meeting) db=\(dbURL.path) questions=\(s.questions) T0=\(s.t0) T1=\(s.t1) T2=\(s.t2) t2_starts=\(s.t2Starts) t2_errors=\(s.t2Errors.values.reduce(0, +)) store_errors=\(s.storeErrors)")
        let k = try Self.kpi(db: dbURL.path, meeting: meeting)
        func p50(_ v: [Int]) -> String { v.isEmpty ? "NA" : String(Int(Probe.percentile(v.map(Double.init), 50))) }
        print("first_text_p50_ms=\(p50(k.firstText)) t2_first_token_p50_ms=\(p50(k.tiers["T2"] ?? [])) t0_match_p50_ms=\(p50(k.tiers["T0"] ?? [])) t1_p50_ms=\(p50(k.tiers["T1"] ?? [])) n_questions=\(s.questions) input=\(wavs[0].lastPathComponent) PROVISIONAL=\(lab.provisional)")
    }
    #endif

    /// Same rows as `bench-report latency`: `latency_events` of one meeting, per tier, plus first text per question
    /// = the earlier of its T0/T1 (03-tdd `first_text_ms`). Values may be negative.
    static func kpi(db: String, meeting: String) throws -> (tiers: [String: [Int]], firstText: [Int]) {
        var tiers: [String: [Int]] = [:], first: [Int: Int] = [:]
        try SQLiteDB(path: db).query("""
            SELECT l.id, l.tier, l.first_text_ms FROM latency_events l JOIN questions q ON q.id = l.id
            WHERE q.meeting_id = ? ORDER BY l.id
            """, [meeting]) {
            let (id, tier, ms) = ($0.int(0), $0.text(1), $0.int(2))
            tiers[tier, default: []].append(ms)
            if tier != "T2" { first[id] = min(first[id] ?? ms, ms) }
        }
        return (tiers, first.keys.sorted().map { first[$0]! })
    }

    /// Fixture states of the overlay (live data cannot reach card / Arabic answer states: no cards, stale index).
    @MainActor
    static func renderFixtures(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        typealias E = LivePipeline.Event
        let q = E.question(id: 1, channel: "them", text: "What is the monthly price of the basic plan?")
        let qAR = E.question(id: 1, channel: "them", text: "كم سعر الباقة الشهرية؟")
        let snippet = "pricing.md › Plans\nBasic is SAR 49 a month, billed monthly; the annual plan is SAR 490."
        let states: [(String, [E], Bool)] = [
            ("empty", [], false),
            ("card", [q, .answer(questionID: 1, tier: "T0", text: "Basic: SAR 49 / month. Annual: SAR 490 (2 months free).", provider: nil, done: true)], false),
            ("snippet", [q, .answer(questionID: 1, tier: "T1", text: snippet, provider: nil, done: true)], false),
            ("streaming", [q, .answer(questionID: 1, tier: "T1", text: snippet, provider: nil, done: true),
                           .answer(questionID: 1, tier: "T2", text: "Basic costs SAR 49 a month; annual", provider: "groq", done: false)], false),
            ("not-in-notes", [q, .answer(questionID: 1, tier: "T2", text: "Not in your notes.", provider: "groq", done: true)], false),
            ("ai-off", [q, .answer(questionID: 1, tier: "T1", text: snippet, provider: nil, done: true)], true),
            ("arabic-rtl", [qAR, .answer(questionID: 1, tier: "T2", text: "الباقة الأساسية ٤٩ ريال شهريًا، والسنوية ٤٩٠ ريال.", provider: "groq", done: true)], false),
            ("restarted", [], false),
        ]
        for (name, events, aiOff) in states {
            let m = OverlayModel()
            events.forEach(m.apply)
            m.aiOff = aiOff
            if name == "restarted" { m.sttRestarted = true }
            for dark in [false, true] {
                let url = dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
                try OverlayController.snapshot(m, to: url, dark: dark)
                print("\(m.state.rawValue) -> \(url.path)")
            }
        }
    }
}

/// Set-once ms value shared by the feeders and the pipeline clock.
final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int?
    var value: Int? { lock.withLock { v } }
    func setOnce(_ x: Int) { lock.withLock { if v == nil { v = x } } }
}
#else
@main
struct BenchLatency: ParsableCommand {
    func run() throws { print("bench-latency needs macOS (Dictation STT + AppKit overlay)") }
}
#endif
