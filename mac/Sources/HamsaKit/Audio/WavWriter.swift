#if os(macOS)
import AVFoundation
import Foundation

/// Receives audio buffers on whatever thread the capture source uses. The buffer is only valid during the call.
public typealias AudioSink = @Sendable (AVAudioPCMBuffer) -> Void

public struct AudioError: Error, CustomStringConvertible {
    public let what: String
    public let status: OSStatus
    public init(_ what: String, status: OSStatus = 0) { self.what = what; self.status = status }
    public var description: String { status == 0 ? what : "\(what) (OSStatus \(status))" }
}

/// Holds the one buffer handed to AVAudioConverter's input block (the block is @Sendable, buffers are not).
private final class Feed: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Converts any incoming buffers to 16 kHz mono Int16 and writes a WAV file, tracking RMS over everything written.
public final class WavWriter: @unchecked Sendable {
    public static let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var sumSquares = 0.0
    private var samples = 0
    private var written = 0
    private let started = ContinuousClock.now
    public private(set) var firstError: String?

    public init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file, buffer.frameLength > 0 else { return }
        do {
            if converter == nil || inFormat != buffer.format {
                inFormat = buffer.format
                converter = AVAudioConverter(from: buffer.format, to: Self.outFormat)
            }
            guard let converter else { throw AudioError("no converter for \(buffer.format)") }
            let ratio = Self.outFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: capacity) else {
                throw AudioError("cannot allocate output buffer")
            }
            let feed = Feed(buffer)
            var convError: NSError?
            // .noDataNow (not .endOfStream) keeps the resampler state across calls.
            let status = converter.convert(to: out, error: &convError) { _, inputStatus in
                guard let next = feed.buffer else { inputStatus.pointee = .noDataNow; return nil }
                feed.buffer = nil
                inputStatus.pointee = .haveData
                return next
            }
            if status == .error { throw convError ?? AudioError("convert failed") }
            let n = Int(out.frameLength)
            guard n > 0, let ptr = out.int16ChannelData?[0] else { return }
            var acc = 0.0
            for i in 0..<n { let s = Double(ptr[i]) / 32768.0; acc += s * s }
            sumSquares += acc
            samples += n
            try padSilence(upTo: elapsedFrames() - n)
            try file.write(from: out)
            written += n
        } catch {
            if firstError == nil { firstError = "\(error)" }
        }
    }

    /// RMS over all written samples in dBFS; silence or nothing written gives -120.
    /// Length of the written file, padding included; should match the capture time on both channels.
    public var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(written) / Self.outFormat.sampleRate
    }

    public var rmsDbfs: Double {
        lock.lock(); defer { lock.unlock() }
        guard samples > 0, sumSquares > 0 else { return -120 }
        return max(-120, 20 * log10((sumSquares / Double(samples)).squareRoot()))
    }

    private func elapsedFrames() -> Int {
        let c = (ContinuousClock.now - started).components
        return Int((Double(c.seconds) + Double(c.attoseconds) / 1e18) * Self.outFormat.sampleRate)
    }

    /// A process tap delivers nothing while no app plays audio; write zeros so both channels stay on one
    /// wall-clock timeline. Gaps under 100 ms are buffer jitter. Padding is not counted in rmsDbfs.
    private func padSilence(upTo frames: Int) throws {
        guard let file, frames - written > 1_600,
              let zeros = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: AVAudioFrameCount(frames - written))
        else { return }
        zeros.frameLength = zeros.frameCapacity
        zeros.int16ChannelData?[0].update(repeating: 0, count: Int(zeros.frameLength))
        try file.write(from: zeros)
        written = frames
    }

    /// Pads to the end time, then closes the file (AVAudioFile finalizes the header on release).
    public func finish() {
        lock.lock(); defer { lock.unlock() }
        try? padSilence(upTo: elapsedFrames())
        file = nil
    }
}
#endif
