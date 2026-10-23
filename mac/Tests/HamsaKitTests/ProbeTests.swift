import XCTest
@testable import HamsaKit

final class ProbeTests: XCTestCase {
    func testIsArabic() {
        XCTAssertTrue(Probe.isArabic("السعر 49 دولار شهريا"))
        XCTAssertTrue(Probe.isArabic("نستخدم Swift للتطبيق"))
        XCTAssertTrue(Probe.isArabic("التطبيق مبني بـ Swift Native مع SwiftUI، والخدمة الخلفية بـ Python FastAPI."))
        XCTAssertFalse(Probe.isArabic("The price is 49 dollars"))
        XCTAssertFalse(Probe.isArabic("١٢٣ 456"))
    }

    func testPassesNormalizesAndAcceptsAlternatives() {
        XCTAssertTrue(Probe.passes(answer: "السعر ٤٩ دولار", expected: "49|٤٩"))
        XCTAssertTrue(Probe.passes(answer: "المؤسِّسة سَارَةُ", expected: "sara|سارة"))
        XCTAssertTrue(Probe.passes(answer: "إطلاق ويندوز قريب", expected: "اطلاق"))
        XCTAssertTrue(Probe.passes(answer: "نستخدم SWIFT", expected: "swift"))
        XCTAssertFalse(Probe.passes(answer: "السعر ٥٠ دولار", expected: "49|٤٩"))
        XCTAssertFalse(Probe.passes(answer: "The price is 49", expected: "49"))
    }

    func testPassesRejectsMoreThanThreeLines() {
        XCTAssertTrue(Probe.passes(answer: "سطر ٤٩\n\nسطر\nسطر", expected: "49"))
        XCTAssertFalse(Probe.passes(answer: "سطر ٤٩\nسطر\nسطر\nسطر", expected: "49"))
        XCTAssertFalse(Probe.passes(answer: "  \n ", expected: "49"))
    }

    func testPercentile() {
        let v = [5.0, 1, 3, 2, 4, 10, 9, 8, 7, 6]
        XCTAssertEqual(Probe.percentile(v, 50), 5)
        XCTAssertEqual(Probe.percentile(v, 90), 9)
        XCTAssertEqual(Probe.percentile(v, 100), 10)
        XCTAssertEqual(Probe.percentile([], 50), 0)
    }
}
