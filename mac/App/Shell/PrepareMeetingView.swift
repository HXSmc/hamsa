import SwiftUI

/// Before a call: title, project, confidential switch; Prepare syncs the brain's cards.
struct PrepareMeetingView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            TextField("Title", text: $app.title)
            Picker("Project", selection: $app.settings.project) {
                ForEach(app.projects, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Toggle("Confidential", isOn: app.confidentialBinding)
                .disabled(app.stopping)
                .accessibilityHint("When on, no question is sent to AI providers and the meeting stays out of summaries.")
            Text(app.recording ? app.confidentialText : "Confidential: answers come only from your cards and notes on this Mac. Nothing goes to AI providers, and the meeting stays out of summaries even if you turn it off later.")
                .fixedSize(horizontal: false, vertical: true)
            if app.offline { Notice(icon: "exclamationmark.triangle.fill", text: app.status, tint: .orange).padding(.top, 4) }
            else { StatusLine(recording: false, text: app.status).padding(.top, 4) }
            if app.cardCount == 0 && !app.preparing {
                Notice(icon: "rectangle.stack.badge.plus", text: "No cards yet. Link the brain so Prepare can pull your answer cards, or start anyway with note snippets only.")
                Button("Link the brain…") { app.openSetup(step: 3) }
            }
            HStack {
                Button("Prepare answers for \(app.settings.project.capitalized)") { Task { await app.prepare() } }
                    .disabled(app.preparing || app.recording)
                if app.preparing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Start meeting") {
                    app.windows.close(.prepare)
                    Task { await app.start() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(app.recording || app.starting)
            }
            if app.preparing { Text("Syncing cards from the brain…") }
            if app.recording { Text("A meeting is already recording. Confidential still works from here.") }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
