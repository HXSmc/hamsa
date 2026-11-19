#if os(macOS)
import AppKit

/// T04b overlay: a floating, non-activating panel that does NOT appear in screen shares (sharingType = .none),
/// pinned to the top-right of the main screen. Shared by `panel-test`, `rehearse` and the T12 answer overlay.
public enum OverlayPanel {
    @MainActor
    public static func make(title: String, size: NSSize, content: NSView,
                            style: NSWindow.StyleMask = [.nonactivatingPanel, .titled]) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
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

    /// `kCGWindowSharingState` of an on-screen window as the window server reports it (0 = none = hidden from shares).
    public static func sharingState(windowNumber: Int) -> Int? {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]]
        return info?.first?[kCGWindowSharingState as String] as? Int
    }
}
#endif
