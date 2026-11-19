#if os(macOS)
import AppKit
import SwiftUI

/// T12: the answer overlay window. A borderless share-hidden OverlayPanel (top-right, 360 pt) hosting
/// AnswerCardView. Click-through except the footer buttons. Used by the app (T13) and `bench-latency --ui`.
///
///     let overlay = OverlayController(); overlay.show()
///     let p = LivePipeline(..., shown: { await overlay.commit($0) }, now: ...)
///     Task { @MainActor in for await e in p.events { overlay.model.apply(e) } }
///     overlay.model.aiOff = try await store.privacy(meeting: id).confidential
///     overlay.close()
@MainActor
public final class OverlayController {
    public static let width: CGFloat = 360
    static let height: CGFloat = 210  // header + 4 body lines + footer; the rest is transparent and click-through

    public let model = OverlayModel()
    public let panel: NSPanel
    private let host: NSHostingView<AnswerCardView>
    private var monitors: [Any] = []

    public init() {
        host = NSHostingView(rootView: AnswerCardView(model: model))
        host.sizingOptions = []  // fixed frame: a window that resizes to its content would move off the top-right corner
        panel = OverlayPanel.make(title: "Hamsa", size: NSSize(width: Self.width, height: Self.height), content: host,
                                  style: [.nonactivatingPanel, .borderless])
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true  // the local monitor needs moves while the pointer is over the buttons
    }

    public func show() {
        panel.orderFrontRegardless()
        // ignoresMouseEvents is per window: follow the pointer and take clicks only over the buttons of a card.
        let track: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.updateClickThrough() } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: track) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { track($0); return $0 }) { monitors.append(l) }
    }

    public func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.close()
    }

    /// Applies an event and pushes it to the window server before returning: LivePipeline's `shown` hook, so
    /// `t_shown_ms` is taken after the text is committed to the overlay window.
    public func commit(_ e: LivePipeline.Event) {
        model.apply(e)
        host.layoutSubtreeIfNeeded()
        host.display()
        CATransaction.flush()
    }

    public var sharingState: Int? { OverlayPanel.sharingState(windowNumber: panel.windowNumber) }

    private func updateClickThrough() {
        let p = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let flipped = CGPoint(x: p.x, y: panel.frame.height - p.y)
        let card = ![.empty, .restarted].contains(model.state)
        let ignore = !(card && model.buttonsRect.insetBy(dx: -4, dy: -4).contains(flipped))
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    /// PNG of what the live overlay view currently draws (its own view hierarchy, not a screen grab).
    public func capture(to url: URL) throws {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    /// Renders the card for a model state to a PNG (evidence; screen capture cannot see a share-hidden window).
    public static func snapshot(_ model: OverlayModel, to url: URL, dark: Bool = false) throws {
        let view = AnswerCardView(model: model).frame(height: height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: dark ? .black : .lightGray))
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
#endif
