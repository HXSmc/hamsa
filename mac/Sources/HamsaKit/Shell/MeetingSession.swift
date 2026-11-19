#if os(macOS)
import Foundation

/// T13: one meeting as the menu bar runs it. Start opens the `meetings` row (privacy stored there, read back by
/// LivePipeline before every T2 send), Stop closes it. Confidential is set only through
/// `LiveStore.startMeeting(confidential:)` and `LivePipeline.setConfidential`; this type adds no gate of its own.
public actor MeetingSession {
    public nonisolated let id: String
    public nonisolated let store: LiveStore
    public nonisolated let pipeline: LivePipeline

    public init(store: LiveStore, title: String, project: String, app: String?, confidential: Bool, llm: AnswerLLM?,
                embedder: (any Embedder)? = nil, index: LocalIndex? = nil, cards: CardMatcher? = nil,
                shown: LivePipeline.Shown? = nil, now: @escaping @Sendable () -> Int) async throws {
        let id = UUID().uuidString
        // notesConsent stays false: no UI for it until the owner decides ADR 002 (Gemini free tier gets nothing).
        try await store.startMeeting(id: id, title: title, app: app, confidential: confidential, notesConsent: false)
        try await store.setProject(meeting: id, project)
        if confidential { try await store.disallowClaude(meeting: id) }
        self.id = id
        self.store = store
        pipeline = LivePipeline(store: store, meeting: id, embedder: embedder, index: index, cards: cards, llm: llm,
                                shown: shown, now: now)
    }

    /// Mid-call switch. ON also marks the meeting local-only for the summary (stays so if switched back OFF:
    /// part of the transcript was said in confidence).
    public func setConfidential(_ on: Bool) async throws {
        try await pipeline.setConfidential(on)
        if on { try await store.disallowClaude(meeting: id) }
    }

    /// Lets the answer in flight end, closes the row. Returns false when the summary is skipped (confidential).
    public func stop() async throws -> Bool {
        await pipeline.finish()
        try await store.endMeeting(id: id)
        return try await store.claudeAllowed(meeting: id)
    }
}
#endif
