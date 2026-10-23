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

        let size = NSSize(width: 320, height: 110)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
        panel.title = "Hamsa panel-test"
        panel.contentView = stack
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 20, y: area.maxY - size.height - 20))
        }
        panel.orderFrontRegardless()
        print("PANEL_SHOWN sharingType=none seconds=\(seconds)")

        try? await Task.sleep(for: .seconds(seconds))
        panel.close()
    }
}
