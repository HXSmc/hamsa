import Foundation
import HamsaBench
import HamsaKit

// Owner: T05b. `bench-match search INDEX PROJECT CASES.jsonl` — T10a parity with the brain:
// each case line is {"q": "...", "qvec": [384 floats], "brain_top": [chunk ids]}; prints top-5 overlap + latency.
let args = CommandLine.arguments
guard args.count == 5, args[1] == "search" else {
    print(HamsaBench.banner("bench-match") + "\nusage: bench-match search INDEX PROJECT CASES.jsonl")
    exit(2)
}
struct Case: Decodable { let q: String; let qvec: [Float]; let brain_top: [Int] }
let t0 = Date()
let index = try LocalIndex(path: args[2], projectID: args[3])
print("load_ms=\(Int(Date().timeIntervalSince(t0) * 1000)) chunks=\(index.chunkIDs.count) questions=\(index.questionChunkIDs.count)")
let cases = try String(contentsOfFile: args[4], encoding: .utf8).split(separator: "\n")
    .map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
var overlap = 0.0, same1 = 0, times: [Double] = []
for c in cases {
    let t = Date()
    let hits = try index.search(c.q, queryVector: c.qvec)
    times.append(Date().timeIntervalSince(t) * 1000)
    overlap += Double(Set(hits.map(\.chunkID)).intersection(c.brain_top).count) / Double(max(c.brain_top.count, 1))
    if hits.first?.chunkID == c.brain_top.first { same1 += 1 }
}
times.sort()
print("cases=\(cases.count) top5_overlap=\(String(format: "%.2f", overlap / Double(cases.count))) top1_same=\(same1)/\(cases.count) t1_p50_ms=\(String(format: "%.1f", times[times.count / 2]))")
