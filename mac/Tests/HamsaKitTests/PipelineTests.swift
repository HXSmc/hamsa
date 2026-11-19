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
    private var made: [String] = []
    override func tearDown() {
        for p in made { for f in [p, p + "-wal", p + "-shm"] { try? FileManager.default.removeItem(atPath: f) } }
        made = []
    }

    func track(_ p: String) -> String { made.append(p); return p }
    func tmp() -> String { track(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path) }
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
        let path = tmp()
        let p = try await pipeline(path, llm: llm("hang.test"))
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
        var cancels: [Int] = []
        for _ in 0..<100 where cancels.isEmpty { cancels = await p.stats.cancelMs; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(cancels.count, 1)
        XCTAssertLessThanOrEqual(cancels.first ?? 999, 200)
        // The replaced answer (one token shown) leaves no answer_events row.
        let rows = try await LiveStore(path: path).questions(meeting: "m1")
        XCTAssertEqual(rows.first?.tiers, [])
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
        let idx = try LocalIndex(path: track(LocalIndexTests().makeIndex()), projectID: "taweed", dim: 4)
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
        let cards = try CardMatcher(path: track(CardMatcherTests().makeCards()), projectID: "taweed", dim: 3)
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

    func testPartialShowsT1EarlyButT2OnlyOnFinal() async throws {
        let path = tmp()
        let idx = try LocalIndex(path: track(LocalIndexTests().makeIndex()), projectID: "taweed", dim: 4)
        let p = try await pipeline(path, llm: llm("up.test"), embedder: FixedEmbedder(v: [1, 0, 0, 0]), index: idx)
        await p.ingest(STTUpdate(channel: "them", text: "can you explain which GPU", startMs: 0, endMs: 900, isFinal: false, lang: "en", arrivalMs: 950))
        var s = await p.stats
        XCTAssertEqual(s.t1, 1)
        XCTAssertEqual(s.t2Starts, 0)  // no speculative T2
        await p.ingest(STTUpdate(channel: "them", text: "can you explain which GPU you run", startMs: 0, endMs: 1500, isFinal: true, lang: "en", arrivalMs: 1600))
        await p.finish()
        s = await p.stats
        XCTAssertEqual(s.t1, 1)
        XCTAssertEqual(s.t2, 1)
        XCTAssertEqual(Fake.count("up.test"), 1)
        let rows = try await LiveStore(path: path).questions(meeting: "m1")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.tiers, ["T1", "T2"])
    }

    /// Two channels ask at once (re-entrant actor): the question created last must own the answer in flight.
    func testInterleavedChannelsNewestQuestionWins() async throws {
        for i in 0..<20 {
            let path = tmp()
            let store = try LiveStore(path: path)
            try await store.startMeeting(id: "m1")
            let p = LivePipeline(store: store, meeting: "m1", embedder: nil, index: nil, cards: nil, llm: llm("hang.test"),
                                 askers: ["them", "me"], minGapMs: 0, now: now)
            let (ua, ub) = (final("What is the monthly price?", at: 1000 + i, channel: "them"),
                            final("How many engineers are on the team?", at: 1000 + i, channel: "me"))
            async let a: Void = p.ingest(ua)
            async let b: Void = p.ingest(ub)
            _ = await (a, b)
            let qs = try await store.questions(meeting: "m1")
            XCTAssertEqual(qs.count, 2)
            let current = await p.currentT2Question
            XCTAssertEqual(current, qs.map(\.id).max(), "iteration \(i): older question won")
            try await p.setConfidential(true)  // tears down the hanging request
        }
    }

    func testPrivacyIsReReadAtSendTime() async throws {
        let path = tmp()
        let p = try await pipeline(path, llm: llm("up.test"), gap: 300)
        await p.ingest(final("What is the monthly price?", at: 1000))
        await waitFor { Fake.count("up.test") == 1 }
        await p.ingest(final("How many engineers are there?", at: 2000))  // waits for the gap
        try await LiveStore(path: path).setConfidential(meeting: "m1", true)  // flipped behind the pipeline's back
        await p.finish()
        XCTAssertEqual(Fake.count("up.test"), 1, "request sent after the meeting turned confidential")
        let s = await p.stats
        XCTAssertEqual(s.t2Skipped["confidential"], 1)
    }

    func testConfidentialSwitchCancelsAnswerInFlight() async throws {
        let p = try await pipeline(tmp(), llm: llm("hang.test"))
        await p.ingest(final("What is the monthly price?"))
        await waitFor { Fake.count("hang.test") == 1 }
        let t = ContinuousClock.now
        try await p.setConfidential(true)
        await waitFor { Fake.stoppedCount() >= 1 }
        XCTAssertGreaterThanOrEqual(Fake.stoppedCount(), 1)
        XCTAssertLessThanOrEqual(t.duration(to: .now), .milliseconds(200))
        await p.ingest(final("How many engineers are there?", at: 5000))
        await p.finish()
        XCTAssertEqual(Fake.count(), 1, "no request after the switch")
    }

    /// Hub add-on: a store write that throws must still tear down the answer in flight (cancel comes first).
    func testConfidentialSwitchCancelsEvenWhenStoreWriteFails() async throws {
        let path = tmp()
        let p = try await pipeline(path, llm: llm("hang.test"))
        await p.ingest(final("What is the monthly price?"))
        await waitFor { Fake.count("hang.test") == 1 }
        try SQLiteDB(path: path, readOnly: false)
            .exec("CREATE TRIGGER no_update BEFORE UPDATE ON meetings BEGIN SELECT RAISE(ABORT, 'disk gone'); END;")
        do { try await p.setConfidential(true); XCTFail("store write should have thrown") } catch {}
        await waitFor { Fake.stoppedCount() >= 1 }
        XCTAssertGreaterThanOrEqual(Fake.stoppedCount(), 1, "answer still streaming after a failed confidential write")
        // The stored row still says not confidential: the in-memory latch must keep the next question local.
        await p.ingest(final("How many GPUs do you run?", at: 5000))
        await p.finish()
        XCTAssertEqual(Fake.count(), 1, "a request left after the owner switched confidential on")
        let skipped = await p.stats.t2Skipped["confidential"]
        XCTAssertEqual(skipped, 1)
    }

    /// OFF then ON quickly: the OFF write lands after ON (stored row ends at 0); the latch must stay on.
    func testLateOffWriteDoesNotClearNewerOnLatch() async throws {
        let path = tmp()
        let p = try await pipeline(path, confidential: true, llm: llm("up.test"))
        let (entered, enteredC) = AsyncStream<Void>.makeStream()
        let (gate, gateC) = AsyncStream<Void>.makeStream()
        await p.setPrivacyWriteHook { on in
            guard !on else { return }
            enteredC.yield()
            for await _ in gate { break }
        }
        let off = Task { try await p.setConfidential(false) }
        for await _ in entered { break }  // OFF is suspended before its write
        try await p.setConfidential(true)
        gateC.yield()
        try await off.value
        let latched = await p.latched
        XCTAssertTrue(latched, "a stale OFF cleared the newer ON")
        let stored = try await LiveStore(path: path).privacy(meeting: "m1").confidential
        XCTAssertFalse(stored, "test setup: the late OFF write should be the stored value")
        await p.ingest(final("What is the monthly price?"))
        await p.finish()
        XCTAssertEqual(Fake.count(), 0, "a request left after the owner's last switch was ON")
    }

    /// The overlay hook gets every event; an answer it did not display is not stamped and writes no row.
    func testShownFalseWritesNoRowAndPrivacyIsPublished() async throws {
        let path = tmp()
        let idx = try LocalIndex(path: track(LocalIndexTests().makeIndex()), projectID: "taweed", dim: 4)
        let store = try LiveStore(path: path)
        try await store.startMeeting(id: "m1")
        let seen = Events()
        let p = LivePipeline(store: store, meeting: "m1", embedder: FixedEmbedder(v: [1, 0, 0, 0]), index: idx, cards: nil,
                             llm: nil, minGapMs: 0, shown: { e in seen.add(e); return false }, now: now)
        await p.ingest(final("Which GPU do you run inference on?", at: 4000))
        try await p.setConfidential(true)
        await p.finish()
        XCTAssertEqual(seen.kinds, ["question", "answer", "privacy:true"])
        var rows = 0
        try SQLiteDB(path: path).query("SELECT COUNT(*) FROM answer_events") { rows = $0.int(0) }
        XCTAssertEqual(rows, 0)
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var k: [String] = []
        var kinds: [String] { lock.withLock { k } }
        func add(_ e: LivePipeline.Event) {
            let s: String
            switch e {
            case .question: s = "question"
            case .answer: s = "answer"
            case .answerFailed: s = "failed"
            case let .privacy(c): s = "privacy:\(c)"
            }
            lock.withLock { k.append(s) }
        }
    }

    /// T12: t_shown_ms is taken after the overlay's `shown` hook returns (T1 and the first T2 token).
    func testShownHookSetsTShown() async throws {
        let path = tmp()
        let idx = try LocalIndex(path: track(LocalIndexTests().makeIndex()), projectID: "taweed", dim: 4)
        let store = try LiveStore(path: path)
        try await store.startMeeting(id: "m1")
        let hooked = Counter()
        let p = LivePipeline(store: store, meeting: "m1", embedder: FixedEmbedder(v: [1, 0, 0, 0]), index: idx, cards: nil,
                             llm: llm("up.test"), minGapMs: 0,
                             shown: { e in
                                 guard case .answer = e else { return true }
                                 hooked.add(); try? await Task.sleep(for: .milliseconds(60)); return true
                             }, now: now)
        let before = now()
        await p.ingest(final("Which GPU do you run inference on?", at: 4000))
        await p.finish()
        XCTAssertEqual(hooked.value, 4)  // T1, two T2 tokens, T2 done: every answer event goes through the one applier
        var shown: [String: Int] = [:]
        try SQLiteDB(path: path).query("SELECT tier, t_shown_ms FROM answer_events") { shown[$0.text(0)] = $0.int(1) }
        XCTAssertGreaterThanOrEqual(shown["T1"] ?? 0, before + 60)
        XCTAssertGreaterThanOrEqual(shown["T2"] ?? 0, (shown["T1"] ?? 0) + 60)  // first token stamped after its commit
    }

    /// 03-tdd: first_text_ms is negative when the text shows before the question ends; the view keeps the sign.
    func testLatencyViewKeepsNegativeValues() async throws {
        let path = tmp()
        let idx = try LocalIndex(path: track(LocalIndexTests().makeIndex()), projectID: "taweed", dim: 4)
        let p = try await pipeline(path, llm: nil, embedder: FixedEmbedder(v: [1, 0, 0, 0]), index: idx)
        let end = now() + 600_000  // the question ends long after T1 shows on the partial
        await p.ingest(STTUpdate(channel: "them", text: "can you explain which GPU", startMs: 0, endMs: 900, isFinal: false, lang: "en", arrivalMs: 950))
        await p.ingest(STTUpdate(channel: "them", text: "can you explain which GPU you run", startMs: 0, endMs: end, isFinal: true, lang: "en", arrivalMs: end))
        await p.finish()
        var first: [Int] = []
        try SQLiteDB(path: path).query("SELECT first_text_ms FROM latency_events WHERE tier = 'T1'") { first.append($0.int(0)) }
        XCTAssertEqual(first.count, 1)
        XCTAssertLessThan(first.first ?? 0, -500_000)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func add() { lock.withLock { n += 1 } }
    }

    func testMissingMeetingRowFailsClosed() async throws {
        let store = try LiveStore(path: tmp())  // no startMeeting: no row for "ghost"
        let chain = AnswerLLM(providers: PipelineProviders.chain { _ in "k" }, session: session)
        let p = LivePipeline(store: store, meeting: "ghost", embedder: nil, index: nil, cards: nil, llm: chain, minGapMs: 0, now: now)
        await p.startT2(1, question: "What is the monthly price?", snippets: ["s"])
        await p.finish()
        XCTAssertEqual(Fake.count(), 0)
        let s = await p.stats
        XCTAssertEqual(s.t2Skipped["confidential"], 1)
    }

    func testChainPacingComesFromProviders() {
        XCTAssertEqual(PipelineProviders.minGapMs(PipelineProviders.chain { _ in "k" }), 6000)  // Groq free tier
        XCTAssertEqual(PipelineProviders.minGapMs(PipelineProviders.chain { $0 == "gemini" ? "k" : nil }), 0)
        XCTAssertEqual(PipelineProviders.minGapMs(llm("up.test").providers), 0)
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
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}
#endif
