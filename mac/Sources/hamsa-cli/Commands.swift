import ArgumentParser
import HamsaKit

/// Owned by T01. Each later task adds its subcommand in its own file and one line here.
struct HamsaCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hamsa-cli",
        abstract: "Hamsa developer CLI.",
        version: Hamsa.version,
        subcommands: []
    )
}
