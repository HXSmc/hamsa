import AppKit
import HamsaKit
import SwiftUI

/// Launch arguments (test hooks; no clicks are synthesised). Use with HAMSA_HOME=<scratch dir>:
///   --snapshot <dir>         render every screen state to PNGs (0600) and quit
///   --show onboarding|prepare  open that window
///   --status-probe <file>    write the status-item window(s) of this process to <file>
///   --step N                 onboarding step to show
///   --prepare                run Prepare at launch
///   --replay <wav> [--confidential] [--seconds N]  a meeting fed by a recorded call, stopped after N s, then quit
/// No arguments: first launch opens onboarding.
@MainActor
enum ShellLaunch {
    static func value(_ args: [String], _ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    static let hooks = ["--snapshot", "--show", "--status-probe", "--step", "--prepare", "--replay"]

    static func run(_ args: [String], _ app: AppState) async {
        if args.contains(where: hooks.contains) {
            // Test hooks write meetings, files and make live calls: only against a scratch HAMSA_HOME.
            guard let home = HamsaHome.testHome() else {
                FileHandle.standardError.write(Data("Hamsa: test launch arguments need HAMSA_HOME set to a scratch folder. Refused.\n".utf8))
                NSApp.terminate(nil)
                return
            }
            if let out = value(args, "--status-probe"), !home.contains(out) {
                FileHandle.standardError.write(Data("Hamsa: --status-probe must write inside HAMSA_HOME. Refused.\n".utf8))
                NSApp.terminate(nil)
                return
            }
        }
        if let dir = value(args, "--snapshot") {
            await Snapshot.renderAll(app, to: URL(fileURLWithPath: dir))
            NSApp.terminate(nil)
            return
        }
        if let out = value(args, "--status-probe") {  // the menu-bar item (on macOS 26 Control Center owns it in CGWindowList)
            try? await Task.sleep(for: .seconds(1))
            let items = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
                .map { "\(type(of: $0)) frame=\($0.frame) visible=\($0.isVisible) windowNumber=\($0.windowNumber)" }
            try? (items.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        if let s = value(args, "--step").flatMap(Int.init) { app.step = s }
        if args.contains("--prepare") { await app.prepare() }
        if let w = value(args, "--show").flatMap(ShellWindows.Kind.init(rawValue:)) { app.windows.show(w, app) }
        else if !app.settings.onboardingDone && value(args, "--replay") == nil { app.windows.show(.onboarding, app) }
        if let wav = value(args, "--replay") {
            await app.setConfidential(args.contains("--confidential"))
            await app.start(replay: URL(fileURLWithPath: wav))
            let secs = value(args, "--seconds").flatMap(Double.init) ?? 30
            try? await Task.sleep(for: .seconds(secs))
            await app.stop()
            NSApp.terminate(nil)
        }
    }
}

/// Renders the real views, in their real states, from an offscreen window (AppKit controls draw; a screen grab
/// is not needed). Evidence only: the share-hidden overlay is never written here.
@MainActor
enum Snapshot {
    static func renderAll(_ app: AppState, to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func shot(_ name: String, _ view: some View) async {
            for dark in [false, true] {
                await render(AnyView(view.environmentObject(app)), dir.appendingPathComponent(name + (dark ? "-dark" : "") + ".png"), dark: dark)
            }
        }
        // Onboarding 1..4 + Done, in the state this Mac really has (mic status, key present or not).
        for s in 1...5 { app.step = s; await shot("onboarding-\(s)", OnboardingView()) }
        await shot("permission-mic", PermissionHelpView(permission: .microphone))
        await shot("permission-system-audio", PermissionHelpView(permission: .systemAudio))
        // Brain unreachable: a real link test against a closed local port.
        app.step = 3
        app.settings.brainURL = "http://127.0.0.1:9"
        app.brainToken = "snapshot-not-a-token"
        await app.testBrain()
        app.brainToken = ""
        await shot("state-brain-unreachable", OnboardingView())
        // Invalid key: a real check with a made-up key (Groq answers 401; nothing is saved).
        app.step = 4
        let had = app.keyPresent
        app.keyPresent = false  // show the entry field even though a key is saved
        app.keyEntry = "not-a-real-key-snapshot"
        await app.testAndSaveKey()
        await shot("state-invalid-key", OnboardingView())
        app.keyPresent = had
        app.keyEntry = ""
        app.settings = ShellSettings.load(app.home)
        // Prepare: the real sync path with this Mac's settings + Keychain.
        app.status = "Not prepared yet"
        await shot("menu-first-launch", MenuBarView())
        await app.prepare()
        await shot("prepare", PrepareMeetingView())
        await shot("menu-ready", MenuBarView())
        // Display states of the menu (set directly; the live run proves the transitions).
        app.recording = true; app.status = "Recording"
        await shot("menu-recording", MenuBarView())
        await app.setConfidential(true); app.status = "Recording · Confidential: AI answers off"
        await shot("menu-recording-confidential", MenuBarView())
        app.recording = false; app.status = "Stopped"; app.lastStop = "Saved on this Mac. Summary skipped (confidential)."
        await shot("menu-stopped-confidential", MenuBarView())
        app.lastStop = nil; await app.setConfidential(false)
        app.error = "Could not start: microphone permission denied (System Settings > Privacy > Microphone)"
        await shot("menu-start-error", MenuBarView())
        app.error = nil
        for rec in [false, true] {
            app.recording = rec
            await render(AnyView(MenuIcon(state: app).padding(4)), dir.appendingPathComponent("menubar-icon-\(rec ? "recording" : "idle").png"), dark: false)
        }
        app.recording = false
    }

    static func render(_ view: AnyView, _ url: URL, dark: Bool) async {
        let host = NSHostingView(rootView: AnyView(view.background(Color(nsColor: .windowBackgroundColor))))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false  // ARC owns it; a released-on-close window double-frees
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.backgroundColor = .windowBackgroundColor
        w.contentView = host
        try? await Task.sleep(for: .milliseconds(150))  // let SwiftUI apply the state change
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        w.close()
    }
}
