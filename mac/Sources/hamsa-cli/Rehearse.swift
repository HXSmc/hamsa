#if os(macOS)
import AppKit
import ArgumentParser
import Foundation
import HamsaKit

/// T02a: mock call. Each turn `say` plays the caller's question to system audio ("them"), then a share-hidden
/// panel shows the line to speak (verbatim) or a topic cue (own words) while the mic records "me".
/// Writes `<stem>.wav`, `<stem>.me.wav` and `<stem>.labels.json` (CallLabels) next to each other in --out.
struct Rehearse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mock call from a JSONL script: say plays questions (them), a panel shows your answers (me).")

    @Option(help: "Script: one JSON turn per line {lang, question, answer|null, cue|null, tech}.") var script: String
    @Option(help: "Output folder, e.g. ../bench/calls (files are named after the script: call-01.wav, ...).") var out: String
    @Option(help: "Fixed answer window in seconds (default: sized to the line, cue turns 20 s).") var answerSeconds: Double?
    @Option(help: "Silence before each question, seconds.") var gap: Double = 1.0
    @Option(help: "Voice for Arabic questions.") var arVoice = "Majed"
    @Option(help: "Voice for English questions.") var enVoice = "Samantha"
    @Flag(help: "Overwrite existing output files.") var force = false

    struct Turn: Decodable {
        var lang: String
        var question: String
        var answer: String?
        var cue: String?
        var tech: Bool?
    }

    @MainActor
    func run() async throws {
        let scriptURL = URL(fileURLWithPath: NSString(string: script).expandingTildeInPath)
        let turns = try Self.load(scriptURL)
        let stem = scriptURL.deletingPathExtension().lastPathComponent
        let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = (them: "\(stem).wav", me: "\(stem).me.wav", labels: "\(stem).labels.json")
        let labelsURL = dir.appendingPathComponent(names.labels)
        if !force, FileManager.default.fileExists(atPath: labelsURL.path) {
            throw ValidationError("\(labelsURL.path) exists (maybe the synthetic call from make-synth-call.sh); pass --force to overwrite")
        }
        let verbatimTurns = turns.filter { $0.answer != nil }.count
        print("SCRIPT \(stem): turns=\(turns.count) verbatim=\(verbatimTurns) cue=\(turns.count - verbatimTurns)")

        let keys = ReturnKeys()
        keys.start()
        if isatty(STDIN_FILENO) == 1 {
            print("READY: headphones on. Press Return to start; during each answer press Return when done.")
            let base = keys.count
            while keys.count == base && !keys.eof { try? await Task.sleep(for: .milliseconds(100)) }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let panel = RehearsePanel()

        print("ALLOW_NEEDED: macOS may ask for microphone + system audio recording permission")
        let session = try Session(dir: dir, names: names)
        session.installInterruptHandler()

        // provisional=false: this IS the T02a corpus (owner's real voice on "me"; "them" is TTS, see ADR 001).
        var labels = CallLabels(audio: ["them": names.them, "me": names.me], provisional: false, items: [])
        try Self.write(labels, to: labelsURL)  // a --force re-take must never keep the old take's labels
        func ms(_ s: Double) -> Double { (s * 1000).rounded() / 1000 }

        for (i, t) in turns.enumerated() {
            let n = "\(i + 1)/\(turns.count)"
            panel.show(header: "\(n) · listen", body: "…", footer: "")
            try? await Task.sleep(for: .seconds(gap))

            let qStart = session.them.elapsed
            try await session.say(t.question, voice: t.lang == "ar" ? arVoice : enVoice)
            let qEnd = session.them.elapsed
            labels.items.append(.init(channel: "them", start: ms(qStart), end: ms(qEnd), text: t.question,
                                      isQuestion: true, tech: t.tech ?? false, verbatim: true, lang: t.lang))

            let verbatim = t.answer != nil
            let text = t.answer ?? t.cue ?? ""
            let seconds = answerSeconds ?? (verbatim ? max(5, 2 + Double(text.count) * 0.085) : 20)
            let header = verbatim ? "\(n) · say exactly / قلها حرفياً" : "\(n) · own words / بكلامك"
            panel.show(header: header, body: text, footer: "")
            let aStart = session.them.elapsed
            let base = keys.count
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
            while ContinuousClock.now < deadline && keys.count == base {
                let left = Int((deadline - ContinuousClock.now).components.seconds) + 1
                panel.setFooter("\(left) s · Return = next")
                try? await Task.sleep(for: .milliseconds(100))
            }
            let aEnd = session.them.elapsed
            // Cue turns: text stays empty (WER reference must not contain the cue); label it later.
            labels.items.append(.init(channel: "me", start: ms(aStart), end: ms(aEnd), text: t.answer ?? "",
                                      isQuestion: false, tech: t.tech ?? false, verbatim: verbatim,
                                      lang: verbatim ? Self.lang(of: text) : nil, cue: t.cue))
            try Self.write(labels, to: labelsURL)
            // them_s/me_s = seconds written so far; both should track a= end (drift check).
            print(String(format: "TURN %@ q=%.2f-%.2f a=%.2f-%.2f %@ them_s=%.2f me_s=%.2f", n, qStart, qEnd, aStart,
                         aEnd, verbatim ? "verbatim" : "cue", session.them.seconds, session.me.seconds))
        }

        panel.close()
        session.finish()
        try Self.write(labels, to: labelsURL)
        print(String(format: "them.wav rms_dbfs=%.1f seconds=%.2f", session.them.rmsDbfs, session.them.seconds))
        print(String(format: "me.wav rms_dbfs=%.1f seconds=%.2f", session.me.rmsDbfs, session.me.seconds))
        print("LABELS \(labelsURL.path) items=\(labels.items.count)")
        for (n, w) in [("them", session.them), ("me", session.me)] { if let e = w.firstError { print("WARN: \(n) write: \(e)") } }
    }

    static func load(_ url: URL) throws -> [Turn] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        let turns = try lines.enumerated().compactMap { i, line -> Turn? in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            let t = try JSONDecoder().decode(Turn.self, from: Data(line.utf8))
            guard (t.answer == nil) != (t.cue == nil), ["ar", "en"].contains(t.lang) else {
                throw ValidationError("\(url.lastPathComponent):\(i + 1): need lang ar|en and exactly one of answer/cue")
            }
            return t
        }
        guard !turns.isEmpty else { throw ValidationError("\(url.path): no turns") }
        return turns
    }

    static func lang(of text: String) -> String {
        text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } ? "ar" : "en"
    }

    static func write(_ labels: CallLabels, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(labels).write(to: url, options: .atomic)
    }
}

