import SwiftUI

/// Menu-bar window: status line, Start/Stop (the one primary action), confidential switch, then Prepare,
/// consent line, setup, Quit. Text stays in the primary label colour (secondary grey is under 4.5:1); state is
/// carried by icons and words.
struct MenuBarView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusLine(recording: app.recording, text: app.status)
            if let s = app.lastStop { Notice(icon: "checkmark.circle", text: s) }
            if let e = app.error { Notice(icon: "exclamationmark.triangle.fill", text: e, tint: .red) }

            Button { Task { await app.toggle() } } label: {
                HStack(spacing: 6) {
                    if app.starting || app.stopping { ProgressView().controlSize(.small) }
                    Text(app.starting ? "Starting…" : app.stopping ? "Stopping…" : app.recording ? "Stop meeting" : "Start meeting")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("h", modifiers: [.option, .command])
            .disabled(app.starting || app.stopping)
            .help(app.starting ? "Loading speech models." : "")
            .accessibilityHint(app.recording ? "Stops recording and saves the meeting." : "Starts listening to the call.")

            Toggle("Confidential", isOn: app.confidentialBinding)
                .toggleStyle(.switch)
                .disabled(app.stopping)
                .accessibilityHint("When on, no question is sent to AI providers and the meeting stays out of summaries.")
            Text(app.confidentialText).fixedSize(horizontal: false, vertical: true)

            Divider()
            MenuRow(title: "Prepare a call…") { app.openPrepare() }
                .disabled(app.recording)
                .help(app.recording ? "Stop the meeting first." : "Pick title, project and privacy, then sync cards.")
            MenuRow(title: "Copy consent line") { app.copyConsentLine() }
                .help(AppState.consentLine)
                .accessibilityHint("Copies a sentence asking the other side if transcription is OK.")
            MenuRow(title: "Set up Hamsa…") { app.openSetup() }
            Divider()
            MenuRow(title: "Quit Hamsa") { Task { await app.stop(); NSApplication.shared.terminate(nil) } }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// A menu-like row: label colour, the whole row width is the hit target.
struct MenuRow: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatusLine: View {
    let recording: Bool
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            if recording { Circle().fill(Color.red).frame(width: 9, height: 9).accessibilityHidden(true) }
            Text(text).font(.headline).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recording ? "Recording. \(text)" : "Status: \(text)")
    }
}

struct Notice: View {
    let icon: String
    let text: String
    var tint: Color = .primary
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(tint) }
            .font(.body)
            .accessibilityElement(children: .combine)
    }
}
