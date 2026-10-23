import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads index.sqlite / cards.sqlite from the brain (T07b). The live path never waits on this:
/// it runs before a call, and the last good copy stays in place if the brain is unreachable.
public struct BrainSync: Sendable {
    public enum Outcome: Equatable, Sendable { case updated, notModified }
    public enum SyncError: Error, Equatable { case http(Int), unknownFile(String) }

    public static let files = ["index.sqlite", "cards.sqlite"]

    let base: URL
    let token: String
    let dir: URL
    let session: URLSession

    public init(base: URL, token: String, dir: URL, session: URLSession = .shared) {
        self.base = base
        self.token = token
        self.dir = dir
        self.session = session
    }

    public func pull(_ name: String) async throws -> Outcome {
        guard Self.files.contains(name) else { throw SyncError.unknownFile(name) }
        let dest = dir.appendingPathComponent(name)
        let etagFile = dir.appendingPathComponent(name + ".etag")
        var req = URLRequest(url: base.appendingPathComponent("sync").appendingPathComponent(name))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if FileManager.default.fileExists(atPath: dest.path), let tag = try? String(contentsOf: etagFile, encoding: .utf8) {
            req.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 304 { return .notModified }
        guard code == 200 else { throw SyncError.http(code) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write beside, then swap, so a reader never sees a half-written database.
        let tmp = dir.appendingPathComponent(name + ".download")
        try data.write(to: tmp)
        _ = try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        if let tag = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") {
            try tag.write(to: etagFile, atomically: true, encoding: .utf8)
        }
        return .updated
    }
}
