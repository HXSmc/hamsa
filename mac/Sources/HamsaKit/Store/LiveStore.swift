import Foundation

/// T08: `live.sqlite` (docs/kickoff/06-backend-schema.md): meetings + segments. `questions` / `answer_events`
/// are added by their owning tasks (T09 / T11). One row per utterance and channel: updated in place while
/// partials arrive (`is_final = 0`), closed with the final text (`is_final = 1`). An actor because both
/// channel workers write at once and SQLiteDB has no lock.
public actor LiveStore {
    public static let schema = """
    CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
    INSERT INTO schema_version (version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
    CREATE TABLE IF NOT EXISTS meetings (
      id TEXT PRIMARY KEY, project_id TEXT, title TEXT, app TEXT,
      started_at INTEGER NOT NULL, ended_at INTEGER, audio_dir TEXT, summary_path TEXT,
      confidential INTEGER NOT NULL DEFAULT 0, claude_allowed INTEGER NOT NULL DEFAULT 1,
      status TEXT CHECK(status IN ('live','queued','summarized','deleted')));
    CREATE TABLE IF NOT EXISTS segments (
      id INTEGER PRIMARY KEY, meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,
      channel TEXT CHECK(channel IN ('me','them')), t_start_ms INTEGER, t_end_ms INTEGER,
      text TEXT NOT NULL, lang TEXT, is_final INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS segments_meeting_t ON segments(meeting_id, t_start_ms);
    """

    let db: SQLiteDB
    /// Open (partial) row per meeting+channel.
    private var open: [String: Int] = [:]

    public init(path: String) throws {
        db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try db.exec(Self.schema)
    }

    public func startMeeting(id: String, title: String? = nil, app: String? = nil, audioDir: String? = nil,
                             startedAt: Int = Int(Date().timeIntervalSince1970)) throws {
        try db.query("INSERT INTO meetings (id, title, app, audio_dir, started_at, status) VALUES (?, ?, ?, ?, ?, 'live')",
                     [id, title as Any, app as Any, audioDir as Any, startedAt]) { _ in }
    }

    public func endMeeting(id: String, endedAt: Int = Int(Date().timeIntervalSince1970)) throws {
        try db.query("UPDATE meetings SET ended_at = ?, status = 'queued' WHERE id = ?", [endedAt, id]) { _ in }
    }

    /// Writes one STT result; returns the segment row id.
    @discardableResult
    public func write(_ u: STTUpdate, meeting: String) throws -> Int {
        let key = meeting + "/" + u.channel
        if let id = open[key] {
            try db.query("UPDATE segments SET t_start_ms = ?, t_end_ms = ?, text = ?, lang = ?, is_final = ? WHERE id = ?",
                         [u.startMs, u.endMs, u.text, u.lang, u.isFinal ? 1 : 0, id]) { _ in }
            if u.isFinal { open[key] = nil }
            return id
        }
        try db.query("INSERT INTO segments (meeting_id, channel, t_start_ms, t_end_ms, text, lang, is_final) VALUES (?, ?, ?, ?, ?, ?, ?)",
                     [meeting, u.channel, u.startMs, u.endMs, u.text, u.lang, u.isFinal ? 1 : 0]) { _ in }
        let id = db.lastInsertRowID
        if !u.isFinal { open[key] = id }
        return id
    }

    /// A worker died mid-utterance: its open partial row stays (is_final = 0) and the next result opens a new row.
    public func closeOpen(meeting: String, channel: String) { open[meeting + "/" + channel] = nil }

    /// Rows for one meeting: channel → (final, partial).
    public func counts(meeting: String) throws -> [String: (final: Int, partial: Int)] {
        var out: [String: (final: Int, partial: Int)] = [:]
        try db.query("SELECT channel, is_final, COUNT(*) FROM segments WHERE meeting_id = ? GROUP BY channel, is_final", [meeting]) { r in
            var c = out[r.text(0)] ?? (0, 0)
            if r.int(1) == 1 { c.final = r.int(2) } else { c.partial = r.int(2) }
            out[r.text(0)] = c
        }
        return out
    }

    /// Final text of one channel in time order.
    public func finalText(meeting: String, channel: String) throws -> String {
        var parts: [String] = []
        try db.query("SELECT text FROM segments WHERE meeting_id = ? AND channel = ? AND is_final = 1 ORDER BY t_start_ms",
                     [meeting, channel]) { parts.append($0.text(0)) }
        return parts.joined(separator: " ")
    }
}
