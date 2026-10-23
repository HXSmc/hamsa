import Foundation
import XCTest
@testable import HamsaKit

final class CardMatcherTests: XCTestCase {
    func vec(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    func makeCards() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
            CREATE TABLE cards(id INTEGER PRIMARY KEY, project_id TEXT, question_en TEXT, question_ar TEXT,
              answer_en TEXT, answer_ar_sa TEXT, source_chunk_ids TEXT, status TEXT);
            CREATE TABLE card_vectors(card_id INTEGER, n INTEGER, embedding BLOB);
            INSERT INTO cards VALUES (1,'taweed','Which GPU?','وش الـGPU؟','L4 in Riyadh.','L4 بالرياض.','[7]','active'),
                                     (2,'taweed','Price?','كم السعر؟','150 SAR per claim.','١٥٠ ريال للمطالبة.','[8]','active'),
                                     (3,'taweed','Old?','قديم؟','x','x','[9]','retired');
            """)
        for (id, n, v) in [(1, 0, [1, 0, 0] as [Float]), (1, 1, [0.8, 0, 0.6]), (2, 0, [0, 1, 0]), (3, 0, [0, 0, 1])] {
            try db.query("INSERT INTO card_vectors VALUES (?, ?, ?)", [id, n, vec(v)]) { _ in }
        }
        return path
    }

    func testConfidentMatch() throws {
        let m = try CardMatcher(path: makeCards(), projectID: "taweed", dim: 3)
        XCTAssertEqual(m.count, 2)  // retired card not loaded
        let hit = m.match([1, 0, 0])
        XCTAssertEqual(hit?.card.id, 1)
        XCTAssertEqual(hit?.card.sourceChunkIDs, [7])
    }

    func testAmbiguousOrWeakGivesNothing() throws {
        let m = try CardMatcher(path: makeCards(), projectID: "taweed", dim: 3)
        XCTAssertNil(m.match([0.707, 0.707, 0]))  // close to both cards: margin too small
        XCTAssertNil(m.match([0, 0, 1]))          // only the retired card is near
    }
}
