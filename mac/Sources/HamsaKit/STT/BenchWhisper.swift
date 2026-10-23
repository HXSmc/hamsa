#if canImport(WhisperKit)
import Foundation
import WhisperKit

/// T02: WhisperKit in chunked "streaming": every `step` s re-decode all audio heard so far (growing window,
/// clips < 30 s), on a simulated real-time clock: a decode starts at max(step boundary, previous decode done).
public final class BenchWhisper {
    let pipe: WhisperKit

    /// Downloads (first run) and loads `model` from argmaxinc/whisperkit-coreml into `downloadBase`.
    public init(model: String, downloadBase: URL) async throws {
        pipe = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: downloadBase, verbose: false, logLevel: .error))
    }

    public func run(url: URL, language: String, step: Double = 1.0) async throws -> BenchClip {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let rate = 16_000.0
        let dur = Double(samples.count) / rate
        let opts = DecodingOptions(task: .transcribe, language: language, temperature: 0, usePrefillPrompt: true,
                                   detectLanguage: false, skipSpecialTokens: true, wordTimestamps: true)
        var hyps: [(time: Double, text: String)] = []
        var last: [TranscriptionResult] = []
        var t = step
        while true {
            let end = min(t, dur)
            let t1 = ContinuousClock.now
            last = try await pipe.transcribe(audioArray: Array(samples[0..<Int(end * rate)]), decodeOptions: opts)
            let c = t1.duration(to: .now).components
            let done = t + Double(c.seconds) + Double(c.attoseconds) / 1e18
            hyps.append((done, last.map(\.text).joined(separator: " ")))
            if end >= dur { break }
            t = max(t + step, done)
        }
        var finalWords: [(word: String, end: Double)] = []
        for seg in last.flatMap(\.segments) {
            for w in seg.words ?? [] { for x in BenchWER.words(w.word) { finalWords.append((x, Double(w.end))) } }
        }
        return BenchClip(text: hyps.last?.text ?? "", lags: BenchWER.wordLags(finalWords: finalWords, hyps: hyps))
    }
}
#endif