/// Capture (same order as `Capture`: mic first, then the tap) plus the running `say` child process.
/// `say` must be a child process: the tap excludes this process, so in-process speech would not be recorded.
private final class Session: @unchecked Sendable {
    let them: WavWriter
    let me: WavWriter
    private let mic = MicCapture()
    private var stopTap: () -> Void = {}
    private let lock = NSLock()
    private var current: Process?
    private var finished = false
    private var interrupted = false
    private let finishLock = NSLock()
    private var signalSource: DispatchSourceSignal?

    init(dir: URL, names: (them: String, me: String, labels: String)) throws {
        them = try WavWriter(url: dir.appendingPathComponent(names.them))
        me = try WavWriter(url: dir.appendingPathComponent(names.me))
        try mic.start { [me] in me.append($0) }
        guard #available(macOS 14.2, *) else { mic.stop(); throw AudioError("system audio tap needs macOS 14.2+") }
        let tap = SystemTap()
        do { try tap.start { [them] in them.append($0) } } catch { mic.stop(); throw error }
        stopTap = { tap.stop() }
    }

    func say(_ text: String, voice: String) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, text]
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run(); track(p) } catch { p.terminationHandler = nil; c.resume(throwing: error) }
        }
        lock.withLock { current = nil }
        // Ctrl-C killed `say`: let the signal handler finalize and exit instead of throwing past it.
        while lock.withLock({ interrupted }) { try? await Task.sleep(for: .seconds(1)) }
        if p.terminationStatus != 0 { throw AudioError("say exited \(p.terminationStatus) (voice \(voice) installed?)") }
    }

    private func track(_ p: Process) { lock.withLock { current = p } }

    /// Ctrl-C: stop `say`, finalize both WAVs (labels are rewritten after every turn), exit 130.
    func installInterruptHandler() {
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler { [self] in
            lock.withLock { interrupted = true; return current }?.terminate()
            finish()
            print("\nINTERRUPTED: audio finalized, labels hold the completed turns")
            Foundation.exit(130)
        }
        src.resume()
        signalSource = src
    }

    /// Idempotent; a second caller waits until the first has finalized the files.
    func finish() {
        finishLock.withLock {
            guard !finished else { return }
            finished = true
            stopTap()
            mic.stop()
            them.finish(); me.finish()
        }
    }
}

/// Counts Return presses on stdin from a background thread. EOF (no terminal) just stops counting.
private final class ReturnKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var ended = false
    var count: Int { lock.withLock { n } }
    var eof: Bool { lock.withLock { ended } }

    func start() {
        Thread.detachNewThread { [self] in
            while readLine() != nil { lock.withLock { n += 1 } }
            lock.withLock { ended = true }
        }
    }
}

/// The T04b overlay (share-hidden) with a header, the line to speak, and a countdown footer.
@MainActor
private final class RehearsePanel {
    private let header = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let panel: NSPanel

    init() {
        let size = NSSize(width: 460, height: 230)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: 20)
        body.preferredMaxLayoutWidth = size.width - 32
        footer.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        footer.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, body, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        panel = OverlayPanel.make(title: "Hamsa rehearse", size: size, content: stack)
        panel.orderFrontRegardless()
    }

    func show(header h: String, body b: String, footer f: String) {
        header.stringValue = h
        let rtl = Rehearse.lang(of: b) == "ar"
        body.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        body.alignment = rtl ? .right : .left
        body.stringValue = b
        footer.stringValue = f
        panel.contentView?.display()
    }

    func setFooter(_ f: String) {
        guard footer.stringValue != f else { return }
        footer.stringValue = f
        panel.contentView?.display()
    }

    func close() { panel.close() }
}
#endif
