#if canImport(Darwin)
import Foundation
import XCTest
@testable import HamsaKit

/// T11b: LivePipeline on the fake LLM transport of AnswerLLMTests (hosts down/up/hang .test; real hosts get
/// the 2-token answer and never leave the process).
final class PipelineTests: XCTestCase {
    typealias Fake = AnswerLLMTests.Fake
    struct FixedEmbedder: Embedder { let v: [Float]; func embed(prefixed text: String) throws -> [Float] { v } }

    override func setUp() { Fake.reset() }

    func tmp() -> String { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path }
    var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Fake.self]
        return URLSession(configuration: cfg)
    }
    func llm(_ host: String) -> AnswerLLM {
        AnswerLLM(providers: [LLMProvider(name: "groq", baseURL: URL(string: "https://\(host)/v1")!, model: "m", apiKey: "k", mayReceiveNotes: true)],
                  session: session)
    }
    static let t0 = ContinuousClock.now
    let now: @Sendable () -> Int = {
        let c = PipelineTests.t0.duration(to: .now).components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }

    func pipeline(_ path: String, confidential: Bool = false, notesConsent: Bool = false, llm: AnswerLLM?, gap: Int = 0,
                  embedder: (any Embedder)? = nil, index: LocalIndex? = nil, cards: CardMatcher? = nil) async throws -> LivePipeline {
        let store = try LiveStore(path: path)
        try await store.startMeeting(id: "m1", confidential: confidential, notesConsent: notesConsent)
        return LivePipeline(store: store, meeting: "m1", embedder: embedder, index: index, cards: cards, llm: llm,
                            minGapMs: gap, now: now)
    }

    func final(_ text: String, at ms: Int = 1000, channel: String = "them") -> STTUpdate {
        STTUpdate(channel: channel, text: text, startMs: ms - 900, endMs: ms, isFinal: true, lang: "en", arrivalMs: ms)
    }

    func waitFor(_ timeout: Double = 3, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testNewQuestionCancelsInFlightAnswerWithin200ms() async throws {
        let p = try await pipeline(tmp(), llm: llm("hang.test"))
        await p.ingest(final("What is the monthly price?"))
        await waitFor { Fake.count("hang.test") == 1 }
        XCTAssertEqual(Fake.count("hang.test"), 1)
        try await Task.sleep(for: .milliseconds(50))  // first token arrived, answer is streaming
        let t = ContinuousClock.now
        await p.ingest(final("How many engineers are on the team?", at: 5000))
        await waitFor { Fake.stoppedCount() >= 1 }
        let c = t.duration(to: .now).components
        let ms = Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
        XCTAssertGreaterThanOrEqual(Fake.stoppedCount(), 1, "old request never torn down")
        XCTAssertLessThanOrEqual(ms, 200, "cancel took \(ms) ms on the wire")
        await waitFor { Fake.count("hang.test") == 2 }
        XCTAssertEqual(Fake.count("hang.test"), 2)  // the new question got its own request
        let cancels = await p.stats.cancelMs
        XCTAssertEqual(cancels.count, 1)
        XCTAssertLessThanOrEqual(cancels.first ?? 999, 200)
    }

    func testConfidentialMeetingSendsNoRequest() async throws {
        let path = tmp()
        let chain = AnswerLLM(providers: PipelineProviders.chain { _ in "k" }, session: session)
        let p = try await pipeline(path, confidential: true, llm: chain)
        await p.ingest(final("What is the monthly price?"))
        await p.finish()
        XCTAssertEqual(Fake.count(), 0)
        let s = await p.stats
        XCTAssertEqual(s.questions, 1)
        XCTAssertEqual(s.t2Skipped["confidential"], 1)
    }

    func testGeminiGetsNotesOnlyWithStoredConsent() async throws {
        // Groq has no key: the chain's only keyed provider is the Gemini free tier.
        let chain = AnswerLLM(providers: PipelineProviders.chain { $0 == "gemini" ? "k" : nil }, session: session)
        XCTAssertEqual(PipelineProviders.chain { _ in "k" }.filter { !$0.mayReceiveNotes }.map(\.name), ["gemini"])
        let p = try await pipeline(tmp(), llm: chain)
        await p.ingest(final("What is the monthly price?"))
        await p.finish()
        XCTAssertEqual(Fake.count(), 0, "no consent in the meeting row: Gemini must get no request")
        let errs = await p.stats.t2Errors
        XCTAssertEqual(errs.keys.first.map { $0.contains("no notes consent") }, true, "\(errs)")

        let ok = try await pipeline(tmp(), notesConsent: true, llm: chain)
        await ok.ingest(final("What is the monthly price?"))
        await ok.finish()
        XCTAssertEqual(Fake.count("generativelanguage.googleapis.com"), 1)
        let okStats = await ok.stats
        XCTAssertEqual(okStats.t2, 1)
    }

    func testAnswerEventsRowsFollowSchema() async throws {
        let path = tmp()
        let idx = try LocalIndex(path: LocalIndexTests().makeIndex(), projectID: "taweed", dim: 4)
        let chain = AnswerLLM(providers: PipelineProviders.chain { _ in "k" }, session: session)
        let p = try await pipeline(path, llm: chain, embedder: FixedEmbedder(v: [1, 0, 0, 0]), index: idx)
        await p.ingest(final("Which GPU do you run inference on?", at: 4000))
        await p.finish()
        XCTAssertEqual(Fake.count("api.groq.com"), 1)
        let db = try SQLiteDB(path: path)
        var rows: [(tier: String, shown: Int, text: String, provider: String)] = []
        try db.query("SELECT tier, t_shown_ms, text, COALESCE(provider, 'NULL') FROM answer_events ORDER BY id") {
            rows.append(($0.text(0), $0.int(1), $0.text(2), $0.text(3)))
        }
        XCTAssertEqual(rows.map(\.tier), ["T1", "T2"])
        XCTAssertTrue(rows[0].text.contains("L4 GPU"))
        XCTAssertEqual(rows[0].provider, "NULL")
        XCTAssertEqual(rows[1].text, "L4 GPU")
        XCTAssertEqual(rows[1].provider, "groq")
        XCTAssertTrue(rows[0].shown >= 0 && rows[1].shown >= rows[0].shown)  // stream clock ms, T2 first token after T1
        var q: (seg: Int, end: Int) = (0, 0)
        try db.query("SELECT segment_id, t_question_end_ms FROM questions") { q = ($0.int(0), $0.int(1)) }
        XCTAssertGreaterThan(q.seg, 0)
        XCTAssertEqual(q.end, 4000)
        var latency = 0
        try db.query("SELECT COUNT(*) FROM latency_events") { latency = $0.int(0) }
        XCTAssertEqual(latency, 2)
    }

    func testCardOnPartialWithoutQuestionWord() async throws {
        let path = tmp()
        let cards = try CardMatcher(path: CardMatcherTests().makeCards(), projectID: "taweed", dim: 3)
        let p = try await pipeline(path, llm: llm("up.test"), embedder: FixedEmbedder(v: [1, 0, 0]), cards: cards)
        await p.ingest(STTUpdate(channel: "them", text: "the GPU you use", startMs: 0, endMs: 900, isFinal: false, lang: "en", arrivalMs: 950))
        await p.finish()
        let s = await p.stats
        XCTAssertEqual(s.t0, 1)
        XCTAssertEqual(s.t2Starts, 0)  // statement, no question word: card only
        let rows = try await LiveStore(path: path).questions(meeting: "m1")
        XCTAssertEqual(rows.first?.tiers, ["T0"])
        XCTAssertEqual(rows.first?.channel, "them")
    }

    func testGapGateKeepsNewestPendingQuestion() async throws {
        let p = try await pipeline(tmp(), llm: llm("up.test"), gap: 400)
        await p.ingest(final("What is the monthly price?", at: 1000))
        await waitFor { Fake.count("up.test") == 1 }
        await p.ingest(final("How many engineers are there?", at: 2000))   // waits for the gap
        await p.ingest(final("Where is your head office?", at: 3000))      // replaces it
        let t = ContinuousClock.now
        await p.finish()
        XCTAssertGreaterThan(t.duration(to: .now), .milliseconds(250), "second request did not wait for the gap")
        XCTAssertEqual(Fake.count("up.test"), 2)
        let s = await p.stats
        XCTAssertEqual(s.replacedPending, 1)
        XCTAssertEqual(s.t2, 2)
    }

    func testAskerChannelsOnly() async throws {
        let p = try await pipeline(tmp(), llm: llm("up.test"))
        await p.ingest(final("What is the monthly price?", channel: "me"))
        await p.finish()
        let s = await p.stats
        XCTAssertEqual(s.questions, 0)  // default askers = them (03-tdd)
    }

    func testSchema1FileIsMigrated() async throws {
        let path = tmp()
        let old = try SQLiteDB(path: path, readOnly: false)
        try old.exec("""
            CREATE TABLE schema_version (version INTEGER NOT NULL); INSERT INTO schema_version VALUES (1);
            CREATE TABLE meetings (id TEXT PRIMARY KEY, project_id TEXT, title TEXT, app TEXT, started_at INTEGER NOT NULL,
              ended_at INTEGER, audio_dir TEXT, summary_path TEXT, confidential INTEGER NOT NULL DEFAULT 0,
              claude_allowed INTEGER NOT NULL DEFAULT 1, status TEXT);
            INSERT INTO meetings (id, started_at, confidential) VALUES ('old', 1, 1);
            """)
        let store = try LiveStore(path: path)
        let priv = try await store.privacy(meeting: "old")
        XCTAssertTrue(priv.confidential)
        XCTAssertFalse(priv.notesConsent)
        let unknown = try await store.privacy(meeting: "nope")
        XCTAssertTrue(unknown.confidential)  // fail closed
        var v = 0
        try old.query("SELECT version FROM schema_version") { v = $0.int(0) }
        XCTAssertEqual(v, 2)
    }
}
#endif
