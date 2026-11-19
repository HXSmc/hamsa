import ArgumentParser
import Foundation
import HamsaKit

/// T12: latency KPI table from the `latency_events` view of one meeting in live.sqlite (03-tdd budgets:
/// T0/T1 first text p50 <= 800 ms, T2 first token p50 <= 1.5 s). Negative values (text shown before the
/// question ended) are kept as they are.
struct Latency: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "p50/p90 per tier vs budget from live.sqlite's latency_events.")

    @Option(help: "live.sqlite path (default: the bench-latency file).") var db = "~/Library/Application Support/Hamsa/bench-live.sqlite"
    @Option(help: "Meeting id (default: the latest meeting).") var meeting: String?

    func run() throws {
        let path = NSString(string: db).expandingTildeInPath
        let sql = try SQLiteDB(path: path)
        var id = meeting ?? ""
        if meeting == nil { try sql.query("SELECT id FROM meetings ORDER BY rowid DESC LIMIT 1") { id = $0.text(0) } }
        guard !id.isEmpty else { throw ValidationError("no meeting in \(path)") }
        // Same rows as bench-latency's KPI line: per tier, and first text per question = the earlier of T0/T1.
        var tiers: [String: [Int]] = [:], first: [Int: Int] = [:]
        try sql.query("""
            SELECT l.id, l.tier, l.first_text_ms FROM latency_events l JOIN questions q ON q.id = l.id
            WHERE q.meeting_id = ? ORDER BY l.id
            """, [id]) {
            let (qid, tier, ms) = ($0.int(0), $0.text(1), $0.int(2))
            tiers[tier, default: []].append(ms)
            if tier != "T2" { first[qid] = min(first[qid] ?? ms, ms) }
        }
        print("meeting=\(id) db=\(path)")
        print(Self.table([("first_text", Array(first.values), 800), ("T0", tiers["T0"] ?? [], 800),
                          ("T1", tiers["T1"] ?? [], 800), ("T2", tiers["T2"] ?? [], 1500)]))
    }

    /// n = 0 prints NA, never a 0 that would read as a pass.
    static func table(_ rows: [(tier: String, ms: [Int], budget: Int)]) -> String {
        func pct(_ v: [Int], _ p: Double) -> String { v.isEmpty ? "NA" : String(Int(Probe.percentile(v.map(Double.init), p))) }
        var out = ["tier        n    p50_ms    p90_ms  budget_ms  result"]
        for r in rows {
            let result = r.ms.isEmpty ? "NA" : Probe.percentile(r.ms.map(Double.init), 50) <= Double(r.budget) ? "pass" : "fail"
            func right(_ s: String, _ w: Int) -> String { String(repeating: " ", count: max(0, w - s.count)) + s }
            out.append(r.tier.padding(toLength: 10, withPad: " ", startingAt: 0) + right("\(r.ms.count)", 4)
                       + right(pct(r.ms, 50), 10) + right(pct(r.ms, 90), 10) + right("\(r.budget)", 11) + "  " + result)
        }
        return out.joined(separator: "\n")
    }
}
