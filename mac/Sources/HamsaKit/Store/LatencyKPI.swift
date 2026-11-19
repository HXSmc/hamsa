import Foundation

/// T12: latency KPIs of one meeting from live.sqlite's `latency_events` view (03-tdd "Latency definitions"),
/// shared by `bench-latency` and `bench-report latency`. Values may be negative (text before the question ended).
public struct LatencyKPI: Sendable {
    /// first_text_ms per tier (first row of each tier per question).
    public var tiers: [String: [Int]] = [:]
    /// Per question: the earlier of its T0/T1 first_text_ms (03-tdd `first_text_ms`).
    public var firstText: [Int: Int] = [:]
    /// Per question: T2 first-token first_text_ms.
    public var t2First: [Int: Int] = [:]
    /// Per question: t_question_end_ms (STT final end on the pipeline clock).
    public var questionEnd: [Int: Int] = [:]

    public init(db: String, meeting: String) throws {
        try SQLiteDB(path: db).query("""
            SELECT l.id, l.tier, l.first_text_ms, q.t_question_end_ms FROM latency_events l
            JOIN questions q ON q.id = l.id WHERE q.meeting_id = ?
            """, [meeting]) {
            let (id, tier, ms) = ($0.int(0), $0.text(1), $0.int(2))
            tiers[tier, default: []].append(ms)
            questionEnd[id] = $0.int(3)
            if tier == "T2" { t2First[id] = ms } else { firstText[id] = min(firstText[id] ?? ms, ms) }
        }
    }

    public static func latestMeeting(db: String) throws -> String? {
        var id: String?
        try SQLiteDB(path: db).query("SELECT id FROM meetings ORDER BY rowid DESC LIMIT 1") { id = $0.text(0) }
        return id
    }

    /// Nearest-rank percentile as text; "NA" for no data (never a 0 that reads as a pass).
    public static func pct(_ v: [Int], _ p: Double) -> String {
        v.isEmpty ? "NA" : String(Int(Probe.percentile(v.map(Double.init), p)))
    }
}
