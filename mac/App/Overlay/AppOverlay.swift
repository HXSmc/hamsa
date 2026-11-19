import HamsaKit

/// T12 app glue: the answer overlay (HamsaKit/Overlay) on a live meeting. T13 creates the pipeline with
/// `shown: AppOverlay.shown(overlay)` and keeps the returned task for the length of the meeting.
@MainActor
enum AppOverlay {
    /// t_shown_ms = text committed to the overlay window.
    static func shown(_ overlay: OverlayController) -> LivePipeline.Shown { { await overlay.commit($0) } }

    /// Shows the overlay, mirrors the stored privacy state ("AI off", read only) and applies events until the meeting ends.
    static func attach(_ overlay: OverlayController, to pipeline: LivePipeline, store: LiveStore, meeting: String) -> Task<Void, Never> {
        overlay.show()
        return Task { @MainActor in
            overlay.model.aiOff = (try? await store.privacy(meeting: meeting).confidential) ?? true
            for await e in pipeline.events { overlay.model.apply(e) }
            overlay.close()
        }
    }
}
