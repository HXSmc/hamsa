import XCTest
@testable import HamsaKit

final class BenchWERTests: XCTestCase {
    func testIdenticalAndNormalized() {
        XCTAssertEqual(BenchWER.errors(ref: "نحتاج نحدد السعر", hyp: "\u{200F}نحتاج نحدد السعر.").errors, 0)
        XCTAssertEqual(BenchWER.errors(ref: "إطلاق الباقة", hyp: "اطلاق الباقه").errors, 0)  // alef + taa marbuta
        XCTAssertEqual(BenchWER.errors(ref: "سَعر", hyp: "سعر؟").errors, 0)                  // tashkeel + Arabic ?
        XCTAssertEqual(BenchWER.errors(ref: "What is the price", hyp: "what is the price?").errors, 0)
    }

    func testEditCounts() {
        XCTAssertEqual(BenchWER.errors(ref: "a b c d", hyp: "a x c d").errors, 1)   // substitution
        XCTAssertEqual(BenchWER.errors(ref: "a b c d", hyp: "a c d").errors, 1)     // deletion
        XCTAssertEqual(BenchWER.errors(ref: "a b c d", hyp: "a b c d e").errors, 1) // insertion
        XCTAssertEqual(BenchWER.wer([("a b", "a b"), ("c d", "x y")]), 0.5, accuracy: 1e-9)
    }

    func testWordLags() {
        let lags = BenchWER.wordLags(finalWords: [("a", 1.0), ("b", 2.0)], hyps: [(1.3, "a"), (2.1, "a c"), (2.6, "a b")])
        XCTAssertEqual(lags.count, 2)
        XCTAssertEqual(lags[0], 0.3, accuracy: 1e-9)
        XCTAssertEqual(lags[1], 0.6, accuracy: 1e-9)
    }
}
