import Foundation
import XCTest
@testable import HamsaKit

/// T02a rehearse: `cue` is optional, old labels without it still decode, and the cue never enters the WER text.
final class CallLabelsCueTests: XCTestCase {
    func testCueRoundTrip() throws {
        let old = #"{"audio":{"them":"a.wav"},"provisional":true,"items":[{"channel":"them","start":0,"end":1,"text":"q","is_question":true,"tech":false,"verbatim":true}]}"#
        XCTAssertNil(try JSONDecoder().decode(CallLabels.self, from: Data(old.utf8)).items[0].cue)

        let labels = CallLabels(audio: ["them": "a.wav", "me": "a.me.wav"], provisional: true, items: [
            .init(channel: "me", start: 1, end: 2, text: "", isQuestion: false, verbatim: false, cue: "retention"),
        ])
        let back = try JSONDecoder().decode(CallLabels.self, from: JSONEncoder().encode(labels))
        XCTAssertEqual(back, labels)
        XCTAssertTrue(back.reference(channel: "me").isEmpty)
    }
}
