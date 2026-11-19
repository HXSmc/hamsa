import ArgumentParser
import Foundation
@_spi(Bench) import HamsaKit

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
    @Flag(help: "Show a fixture card and post one synthetic click on its pin button (only if the overlay is under the pointer).")
    var clickTest = false

    /// Bench meetings end as `queued`; kept out of the app's live.sqlite so the summarizer never picks them up.
    static let defaultDB = "~/Library/Application Support/Hamsa/bench-live.sqlite"

    static func path(_ p: String) -> URL { URL(fileURLWithPath: NSString(string: p).expandingTildeInPath) }
    static func ms(_ d: Duration) -> Int { Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000) }
    static func nonEmpty(_ u: URL) -> Bool { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int ?? 0) > 0 }

    @MainActor
    func run() async throws {
        if clickTest { return await Self.clickTest() }
        if let dir = snapshot, replay == nil { return try await Self.renderFixtures(Self.path(dir)) }
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
            o.model.live = true
            o.show()
            o.model.aiOff = try await store.privacy(meeting: meeting).confidential  // read only, never written
            overlay = o
            print("# overlay window=\(o.panel.windowNumber) kCGWindowSharingState=\(o.sharingState.map(String.init) ?? "not listed")")
        }
        let frames = snapshot.map(Self.path)
        if let frames { try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true) }
        var shown: LivePipeline.Shown?
        if let o = overlay {
            let saver = FrameSaver(dir: frames)
            shown = { e in
                let changed = await o.commit(e)
                // After the hook returns (the stamp is taken then) and after the 150 ms slide-in: never delays t_shown_ms.
                if changed { Task { @MainActor in try? await Task.sleep(for: .milliseconds(200)); saver.save(o) } }
                return changed
            }
        }
        let pipeline = LivePipeline(store: store, meeting: meeting, embedder: embedder, index: idx, cards: cardMatcher, llm: llm,
                                    shown: shown, now: now)

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

        // Real-time feed: 100 ms chunks on the wall clock; chunk 0 = wav time 0 = pipeline time 0.
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
        try await store.endMeeting(id: meeting)
        if let o = overlay {
            print("# overlay kCGWindowSharingState at end=\(o.sharingState.map(String.init) ?? "not listed")")
            o.model.live = false
            o.close()
        }

        let s = await pipeline.stats
        print("# meeting=\(meeting) db=\(dbURL.path) questions=\(s.questions) T0=\(s.t0) T1=\(s.t1) T2=\(s.t2) t2_starts=\(s.t2Starts) t2_errors=\(s.t2Errors.values.reduce(0, +)) store_errors=\(s.storeErrors)")
        let k = try LatencyKPI(db: dbURL.path, meeting: meeting)
        let l = Self.labelBased(k, labels: lab, askers: ["them"])
        print("# t_question_end: STT final end (pipeline) vs hand label (03-tdd:76); label_matched=\(l.firstText.count)/\(k.firstText.count)")
        print("first_text_p50_ms=\(LatencyKPI.pct(Array(k.firstText.values), 50)) t2_first_token_p50_ms=\(LatencyKPI.pct(k.tiers["T2"] ?? [], 50)) t0_match_p50_ms=\(LatencyKPI.pct(k.tiers["T0"] ?? [], 50)) t1_p50_ms=\(LatencyKPI.pct(k.tiers["T1"] ?? [], 50)) n_questions=\(s.questions) input=\(wavs[0].lastPathComponent) PROVISIONAL=\(lab.provisional) first_text_label_p50_ms=\(LatencyKPI.pct(l.firstText, 50)) t2_first_token_label_p50_ms=\(LatencyKPI.pct(l.t2, 50)) stt_end_bias_p50_ms=\(LatencyKPI.pct(l.bias, 50))")
    }
    #endif

    /// 03-tdd:76: first_text_ms against the hand-labelled question end. Each question row is matched to the labelled
    /// question (asker channel) whose window [start - 1 s, end + 3 s] holds its STT end, nearest end first.
    /// bias = STT end - label end (positive = STT ends later, so the STT-based number flatters).
    static func labelBased(_ k: LatencyKPI, labels: CallLabels, askers: Set<String>) -> (firstText: [Int], t2: [Int], bias: [Int]) {
        let qs = labels.questions.filter { askers.contains($0.channel) }
        var first: [Int] = [], t2: [Int] = [], bias: [Int] = []
        for (id, end) in k.questionEnd.sorted(by: { $0.key < $1.key }) {
            let near = qs.filter { Int($0.start * 1000) - 1000 <= end && end <= Int($0.end * 1000) + 3000 }
                .min { abs(Int($0.end * 1000) - end) < abs(Int($1.end * 1000) - end) }
            guard let near else { continue }
            let b = end - Int(near.end * 1000)
            bias.append(b)
            if let f = k.firstText[id] { first.append(f + b) }
            if let f = k.t2First[id] { t2.append(f + b) }
        }
        return (first, t2, bias)
    }

    /// Fixture states of the overlay (live data cannot reach card / Arabic answer states: no cards, generic call).
    @MainActor
    static func renderFixtures(_ dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        typealias E = LivePipeline.Event
        let q = E.question(id: 1, channel: "them", text: "What is the monthly price of the basic plan?")
        let qAR = E.question(id: 1, channel: "them", text: "كم سعر الباقة الشهرية؟")
        // Shaped like a real index hit: heading path with markdown, bullets, blank lines, a cut last sentence.
        let snippet = "Pricing > ## Plans > `Basic` (2026)\n- **Basic:** SAR 49 a month, billed monthly.\n\n- The annual plan is SAR 490, two months free.\nUpgrades are pro-rated from the day of"
        let t1 = E.answer(questionID: 1, tier: "T1", text: snippet, provider: nil, done: true)
        let refusal = E.answer(questionID: 1, tier: "T2", text: "Not in your notes.", provider: "groq", done: true)
        let states: [(String, [E], Bool)] = [
            ("listening", [], false),
            ("searching", [q], false),
            ("card", [q, .answer(questionID: 1, tier: "T0", text: "Basic: SAR 49 / month. Annual: SAR 490 (2 months free).", provider: nil, done: true)], false),
            ("snippet", [q, t1], false),
            ("streaming", [q, t1, .answer(questionID: 1, tier: "T2", text: "Basic costs SAR 49 a month; annual", provider: "groq", done: false)], false),
            ("refusal-prefix-held", [q, t1, .answer(questionID: 1, tier: "T2", text: "Not in", provider: "groq", done: false)], false),
            ("not-in-notes", [q, t1, refusal], false),
            ("not-in-notes-arabic", [qAR, refusal], false),
            ("ai-off", [q, t1], true),
            ("ai-off-no-hit", [q], true),
            ("failed", [q, .answerFailed(questionID: 1)], false),
            ("arabic-rtl", [qAR, .answer(questionID: 1, tier: "T2", text: "الباقة الأساسية ٤٩ ريال شهريًا، والسنوية ٤٩٠ ريال.", provider: "groq", done: true)], false),
            ("restarted", [], false),
        ]
        for (name, events, aiOff) in states {
            let m = OverlayModel()
            m.live = true
            m.aiOff = aiOff
            events.forEach { m.apply($0) }
            if name == "restarted" { m.sttRestarted = true }
            for dark in [false, true] {
                let url = dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
                try OverlayController.snapshot(m, to: url, dark: dark)
                print("\(m.state.rawValue) -> \(url.path)")
            }
        }
        // The live path (controller.commit, then capture), never shown on screen: must draw "Searching", not "Listening".
        let o = OverlayController()
        o.model.live = true
        o.model.aiOff = false
        await o.commit(q)
        // Right after commit the 150 ms slide-in has just started (the live "searching" frames showed "Listening" for
        // this reason); 200 ms later the card is in place.
        for (wait, name) in [(0, "controller-commit-0ms.png"), (200, "controller-commit-200ms.png")] {
            try? await Task.sleep(for: .milliseconds(wait))
            let url = dir.appendingPathComponent(name)
            try o.capture(to: url)
            print("controller \(o.model.state.rawValue) +\(wait) ms -> \(url.path)")
        }
        o.close()
    }

    /// One synthetic click on the pin button of a fixture card in the real overlay (top-right of the main screen).
    /// The click is posted only when the window under the pointer is the overlay, so it can never land in another app.
    @MainActor
    static func clickTest() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        await clickBody()
    }

    /// Event monitors and button clicks need AppKit's event loop (the app runs one; this CLI pumps it, bounded).
    @MainActor
    static func pump(_ ms: Int) {
        let end = Date(timeIntervalSinceNow: Double(ms) / 1000)
        while let e = NSApp.nextEvent(matching: .any, until: end, inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
    }

    /// Transparent system layers (Dock, Notification Center) span the screen above every app window; they are not
    /// what a click at the overlay hits unless they draw there.
    static let systemOverlays: Set<String> = ["Dock", "Notification Center", "Window Server"]

    @MainActor
    static func clickBody() async {
        let o = OverlayController()
        o.model.live = true
        o.model.aiOff = false
        await o.commit(.question(id: 1, channel: "them", text: "What is the monthly price?"))
        await o.commit(.answer(questionID: 1, tier: "T1", text: "Pricing > Plans\nBasic is SAR 49 a month.", provider: nil, done: true))
        o.show()
        pump(400)
        let r = o.model.buttonsRect  // hosting-view coordinates, top-left origin; pin = last 32 pt button
        let local = NSPoint(x: r.maxX - 16, y: o.panel.frame.height - r.midY)
        let screenPt = o.panel.convertPoint(toScreen: local)
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let target = CGPoint(x: screenPt.x, y: primaryH - screenPt.y)  // CG global: top-left origin
        let home = CGEvent(source: nil)?.location ?? target
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, target)
        pump(400)
        let accepts = !o.panel.ignoresMouseEvents
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let top = windows.first { Self.contains($0, target) && !systemOverlays.contains($0[kCGWindowOwnerName as String] as? String ?? "") }
        let topIsOverlay = (top?[kCGWindowNumber as String] as? Int) == o.panel.windowNumber
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let overlayRank = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == o.panel.windowNumber }
        print("# click_test buttons_rect=\(r) cursor_after_move=\(Int(cursor.x)),\(Int(cursor.y)) overlay_rank=\(overlayRank.map(String.init) ?? "absent") windows_above=\(windows.prefix(overlayRank ?? 0).filter { Self.contains($0, target) }.map { "\($0[kCGWindowOwnerName as String] ?? "?")/layer \($0[kCGWindowLayer as String] ?? "?")" })")
        print("# click_test target=\(Int(target.x)),\(Int(target.y)) panel_accepts_mouse=\(accepts) top_window_is_overlay=\(topIsOverlay) top_owner=\(top?[kCGWindowOwnerName as String] as? String ?? "none")")
        let seen = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            let hit = o.panel.contentView?.hitTest(e.locationInWindow).map { String(describing: type(of: $0)) } ?? "nil"
            print("# click_test app got \(e.type == .leftMouseDown ? "down" : "up") window=\(e.windowNumber) at=\(e.locationInWindow) hit=\(hit)")
            return e
        }
        defer { seen.map(NSEvent.removeMonitor) }
        if accepts, topIsOverlay {
            post(.leftMouseDown, target)
            pump(60)
            post(.leftMouseUp, target)
            pump(400)
            print("click_test pinned_after_first_click=\(o.model.pinned)")
        } else {
            print("click_test skipped: the pointer is not over the overlay's buttons, a click could reach another app")
        }
        post(.mouseMoved, home)
        o.model.live = false
        o.close()
    }
}

extension BenchLatency {
    static func contains(_ w: [String: Any], _ p: CGPoint) -> Bool {
        guard let b = w[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: b) else { return false }
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        return alpha > 0 && rect.contains(p)
    }
}

/// Live frames for the evidence folder: one per question and state, written 0600.
@MainActor
final class FrameSaver {
    let dir: URL?
    var last = ""
    init(dir: URL?) { self.dir = dir }
    func save(_ o: OverlayController) {
        guard let dir else { return }
        let key = "\(o.model.questionID ?? 0)-\(o.model.state.rawValue)"
        guard key != last else { return }
        last = key
        do { try o.capture(to: dir.appendingPathComponent("live-q\(key).png")) } catch { print("# WARN: frame \(key): \(error)") }
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
