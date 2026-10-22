import XCTest
@testable import HamsaKit

final class HamsaTests: XCTestCase {
    func testVersion() { XCTAssertFalse(Hamsa.version.isEmpty) }
}
