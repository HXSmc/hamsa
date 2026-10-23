import ArgumentParser
import Foundation
import HamsaKit

/// T07b: pull index.sqlite + cards.sqlite from the brain before a call.
struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download the latest index and cards from the brain.")

    @Option(help: "Brain base URL, e.g. http://100.x.y.z:8770") var brain: String
    @Option(help: "File holding the bearer token (Keychain support comes with the app).") var tokenFile: String
    @Option(help: "Local folder for the databases.") var dir: String = "~/Library/Application Support/Hamsa"

    func run() async throws {
        let token = try String(contentsOfFile: NSString(string: tokenFile).expandingTildeInPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: brain) else { throw ValidationError("bad --brain URL") }
        let sync = BrainSync(base: base, token: token, dir: URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath))
        for name in BrainSync.files {
            do {
                print("\(name): \(try await sync.pull(name))")
            } catch BrainSync.SyncError.http(404) {
                print("\(name): not built yet on the brain")
            }
        }
    }
}
