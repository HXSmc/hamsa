#if os(macOS) && compiler(>=6.2)
import AVFoundation
import Foundation
import Speech

/// T02: Apple DictationTranscriber (SpeechAnalyzer, macOS 26) fed in real time, 100 ms chunks.
@available(macOS 26, *)
public enum BenchDictation {
    /// Installs the locale's on-device asset if missing; returns the AssetInventory status after.
    public static func ensureAsset(_ locale: Locale) async throws -> String {
        let t = transcriber(locale)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await req.downloadAndInstall() }
        return "\(await AssetInventory.status(forModules: [t]))"
    }

    static func transcriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    }

    /// Plays `url` into the analyzer at real-time pace, then `tailSeconds` of silence, then finalizes.
    public static func run(url: URL, locale: Locale, tailSeconds: Double = 2) async throws -> BenchClip {
        let t = transcriber(locale)
        let analyzer = SpeechAnalyzer(modules: [t])
        let file = try AVAudioFile(forReading: url)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t], considering: file.processingFormat)
        else { throw AudioError("no analyzer format") }
        let chunks = try slices(file: file, to: format, chunkSeconds: 0.1, tailSeconds: tailSeconds)

        let clock = ContinuousClock()
        let t0 = clock.now
        func now() -> Double { let c = t0.duration(to: clock.now).components; return Double(c.seconds) + Double(c.attoseconds) / 1e18 }

        let collector = Task { () -> BenchClip in
            var pending: [(time: Double, text: String)] = []
            var text: [String] = [], lags: [Double] = []
            for try await r in t.results {
                let s = String(r.text.characters)
                pending.append((now(), s))
                guard r.isFinal else { continue }
                var finalWords: [(word: String, end: Double)] = []
                for run in r.text.runs {
                    guard let tr = run.audioTimeRange else { continue }
                    for w in BenchWER.words(String(r.text[run.range].characters)) { finalWords.append((w, tr.end.seconds)) }
                }
                lags += BenchWER.wordLags(finalWords: finalWords, hyps: pending)
                text.append(s)
                pending = []
            }
            return BenchClip(text: text.joined(separator: " "), lags: lags)
        }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        var fed = 0.0, frames: Int64 = 0
        for buf in chunks {
            let wait = fed - now()
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            cont.yield(AnalyzerInput(buffer: buf, bufferStartTime: CMTime(value: frames, timescale: CMTimeScale(format.sampleRate))))
            frames += Int64(buf.frameLength)
            fed = Double(frames) / format.sampleRate
        }
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    /// Reads the file, converts to the analyzer format, cuts into chunks, appends silence.
    static func slices(file: AVAudioFile, to format: AVAudioFormat, chunkSeconds: Double, tailSeconds: Double) throws -> [AVAudioPCMBuffer] {
        guard let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioError("cannot allocate read buffer")
        }
        try file.read(into: src)
        let tailFrames = AVAudioFrameCount(tailSeconds * format.sampleRate)
        let cap = AVAudioFrameCount(Double(src.frameLength) * format.sampleRate / src.format.sampleRate) + tailFrames + 1024
        guard let all = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap), let conv = AVAudioConverter(from: src.format, to: format)
        else { throw AudioError("no converter to \(format)") }
        var given = false
        var err: NSError?
        _ = conv.convert(to: all, error: &err) { _, st in
            if given { st.pointee = .endOfStream; return nil }
            given = true; st.pointee = .haveData; return src
        }
        if let err { throw err }
        // Silence tail: buffers start zeroed; extend frameLength.
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let start = Int(all.frameLength)
        all.frameLength = min(all.frameCapacity, all.frameLength + tailFrames)
        if let p = all.audioBufferList.pointee.mBuffers.mData {
            memset(p + start * bytesPerFrame, 0, (Int(all.frameLength) - start) * bytesPerFrame)
        }
        let step = AVAudioFrameCount(chunkSeconds * format.sampleRate)
        var out: [AVAudioPCMBuffer] = []
        var off: AVAudioFrameCount = 0
        while off < all.frameLength {
            let n = min(step, all.frameLength - off)
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
            b.frameLength = n
            memcpy(b.audioBufferList.pointee.mBuffers.mData!, all.audioBufferList.pointee.mBuffers.mData! + Int(off) * bytesPerFrame,
                   Int(n) * bytesPerFrame)
            out.append(b)
            off += n
        }
        return out
    }
}
#endif
