#if os(macOS)
import AppKit
import SwiftUI

/// T12: the answer overlay window. A borderless share-hidden OverlayPanel (top-right, 360 pt) hosting
/// AnswerCardView. Click-through except the footer buttons. Used by the app (T13) and `bench-latency --ui`.
///
///     let overlay = OverlayController(); overlay.model.live = true; overlay.show()
///     overlay.model.aiOff = (try? await store.privacy(meeting: id).confidential) ?? true
///     let p = LivePipeline(..., shown: { await overlay.commit($0) }, now: ...)   // the overlay's only input
///     overlay.model.sttRestarted = true   // on an STT worker restart
///     overlay.model.live = false; overlay.close()
@MainActor
public final class OverlayController {
    public static let width: CGFloat = 360
    static let height: CGFloat = 220  // header + 4 body lines + footer; the rest is transparent and click-through

    public let model = OverlayModel()
    public let panel: NSPanel
    private let host: FirstClickHostingView
    private var monitors: [Any] = []

    public init() {
        host = FirstClickHostingView(rootView: AnswerCardView(model: model))
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

    /// LivePipeline's `shown` hook: applies an event and, when the card changed, pushes it to the window server
    /// before returning, so `t_shown_ms` is taken after the text is committed to the overlay window. An answer that
    /// lands while a new card is still sliding in (150 ms) returns once the slide is over: the stamp is "in place".
    @discardableResult
    public func commit(_ e: LivePipeline.Event) async -> Bool {
        let changed = model.apply(e)
        guard changed else { return false }
        host.layoutSubtreeIfNeeded()
        host.display()
        CATransaction.flush()
        if case .question = e { slideStart = .now }
        if case .answer = e, let start = slideStart {
            let left = Self.slide - start.duration(to: .now)
            if left > .zero { try? await Task.sleep(for: left) }
        }
        return true
    }

    static let slide = Duration.milliseconds(150)
    private var slideStart: ContinuousClock.Instant?

    public var sharingState: Int? { OverlayPanel.sharingState(windowNumber: panel.windowNumber) }

    private func updateClickThrough() {
        let p = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let flipped = CGPoint(x: p.x, y: panel.frame.height - p.y)
        let card = ![.hidden, .listening, .restarted].contains(model.state)
        let ignore = !(card && model.buttonsRect.insetBy(dx: -4, dy: -4).contains(flipped))
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    /// PNG of what the live overlay view currently draws (its own view hierarchy, not a screen grab). Bench only:
    /// the app must never write the share-hidden overlay's content to disk.
    @_spi(Bench) public func capture(to url: URL) throws {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try Self.writePrivate(png, url)
    }

    static func writePrivate(_ data: Data, _ url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Renders the card for a model state to a PNG (evidence; screen capture cannot see a share-hidden window).
    @_spi(Bench) public static func snapshot(_ model: OverlayModel, to url: URL, dark: Bool = false) throws {
        let view = AnswerCardView(model: model).frame(height: height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: dark ? .black : .lightGray))
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writePrivate(png, url)
    }
}
/// The overlay never becomes key (non-activating, click-through): without this the first click on a footer button
/// only "activates" the view and the button does nothing.
final class FirstClickHostingView: NSHostingView<AnswerCardView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
