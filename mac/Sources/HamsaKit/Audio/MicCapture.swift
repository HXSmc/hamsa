#if os(macOS)
import AVFoundation
import Foundation

/// T04: the user's microphone ("me" channel) via an AVAudioEngine input tap.
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var running = false

    public init() {}

    public func start(onBuffer: @escaping AudioSink) throws {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        if auth == .denied || auth == .restricted { throw AudioError("microphone permission denied (System Settings > Privacy > Microphone)") }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError("no microphone input format (permission pending or no input device)")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in onBuffer(buffer) }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioError("mic engine failed: \(error)", status: OSStatus((error as NSError).code))
        }
        running = true
    }

    public func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
#endif
