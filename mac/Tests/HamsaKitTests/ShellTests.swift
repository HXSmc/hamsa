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

    /// Stored (confidential, claude_allowed) of one meeting, read on a separate connection.
    func pair(_ id: String) throws -> String {
        var out = "none"
        try SQLiteDB(path: HamsaHome(dir: dir).live.path).query("SELECT confidential, claude_allowed FROM meetings WHERE id = ?", [id]) {
            out = "\($0.int(0)),\($0.int(1))"
        }
        return out
    }
    func sql(_ q: String) throws { try SQLiteDB(path: HamsaHome(dir: dir).live.path, readOnly: false).exec(q) }

    func testConfidentialStartStoresPairInOneGo() async throws {
        let s = try await session(confidential: true)
        XCTAssertEqual(try pair(s.id), "1,0")
        _ = try await s.stop()
        XCTAssertEqual(try pair(s.id), "1,0")
    }

    func testOnThenOffEndsLocalOnly() async throws {
        let s = try await session(confidential: false)
        XCTAssertEqual(try pair(s.id), "0,1")
        try await s.setConfidential(true)
        try await s.setConfidential(false)
        let summary = try await s.stop()
        XCTAssertFalse(summary, "a meeting that was confidential for a while must not be summarised by Claude")
        XCTAssertEqual(try pair(s.id), "1,0", "the brain skips only confidential=1 AND claude_allowed=0")
    }

    func testFailedMidCallOnWriteStillDisallowsAndLatches() async throws {
        let s = try await session(confidential: false)
        try sql("CREATE TRIGGER no_conf BEFORE UPDATE OF confidential ON meetings BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        var threw = false
        do { try await s.setConfidential(true) } catch { threw = true }
        XCTAssertTrue(threw, "the injected write failure did not fire")
        XCTAssertEqual(try pair(s.id), "0,0", "claude_allowed=0 must be written even when the pipeline write fails")
        await question(s)
        XCTAssertEqual(Fake.count(), 0, "the latch must hold after a failed ON write")
        try sql("DROP TRIGGER no_conf;")
        _ = try await s.stop()
        XCTAssertEqual(try pair(s.id), "1,0", "Stop re-asserts the pair for a meeting that was ever ON")
    }

    func testFailedStartLeavesNoRow() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LiveStore(path: HamsaHome(dir: dir).live.path)
        try sql("CREATE TRIGGER no_project BEFORE UPDATE OF project_id ON meetings BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        var threw = false
        do { _ = try await MeetingSession(store: store, title: "t", project: "taweed", app: nil, confidential: true, llm: llm(), now: { 1000 }) }
        catch { threw = true }
        XCTAssertTrue(threw, "the injected setProject failure did not fire")
        var rows = -1
        try SQLiteDB(path: HamsaHome(dir: dir).live.path).query("SELECT COUNT(*) FROM meetings") { rows = $0.int(0) }
        XCTAssertEqual(rows, 0, "a failed start must leave no (1,1) or live row")
        // The connection is usable afterwards (the transaction was rolled back, not left open).
        try sql("DROP TRIGGER no_project;")
        let s = try await MeetingSession(store: store, title: "t", project: "taweed", app: nil, confidential: false, llm: llm(), now: { 1000 })
        XCTAssertEqual(try pair(s.id), "0,1")
    }

    func testBrainLinkRules() {
        func ok(_ s: String) -> Bool { BrainLink.isAllowed(URL(string: s)!) }
        XCTAssertTrue(ok("http://100.64.0.0:8770"))
        XCTAssertTrue(ok("http://100.127.255.255:8770"))
        XCTAssertFalse(ok("http://100.63.255.255:8770"))
        XCTAssertFalse(ok("http://100.128.0.0:8770"))
        XCTAssertFalse(ok("http://100.64.0.1.evil.com:8770"))
        XCTAssertTrue(ok("http://mini.tail1234.TS.NET:8770"))
        XCTAssertFalse(ok("http://ts.net.evil.com"))
        XCTAssertTrue(ok("http://localhost:8770"))
        XCTAssertTrue(ok("http://127.0.0.1:9"))
        XCTAssertTrue(ok("http://[::1]:8770"))
        XCTAssertFalse(ok("http://192.168.1.10:8770"))
        XCTAssertTrue(ok("https://brain.example.com"))
        XCTAssertFalse(ok("ftp://100.64.0.1"))
    }

    func testHooksNeedScratchHome() throws {
        XCTAssertNil(HamsaHome.testHome([:]))
        XCTAssertNil(HamsaHome.testHome(["HAMSA_HOME": ""]))
        XCTAssertNil(HamsaHome.testHome(["HAMSA_HOME": "~/Library/Application Support/Hamsa"]), "the real home is not a scratch home")
        let home = try XCTUnwrap(HamsaHome.testHome(["HAMSA_HOME": dir.path]))
        XCTAssertTrue(home.contains(dir.appendingPathComponent("probe.txt").path))
        XCTAssertFalse(home.contains(dir.path + "Evil/probe.txt"))
        XCTAssertFalse(home.contains(dir.appendingPathComponent("../probe.txt").path))
        XCTAssertFalse(home.contains("/etc/probe.txt"))
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
