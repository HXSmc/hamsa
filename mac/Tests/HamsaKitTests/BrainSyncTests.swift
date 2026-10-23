import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HamsaKit

/// Fake brain: 304 when If-None-Match matches, else 200 with a body; 401 on a wrong token.
final class FakeBrain: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var hits = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.hits += 1
        let ok = request.value(forHTTPHeaderField: "Authorization") == "Bearer good"
        let fresh = request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\""
        let code = !ok ? 401 : (fresh ? 304 : 200)
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["ETag": "\"v1\""])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if code == 200 { client?.urlProtocol(self, didLoad: Data("SQLite format 3".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class BrainSyncTests: XCTestCase {
    func makeSync(token: String, dir: URL) -> BrainSync {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeBrain.self]
        return BrainSync(base: URL(string: "http://brain.test:8770")!, token: token, dir: dir, session: URLSession(configuration: cfg))
    }

    func testDownloadThenNotModified() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sync = makeSync(token: "good", dir: dir)
        let first = try await sync.pull("cards.sqlite")
        XCTAssertEqual(first, .updated)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("cards.sqlite"), encoding: .utf8), "SQLite format 3")
        let second = try await sync.pull("cards.sqlite")
        XCTAssertEqual(second, .notModified)
    }

    func testBadTokenKeepsOldCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try await makeSync(token: "good", dir: dir).pull("index.sqlite")
        do {
            _ = try await makeSync(token: "bad", dir: dir).pull("index.sqlite")
            XCTFail("expected 401")
        } catch BrainSync.SyncError.http(let code) {
            XCTAssertEqual(code, 401)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.sqlite").path))
    }

    func testRejectsUnknownFile() async {
        do {
            _ = try await makeSync(token: "good", dir: FileManager.default.temporaryDirectory).pull("../token")
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? BrainSync.SyncError, .unknownFile("../token"))
        }
    }
}
