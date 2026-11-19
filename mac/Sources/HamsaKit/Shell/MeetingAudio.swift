#if os(macOS) && compiler(>=6.2)
import AVFoundation
import Foundation

/// T13: audio -> supervised Dictation per channel -> LivePipeline, for the app. Live: mic = "me", system tap =
/// "them". `replay`: a recorded THEM wav fed in real time instead (test hook; no mic or tap is opened).
/// Same plumbing as `hamsa-cli live` (T11b), minus its bench report.
@available(macOS 26, *)
public final class MeetingAudio: @unchecked Sendable {
    private var relays: [String: LiveRelay<PCMChunk>] = [:]
    private var sups: [STTSupervisor] = []
    private var mic: MicCapture?
    private var tap: SystemTap?
    private var feeder: Task<Void, Never>?

    public init() {}

    /// `now()` = the pipeline's clock (ms). Throws on a permission or device error (nothing left running).
    public func start(pipeline: LivePipeline, store: LiveStore, meeting: String, replay: URL?,
                      themLang: String = "ar", meLang: String = "en", now: @escaping @Sendable () -> Int) async throws {
        let channels = replay == nil ? ["me", "them"] : ["them"]
        var formats: [String: AVAudioFormat] = [:]
        for ch in channels {
            let lang = ch == "them" ? themLang : meLang
            let loc = Locale(identifier: lang == "en" ? "en_US" : "ar_SA")
            _ = try await BenchDictation.ensureAsset(loc)
            let considering = try replay.map { try AVAudioFile(forReading: $0).processingFormat }
            let format = try await LiveDictation.format(locale: loc, considering: considering)
            let relay = LiveRelay<PCMChunk>()
            relays[ch] = relay; formats[ch] = format
            let sup = STTSupervisor(name: ch) { g in
                if g > 1 { await store.closeOpen(meeting: meeting, channel: ch) }
                try await LiveDictation.work(channel: ch, locale: loc, lang: lang, format: format, relay: relay,
                                             generation: g, now: now) { await pipeline.ingest($0) }
            }
            sups.append(sup)
            await sup.start()
        }
        if let replay, let relay = relays["them"], let format = formats["them"] {
            let chunks = try LiveDictation.chunks(url: replay, format: format)
            feeder = Task.detached {
                let start = now()
                for (i, c) in chunks.enumerated() where !Task.isCancelled {
                    let wait = start + i * 100 - now()
                    if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
                    relay.push(c, frames: Int(c.buffer.frameLength))
                }
            }
            return
        }
        // Mic first: it makes this process an audio client, so the tap can exclude Hamsa's own output.
        do {
            let m = MicCapture()
            do { try m.start(onBuffer: Self.sink(relays["me"]!, formats["me"]!)) } catch { throw AudioStartError.microphone(error) }
            mic = m
            let t = SystemTap()
            do { try t.start(onBuffer: Self.sink(relays["them"]!, formats["them"]!)) } catch { throw AudioStartError.systemAudio(error) }
            tap = t
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        feeder?.cancel()
        tap?.stop(); mic?.stop()
        tap = nil; mic = nil
        for r in relays.values { r.finish() }
        for s in sups { await s.wait() }
        relays = [:]; sups = []
    }

    /// Converts capture buffers to the analyzer format and pushes them to a channel's relay.
    static func sink(_ relay: LiveRelay<PCMChunk>, _ out: AVAudioFormat) -> AudioSink {
        let box = ConverterBox()
        return { buf in
            guard buf.frameLength > 0 else { return }
            if box.conv == nil || box.conv?.inputFormat != buf.format { box.conv = AVAudioConverter(from: buf.format, to: out) }
            guard let conv = box.conv else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * out.sampleRate / buf.format.sampleRate) + 64
            guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return }
            var given = false
            var err: NSError?
            _ = conv.convert(to: dst, error: &err) { _, st in
                if given { st.pointee = .noDataNow; return nil }
                given = true; st.pointee = .haveData; return buf
            }
            if err == nil, dst.frameLength > 0 { relay.push(PCMChunk(dst), frames: Int(dst.frameLength)) }
        }
    }

    /// Each capture callback runs on one serial audio thread, so the converter needs no lock.
    final class ConverterBox: @unchecked Sendable { var conv: AVAudioConverter? }
}
#endif
