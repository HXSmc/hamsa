#if os(macOS)
import Foundation

/// T13: where the app keeps its files. `HAMSA_HOME=<dir>` (tests) moves settings and every sqlite file there,
/// so a test run never touches the owner's real meetings. The Keychain is not redirected (read-only in tests).
public struct HamsaHome: Sendable {
    public let dir: URL
    public init(dir: URL) { self.dir = dir }
    public static func current(_ env: [String: String] = ProcessInfo.processInfo.environment) -> HamsaHome {
        if let h = env["HAMSA_HOME"], !h.isEmpty { return HamsaHome(dir: URL(fileURLWithPath: NSString(string: h).expandingTildeInPath)) }
        return HamsaHome(dir: URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Hamsa").expandingTildeInPath))
    }
    public var live: URL { dir.appendingPathComponent("live.sqlite") }
    public var cards: URL { dir.appendingPathComponent("cards.sqlite") }
    public var index: URL { dir.appendingPathComponent("index.sqlite") }
    public var settingsFile: URL { dir.appendingPathComponent("settings.json") }

    /// Test launch hooks run only against a scratch home: HAMSA_HOME set and not the real one.
    public static func testHome(_ env: [String: String] = ProcessInfo.processInfo.environment) -> HamsaHome? {
        guard let h = env["HAMSA_HOME"], !h.isEmpty else { return nil }
        let home = current(env)
        return home.dir.resolvingSymlinksInPath().standardized == current([:]).dir.resolvingSymlinksInPath().standardized ? nil : home
    }

    /// `path` lies inside this home (symlinks and `..` resolved; `/x/homeEvil` is not inside `/x/home`).
    public func contains(_ path: String) -> Bool {
        let root = dir.resolvingSymlinksInPath().standardized.path
        let file = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().standardized
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        return file.hasPrefix(root + "/")
    }
}

/// Which capture failed at Start, so the app can route to the right permission help without matching error text.
public enum AudioStartError: Error {
    case microphone(Error)
    case systemAudio(Error)
}

/// Brain address rules: the token travels as a Bearer header, so plain http only where the link is already
/// private (Tailscale 100.64.0.0/10, *.ts.net, this Mac); https everywhere else.
public enum BrainLink {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".ts.net") || isTailscaleIPv4(host)
        default: return false
        }
    }

    /// Exactly four decimal octets, first 100, second 64...127.
    static func isTailscaleIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let n = parts.compactMap { $0.count <= 3 && $0.allSatisfy(\.isNumber) ? Int($0) : nil }
        return n.count == 4 && n.allSatisfy { $0 <= 255 } && n[0] == 100 && (64...127).contains(n[1])
    }
}

/// Non-secret app settings (no keys or tokens: those live in the Keychain only).
public struct ShellSettings: Codable, Equatable, Sendable {
    public var onboardingDone = false
    public var brainURL = ""
    public var project = "taweed"
    /// The brain address the Keychain token was saved for (optional: older settings files have no such key).
    public var brainTokenFor: String?
    public init() {}

    public static func load(_ home: HamsaHome) -> ShellSettings {
        (try? JSONDecoder().decode(ShellSettings.self, from: Data(contentsOf: home.settingsFile))) ?? ShellSettings()
    }
    public func save(_ home: HamsaHome) throws {
        try FileManager.default.createDirectory(at: home.dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: home.settingsFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.settingsFile.path)
    }
}

/// Keychain via /usr/bin/security, like PipelineProviders.keychainKey (items stay readable by that tool).
/// Secrets go in on stdin (`security -i`), never on a command line, and are never printed or logged.
public enum ShellKeychain {
    public static let groq = (service: "hamsa", account: "groq")
    public static let brain = (service: "hamsa-brain", account: "brain")

    /// Presence only: no `-w`/`-g`, the secret is never read.
    public static func has(service: String, account: String) -> Bool {
        run(["find-generic-password", "-s", service, "-a", account], stdin: nil).status == 0
    }

    /// Value for in-process use (brain token for sync). Never print it.
    public static func read(service: String, account: String) -> String? {
        let r = run(["find-generic-password", "-s", service, "-a", account, "-w"], stdin: nil)
        let v = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !v.isEmpty ? v : nil
    }

