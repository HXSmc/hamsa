import ArgumentParser
import Foundation
import HamsaKit

/// T04: record system audio ("them") and the microphone ("me") to 16 kHz mono WAVs and print their levels.
struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record them.wav (system audio) and me.wav (mic) for N seconds.")

    @Option(help: "Seconds to record.") var seconds: Int = 10
    @Option(help: "Output folder.") var out: String = "/tmp/cap"

    func run() async throws {
        let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let them = try WavWriter(url: dir.appendingPathComponent("them.wav"))
        let me = try WavWriter(url: dir.appendingPathComponent("me.wav"))
        print("ALLOW_NEEDED: macOS may ask for microphone + system audio recording permission")

        // Mic first: it makes this process an audio client, so the tap can exclude it by process object.
        let mic = MicCapture()
        var failed = false
        do { try mic.start { me.append($0) } } catch { print("ERROR: mic: \(error)"); failed = true }

        var stopTap: () -> Void = {}
        if #available(macOS 14.2, *) {
            let tap = SystemTap()
            do { try tap.start { them.append($0) }; stopTap = { tap.stop() } } catch { print("ERROR: system tap: \(error)"); failed = true }
        } else {
            print("ERROR: system audio tap needs macOS 14.2+"); failed = true
        }

        try? await Task.sleep(for: .seconds(seconds))
        stopTap()
        mic.stop()
        them.finish(); me.finish()
        print(String(format: "them.wav rms_dbfs=%.1f", them.rmsDbfs))
        print(String(format: "me.wav rms_dbfs=%.1f", me.rmsDbfs))
        for (n, w) in [("them", them), ("me", me)] { if let e = w.firstError { print("WARN: \(n) write: \(e)") } }
        if failed { throw ExitCode.failure }
    }
}

