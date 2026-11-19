import AppKit
import AVFoundation
import HamsaKit
import SwiftUI

/// T13: the menu-bar app's state and actions. Views only read it and call its methods.
@MainActor
final class AppState: ObservableObject {
    enum Permission { case microphone, systemAudio }
    enum KeyCheck: Equatable { case none, checking, saved, failed(String) }
    enum BrainCheck: Equatable { case none, checking, ok, failed(String) }

    let home = HamsaHome.current()
    @Published var settings: ShellSettings

    // Status + meeting
    @Published var status = "Not prepared yet"
    @Published var preparing = false
    @Published var recording = false
    @Published var starting = false
    @Published var stopping = false
    /// Change only through `setConfidential`: it is the one path to the live meeting.
    @Published private(set) var confidential = false
    /// This meeting was confidential at some point: it stays out of summaries even after the switch goes OFF.
    @Published private(set) var localOnly = false
    @Published var title = ""
    @Published var agenda = ""
    @Published var lastStop: String?
    @Published var error: String?

    // Onboarding
    @Published var step = 1
    @Published var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var systemAudioAsked = false
    @Published var deniedPermission: Permission?
    @Published var brainToken = ""
    @Published var brain = BrainCheck.none
    @Published var keyEntry = ""
    @Published var key = KeyCheck.none
    @Published var keyPresent = ShellKeychain.has(service: ShellKeychain.groq.service, account: ShellKeychain.groq.account)

    private var session: MeetingSession?
    private var audio: AnyObject?
    private var overlay: OverlayController?
    private var stopTask: Task<Void, Never>?
    let windows = ShellWindows()

    init() {
        settings = ShellSettings.load(home)
        title = Self.defaultTitle()
    }

    var projects: [String] { Prepare.projects(home.index) }
    var brainTokenPresent: Bool { ShellKeychain.has(service: ShellKeychain.brain.service, account: ShellKeychain.brain.account) }

    /// "<App> call <date>": app = the frontmost app (NSWorkspace, no Accessibility permission).
    static func defaultTitle() -> String {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Hamsa"
        let name = app == "Hamsa" ? "Meeting" : app
        return "\(name) call \(Date().formatted(date: .abbreviated, time: .omitted))"
    }

    func saveSettings() { try? settings.save(home) }

    // MARK: Prepare

    func prepare() async {
        preparing = true
        status = "Preparing…"
        saveSettings()
        var sync: BrainSync?
        if let url = linkedBrain, let token = ShellKeychain.read(service: ShellKeychain.brain.service, account: ShellKeychain.brain.account) {
            sync = BrainSync(base: url, token: token, dir: home.dir)
        }
        status = await Prepare.run(home: home, brain: sync)
        preparing = false
    }

    /// The saved brain address, if the Keychain token was saved for exactly it and the scheme rules allow it.
    var linkedBrain: URL? {
        let addr = settings.brainURL.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty, settings.brainTokenFor == addr, let url = URL(string: addr), BrainLink.isAllowed(url) else { return nil }
        return url
    }

    // MARK: Start / Stop

