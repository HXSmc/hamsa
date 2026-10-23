import SwiftUI
import HamsaKit

@main
struct HamsaApp: App {
    var body: some Scene {
        MenuBarExtra("Hamsa", systemImage: "waveform") {
            Text("Hamsa \(Hamsa.version)")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
