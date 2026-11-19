#if canImport(Darwin)
import Foundation

/// T11b: the live answer path (03-tdd "4 answer tiers"). Feed it every STT update of a meeting. It writes the
/// segment, runs the question detector on the asker channels and shows, per question:
/// - T0 card: on partials and finals when CardMatcher is confident (no question word needed),
/// - T1 snippet: top LocalIndex hit, early on a partial with rules score >= 2, else on the final,
/// - T2: streamed LLM answer from the top-3 hits, once per question, on the final with rules score >= 1.
/// A newer question's T2 cancels the one in flight (the cancelled answer writes no answer_events row).
/// T2 requests are spaced >= `minGapMs` (from the provider chain, PipelineProviders.minGapMs); a question waiting
/// for the gap is replaced by a newer one (newest question wins).
/// `confidential` and `notes_consent` are read from the meeting row in LiveStore right before each request is sent
/// (after any gap wait). `setConfidential(true)` also cancels the answer in flight.
/// All `*_ms` values use `now()`, the same clock as STTUpdate times (stream clock = audio timeline on a live feed),
/// so `latency_events` (t_shown_ms - t_question_end_ms) is meaningful.
/// `shown` (T12 overlay): every event is handed to it (the overlay's only input), awaited, before `t_shown_ms` is
/// taken. It returns whether the screen changed: an answer it did not display (a T1 behind a T0 card, a T2 refusal
/// still streaming) is not stamped; a T0/T1 it did not display writes no row. nil = stamped when emitted.
/// It runs on the overlay's actor while this actor waits: a hung main thread would stall `ingest` (accepted: the
/// overlay only sets state and flushes one view).
public actor LivePipeline {
    public enum Event: Sendable {
        case question(id: Int, channel: String, text: String)
        /// T2 repeats with the growing text; `done` marks its last event.
        case answer(questionID: Int, tier: String, text: String, provider: String?, done: Bool)
        /// The T2 of this question ended without showing any text (error, timeout, empty, or a refusal held back).
        case answerFailed(questionID: Int)
        /// After every `setConfidential`: the state the send gates now enforce.
        case privacy(confidential: Bool)
    }

    public struct Stats: Sendable {
        public var questions = 0, t0 = 0, t1 = 0, t2 = 0
        /// T2 streams handed to AnswerLLM (after the gap gate and the send-time privacy check).
        public var t2Starts = 0
        /// T2 not sent, by reason (`confidential`, `no llm`).
        public var t2Skipped: [String: Int] = [:]
        public var t2Errors: [String: Int] = [:]
        /// Answers still waiting for the gap when a newer question replaced them (no request was sent).
        public var replacedPending = 0
        /// Per cancelled in-flight answer: ms from cancel to its task having ended (stream torn down).
        public var cancelMs: [Int] = []
        public var storeErrors = 0
    }

    public typealias Shown = @Sendable (Event) async -> Bool
    public nonisolated let events: AsyncStream<Event>
    private let cont: AsyncStream<Event>.Continuation
    let store: LiveStore
    let meeting: String
    let embedder: (any Embedder)?
    let index: LocalIndex?
    let cards: CardMatcher?
    let llm: AnswerLLM?
    let askers: Set<String>
    let now: @Sendable () -> Int
    let shown: Shown?
    let minGapMs: Int
    public private(set) var stats = Stats()

    struct Utterance { var channel: String; var words = 0; var questionID: Int?; var cardID: Int?; var t1Shown = false }
    private var open: [Int: Utterance] = [:]  // by segment row id
    private var style: [(ms: Int, text: String)] = []
    private var t2: (token: Int, task: Task<Void, Never>, sent: Bool, questionID: Int)?
    private var token = 0
    private var lastSentMs: Int?
    /// The owner's switch in memory: wins over the stored row (a failed or not-yet-committed write must not send).
    private var confidentialLatch = false
    private var cancelWaits: [Task<Void, Never>] = []  // one per in-flight cancel; awaited by finish()

    /// `minGapMs` nil = the chain's own pacing (`PipelineProviders.minGapMs`).
    public init(store: LiveStore, meeting: String, embedder: (any Embedder)?, index: LocalIndex?, cards: CardMatcher?,
                llm: AnswerLLM?, askers: Set<String> = ["them"], minGapMs: Int? = nil, shown: Shown? = nil, now: @escaping @Sendable () -> Int) {
        self.store = store; self.meeting = meeting; self.embedder = embedder; self.index = index; self.cards = cards
        self.llm = llm; self.askers = askers; self.now = now; self.shown = shown
        self.minGapMs = minGapMs ?? PipelineProviders.minGapMs(llm?.providers ?? [])
        // Newest-only buffer: a run without a consumer (CLI soak) must not grow memory.
        (events, cont) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    public func ingest(_ u: STTUpdate) async {
        let seg: Int
        do { seg = try await store.write(u, meeting: meeting) } catch { stats.storeErrors += 1; return }
        if u.channel == "me", u.isFinal { noteStyle(u) }
        guard askers.contains(u.channel) else { return }
        if open[seg] == nil {  // a new utterance: drop rows of this channel that never got a final (STT restart)
            open = open.filter { $0.value.channel != u.channel }
        }
        var ut = open[seg] ?? Utterance(channel: u.channel)
        let words = u.text.split(whereSeparator: \.isWhitespace).count
        // A partial is re-checked only after it grew by >= 2 words (03-tdd).
        guard u.isFinal || words >= ut.words + 2 else { return }
        ut.words = words
        let rules = QuestionRules.score(u.text)
        let conf = rules >= 2 ? 0.9 : rules == 1 ? 0.6 : 0
        let fire = u.isFinal ? rules >= 1 : conf >= 0.7
        let qv = (cards != nil || (fire && index != nil)) ? (try? embedder?.query(u.text)) : nil

        if let qv, let m = cards?.match(qv), ut.cardID != m.card.id {
            let qid = await question(&ut, u, seg: seg, conf: max(conf, Double(m.score)), cardID: m.card.id, score: Double(m.score))
            let text = LocalIndex.lang(u.text) == "ar" ? m.card.answerAR : m.card.answerEN
            await show(qid, "T0", text, nil)
            ut.cardID = m.card.id
        }
        if fire {
            let qid = await question(&ut, u, seg: seg, conf: conf, cardID: nil, score: nil)
            let hits = qv.flatMap { try? index?.search(u.text, queryVector: $0, k: 3) } ?? []
            if !ut.t1Shown, let h = hits.first {
                await show(qid, "T1", String("\(h.heading)\n\(h.text)".prefix(600)), nil)
                ut.t1Shown = true
            }
            if u.isFinal {
                await startT2(qid, question: u.text, snippets: hits.map { "\($0.heading)\n\($0.text)" })
            }
        }
        if u.isFinal, let qid = ut.questionID {
            do { try await store.updateQuestion(id: qid, text: u.text, detectConf: conf, tQuestionEndMs: u.endMs) }
            catch { stats.storeErrors += 1 }
        }
        open[seg] = u.isFinal ? nil : ut
    }

    /// Owner flips the meeting's confidential switch: stored first, then an answer in flight is cancelled.
    /// ON latches and cancels before any await, so neither a throwing nor a slow store write can let a request out.
    /// OFF clears the latch only after the write landed (a failed OFF stays closed).
    public func setConfidential(_ on: Bool) async throws {
        if on { confidentialLatch = true; cancelT2() }
        do { try await store.setConfidential(meeting: meeting, on) } catch { await publish(.privacy(confidential: confidentialLatch)); throw error }
        if !on { confidentialLatch = false }
        await publish(.privacy(confidential: confidentialLatch))
    }

    private func publish(_ e: Event) async {
        cont.yield(e)
        _ = await shown?(e)
    }

    /// End of meeting: lets the answer in flight finish, waits for cancel measurements, closes `events`.
    public func finish() async {
        if let cur = t2 { await cur.task.value }
        for w in cancelWaits { await w.value }
        cancelWaits = []
        cont.finish()
    }

    /// Question id of the answer in flight or waiting for the gap (tests).
    var currentT2Question: Int? { t2?.questionID }

    // MARK: - tiers

    private func question(_ ut: inout Utterance, _ u: STTUpdate, seg: Int, conf: Double, cardID: Int?, score: Double?) async -> Int {
        if let q = ut.questionID { return q }
        do {
            let q = try await store.addQuestion(meeting: meeting, segmentID: seg, text: u.text, detectConf: conf, tDetectMs: now(),
                                                tQuestionEndMs: u.endMs, cardID: cardID, matchScore: score)
            ut.questionID = q
            stats.questions += 1
            await publish(.question(id: q, channel: u.channel, text: u.text))
            return q
        } catch {
            stats.storeErrors += 1
            return -1
        }
    }

    private func show(_ qid: Int, _ tier: String, _ text: String, _ provider: String?, at: Int? = nil) async {
        guard qid >= 0 else { return }
        let e = Event.answer(questionID: qid, tier: tier, text: text, provider: provider, done: true)
        cont.yield(e)
        let ms: Int
        if let at {  // T2's last event: the row keeps its first-token time
            _ = await shown?(e)
            ms = at
        } else {
            if let shown, !(await shown(e)) { return }  // not displayed: no row
            ms = now()
        }
        switch tier { case "T0": stats.t0 += 1; case "T1": stats.t1 += 1; default: stats.t2 += 1 }
        do { try await store.addAnswer(questionID: qid, tier: tier, tShownMs: ms, text: text, provider: provider) }
        catch { stats.storeErrors += 1 }
    }

    /// Internal (not private) so tests can drive it for a meeting that has no row.
    func startT2(_ qid: Int, question: String, snippets: [String]) async {
        guard qid >= 0 else { return }
        guard let llm else { stats.t2Skipped["no llm", default: 0] += 1; return }
        // Token first: the actor is re-entrant, so a question that arrives during the await below must win.
        token += 1
        let tok = token
        let priv = (try? await store.privacy(meeting: meeting)) ?? (confidential: true, notesConsent: false)
        guard token == tok else { return }  // a newer question took over while we read
        cancelT2()
        if priv.confidential || confidentialLatch { stats.t2Skipped["confidential", default: 0] += 1; return }
        let wait = lastSentMs.map { max(0, $0 + minGapMs - now()) } ?? 0
        let styleLines = style.filter { $0.ms >= now() - 180_000 }.map(\.text)
        let (cont, now, shown) = (cont, now, shown)
        let task = Task {
            if wait > 0 {
                do { try await Task.sleep(for: .milliseconds(wait)) } catch { return }
            }
            guard let sendPriv = await self.claimSend(tok) else { return }
            var text = "", provider: String?, firstMs: Int?, err: String?
            do {
                for try await (p, t) in llm.stream(question: question, snippets: snippets, styleLines: styleLines,
                                                   confidential: sendPriv.confidential, notesConsent: sendPriv.notesConsent) {
                    text += t
                    provider = p
                    let e = Event.answer(questionID: qid, tier: "T2", text: text, provider: p, done: false)
                    cont.yield(e)
                    let onScreen = await shown?(e) ?? true
                    if firstMs == nil, onScreen { firstMs = now() }
                }
            } catch {
                err = String("\(error)".prefix(160))
            }
            await self.t2Ended(tok, qid, firstMs, text, provider, err, cancelled: Task.isCancelled)
        }
        t2 = (tok, task, false, qid)
    }

    /// Right before the request: still the current answer, and the stored meeting state (re-read after any gap
    /// wait) still allows it. Returns the privacy state to send with, or nil = do not send.
    private func claimSend(_ tok: Int) async -> (confidential: Bool, notesConsent: Bool)? {
        guard t2?.token == tok, !Task.isCancelled else { return nil }
        let priv = (try? await store.privacy(meeting: meeting)) ?? (confidential: true, notesConsent: false)
        guard t2?.token == tok, !Task.isCancelled else { return nil }
        if priv.confidential || confidentialLatch {
            stats.t2Skipped["confidential", default: 0] += 1
            t2 = nil
            return nil
        }
        t2?.sent = true
        lastSentMs = now()
        stats.t2Starts += 1
        return priv
    }

    /// A stream cancelled by a newer question (or the confidential switch) writes no row: it was replaced.
    private func t2Ended(_ tok: Int, _ qid: Int, _ firstMs: Int?, _ text: String, _ provider: String?, _ err: String?,
                         cancelled: Bool) async {
        if t2?.token == tok { t2 = nil }
        if let err, !cancelled { stats.t2Errors[err, default: 0] += 1 }
        if !cancelled, let firstMs, !text.isEmpty { await show(qid, "T2", text, provider, at: firstMs) }
        else if !cancelled { await publish(.answerFailed(questionID: qid)) }
    }

    private func cancelT2() {
        guard let cur = t2 else { return }
        t2 = nil
        cur.task.cancel()
        guard cur.sent else { stats.replacedPending += 1; return }
        let start = ContinuousClock.now
        cancelWaits.append(Task {
            await cur.task.value
            let c = start.duration(to: .now).components
            await self.recordCancel(Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000))
        })
    }

    private func recordCancel(_ ms: Int) { stats.cancelMs.append(ms) }

    /// T2 style sample (03-tdd): last 3 ME finals of >= 4 words.
    private func noteStyle(_ u: STTUpdate) {
        guard u.text.split(whereSeparator: \.isWhitespace).count >= 4 else { return }
        style.append((u.endMs, u.text))
        if style.count > 3 { style.removeFirst() }
    }
}
#endif
