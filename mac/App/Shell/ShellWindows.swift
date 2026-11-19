import AppKit
import SwiftUI

/// Plain AppKit windows for the menu-bar app (an LSUIElement app has no scene to open them from).
@MainActor
final class ShellWindows {
    enum Kind: String { case onboarding, prepare, permission }
    private var open: [Kind: NSWindow] = [:]

    @discardableResult
    func show(_ kind: Kind, _ state: AppState) -> NSWindow {
        let w = open[kind] ?? make(kind, state)
        open[kind] = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return w
    }

    func close(_ kind: Kind) { open.removeValue(forKey: kind)?.close() }

    static func view(_ kind: Kind, _ state: AppState) -> AnyView {
        switch kind {
        case .onboarding: AnyView(OnboardingView().environmentObject(state))
        case .prepare: AnyView(PrepareMeetingView().environmentObject(state))
        case .permission: AnyView(PermissionHelpView(permission: state.deniedPermission ?? .microphone).environmentObject(state))
        }
    }

    private func make(_ kind: Kind, _ state: AppState) -> NSWindow {
        let host = NSHostingView(rootView: Self.view(kind, state))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = ["onboarding": "Set up Hamsa", "prepare": "Prepare a call", "permission": "Permission needed"][kind.rawValue]!
        w.contentView = host
        w.isReleasedWhenClosed = false
        return w
    }
}
