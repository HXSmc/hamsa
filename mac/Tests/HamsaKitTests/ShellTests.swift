#if os(macOS)
import Foundation
import XCTest
@testable import HamsaKit

/// T13: the menu-bar meeting on the counting fake transport (AnswerLLMTests.Fake): confidential = 0 requests.
final class ShellTests: XCTestCase {
    typealias Fake = AnswerLLMTests.Fake
    private var dir: URL!
    override func setUp() {
        Fake.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hamsa-shell-" + UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func llm() -> AnswerLLM {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Fake.self]
        // The real chain (Groq + Gemini hosts) with a dummy key: every request is counted by the fake, none leaves.
        return AnswerLLM(providers: PipelineProviders.chain { _ in "k" }, session: URLSession(configuration: cfg))
    }

    func session(confidential: Bool) async throws -> MeetingSession {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LiveStore(path: HamsaHome(dir: dir).live.path)
        return try await MeetingSession(store: store, title: "t", project: "taweed", app: nil, confidential: confidential,
                                        llm: llm(), now: { 1000 })
    }

    func question(_ s: MeetingSession) async {
        await s.pipeline.ingest(STTUpdate(channel: "them", text: "What is the monthly price?", startMs: 100, endMs: 1000,
                                          isFinal: true, lang: "en", arrivalMs: 1000))
    }

    func testConfidentialStartSendsNoRequestAndSkipsSummary() async throws {
        let s = try await session(confidential: true)
        await question(s)
        let summary = try await s.stop()
        XCTAssertEqual(Fake.count(), 0, "a T2 request left a confidential meeting")
        XCTAssertFalse(summary)
        let priv = try await s.store.privacy(meeting: s.id)
        XCTAssertTrue(priv.confidential)
        XCTAssertFalse(priv.notesConsent)
    }

    func testNormalStartSendsAndClosesRow() async throws {
        let s = try await session(confidential: false)
        await question(s)
        let summary = try await s.stop()
        XCTAssertGreaterThanOrEqual(Fake.count(), 1)
        XCTAssertEqual(Fake.count("generativelanguage.googleapis.com"), 0, "Gemini needs notes consent")
        XCTAssertTrue(summary)
        var ended = 0
        try SQLiteDB(path: HamsaHome(dir: dir).live.path).query("SELECT ended_at IS NOT NULL FROM meetings WHERE id = ?", [s.id]) { ended = $0.int(0) }
        XCTAssertEqual(ended, 1)
    }

    func testMidCallSwitchOnMarksLocalOnly() async throws {
        let s = try await session(confidential: false)
        try await s.setConfidential(true)
        try await s.setConfidential(false)
        let summary = try await s.stop()
        XCTAssertFalse(summary, "a meeting that was confidential for a while must not be summarised by Claude")
    }

    func testPrepareOfflineAndCardCount() async throws {
        let home = HamsaHome(dir: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let status = await Prepare.run(home: home, brain: nil)
        XCTAssertEqual(status, "Using 0 cards from last sync (brain not linked, never synced)")
        let db = try SQLiteDB(path: home.cards.path, readOnly: false)
        try db.exec("CREATE TABLE cards (id INTEGER PRIMARY KEY); INSERT INTO cards VALUES (1),(2),(3);")
        XCTAssertEqual(Prepare.cardCount(home.cards), 3)
        let unreachable = BrainSync(base: URL(string: "http://127.0.0.1:9")!, token: "t", dir: dir)
        let s2 = await Prepare.run(home: home, brain: unreachable)
        XCTAssertTrue(s2.hasPrefix("Using 3 cards from last sync (brain unreachable, 0 h old"), s2)
    }

    func testSettingsAndTokenRules() throws {
        let home = HamsaHome(dir: dir)
        var s = ShellSettings()
        s.onboardingDone = true
        s.brainURL = "http://100.64.0.1:8770"
        try s.save(home)
        XCTAssertEqual(ShellSettings.load(home), s)
        let mode = try FileManager.default.attributesOfItem(atPath: home.settingsFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(HamsaHome.current(["HAMSA_HOME": dir.path]).live, home.live)
        XCTAssertTrue(ShellKeychain.isPlainToken("abcd_EFGH-1234.x"))
        XCTAssertFalse(ShellKeychain.isPlainToken("abc def ghij"), "a space would split the security -i command")
        XCTAssertFalse(ShellKeychain.isPlainToken("abcdefgh\nadd-generic-password"))
        XCTAssertFalse(ShellKeychain.isPlainToken("short"))
    }
}
#endif
