#if os(macOS)
import ArgumentParser
import AVFoundation
import CoreAudio
import Foundation
import HamsaKit

/// T11b: the live pipeline end to end: audio -> supervised Dictation per channel -> LivePipeline (detect, T0/T1/T2)
/// -> live.sqlite. Audio comes from an input device (`--audio-device loopback`: stereo, left = them, right = me;
/// `--play` loops a labelled call into that same device) or from a replayed call (`--replay`).
struct Live: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Live pipeline from a loopback device or a replayed call; prints row counts, answer_coverage, cancel_ok.")

    @Option(help: "Input device name substring, or `loopback` = first BlackHole/Loopback/Soundflower device. Left = them, right = me.")
    var audioDevice: String?
    @Option(help: "With --audio-device: play this THEM wav (+ labels' ME wav) into the device (left/right). Never to the speakers.")
    var play: String?
    @Option(help: "Instead of a device: feed this THEM wav (+ labels' ME wav) straight into STT in real time.") var replay: String?
    @Option(help: "Labels JSON (CallLabels) for answer_coverage and the ME wav.") var labels: String?
    @Flag(help: "Loop the played/replayed call.") var loop = false
    @Option(help: "Stop after N seconds (default: one pass of the call; Ctrl-C also stops cleanly).") var seconds: Double?
    @Option(help: "live.sqlite path.") var db: String = "~/Library/Application Support/Hamsa/live.sqlite"
    @Option(help: "Local index (T10a).") var index: String = "~/Library/Application Support/Hamsa/index.sqlite"
    @Option(help: "Prepared cards (T10b).") var cards: String = "~/Library/Application Support/Hamsa/cards.sqlite"
    @Option(help: "Project id in the index / cards.") var project: String = "taweed"
    @Option(help: "Comma list of channels whose questions get answers (03-tdd: them).") var askers: String = "them"
    @Flag(help: "Store the meeting as confidential: no T2 request.") var confidential = false
    @Flag(help: "No LLM tier (T0/T1 only).") var noLlm = false
    @Option(help: "Dictation language of THEM (ar|en).") var themLang: String = "ar"
    @Option(help: "Dictation language of ME (ar|en).") var meLang: String = "en"

    func run() async throws {
        #if compiler(>=6.2)
        guard #available(macOS 26, *) else { throw ValidationError("DictationTranscriber needs macOS 26") }
        try await live()
        #else
        throw ValidationError("built without the macOS 26 SDK")
        #endif
    }

    static func path(_ p: String) -> URL { URL(fileURLWithPath: NSString(string: p).expandingTildeInPath) }
    static func ms(_ d: Duration) -> Int { Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000) }
    static func nonEmpty(_ u: URL) -> Bool { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int ?? 0) > 0 }

    #if compiler(>=6.2)
    @available(macOS 26, *)
    func live() async throws {
        guard (audioDevice == nil) != (replay == nil) else { throw ValidationError("give exactly one of --audio-device / --replay") }
        if play != nil, audioDevice == nil { throw ValidationError("--play needs --audio-device") }
        let lab = try labels.map { try CallLabels.load(Self.path($0)) }
        // Call wavs (them [+ me from labels]) to replay or play into the device.
        var wavs: [URL] = []
        if let first = replay ?? play {
            wavs = [Self.path(first)]
            if let me = lab?.audio["me"], let l = labels {
                let u = Self.path(l).deletingLastPathComponent().appendingPathComponent(me)
                if FileManager.default.fileExists(atPath: u.path) { wavs.append(u) }
            }
        }

        // Stores and tiers.
        let dbURL = Self.path(db)
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try LiveStore(path: dbURL.path)
        let meeting = UUID().uuidString
        try await store.startMeeting(id: meeting, title: "live \(wavs.first?.lastPathComponent ?? audioDevice ?? "")",
                                     app: audioDevice == nil ? "replay" : "device", confidential: confidential)
        let embedder: (any Embedder)?
        do { embedder = try await E5Embedder.load() } catch { embedder = nil; print("WARN: no e5 embedder (\(error)): T0/T1 off") }
        let idxURL = Self.path(index), cardsURL = Self.path(cards)
        let idx = Self.nonEmpty(idxURL) ? try LocalIndex(path: idxURL.path, projectID: project) : nil
        let cardMatcher = Self.nonEmpty(cardsURL) ? try CardMatcher(path: cardsURL.path, projectID: project) : nil
        print("index=\(idx.map { "\($0.chunkIDs.count) chunks" } ?? "none") cards=\(cardMatcher.map { "\($0.count)" } ?? "none (\(cardsURL.lastPathComponent) missing or empty): T0 off")")
        var llm: AnswerLLM?
        if !noLlm {
            let chain = PipelineProviders.chain(key: PipelineProviders.keychainKey)
            print("llm chain=\(chain.map { "\($0.name)/\($0.model)\($0.apiKey.isEmpty ? "(no key)" : "")\($0.mayReceiveNotes ? "" : "(notes consent only)")" }.joined(separator: ","))")
            llm = AnswerLLM(providers: chain)
        }
        let clock = ContinuousClock()
        let t0 = clock.now
        let now: @Sendable () -> Int = { Self.ms(t0.duration(to: clock.now)) }
        let askerSet = Set(askers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        // Pipeline times on the audio timeline (ms since the first audio pushed), the clock of STTUpdate start/end,
        // so t_shown_ms - t_question_end_ms is real latency.
        let audioZero = StopFlag.Box()
        let pipeline = LivePipeline(store: store, meeting: meeting, embedder: embedder, index: idx, cards: cardMatcher,
                                    llm: llm, askers: askerSet, now: { let n = now(); return n - (audioZero.value ?? n) })
        print("meeting=\(meeting) confidential=\(confidential) notes_consent=false askers=\(askerSet.sorted().joined(separator: ","))")

        // STT: one supervised worker per channel, fed through a relay.
        let stop = StopFlag()
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sig.setEventHandler { stop.set() }
        sig.resume()

        var relays: [String: LiveRelay<PCMChunk>] = [:], formats: [String: AVAudioFormat] = [:], sups: [String: STTSupervisor] = [:]
        let deviceIO = try audioDevice.map { try DeviceIO(match: $0) }
        let considering = deviceIO?.channelFormat
        let channels = deviceIO == nil ? Array(["them", "me"].prefix(wavs.count)) : Array(["them", "me"].prefix(Int(deviceIO!.channels)))
        for (i, ch) in channels.enumerated() {
            let lang = ch == "them" ? themLang : meLang
            let loc = Locale(identifier: lang == "en" ? "en_US" : "ar_SA")
            _ = try await BenchDictation.ensureAsset(loc)
            let format = try await LiveDictation.format(locale: loc, considering: considering ?? AVAudioFile(forReading: wavs[i]).processingFormat)
            let relay = LiveRelay<PCMChunk>()
            relays[ch] = relay; formats[ch] = format
            sups[ch] = STTSupervisor(name: ch) { g in
                if g > 1 { await store.closeOpen(meeting: meeting, channel: ch) }
                try await LiveDictation.work(channel: ch, locale: loc, lang: lang, format: format, relay: relay, generation: g, now: now) { u in
                    await pipeline.ingest(u)
                }
            }
        }
        for s in sups.values { await s.start() }

        // Audio source.
        let startMs = now()  // model + asset loading above is not part of the run time
        var periodSec = 0.0, offsetMs = 0
        if let io = deviceIO {
            print("route=loopback device=\"\(io.name)\" input=\(io.channelFormat.sampleRate) Hz x\(io.channels)")
            try io.startCapture(relays: channels.map { relays[$0]! }, formats: channels.map { formats[$0]! }) {
                audioZero.setOnce(now())
            }
            if !wavs.isEmpty {
                periodSec = try io.play(wavs, loop: loop)
                offsetMs = now()  // corrected against audioZero below
            }
        } else {
            print("route=replay (no --audio-device)")
            var feeds: [(LiveRelay<PCMChunk>, [PCMChunk])] = []
            for (i, ch) in channels.enumerated() { feeds.append((relays[ch]!, try LiveDictation.chunks(url: wavs[i], format: formats[ch]!))) }
            periodSec = Double(feeds.map(\.1.count).max() ?? 0) * 0.1
            let loop = loop
            for (relay, chunks) in feeds {
                Task.detached {
                    var i = 0
                    let start = now()
                    audioZero.setOnce(start)
                    while !stop.isSet, loop || i < chunks.count {
                        let wait = start + i * 100 - now()
                        if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
                        let c = chunks[i % chunks.count]
                        relay.push(c, frames: Int(c.buffer.frameLength))
                        i += 1
                    }
                }
            }
        }
        let limit = seconds ?? (periodSec > 0 ? periodSec + 3 : 60)
        while !stop.isSet, Double(now() - startMs) / 1000 < limit { try? await Task.sleep(for: .milliseconds(100)) }
        stop.set()
        deviceIO?.stop()
        let endMs = now()
        for r in relays.values { r.finish() }
        for s in sups.values { await s.wait() }
        await pipeline.finish()
        try await store.endMeeting(id: meeting)
        sig.cancel()
        let zero = audioZero.value ?? 0
        if deviceIO != nil { offsetMs -= zero } else { offsetMs = 0 }
        try await report(store: store, meeting: meeting, pipeline: pipeline, labels: lab, dbPath: dbURL.path,
                         periodSec: periodSec, offsetMs: offsetMs, audioEndMs: endMs - zero)
    }

    @available(macOS 26, *)
    func report(store: LiveStore, meeting: String, pipeline: LivePipeline, labels: CallLabels?, dbPath: String,
                periodSec: Double, offsetMs: Int, audioEndMs: Int) async throws {
        if labels?.provisional == true { print("PROVISIONAL: labels are synthetic (TTS), not a real call") }
        let counts = try await store.counts(meeting: meeting)
        let segs = counts.values.reduce(0) { $0 + $1.final + $1.partial }
        let qs = try await store.questions(meeting: meeting)
        let tiers = qs.flatMap(\.tiers)
        print("live.sqlite=\(dbPath) meeting=\(meeting)")
        print("segments=\(segs) questions=\(qs.count) answer_events=\(tiers.count) T0=\(tiers.filter { $0 == "T0" }.count) T1=\(tiers.filter { $0 == "T1" }.count) T2=\(tiers.filter { $0 == "T2" }.count)")
        let s = await pipeline.stats
        print("t2_starts=\(s.t2Starts) t2_replaced_pending=\(s.replacedPending) skipped=\(s.t2Skipped) store_errors=\(s.storeErrors)")
        for (e, n) in s.t2Errors.sorted(by: { $0.value > $1.value }) { print("t2_error x\(n): \(e)") }
        let cOK = s.cancelMs.filter { $0 <= 200 }.count
        print("cancel_ok=\(s.cancelMs.isEmpty ? "NA" : "\(cOK * 100 / s.cancelMs.count)%") (\(cOK)/\(s.cancelMs.count)) cancel_max_ms=\(s.cancelMs.max() ?? -1)")

        guard let labels, periodSec > 0 else { return }
        // Labelled question i in pass k sits at (t + k * period) on the audio timeline (+ device play offset).
        // Covered = a question row on that channel ending in [start - 1 s, end + 3 s] with >= 1 answer_events row.
        print("passes: period_s=\(String(format: "%.1f", periodSec)) play_offset_ms=\(offsetMs) audio_end_ms=\(audioEndMs)")
        func window(_ q: CallLabels.Item, _ k: Int) -> ClosedRange<Int> {
            let base = Int(Double(k) * periodSec * 1000) + offsetMs
            return (base + Int(q.start * 1000) - 1000)...(base + Int(q.end * 1000) + 3000)
        }
        func rows(_ q: CallLabels.Item, _ k: Int) -> [LiveStore.QuestionRow] {
            let w = window(q, k)
            return qs.filter { $0.channel == q.channel && w.contains($0.tQuestionEndMs) }
        }
        var line: [String] = []
        for (name, set) in [("answer_coverage", labels.questions.filter(\.tech)),
                            ("answer_coverage_them", labels.questions.filter { $0.tech && $0.channel == "them" }),
                            ("all_questions_coverage", labels.questions)] {
            var total = 0, covered = 0, t2 = 0
            for k in 0..<Int((Double(audioEndMs) / 1000 / periodSec).rounded(.up)) {
                for q in set where window(q, k).upperBound <= audioEndMs {
                    total += 1
                    let r = rows(q, k)
                    if r.contains(where: { !$0.tiers.isEmpty }) { covered += 1 }
                    if r.contains(where: { $0.tiers.contains("T2") }) { t2 += 1 }
                }
            }
            line.append("\(name)=\(total == 0 ? 0 : covered * 100 / total)% (\(covered)/\(total), with T2 \(t2))")
        }
        line.forEach { print($0) }
        var labelled = Set<Int>()
        for k in 0..<Int((Double(audioEndMs) / 1000 / periodSec).rounded(.up)) {
            for q in labels.questions { rows(q, k).forEach { labelled.insert($0.id) } }
        }
        print("question_rows_not_a_labelled_question=\(qs.filter { !labelled.contains($0.id) }.count)")
    }
    #endif
}

