#if os(macOS)
import XCTest
@testable import HamsaKit

/// T12: overlay card rules (04-app-flow Journey 2).
@MainActor
final class OverlayTests: XCTestCase {
    typealias E = LivePipeline.Event
    let q = E.question(id: 1, channel: "them", text: "What is the price?")

    func testT2UpgradesSnippetInPlaceAndRefusalShowsNotInNotes() {
        let m = OverlayModel()
        XCTAssertEqual(m.state, .empty)
        m.apply(q)
        XCTAssertEqual(m.state, .searching)
        m.apply(.answer(questionID: 1, tier: "T1", text: "pricing.md\nSAR 49", provider: nil, done: true))
        XCTAssertEqual(m.state, .snippet)
        XCTAssertEqual(m.source, "pricing.md")
        XCTAssertEqual(m.body, "SAR 49")
        m.apply(.answer(questionID: 1, tier: "T2", text: "SAR", provider: "groq", done: false))
        XCTAssertEqual(m.state, .streaming)
        m.apply(.answer(questionID: 1, tier: "T2", text: "SAR 49 a month", provider: "groq", done: true))
        XCTAssertEqual(m.state, .answer)
        XCTAssertEqual(m.body, "SAR 49 a month")

        let r = OverlayModel()
        r.apply(q)
        r.apply(.answer(questionID: 1, tier: "T2", text: "Not in your notes.", provider: "groq", done: true))
        XCTAssertEqual(r.state, .notInNotes)
    }

    func testCardIsKeptOverSnippetAndRefusalAndOldAnswersIgnored() {
        let m = OverlayModel()
        m.apply(q)
        m.apply(.answer(questionID: 1, tier: "T0", text: "SAR 49", provider: nil, done: true))
        m.apply(.answer(questionID: 1, tier: "T1", text: "x\ny", provider: nil, done: true))
        m.apply(.answer(questionID: 1, tier: "T2", text: "Not", provider: "groq", done: false))
        m.apply(.answer(questionID: 1, tier: "T2", text: "Not in your notes.", provider: "groq", done: true))
        XCTAssertEqual(m.state, .card)
        XCTAssertEqual(m.body, "SAR 49")
        m.apply(.question(id: 2, channel: "them", text: "كم السعر؟"))
        m.apply(.answer(questionID: 1, tier: "T2", text: "late", provider: "groq", done: true))
        XCTAssertEqual(m.state, .searching)
        XCTAssertTrue(m.rtl)  // Arabic question, no answer yet
        m.apply(.answer(questionID: 2, tier: "T2", text: "٤٩ ريال", provider: "groq", done: true))
        XCTAssertTrue(m.rtl)
        XCTAssertEqual(m.badge, "AI")
    }

    func testRestartedAndAiOffStates() {
        let m = OverlayModel()
        m.sttRestarted = true
        XCTAssertEqual(m.state, .restarted)
        m.apply(q)
        XCTAssertFalse(m.sttRestarted)  // cleared by the next question
        m.aiOff = true
        XCTAssertTrue(m.aiOff)
    }
}
#endif
