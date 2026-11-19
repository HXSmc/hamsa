import Foundation

/// T08: `live.sqlite` (docs/kickoff/06-backend-schema.md): meetings + segments; T11b adds `questions`,
/// `answer_events`, the `latency_events` view and `meetings.notes_consent` (schema 2). One row per utterance and channel: updated in place while
/// partials arrive (`is_final = 0`), closed with the final text (`is_final = 1`). An actor because both
/// channel workers write at once and SQLiteDB has no lock.
public actor LiveStore {
    public static let schema = """
    CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
    INSERT INTO schema_version (version) SELECT 2 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
    CREATE TABLE IF NOT EXISTS meetings (
      id TEXT PRIMARY KEY, project_id TEXT, title TEXT, app TEXT,
      started_at INTEGER NOT NULL, ended_at INTEGER, audio_dir TEXT, summary_path TEXT,
      confidential INTEGER NOT NULL DEFAULT 0, claude_allowed INTEGER NOT NULL DEFAULT 1,
      notes_consent INTEGER NOT NULL DEFAULT 0,
      status TEXT CHECK(status IN ('live','queued','summarized','deleted')));
    CREATE TABLE IF NOT EXISTS segments (
      id INTEGER PRIMARY KEY, meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,
      channel TEXT CHECK(channel IN ('me','them')), t_start_ms INTEGER, t_end_ms INTEGER,
      text TEXT NOT NULL, lang TEXT, is_final INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS segments_meeting_t ON segments(meeting_id, t_start_ms);
    CREATE TABLE IF NOT EXISTS questions (
      id INTEGER PRIMARY KEY, meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,
      segment_id INTEGER REFERENCES segments(id) ON DELETE SET NULL, text TEXT, detect_conf REAL,
      t_detect_ms INTEGER, t_question_end_ms INTEGER, matched_card_id INTEGER, match_score REAL,
      manual INTEGER DEFAULT 0);
    CREATE INDEX IF NOT EXISTS questions_meeting ON questions(meeting_id);
    CREATE TABLE IF NOT EXISTS answer_events (
      id INTEGER PRIMARY KEY, question_id INTEGER REFERENCES questions(id) ON DELETE CASCADE,
      tier TEXT CHECK(tier IN ('T0','T1','T2')), t_shown_ms INTEGER NOT NULL, text TEXT, provider TEXT,
      rating INTEGER CHECK(rating IN (-1,1)));
    CREATE INDEX IF NOT EXISTS answer_events_question ON answer_events(question_id);
    DROP VIEW IF EXISTS latency_events;
    CREATE VIEW latency_events AS
      SELECT q.id, a.tier, MAX(0, a.t_shown_ms - q.t_question_end_ms) AS first_text_ms FROM questions q
      JOIN answer_events a ON a.question_id = q.id
      WHERE a.id = (SELECT MIN(id) FROM answer_events WHERE question_id = q.id AND tier = a.tier);
    """

    let db: SQLiteDB
    /// Open (partial) row per meeting+channel.
    private var open: [String: Int] = [:]

    public init(path: String) throws {
        db = try SQLiteDB(path: path, readOnly: false)
        // Transcripts (confidential meetings too): owner-only, set before WAL so -wal/-shm inherit the mode.
        if path != ":memory:" { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try db.exec(Self.schema)
        // Schema 1 files (T08) have no notes_consent; CREATE TABLE IF NOT EXISTS does not add columns.
        var hasConsent = false
        try db.query("PRAGMA table_info(meetings)") { if $0.text(1) == "notes_consent" { hasConsent = true } }
        try db.exec("BEGIN; \(hasConsent ? "" : "ALTER TABLE meetings ADD COLUMN notes_consent INTEGER NOT NULL DEFAULT 0;") UPDATE schema_version SET version = 2 WHERE version < 2; COMMIT;")
    }

    /// `confidential`: no T2 request at all. `notesConsent`: owner OK for notes to reach providers that may
    /// train on prompts (Gemini free tier, ADR 002 decision 3). Both are read back per question by LivePipeline.
    public func startMeeting(id: String, title: String? = nil, app: String? = nil, audioDir: String? = nil,
                             startedAt: Int = Int(Date().timeIntervalSince1970), confidential: Bool = false,
                             notesConsent: Bool = false) throws {
        try db.query("""
            INSERT INTO meetings (id, title, app, audio_dir, started_at, status, confidential, notes_consent)
            VALUES (?, ?, ?, ?, ?, 'live', ?, ?)
            """, [id, title as Any, app as Any, audioDir as Any, startedAt, confidential, notesConsent]) { _ in }
    }

    /// The owner's confidential switch (use LivePipeline.setConfidential during a call: it also cancels the answer in flight).
    public func setConfidential(meeting: String, _ on: Bool) throws {
        try db.query("UPDATE meetings SET confidential = ? WHERE id = ?", [on, meeting]) { _ in }
    }

    /// Stored privacy state of a meeting. Unknown meeting = confidential (fail closed).
    public func privacy(meeting: String) throws -> (confidential: Bool, notesConsent: Bool) {
        var out = (confidential: true, notesConsent: false)
        try db.query("SELECT confidential, notes_consent FROM meetings WHERE id = ?", [meeting]) {
            out = ($0.int(0) != 0, $0.int(1) != 0)
        }
        return out
    }

    public func addQuestion(meeting: String, segmentID: Int?, text: String, detectConf: Double, tDetectMs: Int,
                            tQuestionEndMs: Int, cardID: Int? = nil, matchScore: Double? = nil) throws -> Int {
        try db.query("""
            INSERT INTO questions (meeting_id, segment_id, text, detect_conf, t_detect_ms, t_question_end_ms, matched_card_id, match_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [meeting, segmentID as Any, text, detectConf, tDetectMs, tQuestionEndMs, cardID as Any, matchScore as Any]) { _ in }
        return db.lastInsertRowID
    }

    /// The final segment landed: final text and end time.
    public func updateQuestion(id: Int, text: String, detectConf: Double, tQuestionEndMs: Int) throws {
        try db.query("UPDATE questions SET text = ?, detect_conf = MAX(detect_conf, ?), t_question_end_ms = ? WHERE id = ?",
                     [text, detectConf, tQuestionEndMs, id]) { _ in }
    }

    @discardableResult
    public func addAnswer(questionID: Int, tier: String, tShownMs: Int, text: String, provider: String? = nil) throws -> Int {
        try db.query("INSERT INTO answer_events (question_id, tier, t_shown_ms, text, provider) VALUES (?, ?, ?, ?, ?)",
                     [questionID, tier, tShownMs, text, provider as Any]) { _ in }
        return db.lastInsertRowID
    }

    public struct QuestionRow: Sendable {
        public let id: Int
        public let channel: String
        public let text: String
        public let tQuestionEndMs: Int
        public let tiers: [String]
        /// Has a T2 answer that is not the "Not in your notes." refusal.
        public let realT2: Bool
    }

    /// Questions of one meeting with the asker channel and the tiers shown for each.
    public func questions(meeting: String) throws -> [QuestionRow] {
        var out: [QuestionRow] = []
        try db.query("""
            SELECT q.id, COALESCE(s.channel, ''), q.text, q.t_question_end_ms,
                   COALESCE((SELECT GROUP_CONCAT(tier) FROM answer_events a WHERE a.question_id = q.id), ''),
                   EXISTS (SELECT 1 FROM answer_events a WHERE a.question_id = q.id AND a.tier = 'T2'
                           AND a.text NOT LIKE '%Not in your notes%')
            FROM questions q LEFT JOIN segments s ON s.id = q.segment_id WHERE q.meeting_id = ? ORDER BY q.id
            """, [meeting]) {
            out.append(QuestionRow(id: $0.int(0), channel: $0.text(1), text: $0.text(2), tQuestionEndMs: $0.int(3),
                                   tiers: $0.text(4).split(separator: ",").map(String.init), realT2: $0.int(5) != 0))
        }
        return out
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
