#if os(macOS)
import XCTest
@testable import HamsaKit

/// T12: overlay card rules (04-app-flow Journey 2).
@MainActor
final class OverlayTests: XCTestCase {
    typealias E = LivePipeline.Event
    let q = E.question(id: 1, channel: "them", text: "What is the price?")
    func model(aiOff: Bool = false) -> OverlayModel { let m = OverlayModel(); m.live = true; m.aiOff = aiOff; return m }

    func testT2UpgradesSnippetInPlace() {
        let m = model()
        XCTAssertEqual(m.state, .listening)
        XCTAssertTrue(m.apply(q))
        XCTAssertEqual(m.state, .searching)
        XCTAssertTrue(m.apply(.answer(questionID: 1, tier: "T1", text: "Pricing > ## `Plans`\n- **Basic:** SAR 49.\n\nMore", provider: nil, done: true)))
        XCTAssertEqual(m.state, .snippet)
        XCTAssertEqual(m.source, "Pricing › Plans")
        XCTAssertEqual(OverlayModel.snippet("٦. المساعدة في الخطة.\n3) Second."), "المساعدة في الخطة.\nSecond.")
        XCTAssertEqual(OverlayModel.plain("HUMAN_CONFIRMATION"), "HUMAN CONFIRMATION")
        XCTAssertEqual(m.body, "**Basic:** SAR 49.")  // blank line gone, unfinished tail cut
        XCTAssertTrue(m.apply(.answer(questionID: 1, tier: "T2", text: "SAR", provider: "groq", done: false)))
        XCTAssertEqual(m.state, .streaming)
        XCTAssertEqual(m.body, "SAR …")
        m.apply(.answer(questionID: 1, tier: "T2", text: "SAR 49 a month", provider: "groq", done: true))
        XCTAssertEqual(m.state, .answer)
        XCTAssertEqual(m.source, "")  // a provider id is not a source
    }

    func testRefusalPrefixIsHeldOverSnippetThenShown() {
        let m = model()
        m.apply(q)
        m.apply(.answer(questionID: 1, tier: "T1", text: "Pricing\nSAR 49", provider: nil, done: true))
        XCTAssertFalse(m.apply(.answer(questionID: 1, tier: "T2", text: "Not", provider: "groq", done: false)))
        XCTAssertFalse(m.apply(.answer(questionID: 1, tier: "T2", text: "Not in your", provider: "groq", done: false)))
        XCTAssertEqual(m.state, .snippet)
        XCTAssertEqual(m.body, "SAR 49")
        XCTAssertTrue(m.apply(.answer(questionID: 1, tier: "T2", text: "Not in your notes.", provider: "groq", done: true)))
        XCTAssertEqual(m.state, .notInNotes)
        XCTAssertTrue(OverlayModel.isRefusal("مو موجود في ملاحظاتك"))
    }

    func testCardIsKeptAndOldAnswersIgnored() {
        let m = model()
        m.apply(q)
        m.apply(.answer(questionID: 1, tier: "T0", text: "SAR 49", provider: nil, done: true))
        XCTAssertFalse(m.apply(.answer(questionID: 1, tier: "T1", text: "x\ny", provider: nil, done: true)))
        XCTAssertFalse(m.apply(.answer(questionID: 1, tier: "T2", text: "Not in your notes.", provider: "groq", done: true)))
        XCTAssertEqual(m.state, .card)
        m.apply(.question(id: 2, channel: "them", text: "كم السعر؟"))
        XCTAssertFalse(m.apply(.answer(questionID: 1, tier: "T2", text: "late", provider: "groq", done: true)))
        XCTAssertEqual(m.state, .searching)
        XCTAssertTrue(m.ar)
        XCTAssertEqual(m.tr("Searching your notes"), "أدوّر في ملاحظاتك")
    }

    func testNoHitStatesNeverSitOnSearching() {
        let off = model(aiOff: true)
        off.apply(q)
        XCTAssertEqual(off.state, .notInNotes)  // AI off and no T0/T1: nothing else is coming
        let failed = model()
        failed.apply(q)
        XCTAssertTrue(failed.apply(.answerFailed(questionID: 1)))
        XCTAssertEqual(failed.state, .failed)
        let m = model()
        XCTAssertTrue(m.apply(.privacy(confidential: true)))
        XCTAssertTrue(m.aiOff)
        XCTAssertEqual(OverlayModel().state, .hidden)  // no meeting: no "Listening"
        XCTAssertTrue(OverlayModel().aiOff)  // fail closed until the stored state is read
        m.sttRestarted = true
        XCTAssertEqual(m.state, .restarted)
    }
}
#endif
