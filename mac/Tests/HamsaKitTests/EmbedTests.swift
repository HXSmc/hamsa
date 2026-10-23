import Foundation
import XCTest
@testable import HamsaKit

final class EmbedTests: XCTestCase {
    func testPaddedPicksSmallestBucket() {
        let ids = [0, 5, 6, 2]
        let p = EmbedMath.padded(ids)
        XCTAssertEqual(p.count, 16)
        XCTAssertEqual(Array(p.prefix(4)), [0, 5, 6, 2])
        XCTAssertTrue(p.dropFirst(4).allSatisfy { $0 == Int32(EmbedMath.padID) })
        XCTAssertEqual(EmbedMath.padded([Int](repeating: 7, count: 17)).count, 32)
    }

    func testTruncatesLikeSentenceTransformers() {
        let p = EmbedMath.padded([0] + [Int](repeating: 9, count: 600) + [2])
        XCTAssertEqual(p.count, 512)
        XCTAssertEqual(p.last, Int32(EmbedMath.eosID))
        XCTAssertEqual(p[510], 9)
    }

    func testCosine() {
        XCTAssertEqual(EmbedMath.cosine([1, 0], [2, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(EmbedMath.cosine([1, 0], [0, 3]), 0, accuracy: 1e-6)
        XCTAssertEqual(EmbedMath.cosine([0, 0], [1, 0]), 0)
    }

    #if os(macOS) && canImport(Tokenizers)
    /// Needs the converted model (mac/Models/convert_e5.py); skipped in CI where it is not built.
    func testE5ModelWhenPresent() async throws {
        let dir = EmbedMath.defaultModelDir() ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Models/e5-small").standardized
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("E5Small.mlmodelc").path) else {
            throw XCTSkip("e5 model not built (run mac/Models/convert_e5.py)")
        }
        let e = try await E5Embedder.load(dir: dir)
        // Arabic diacritics must stay separate pieces (WhisperKit's vendored tokenizer turned them into <unk>).
        XCTAssertFalse(e.tokenIDs("تقريباً").contains(3))
        let a = try e.query("كم سعر الباقة الشهرية؟"), b = try e.query("وش سعر الاشتراك الشهري؟"), c = try e.query("Which GPU runs inference?")
        XCTAssertEqual(a.count, 384)
        XCTAssertEqual(EmbedMath.dot(a, a), 1, accuracy: 1e-3)
        XCTAssertGreaterThan(EmbedMath.cosine(a, b), EmbedMath.cosine(a, c))
    }
    #endif
}
