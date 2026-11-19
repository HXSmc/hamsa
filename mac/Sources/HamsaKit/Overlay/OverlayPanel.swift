#if os(macOS)
import AppKit

/// T04b overlay: a floating, non-activating panel that does NOT appear in screen shares (sharingType = .none),
/// pinned to the top-right of the main screen. Shared by `panel-test` and `rehearse`.
enum OverlayPanel {
    @MainActor
    static func make(title: String, size: NSSize, content: NSView) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
        panel.title = title
        panel.contentView = content
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 20, y: area.maxY - size.height - 20))
        }
        return panel
    }
}
#endif
