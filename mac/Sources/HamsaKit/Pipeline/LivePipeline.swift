#if canImport(Darwin)
import Foundation

/// T11b: the live answer path (03-tdd "4 answer tiers"). Feed it every STT update of a meeting. It writes the
/// segment, runs the question detector on the asker channels and shows, per question:
/// - T0 card: on partials and finals when CardMatcher is confident (no question word needed),
/// - T1 snippet: top LocalIndex hit, and T2: streamed LLM answer from the top-3 hits,
///   fired on a final with rules score >= 1, or speculatively on a partial with rules score >= 2,
///   restarted when the top-3 chunks change.
/// A newer T2 cancels the one in flight. T2 requests are spaced >= `minGapMs` (Groq free tier 429s when
/// paced faster than ~6 s); a question waiting for the gap is replaced by a newer one (newest question wins).
/// `confidential` and `notes_consent` are read from the meeting row in LiveStore before every T2.
/// All `*_ms` values use `now()`, the same clock as STTUpdate times (stream clock = audio timeline on a live feed),
/// so `latency_events` (t_shown_ms - t_question_end_ms) is meaningful.
public actor LivePipeline {
    public enum Event: Sendable {
        case question(id: Int, channel: String, text: String)
        /// T2 repeats with the growing text; `done` marks its last event.
        case answer(questionID: Int, tier: String, text: String, provider: String?, done: Bool)
    }

    public struct Stats: Sendable {
        public var questions = 0, t0 = 0, t1 = 0, t2 = 0
        /// T2 streams handed to AnswerLLM (after the gap gate).
        public var t2Starts = 0
        /// T2 not started, by reason (`confidential`, `no llm`).
        public var t2Skipped: [String: Int] = [:]
        public var t2Errors: [String: Int] = [:]
        /// Answers still waiting for the gap when a newer question replaced them (no request was sent).
        public var replacedPending = 0
        /// Per cancelled in-flight answer: ms from cancel to its task having ended (stream torn down).
        public var cancelMs: [Int] = []
        public var storeErrors = 0
    }

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
    let minGapMs: Int
    public private(set) var stats = Stats()

    struct Utterance { var words = 0; var questionID: Int?; var cardID: Int?; var chunkIDs: [Int]?; var t1Shown = false }
    private var open: [Int: Utterance] = [:]  // by segment row id
    private var style: [(ms: Int, text: String)] = []
    private var t2: (token: Int, task: Task<Void, Never>, sent: Bool)?
    private var token = 0
    private var lastSentMs: Int?

    public init(store: LiveStore, meeting: String, embedder: (any Embedder)?, index: LocalIndex?, cards: CardMatcher?,
                llm: AnswerLLM?, askers: Set<String> = ["them"], minGapMs: Int = 6000, now: @escaping @Sendable () -> Int) {
        self.store = store; self.meeting = meeting; self.embedder = embedder; self.index = index; self.cards = cards
        self.llm = llm; self.askers = askers; self.minGapMs = minGapMs; self.now = now
        // Newest-only buffer: a run without a consumer (CLI soak) must not grow memory.
        (events, cont) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    public func ingest(_ u: STTUpdate) async {
        let seg: Int
        do { seg = try await store.write(u, meeting: meeting) } catch { stats.storeErrors += 1; return }
        if u.channel == "me", u.isFinal { noteStyle(u) }
        guard askers.contains(u.channel) else { return }
        var ut = open[seg] ?? Utterance()
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
            let ids = hits.map(\.chunkID)
            if ut.chunkIDs != ids {
                ut.chunkIDs = ids
                await startT2(qid, question: u.text, snippets: hits.map { "\($0.heading)\n\($0.text)" })
            }
        }
        if u.isFinal, let qid = ut.questionID {
            do { try await store.updateQuestion(id: qid, text: u.text, detectConf: conf, tQuestionEndMs: u.endMs) }
            catch { stats.storeErrors += 1 }
        }
        open[seg] = u.isFinal ? nil : ut
    }

    /// End of meeting: lets the answer in flight finish, then closes `events`.
    public func finish() async {
        if let cur = t2 { await cur.task.value }
        cont.finish()
    }

    // MARK: - tiers

    private func question(_ ut: inout Utterance, _ u: STTUpdate, seg: Int, conf: Double, cardID: Int?, score: Double?) async -> Int {
        if let q = ut.questionID { return q }
        do {
            let q = try await store.addQuestion(meeting: meeting, segmentID: seg, text: u.text, detectConf: conf, tDetectMs: now(),
                                                tQuestionEndMs: u.endMs, cardID: cardID, matchScore: score)
            ut.questionID = q
            stats.questions += 1
            cont.yield(.question(id: q, channel: u.channel, text: u.text))
            return q
        } catch {
            stats.storeErrors += 1
            return -1
        }
    }

    private func show(_ qid: Int, _ tier: String, _ text: String, _ provider: String?, at: Int? = nil) async {
        guard qid >= 0 else { return }
        let ms = at ?? now()
        cont.yield(.answer(questionID: qid, tier: tier, text: text, provider: provider, done: true))
        switch tier { case "T0": stats.t0 += 1; case "T1": stats.t1 += 1; default: stats.t2 += 1 }
        do { try await store.addAnswer(questionID: qid, tier: tier, tShownMs: ms, text: text, provider: provider) }
        catch { stats.storeErrors += 1 }
    }

    private func startT2(_ qid: Int, question: String, snippets: [String]) async {
        guard qid >= 0 else { return }
        guard let llm else { stats.t2Skipped["no llm", default: 0] += 1; return }
        // Read before touching `t2`: no await between cancel and the new task, so two questions never interleave.
        let priv = (try? await store.privacy(meeting: meeting)) ?? (confidential: true, notesConsent: false)
        cancelT2()
        if priv.confidential { stats.t2Skipped["confidential", default: 0] += 1; return }
        token += 1
        let tok = token
        let wait = lastSentMs.map { max(0, $0 + minGapMs - now()) } ?? 0
        let styleLines = style.filter { $0.ms >= now() - 180_000 }.map(\.text)
        let (cont, now) = (cont, now)
        let task = Task {
            if wait > 0 {
                do { try await Task.sleep(for: .milliseconds(wait)) } catch { return }
            }
            guard await self.claimSend(tok) else { return }
            var text = "", provider: String?, firstMs: Int?, err: String?
            do {
                for try await (p, t) in llm.stream(question: question, snippets: snippets, styleLines: styleLines,
                                                   confidential: priv.confidential, notesConsent: priv.notesConsent) {
                    if firstMs == nil { firstMs = now() }
                    text += t
                    provider = p
                    cont.yield(.answer(questionID: qid, tier: "T2", text: text, provider: p, done: false))
                }
            } catch {
                err = String("\(error)".prefix(160))
            }
            await self.t2Ended(tok, qid, firstMs, text, provider, err)
        }
        t2 = (tok, task, false)
    }

    private func claimSend(_ tok: Int) -> Bool {
        guard t2?.token == tok, !Task.isCancelled else { return false }
        t2?.sent = true
        lastSentMs = now()
        stats.t2Starts += 1
        return true
    }

    /// A cancelled stream ends normally with the text shown so far; that partial answer is logged too.
    private func t2Ended(_ tok: Int, _ qid: Int, _ firstMs: Int?, _ text: String, _ provider: String?, _ err: String?) async {
        if t2?.token == tok { t2 = nil }
        if let err { stats.t2Errors[err, default: 0] += 1 }
        if let firstMs, !text.isEmpty { await show(qid, "T2", text, provider, at: firstMs) }
    }

    private func cancelT2() {
        guard let cur = t2 else { return }
        t2 = nil
        cur.task.cancel()
        guard cur.sent else { stats.replacedPending += 1; return }
        let start = ContinuousClock.now
        Task {
            await cur.task.value
            let c = start.duration(to: .now).components
            await self.recordCancel(Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000))
        }
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
