import HamsaKit

/// T12 app glue: the answer overlay (HamsaKit/Overlay) on a live meeting. T13: `start` when the meeting starts,
/// create the pipeline with `shown: AppOverlay.shown(overlay)` (the overlay's only input: questions, answers,
/// privacy changes), `end` when it stops.
@MainActor
enum AppOverlay {
    /// t_shown_ms = text committed to the overlay window.
    static func shown(_ overlay: OverlayController) -> LivePipeline.Shown { { await overlay.commit($0) } }

    /// Shows the overlay; "AI off" stays on until the stored privacy state is read (read only, never written).
    static func start(_ overlay: OverlayController, store: LiveStore, meeting: String) async {
        overlay.model.live = true
        overlay.show()
        overlay.model.aiOff = (try? await store.privacy(meeting: meeting).confidential) ?? true
    }

    static func end(_ overlay: OverlayController) {
        overlay.model.live = false
        overlay.close()
    }
}
