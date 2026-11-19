#if os(macOS)
import Foundation

/// T13: one meeting as the menu bar runs it. Start opens the `meetings` row (privacy stored there, read back by
/// LivePipeline before every T2 send), Stop closes it. Confidential is set only through
/// `LiveStore.startMeeting(confidential:)` and `LivePipeline.setConfidential`; this type adds no gate of its own.
public actor MeetingSession {
    public nonisolated let id: String
    public nonisolated let store: LiveStore
    public nonisolated let pipeline: LivePipeline
    /// Confidential at any point: the meeting stays out of the brain summary (hub ruling, sticky).
    public private(set) var everConfidential: Bool

    public init(store: LiveStore, title: String, project: String, app: String?, confidential: Bool, llm: AnswerLLM?,
                embedder: (any Embedder)? = nil, index: LocalIndex? = nil, cards: CardMatcher? = nil,
                shown: LivePipeline.Shown? = nil, now: @escaping @Sendable () -> Int) async throws {
        let id = UUID().uuidString
        // notesConsent stays false: no UI for it until the owner decides ADR 002 (Gemini free tier gets nothing).
        try await store.openMeeting(id: id, title: title, app: app, project: project, confidential: confidential)
        self.id = id
        self.store = store
        everConfidential = confidential
        pipeline = LivePipeline(store: store, meeting: id, embedder: embedder, index: index, cards: cards, llm: llm,
                                shown: shown, now: now)
    }

    /// Mid-call switch. ON also marks the meeting local-only for the summary, and it stays so after OFF (part of
    /// the transcript was said in confidence). The disallow write runs even when the pipeline write throws.
    public func setConfidential(_ on: Bool) async throws {
        if on { everConfidential = true }
        var failure: Error?
        do { try await pipeline.setConfidential(on) } catch { failure = error }
        if on { try await store.disallowClaude(meeting: id) }
        if let failure { throw failure }
    }

    /// Lets the answer in flight end, closes the row. Returns false when the summary is skipped (confidential).
    /// A meeting that was ever ON (in memory, or `claude_allowed = 0` stored: only ON writes it) ends (1, 0).
    public func stop() async throws -> Bool {
        await pipeline.finish()
        var failure: Error?
        do {
            let wasOn = try await everConfidential ? true : !store.claudeAllowed(meeting: id)
            if wasOn { try await store.markLocalOnly(meeting: id) }
        } catch { failure = error }
        try await store.endMeeting(id: id)  // close the row even if the re-assert failed
        if let failure { throw failure }
        return try await store.claudeAllowed(meeting: id)
    }
}
#endif
