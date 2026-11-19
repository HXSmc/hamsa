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
    @Published var confidential = false
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
        if let url = URL(string: settings.brainURL), !settings.brainURL.isEmpty,
           let token = ShellKeychain.read(service: ShellKeychain.brain.service, account: ShellKeychain.brain.account) {
            sync = BrainSync(base: url, token: token, dir: home.dir)
        }
        status = await Prepare.run(home: home, brain: sync)
        preparing = false
    }

    // MARK: Start / Stop

    /// `replay`: test hook, a recorded THEM wav instead of mic + system audio.
    func start(replay: URL? = nil) async {
        guard !recording, !starting else { return }
        starting = true
        error = nil
        lastStop = nil
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
            let s = try await MeetingSession(store: store, title: title, project: project, app: replay == nil ? NSWorkspace.shared.frontmostApplication?.localizedName : "replay",
                                             confidential: confidential, llm: llm, embedder: embedder, index: index, cards: cards,
                                             shown: AppOverlay.shown(ov), now: now)
            await AppOverlay.start(ov, store: store, meeting: s.id)
            session = s; overlay = ov
            recording = true
            status = confidential ? "Recording · Confidential: AI answers off" : "Recording"
            if #available(macOS 26, *) {
                let a = MeetingAudio()
                audio = a
                do { try await a.start(pipeline: s.pipeline, store: store, meeting: s.id, replay: replay, now: now) }
                catch { await stop(); report(error) }
            } else {
                await stop()
                error = "Transcription needs macOS 26."
            }
        } catch {
            report(error)
        }
    }

    private func report(_ e: Error) {
        let text = "\(e)"
        if text.contains("microphone permission") { deniedPermission = .microphone; windows.show(.permission, self) }
        else if text.contains("process tap") { deniedPermission = .systemAudio; windows.show(.permission, self) }
        error = "Could not start: \(text)"
    }

    func stop() async {
        guard let s = session else { return }
        if #available(macOS 26, *), let a = audio as? MeetingAudio { await a.stop() }
        audio = nil
        let summary = (try? await s.stop()) ?? false
        if let ov = overlay { AppOverlay.end(ov) }
        session = nil; overlay = nil
        recording = false
        lastStop = summary ? "Saved on this Mac." : "Saved on this Mac. Summary skipped (confidential)."
        status = "Stopped"
    }

    func toggle() async { if recording { await stop() } else { await start() } }

    /// Mid-call switch: goes through the pipeline's latch + stored row only.
    func setConfidentialLive(_ on: Bool) async {
        confidential = on
        guard let s = session else { return }
        do { try await s.setConfidential(on) } catch { self.error = "Confidential switch not saved; AI answers stay off." }
        status = on ? "Recording · Confidential: AI answers off" : "Recording"
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
        let entered = brainToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty, !ShellKeychain.isPlainToken(entered) { brain = .failed("The token has characters a brain token never has."); return }
        guard let token = entered.isEmpty ? ShellKeychain.read(service: ShellKeychain.brain.service, account: ShellKeychain.brain.account) : entered else {
            brain = .failed("Paste the brain token first."); return
        }
        var req = URLRequest(url: base.appendingPathComponent("healthz"), timeoutInterval: 5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                if !entered.isEmpty { ShellKeychain.save(service: ShellKeychain.brain.service, account: ShellKeychain.brain.account, secret: entered) }
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
