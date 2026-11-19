import SwiftUI

/// Menu-bar window: status line, Prepare, Start/Stop, confidential switch, consent line, setup, Quit.
/// Text stays in the primary label colour (secondary grey is under 4.5:1); state is carried by icons and words.
struct MenuBarView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusLine(recording: app.recording, text: app.status)
            if let s = app.lastStop { Notice(icon: "checkmark.circle", text: s) }
            if let e = app.error { Notice(icon: "exclamationmark.triangle.fill", text: e, tint: .red) }

            Toggle("Confidential", isOn: Binding(get: { app.confidential },
                                                  set: { on in Task { await app.setConfidentialLive(on) } }))
                .toggleStyle(.switch)
                .accessibilityHint("When on, no question is sent to AI providers and no summary is made.")
            Text(app.confidential ? "AI answers off. Cards and notes only. No summary." : "AI answers on for questions your cards miss.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)

            Divider()
            Button(app.recording ? "Stop meeting" : "Start meeting") { Task { await app.toggle() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("h", modifiers: [.option, .command])
                .disabled(app.starting)
                .accessibilityHint(app.recording ? "Stops recording and saves the meeting." : "Starts listening to the call.")
            if app.starting { Text("Starting… loading speech models.").font(.callout) }
            Button("Prepare a call…") { app.windows.show(.prepare, app) }
                .disabled(app.recording)
                .help(app.recording ? "Stop the meeting first." : "Pick title, project and privacy, then sync cards.")
            if app.recording { Text("Prepare is off while recording.").font(.callout) }
            Button("Copy consent line") { app.copyConsentLine() }
                .help(AppState.consentLine)
                .accessibilityHint("Copies a sentence asking the other side if transcription is OK.")
            Button("Set up Hamsa…") { app.windows.show(.onboarding, app) }
            Divider()
            Button("Quit Hamsa") {
                Task { await app.stop(); NSApplication.shared.terminate(nil) }
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)  // menu rows in the label colour (borderless blue reads grey when the panel is inactive)
        .padding(14)
        .frame(width: 300, alignment: .leading)
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
            .font(.callout)
            .accessibilityElement(children: .combine)
    }
}
