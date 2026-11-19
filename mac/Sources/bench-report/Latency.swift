import ArgumentParser
import Foundation
import HamsaKit

/// T12: latency KPI table from the `latency_events` view of one meeting in live.sqlite (03-tdd budgets:
/// T0/T1 first text p50 <= 800 ms, T2 first token p50 <= 1.5 s). Negative values are kept as they are.
struct Latency: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "p50/p90 per tier vs budget from live.sqlite's latency_events.")

    @Option(help: "live.sqlite path (default: the bench-latency file).") var db = "~/Library/Application Support/Hamsa/bench-live.sqlite"
    @Option(help: "Meeting id (default: the latest meeting).") var meeting: String?

    func run() throws {
        let path = NSString(string: db).expandingTildeInPath
        guard let id = try meeting ?? LatencyKPI.latestMeeting(db: path) else { throw ValidationError("no meeting in \(path)") }
        let k = try LatencyKPI(db: path, meeting: id)
        print("meeting=\(id) db=\(path)  (first_text_ms from t_question_end_ms = STT final end)")
        print(Self.table([("first_text", Array(k.firstText.values), 800), ("T0", k.tiers["T0"] ?? [], 800),
                          ("T1", k.tiers["T1"] ?? [], 800), ("T2", k.tiers["T2"] ?? [], 1500)]))
    }

    static func table(_ rows: [(tier: String, ms: [Int], budget: Int)]) -> String {
        func right(_ s: String, _ w: Int) -> String { String(repeating: " ", count: max(0, w - s.count)) + s }
        var out = ["tier        n    p50_ms    p90_ms  budget_ms  result"]
        for r in rows {
            let p50 = LatencyKPI.pct(r.ms, 50)
            let result = Int(p50).map { $0 <= r.budget ? "pass" : "fail" } ?? "NA"
            out.append(r.tier.padding(toLength: 10, withPad: " ", startingAt: 0) + right("\(r.ms.count)", 4)
                       + right(p50, 10) + right(LatencyKPI.pct(r.ms, 90), 10) + right("\(r.budget)", 11) + "  " + result)
        }
        return out.joined(separator: "\n")
    }
}
