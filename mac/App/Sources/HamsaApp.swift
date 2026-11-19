import AppKit
import SwiftUI
import HamsaKit

@main
struct HamsaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(delegate.state)
        } label: {
            MenuIcon(state: delegate.state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Waveform when idle, a red dot while recording (a non-template image keeps its colour in the menu bar).
struct MenuIcon: View {
    @ObservedObject var state: AppState
    static let dot: NSImage = {
        let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Hamsa is recording")!
            .withSymbolConfiguration(cfg)!
        img.isTemplate = false
        return img
    }()
    var body: some View {
        if state.recording { Image(nsImage: Self.dot).accessibilityLabel("Hamsa, recording") }
        else { Image(systemName: "waveform").accessibilityLabel("Hamsa") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await ShellLaunch.run(CommandLine.arguments, state) }
    }
}
