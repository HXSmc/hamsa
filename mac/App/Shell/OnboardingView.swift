import AVFoundation
import SwiftUI

/// First launch: microphone, system audio, brain link, Groq key (04-app-flow "Onboarding"). Every step can be
/// skipped; a denied permission opens PermissionHelpView.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @State private var replaceKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if app.step <= 4 {
                Text("Step \(app.step) of 4").font(.callout).accessibilityLabel("Step \(app.step) of 4")
            }
            content
            Spacer(minLength: 0)
            HStack {
                if app.step > 1 && app.step <= 4 { Button("Back") { app.step -= 1 } }
                Spacer()
                footer
            }
        }
        .padding(24)
        .frame(width: 460, height: 340, alignment: .topLeading)
    }

    @ViewBuilder var content: some View {
        switch app.step {
        case 1:
            Header(title: "Let Hamsa hear you", text: "Hamsa transcribes your side of the call from the microphone. Audio stays on this Mac.")
            if app.mic == .authorized { Notice(icon: "checkmark.circle.fill", text: "Microphone allowed.") }
            else if app.mic == .denied || app.mic == .restricted { Notice(icon: "xmark.octagon.fill", text: "Microphone is blocked.", tint: .red) }
        case 2:
            Header(title: "Let Hamsa hear the call", text: "Hamsa records the other side from your Mac's sound output. macOS asks once; choose Allow.")
            if app.systemAudioAsked { Notice(icon: "checkmark.circle.fill", text: "System audio allowed.") }
        case 3:
            Header(title: "Link the brain", text: "The mini PC builds your answer cards. Enter its address and token. You can skip this and use the cards already on this Mac.")
            TextField("Brain address", text: $app.settings.brainURL, prompt: Text("http://100.64.0.1:8770"))
                .textFieldStyle(.roundedBorder)
            SecureField("Brain token", text: $app.brainToken,
                        prompt: Text(app.brainTokenPresent ? "Saved in Keychain. Paste to replace." : "Paste the token"))
                .textFieldStyle(.roundedBorder)
            switch app.brain {
            case .none: EmptyView()
            case .checking: Text("Checking…").font(.callout)
            case .ok: Notice(icon: "checkmark.circle.fill", text: "Brain linked. Token saved in Keychain.")
            case .failed(let why): Notice(icon: "wifi.exclamationmark", text: "\(why) You can continue offline: Prepare will use the cards from the last sync.", tint: .red)
            }
        case 4:
            Header(title: "Add your Groq key", text: "Groq writes answers when your cards and notes miss. The key is saved in your Keychain only.")
            if app.keyPresent && !replaceKey {
                Notice(icon: "key.fill", text: "A Groq key is saved in your Keychain.")
                Button("Replace key") { replaceKey = true }
            } else {
                SecureField("Groq API key", text: $app.keyEntry, prompt: Text("gsk_…"))
                    .textFieldStyle(.roundedBorder)
                switch app.key {
                case .none: EmptyView()
                case .checking: Text("Checking the key with Groq…").font(.callout)
                case .saved: Notice(icon: "checkmark.circle.fill", text: "Key works. Saved in Keychain.")
                case .failed(let why): Notice(icon: "xmark.octagon.fill", text: "\(why) Retry, or skip: you still get cards and note snippets.", tint: .red)
                }
            }
        default:
            Header(title: "Hamsa is ready", text: "Find it in the menu bar (the waveform icon). Before a call choose Prepare a call; during a call choose Start meeting, or press Option-Command-H.")
        }
    }

    @ViewBuilder var footer: some View {
        switch app.step {
        case 1:
            Button("Skip for now") { app.step = 2 }
            if app.mic == .authorized { Button("Continue") { app.step = 2 }.buttonStyle(.borderedProminent) }
            else { Button("Allow microphone") { Task { await app.requestMic() } }.buttonStyle(.borderedProminent) }
        case 2:
            Button("Skip for now") { app.step = 3 }
            Button("Allow system audio") { app.requestSystemAudio() }.buttonStyle(.borderedProminent)
        case 3:
            if case .failed = app.brain { Button("Continue offline") { app.saveSettings(); app.step = 4 } }
            else { Button("Skip") { app.step = 4 } }
            if app.brain == .ok { Button("Continue") { app.step = 4 }.buttonStyle(.borderedProminent) }
            else {
                Button("Test link") { Task { await app.testBrain() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.settings.brainURL.isEmpty || app.brain == .checking)
                    .help(app.settings.brainURL.isEmpty ? "Enter the brain address first." : "")
            }
        case 4:
            if (app.keyPresent && !replaceKey) || app.key == .saved {
                Button("Continue") { app.step = 5 }.buttonStyle(.borderedProminent)
            } else {
                Button("Skip: cards and notes only") { app.step = 5 }
                Button(app.key == .none || app.key == .checking ? "Test and save" : "Retry") { Task { await app.testAndSaveKey() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.keyEntry.isEmpty || app.key == .checking)
                    .help(app.keyEntry.isEmpty ? "Paste a key first." : "")
            }
        default:
            Button("Done") { app.finishOnboarding() }.buttonStyle(.borderedProminent)
        }
    }
}

struct Header: View {
    let title: String
    let text: String
    var body: some View {
        Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
        Text(text).fixedSize(horizontal: false, vertical: true)
    }
}
