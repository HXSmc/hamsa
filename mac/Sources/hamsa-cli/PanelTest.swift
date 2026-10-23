#if os(macOS)
import AppKit
import ArgumentParser
import Foundation

/// T04b: spike - show a floating panel that must NOT appear in screen shares (sharingType = .none).
struct PanelTest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a share-hidden overlay panel for N seconds.")

    @Option(help: "Seconds to keep the panel up.") var seconds: Int = 60

    @MainActor
    func run() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let arabic = NSTextField(wrappingLabelWithString: "السعر ٤٩ ريال شهريًا")
        arabic.baseWritingDirection = .rightToLeft
        arabic.alignment = .right
        arabic.font = .systemFont(ofSize: 20)
        let english = NSTextField(wrappingLabelWithString: "Price: SAR 49 per month")
        english.font = .systemFont(ofSize: 16)
        let stack = NSStackView(views: [arabic, english])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let panel = OverlayPanel.make(title: "Hamsa panel-test", size: NSSize(width: 320, height: 110), content: stack)
        panel.orderFrontRegardless()
        print("PANEL_SHOWN sharingType=none seconds=\(seconds)")

        try? await Task.sleep(for: .seconds(seconds))
        panel.close()
    }
}
#endif
