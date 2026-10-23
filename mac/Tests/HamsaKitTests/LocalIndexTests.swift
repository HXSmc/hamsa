import Foundation
import XCTest
@testable import HamsaKit

final class LocalIndexTests: XCTestCase {
    func vec(_ hot: Int, dim: Int = 4) -> Data {
        var v = [Float](repeating: 0, count: dim); v[hot] = 1
        return v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func makeIndex() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
            CREATE TABLE sources(id INTEGER PRIMARY KEY, project_id TEXT, path TEXT);
            CREATE TABLE chunks(id INTEGER PRIMARY KEY, source_id INTEGER, heading TEXT, text TEXT);
            CREATE VIRTUAL TABLE chunks_fts USING fts5(heading, text, content='chunks', content_rowid='id');
            CREATE TABLE chunk_vectors(chunk_id INTEGER PRIMARY KEY, embedding BLOB);
            CREATE TABLE chunk_questions(id INTEGER PRIMARY KEY, chunk_id INTEGER, q TEXT, lang TEXT, embedding BLOB);
            INSERT INTO sources VALUES (1,'taweed','/v/Taweed.md'), (2,'other','/v/Other.md');
            INSERT INTO chunks VALUES (1,1,'Infra','Inference runs on an L4 GPU in Riyadh'),
                                      (2,1,'Pricing','السعر ١٥٠ ريال للمطالبة'),
                                      (3,2,'Infra','Other project GPU A100');
            INSERT INTO chunks_fts(rowid, heading, text) SELECT id, heading, text FROM chunks;
            """)
        for (id, hot) in [(1, 0), (2, 1), (3, 0)] {
            try db.query("INSERT INTO chunk_vectors VALUES (?, ?)", [id, vec(hot)]) { _ in }
        }
        try db.query("INSERT INTO chunk_questions(chunk_id, q, lang, embedding) VALUES (2, 'بكم المطالبة', 'ar', ?)", [vec(2)]) { _ in }
        return path
    }

    func testHybridSearchStaysInProject() throws {
        let idx = try LocalIndex(path: makeIndex(), projectID: "taweed", dim: 4)
        XCTAssertEqual(idx.chunkIDs.sorted(), [1, 2])
        let gpu = try idx.search("which GPU", queryVector: [1, 0, 0, 0])
        XCTAssertEqual(gpu.first?.chunkID, 1)
        XCTAssertFalse(gpu.contains { $0.chunkID == 3 })
    }

    func testGeneratedQuestionFindsArabicChunk() throws {
        // Query vector only matches the Claude-written question, not the chunk text vector.
        let idx = try LocalIndex(path: makeIndex(), projectID: "taweed", dim: 4)
        XCTAssertEqual(try idx.search("كم تاخذون", queryVector: [0, 0, 1, 0]).first?.chunkID, 2)
    }
}