    /// Keys and tokens are plain tokens: anything else could break out of the `security -i` command line.
    public static func isPlainToken(_ s: String) -> Bool {
        (8...512).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    @discardableResult
    public static func save(service: String, account: String, secret: String) -> Bool {
        guard isPlainToken(secret) else { return false }
        // `security -i` exit status on a failed inner command is unverified, so confirm the item is there.
        // shortcut: on a replace this proves an item exists, not that it is the new one; SecItem API once signed.
        return run(["-i"], stdin: "add-generic-password -U -s \(service) -a \(account) -w \(secret)\n").status == 0
            && has(service: service, account: account)
    }

    static func run(_ args: [String], stdin: String?) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = inp
        do { try p.run() } catch { return (-1, "") }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Prepare (04-app-flow Journey 1): pull the brain's index + cards, then report what the local store holds.
public enum Prepare {
    /// Cards in the local store (`select count(*) from cards`); a missing or empty file counts 0.
    public static func cardCount(_ url: URL) -> Int {
        guard let db = try? SQLiteDB(path: url.path) else { return 0 }
        var n = 0
        try? db.query("SELECT COUNT(*) FROM cards") { n = $0.int(0) }
        return n
    }

    /// Project ids registered in the local index; Taweed when there is no index yet.
    public static func projects(_ index: URL) -> [String] {
        var ids: [String] = []
        if let db = try? SQLiteDB(path: index.path) { try? db.query("SELECT id FROM projects ORDER BY id") { ids.append($0.text(0)) } }
        return ids.isEmpty ? ["taweed"] : ids
    }

    static func age(_ url: URL, now: Date) -> String? {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) > 0 else { return nil }
        let h = Int(now.timeIntervalSince(m) / 3600)
        return h < 48 ? "\(h) h old" : "\(h / 24) days old"
    }

    /// `brain` nil = not linked (no address or no token). Start stays allowed whatever this returns.
    /// `offline`: the line is the "Using N cards from last sync" fallback, not "Ready".
    public static func run(home: HamsaHome, brain: BrainSync?, now: Date = Date()) async -> (text: String, offline: Bool) {
        guard let brain else { return offline(home, "brain not linked", now) }
        do {
            for name in BrainSync.files {
                do { _ = try await brain.pull(name) } catch BrainSync.SyncError.http(404) { continue }  // not built yet
            }
        } catch BrainSync.SyncError.http(401) {
            return offline(home, "brain refused the token", now)
        } catch {
            return offline(home, "brain unreachable", now)
        }
        let n = cardCount(home.cards)
        if n == 0 { return offline(home, "the brain has no cards yet", now) }  // 404s: nothing built, not "Ready"
        let index = age(home.index, now: now).map { ", index \($0)" } ?? ""
        return ("Ready: \(n) cards\(index)", false)
    }

    static func offline(_ home: HamsaHome, _ why: String, _ now: Date) -> (text: String, offline: Bool) {
        let synced = age(home.cards, now: now).map { ", \($0)" } ?? ", never synced"
        return ("Using \(cardCount(home.cards)) cards from last sync (\(why)\(synced))", true)
    }
}

extension LiveStore {
    /// Opens the row in one transaction: confidential flag (via startMeeting), project, and for a confidential
    /// meeting `claude_allowed = 0`. Any failure rolls back: no half-written (confidential=1, claude_allowed=1) row.
    public func openMeeting(id: String, title: String, app: String?, project: String, confidential: Bool) throws {
        try db.exec("BEGIN IMMEDIATE")
        do {
            try startMeeting(id: id, title: title, app: app, confidential: confidential, notesConsent: false)
            try db.query("UPDATE meetings SET project_id = ?, claude_allowed = ? WHERE id = ?", [project, !confidential, id]) { _ in }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }
    /// End state of a meeting that was ever confidential: (confidential=1, claude_allowed=0), one statement.
    public func markLocalOnly(meeting: String) throws {
        try db.query("UPDATE meetings SET confidential = 1, claude_allowed = 0 WHERE id = ?", [meeting]) { _ in }
    }
    /// `claude_allowed = 0`: the brain must not send this meeting to Claude (summary skipped). One way only.
    public func disallowClaude(meeting: String) throws {
        try db.query("UPDATE meetings SET claude_allowed = 0 WHERE id = ?", [meeting]) { _ in }
    }
    /// Crash repair: an ON->OFF flip stores (0,0) until Stop re-asserts (1,0), so a (0,0) row left by a crash would be
    /// summarised. Run once when the app opens the store, before this process starts a meeting: every row qualifies.
    /// Never call it while a meeting is live (the pipeline re-reads `confidential` before each send).
    public func repairCrashedConfidential() throws {
        try db.query("UPDATE meetings SET confidential = 1 WHERE claude_allowed = 0 AND confidential = 0", []) { _ in }
    }
    public func claudeAllowed(meeting: String) throws -> Bool {
        var out = false
        try db.query("SELECT claude_allowed FROM meetings WHERE id = ?", [meeting]) { out = $0.int(0) != 0 }
        return out
    }
}
#endif