    /// `replay`: test hook, a recorded THEM wav instead of mic + system audio.
    func start(replay: URL? = nil) async {
        guard !recording, !starting, !stopping else { return }
        starting = true
        error = nil
        lastStop = nil
        localOnly = confidential
        defer { starting = false }
        do {
            try FileManager.default.createDirectory(at: home.dir, withIntermediateDirectories: true)
            let store = try LiveStore(path: home.live.path)
            let embedder: (any Embedder)? = try? await E5Embedder.load()
            let project = settings.project
            let index = Self.nonEmpty(home.index) ? try? LocalIndex(path: home.index.path, projectID: project) : nil
            let cards = Prepare.cardCount(home.cards) > 0 ? try? CardMatcher(path: home.cards.path, projectID: project) : nil
            // The chain always gets built; a confidential meeting is stopped at the pipeline's send gate.
            let llm = AnswerLLM(providers: PipelineProviders.chain(key: PipelineProviders.keychainKey))
            let ov = OverlayController()
            let clock = ContinuousClock(), t0 = clock.now
            let now: @Sendable () -> Int = { let c = t0.duration(to: clock.now).components; return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000) }
            let startedWith = confidential
            let s = try await MeetingSession(store: store, title: title, project: project, app: replay == nil ? NSWorkspace.shared.frontmostApplication?.localizedName : "replay",
                                             confidential: startedWith, llm: llm, embedder: embedder, index: index, cards: cards,
                                             shown: AppOverlay.shown(ov), now: now)
            session = s; overlay = ov
            // A flip made while the session was being built: apply it before any audio (no audio = no question).
            if confidential != startedWith { await apply(confidential, to: s) }
            await AppOverlay.start(ov, store: store, meeting: s.id)
            recording = true
            status = recordingStatus
            if #available(macOS 26, *) {
                let a = MeetingAudio()
                audio = a
                do { try await a.start(pipeline: s.pipeline, store: store, meeting: s.id, replay: replay, now: now) }
                catch { await stop(showResult: false); report(error) }
            } else {
                await stop(showResult: false)
                error = "Transcription needs macOS 26. Update macOS to use Hamsa in calls."
            }
        } catch {
            report(error)
        }
    }

    /// What the Confidential switch means right now, in plain words.
    var confidentialText: String {
        if confidential { return "AI answers off. Cards and notes only. This meeting stays out of summaries." }
        if localOnly { return "AI answers on again. This meeting stays out of summaries: part of it was confidential." }
        return "AI answers on for questions your cards miss."
    }

    private var recordingStatus: String { confidential ? "Recording · Confidential: AI answers off" : "Recording" }

    private func report(_ e: Error) {
        switch e {
        case AudioStartError.microphone:
            deniedPermission = .microphone; windows.show(.permission, self)
            error = "Hamsa can't use the microphone. Allow it in System Settings, then start again."
        case AudioStartError.systemAudio:
            deniedPermission = .systemAudio; windows.show(.permission, self)
            error = "Hamsa can't hear the call audio. Allow System Audio Recording in System Settings, then start again."
        default:
            error = "Could not start the meeting. Try again; if it keeps failing, quit and reopen Hamsa. (\(e))"
        }
    }

    /// Clears `session` before any await, so Stop then Quit (or a double click) closes the meeting once; a second
    /// caller waits for the first. `showResult: false` = a failed Start tearing down (no "Saved on this Mac.").
    func stop(showResult: Bool = true) async {
        if let t = stopTask { await t.value; return }
        guard let s = session else { return }
        session = nil
        stopping = true
        status = "Stopping…"
        let a = audio, ov = overlay
        audio = nil; overlay = nil
        let t = Task {
            if #available(macOS 26, *), let a = a as? MeetingAudio { await a.stop() }
            do {
                let summary = try await s.stop()
                if showResult { lastStop = summary ? "Saved on this Mac." : "Saved on this Mac. Summary skipped (confidential)." }
                status = "Stopped"
            } catch {
                lastStop = nil
                self.error = "Could not close the meeting on this Mac (\(error)). What was said so far is kept."
                status = "Stopped with an error"
            }
            if let ov { AppOverlay.end(ov) }
            recording = false
            stopping = false
        }
        stopTask = t
        await t.value
        stopTask = nil
    }

    func toggle() async { if recording { await stop() } else { await start() } }

    /// The one Confidential setter (menu and Prepare). Before Start it only sets the value Start opens the row
    /// with; while starting, Start applies it once the session exists; during a meeting it goes to the pipeline
    /// latch + stored row. Turning it ON during a meeting keeps that meeting out of summaries for good.
    func setConfidential(_ on: Bool) async {
        confidential = on
        if on && (starting || session != nil) { localOnly = true }
        guard let s = session else { return }
        await apply(on, to: s)
    }

    /// Toggle binding for every Confidential switch: writes go through `setConfidential`.
    var confidentialBinding: Binding<Bool> {
        Binding(get: { self.confidential }, set: { on in Task { await self.setConfidential(on) } })
    }

    private func apply(_ on: Bool, to s: MeetingSession) async {
        do { try await s.setConfidential(on) } catch {
            if on { self.error = "Confidential was not fully saved. AI answers are off and this meeting stays out of summaries." }
            else { confidential = true; self.error = "Could not turn Confidential off. AI answers stay off." }
        }
        if recording { status = recordingStatus }
    }

    static let consentLine = "Quick note: I use an assistant on my Mac that transcribes this call to help me answer. Is that OK with you?"
    func copyConsentLine() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.consentLine, forType: .string)
    }

    static func nonEmpty(_ u: URL) -> Bool { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int ?? 0) > 0 }

    // MARK: Onboarding

    func requestMic() async {
        if mic == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .authorized { step = 2 } else { deniedPermission = .microphone; windows.show(.permission, self) }
    }

    /// macOS has no public status call for system-audio capture: opening a tap once asks (first time) or fails.
    func requestSystemAudio() {
        systemAudioAsked = true
        guard #available(macOS 14.2, *) else { return }
        let tap = SystemTap()
        do { try tap.start { _ in }; tap.stop(); step = 3 }
        catch { deniedPermission = .systemAudio; windows.show(.permission, self) }
    }

    func testBrain() async {
        brain = .checking
        let url = settings.brainURL.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: url), base.scheme == "http" || base.scheme == "https", base.host != nil else {
            brain = .failed("That address does not look right. Example: http://100.64.0.1:8770"); return
        }
        guard BrainLink.isAllowed(base) else {
            brain = .failed("Plain http is only for Tailscale addresses (100.x or *.ts.net). Use https for this address."); return
        }
        let entered = brainToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty, !ShellKeychain.isPlainToken(entered) { brain = .failed("The token has characters a brain token never has."); return }
        // The stored token only goes to the address it was saved for.
        if entered.isEmpty, settings.brainTokenFor != url {
            brain = .failed(brainTokenPresent ? "The saved token is for another address. Paste the token for this one." : "Paste the brain token first."); return
        }
        guard let token = entered.isEmpty ? ShellKeychain.read(service: ShellKeychain.brain.service, account: ShellKeychain.brain.account) : entered else {
            brain = .failed("Paste the brain token first."); return
        }
        var req = URLRequest(url: base.appendingPathComponent("healthz"), timeoutInterval: 5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                if !entered.isEmpty {
                    guard ShellKeychain.save(service: ShellKeychain.brain.service, account: ShellKeychain.brain.account, secret: entered) else {
                        brain = .failed("The brain answered but the Keychain did not save the token."); return
                    }
                    settings.brainTokenFor = url
                }
                brainToken = ""
                saveSettings()
                brain = .ok
            case 401, 403: brain = .failed("The brain refused this token.")
            case let c: brain = .failed("The brain answered with error \(c).")
            }
        } catch {
            brain = .failed("Could not reach the brain. Check that the mini PC is on and Tailscale is connected.")
        }
    }

    func testAndSaveKey() async {
        let k = keyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ShellKeychain.isPlainToken(k) else { key = .failed("That does not look like an API key."); return }
        key = .checking
        key = await Self.checkGroq(k)
        if key == .saved {
            guard ShellKeychain.save(service: ShellKeychain.groq.service, account: ShellKeychain.groq.account, secret: k) else {
                key = .failed("The key works but the Keychain did not save it."); return
            }
            keyEntry = ""
            keyPresent = true
        }
    }

    /// GET /models with the key: 200 = works. Never logs the key.
    static func checkGroq(_ k: String) async -> KeyCheck {
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!, timeoutInterval: 8)
        req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return .saved }
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            let text = msg ?? "error \(code)"
            return .failed("Groq said: \(text)\(text.hasSuffix(".") ? "" : ".")")
        } catch {
            return .failed("Could not reach Groq: \(error.localizedDescription)")
        }
    }

    func finishOnboarding() {
        settings.onboardingDone = true
        saveSettings()
        windows.close(.onboarding)
    }
}
