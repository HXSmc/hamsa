#if os(macOS) && compiler(>=6.2)
import AVFoundation
import Foundation
import Speech

/// One PCM chunk handed across tasks (AVAudioPCMBuffer is not Sendable; the feeder never touches it again).
public struct PCMChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// T08: live partials with Apple DictationTranscriber (ADR 001), one analyzer per channel and worker generation.
@available(macOS 26, *)
public enum LiveDictation {
    /// Analyzer input format for `locale` (same transcriber setup as the T02 bench).
    public static func format(locale: Locale, considering: AVAudioFormat?) async throws -> AVAudioFormat {
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [BenchDictation.transcriber(locale)],
                                                                   considering: considering)
        else { throw AudioError("no analyzer format") }
        return f
    }

    /// Replay helper: a wav cut into `chunkSeconds` chunks in `format`, plus `tailSeconds` of silence.
    public static func chunks(url: URL, format: AVAudioFormat, chunkSeconds: Double = 0.1, tailSeconds: Double = 2) throws -> [PCMChunk] {
        try BenchDictation.slices(file: AVAudioFile(forReading: url), to: format, chunkSeconds: chunkSeconds,
                                  tailSeconds: tailSeconds).map(PCMChunk.init)
    }

    /// RMS of a PCM buffer (int16 or float32, first channel) in dBFS.
    static func rmsDbfs(_ b: AVAudioPCMBuffer) -> Double {
        let n = Int(b.frameLength)
        guard n > 0 else { return -120 }
        var acc = 0.0
        if let p = b.floatChannelData?[0] { for i in 0..<n { acc += Double(p[i] * p[i]) } }
        else if let p = b.int16ChannelData?[0] { for i in 0..<n { let x = Double(p[i]) / 32768; acc += x * x } }
        else { return 0 }  // unknown sample type: treat as voice (never forces a final)
        return acc > 0 ? 10 * log10(acc / Double(n)) : -120
    }

    /// One worker generation: attaches to `relay`, transcribes until the relay finishes (returns) or the
    /// task is cancelled (throws CancellationError, so the supervisor restarts it). `now()` = stream clock ms.
    public static func work(channel: String, locale: Locale, lang: String, format: AVAudioFormat,
                            relay: LiveRelay<PCMChunk>, generation: Int, now: @escaping @Sendable () -> Int,
                            silenceSeconds: Double = 0.8, voiceDbfs: Double = -45,
                            ready: @escaping @Sendable () -> Void = {},
                            sink: @escaping @Sendable (STTUpdate) async -> Void) async throws {
        let t = BenchDictation.transcriber(locale)
        let analyzer = SpeechAnalyzer(modules: [t])
        let (input, offsetFrames) = relay.attach()
        let offsetMs = Int(Double(offsetFrames) / format.sampleRate * 1000)
        let ms = { (c: CMTime) in offsetMs + Int(c.seconds * 1000) }

        let collector = Task {
            for try await r in t.results {
                let at = now()  // stamp before any DB write
                var words: [(word: String, endMs: Int)] = []
                if r.isFinal {
                    for run in r.text.runs {
                        guard let tr = run.audioTimeRange else { continue }
                        for w in BenchWER.words(String(r.text[run.range].characters)) { words.append((w, ms(tr.end))) }
                    }
                }
                await sink(STTUpdate(channel: channel, text: String(r.text.characters), startMs: ms(r.range.start),
                                     endMs: ms(r.range.end), isFinal: r.isFinal, lang: lang, arrivalMs: at,
                                     words: words, generation: generation))
            }
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        ready()
        // Energy VAD: Dictation alone finalizes about once a minute; close the utterance after `silenceSeconds`.
        var frames: Int64 = 0, lastVoice: Int64 = -1, closed = true
        let rate = CMTimeScale(format.sampleRate)
        for await c in input {  // ends on relay.finish() or on cancel
            cont.yield(AnalyzerInput(buffer: c.buffer, bufferStartTime: CMTime(value: frames, timescale: rate)))
            frames += Int64(c.buffer.frameLength)
            if rmsDbfs(c.buffer) > voiceDbfs { lastVoice = frames; closed = false }
            if !closed, Double(frames - lastVoice) / format.sampleRate >= silenceSeconds {
                closed = true
                let through = CMTime(value: lastVoice, timescale: rate)
                Task { try? await analyzer.finalize(through: through) }
            }
        }
        cont.finish()
        if Task.isCancelled {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await collector.value
        try Task.checkCancellation()
    }
}
#endif
