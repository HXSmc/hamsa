import SwiftUI

/// Before a call: title, project, confidential switch, agenda; Prepare syncs the brain's cards.
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
                .accessibilityHint("When on, no question is sent to AI providers and no summary is made.")
            Text(app.recording ? app.confidentialText : "Confidential: answers come only from your cards and notes on this Mac. Nothing goes to AI providers, and the meeting stays out of summaries even if you turn it off later.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            LabeledContent("Agenda") {
                TextEditor(text: $app.agenda)
                    .font(.body)
                    .frame(height: 64)
                    .accessibilityLabel("Agenda, optional")
            }
            StatusLine(recording: false, text: app.status)
                .padding(.top, 4)
            HStack {
                Button("Prepare answers for \(app.settings.project.capitalized)") { Task { await app.prepare() } }
                    .disabled(app.preparing || app.recording)
                Spacer()
                Button("Start meeting") {
                    app.windows.close(.prepare)
                    Task { await app.start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.recording || app.starting)
            }
            if app.preparing { Text("Syncing cards from the brain…").font(.callout) }
            if app.recording { Text("A meeting is already recording.").font(.callout) }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
