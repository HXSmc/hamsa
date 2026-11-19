import ArgumentParser
import HamsaBench

/// Owned by T01. Each later task adds its subcommand in its own file and one line here.
struct BenchReport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench-report", abstract: HamsaBench.banner("bench-report"), subcommands: [Latency.self])
}

BenchReport.main()
