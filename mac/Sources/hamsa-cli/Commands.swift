import ArgumentParser
import HamsaKit

/// Owned by T01. Each later task adds its subcommand in its own file and one line here.
@main
struct HamsaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hamsa-cli",
        abstract: "Hamsa developer CLI.",
        version: Hamsa.version,
        subcommands: [Sync.self] + macOnly
    )
}

#if os(macOS)
private let macOnly: [ParsableCommand.Type] = [Capture.self, PanelTest.self, Transcribe.self, Rehearse.self]
#else
private let macOnly: [ParsableCommand.Type] = []
#endif