/// Thread-safe stop flag (SIGINT handler, feeders, main loop) and a set-once ms box.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isSet: Bool { lock.withLock { on } }
    func set() { lock.withLock { on = true } }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Int?
        var value: Int? { lock.withLock { v } }
        func setOnce(_ x: Int) { lock.withLock { if v == nil { v = x } } }
    }
}

/// One audio device used both ways: capture from its input (own AVAudioEngine, the system default input is never
/// changed) and, for the loopback test, playback of a call into its output (left = them, right = me).
final class DeviceIO: @unchecked Sendable {
    let id: AudioDeviceID
    let name: String
    let channels: AVAudioChannelCount
    let channelFormat: AVAudioFormat
    private let capture = AVAudioEngine()
    private let player = AVAudioEngine()

    init(match: String) throws {
        // Recording any input device needs the Microphone permission; never trigger the dialog from here.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw ValidationError("OWNER_NEEDED: microphone permission for this terminal is \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (not authorized); use --replay")
        }
        let wanted = match.lowercased() == "loopback" ? ["blackhole", "loopback", "soundflower"] : [match.lowercased()]
        guard let dev = Self.devices().first(where: { d in d.inputs > 0 && wanted.contains { d.name.lowercased().contains($0) } })
        else { throw ValidationError("no input device matching \(match)") }
        id = dev.id; name = dev.name
        try Self.setDevice(capture.inputNode.audioUnit, id)
        let f = capture.inputNode.outputFormat(forBus: 0)
        guard f.sampleRate > 0 else { throw ValidationError("device \(name) has no input format") }
        channels = min(f.channelCount, 2)
        channelFormat = AVAudioFormat(standardFormatWithSampleRate: f.sampleRate, channels: 1)!
    }

    static func devices() -> [(id: AudioDeviceID, name: String, inputs: Int)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?
            var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let name = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &n, &cf) == noErr ? (cf?.takeRetainedValue() as String? ?? "") : ""
            var inAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
                                                    mElement: kAudioObjectPropertyElementMain)
            var sz: UInt32 = 0
            var inputs = 0
            if AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &sz) == noErr, sz > 0 {
                let list = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16)
                defer { list.deallocate() }
                if AudioObjectGetPropertyData(id, &inAddr, 0, nil, &sz, list) == noErr {
                    inputs = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
                }
            }
            return (id, name, inputs)
        }
    }

    /// Points an engine I/O unit at `id` and reads it back: a silent failure would play the call on the speakers.
    static func setDevice(_ unit: AudioUnit?, _ id: AudioDeviceID) throws {
        guard let unit else { throw ValidationError("no audio unit") }
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, size) == noErr
        else { throw ValidationError("cannot select audio device \(id)") }
        var got: AudioDeviceID = 0
        var gotSize = size
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &got, &gotSize) == noErr, got == id
        else { throw ValidationError("audio device \(id) not selected (got \(got))") }
    }

    /// Splits the device input into mono channels, converts each to its analyzer format, pushes to its relay.
    func startCapture(relays: [LiveRelay<PCMChunk>], formats: [AVAudioFormat], first: @escaping @Sendable () -> Void) throws {
        let input = capture.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let mono = channelFormat
        let convs = try formats.map { f -> AVAudioConverter in
            guard let c = AVAudioConverter(from: mono, to: f) else { throw ValidationError("no converter to \(f)") }
            return c
        }
        input.installTap(onBus: 0, bufferSize: 4800, format: inFormat) { buf, _ in
            first()
            let n = buf.frameLength
            guard n > 0, let src = buf.floatChannelData else { return }
            for (ch, relay) in relays.enumerated() where ch < Int(buf.format.channelCount) {
                guard let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: n) else { continue }
                m.frameLength = n
                m.floatChannelData![0].update(from: src[ch], count: Int(n))
                let f = formats[ch]
                let cap = AVAudioFrameCount(Double(n) * f.sampleRate / mono.sampleRate) + 64
                guard let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: cap) else { continue }
                var given = false
                var err: NSError?
                _ = convs[ch].convert(to: out, error: &err) { _, st in
                    if given { st.pointee = .noDataNow; return nil }
                    given = true; st.pointee = .haveData; return m
                }
                if err == nil, out.frameLength > 0 { relay.push(PCMChunk(out), frames: Int(out.frameLength)) }
            }
        }
        capture.prepare()
        try capture.start()
    }

    /// Plays them (left) and me (right) into the device output; returns the call length in seconds.
    func play(_ wavs: [URL], loop: Bool) throws -> Double {
        try Self.setDevice(player.outputNode.audioUnit, id)
        var longest = 0.0
        for (i, url) in wavs.prefix(2).enumerated() {
            let file = try AVAudioFile(forReading: url)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw ValidationError("cannot read \(url.lastPathComponent)")
            }
            try file.read(into: buf)
            longest = max(longest, Double(buf.frameLength) / buf.format.sampleRate)
            let node = AVAudioPlayerNode()
            player.attach(node)
            player.connect(node, to: player.mainMixerNode, format: buf.format)
            node.pan = i == 0 ? -1 : 1
            node.scheduleBuffer(buf, at: nil, options: loop ? .loops : [])
        }
        player.prepare()
        try player.start()
        for case let node as AVAudioPlayerNode in player.attachedNodes { node.play() }
        return longest
    }

    func stop() {
        player.stop()
        capture.inputNode.removeTap(onBus: 0)
        capture.stop()
    }
}
#endif
