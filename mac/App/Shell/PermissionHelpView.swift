import AppKit
import SwiftUI

/// A permission was denied: where to turn it on, and a button that opens that System Settings pane.
struct PermissionHelpView: View {
    let permission: AppState.Permission

    var what: String { permission == .microphone ? "your microphone" : "the call audio" }
    var path: String {
        permission == .microphone
            ? "System Settings > Privacy & Security > Microphone"
            : "System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only"
    }
    /// shortcut: pane anchors are undocumented; if one stops working the button opens Privacy & Security.
    var pane: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?"
            + (permission == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"))!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(title: "Hamsa can't hear \(what)", text: "macOS blocked it. Turn Hamsa on here:")
            Text(path).font(.body.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(permission == .microphone
                 ? "Then quit and reopen Hamsa. Meetings will not start until the microphone is allowed."
                 : "Then quit and reopen Hamsa. Without it Hamsa cannot hear the other side's questions.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Open System Settings") { NSWorkspace.shared.open(pane) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Opens \(path)")
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .topLeading)
    }
}
