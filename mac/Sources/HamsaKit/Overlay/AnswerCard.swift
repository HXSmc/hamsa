#if os(macOS)
import SwiftUI

/// T12: state of the answer overlay (04-app-flow Journey 2). Its only input is `apply`, fed every LivePipeline event
/// through the pipeline's `shown` hook (OverlayController.commit). The newest question owns the card; T2 upgrades a
/// snippet in place; a prepared T0 card is never replaced by a refusal; a refusal still streaming ("Not", "Not in")
/// is held back over whatever is on screen. `aiOff` mirrors the state the pipeline's send gates enforce (privacy
/// events); it is never written back.
@MainActor @Observable
public final class OverlayModel {
    public enum State: String, Sendable {
        case hidden, listening, searching, card, snippet, streaming, notInNotes, failed, answer, restarted
    }

    public private(set) var questionID: Int?
    public private(set) var question = ""
    /// Tier of the text in the body: T0 card, T1 snippet, T2 AI.
    public private(set) var tier: String?
    public private(set) var text = ""
    public private(set) var provider: String?
    public private(set) var streaming = false
    public private(set) var visible = false
    /// The T2 of the current question ended with nothing shown.
    public private(set) var t2Failed = false
    public var pinned = false { didSet { scheduleFade() } }
    public var rating: Int?
    /// True until the stored privacy state is read (fail closed on screen too).
    public var aiOff = true
    /// A meeting is running: the idle "Listening" chip shows only then.
    public var live = false
    /// STT worker restarted (STTSupervisor generation > 1); cleared by the next question.
    public var sttRestarted = false

    public static let fadeSeconds = 20
    /// T2's refusal (AnswerLLM prompt) and the Arabic forms a model may translate it to.
    static let refusals = ["Not in your notes", "مو موجود في ملاحظاتك", "غير موجود في ملاحظاتك", "ليس في ملاحظاتك", "ليست في ملاحظاتك"]
    @ObservationIgnored private var fade: Task<Void, Never>?
    /// Where the footer buttons are (hosting-view coordinates, top-left origin): the only part that takes clicks.
    @_spi(Bench) @ObservationIgnored public internal(set) var buttonsRect: CGRect = .zero

    public init() {}

    public var state: State {
        if !visible { return sttRestarted ? .restarted : live ? .listening : .hidden }
        if tier == "T2", Self.isRefusal(text) { return .notInNotes }
        if tier == nil { return aiOff ? .notInNotes : t2Failed ? .failed : .searching }  // nothing else is coming
        if streaming { return .streaming }
        switch tier { case "T0": return .card; case "T1": return .snippet; default: return .answer }
    }

    static func isRefusal(_ s: String) -> Bool { refusals.contains { s.contains($0) } }

    /// Applies one pipeline event; returns whether what the card shows changed (the pipeline stamps t_shown_ms only then).
    @discardableResult
    public func apply(_ e: LivePipeline.Event) -> Bool {
        defer { scheduleFade() }
        switch e {
        case let .question(id, _, q):
            guard id != questionID else { return false }
            withAnimation(.easeOut(duration: 0.15)) {  // the only animation (04-app-flow visual rules)
                questionID = id; question = q; tier = nil; text = ""; provider = nil; t2Failed = false
                streaming = false; pinned = false; rating = nil; sttRestarted = false; visible = true
            }
            return true
        case let .answer(qid, t, body, p, done):
            guard qid == questionID else { return false }  // an older question's answer
            if t == "T1", tier == "T0" { return false }  // the prepared card beats the top snippet
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let refusal = Self.isRefusal(trimmed)
            let partialRefusal = !refusal && Self.refusals.contains { $0.hasPrefix(trimmed) }
            if t == "T2", tier == "T0", refusal || partialRefusal { return false }  // a matched card stays
            if t == "T2", partialRefusal { return false }  // "Not", "Not in": hold until it is a refusal or an answer
            let before = (tier, text, streaming)
            tier = t; text = body; provider = p; streaming = t == "T2" && !done; visible = true
            return before != (tier, text, streaming)
        case let .answerFailed(qid):
            guard qid == questionID else { return false }
            streaming = false
            t2Failed = tier == nil
            return tier == nil
        case let .privacy(confidential):
            defer { aiOff = confidential }
            return aiOff != confidential
        }
    }

    /// Cards auto-fade 20 s after their last update unless pinned.
    private func scheduleFade() {
        fade?.cancel()
        guard visible, !pinned else { return }
        fade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeSeconds))
            guard !Task.isCancelled else { return }
            self?.visible = false
        }
    }

    // MARK: - display text

    /// Card language: the answer's when the body shows answer text, else the question's (fixed strings follow it).
    var ar: Bool {
        let s = [.card, .snippet, .streaming, .answer].contains(state) ? body : question.isEmpty ? text : question
        return LocalIndex.lang(s) == "ar"
    }

    func tr(_ en: String) -> String { ar ? Self.arabic[en] ?? en : en }
    static let arabic = [
        "Not in your notes": "مو موجود في ملاحظاتك", "Searching your notes": "أدوّر في ملاحظاتك",
        "AI off": "AI متوقف", "Transcription restarted": "أُعيد تشغيل التفريغ", "Listening": "أستمع",
        "No answer. Try asking again.": "ما وصل جواب. جرّب تسأل مرة ثانية.", "Prepared card": "بطاقة جاهزة",
        "Card": "بطاقة", "Note": "ملاحظة", "AI": "AI",
    ]

    /// T1 text is "heading path\nsnippet": the first and last heading parts, without markdown, name the source.
    var source: String {
        switch tier {
        case "T0": return tr("Prepared card")
        case "T1":
            let parts = String(text.prefix { $0 != "\n" }).components(separatedBy: " > ").map(Self.plain).filter { !$0.isEmpty }
            return parts.count > 1 ? "\(parts[0]) › \(parts[parts.count - 1])" : parts.first ?? ""
        default: return ""  // a provider id is not a source
        }
    }

    var body: String {
        guard tier == "T1" else { return streaming ? text + " …" : text }
        return Self.snippet(String(text.drop { $0 != "\n" }.dropFirst()))
    }

    var badge: String { tr(["T0": "Card", "T1": "Note", "T2": "AI"][tier ?? ""] ?? "") }

    var badgeLabel: String {
        switch tier {
        case "T0": return "Answer source: prepared card"
        case "T1": return "Answer source: your notes"
        default: return streaming ? "Answer source: AI, still writing" : "Answer source: AI"
        }
    }

    /// Markdown-lite heading part: no #, *, `, brackets.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ").filter { !"#*`()[]".contains($0) }.trimmingCharacters(in: .whitespaces)
    }

    /// A raw index chunk made glanceable: no heading marks or list bullets, no blank lines, cut at the last sentence end.
    static func snippet(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline).map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while l.hasPrefix("#") { l.removeFirst() }
            for bullet in ["- ", "* ", "+ ", "> "] where l.hasPrefix(bullet) { l.removeFirst(bullet.count) }
            // Ordered-list number ("6. ", "٦. ", "3) "), Western or Arabic-Indic digits.
            if let m = l.firstMatch(of: /^[0-9٠-٩]{1,3}[.)]\s+/) { l.removeSubrange(m.range) }
            return l.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        guard let end = joined.lastIndex(where: { ".!?؟".contains($0) }),
              joined.distance(from: joined.startIndex, to: end) > joined.count / 2 else { return joined }
        return String(joined[...end])
    }
}

/// T12 answer card: header (question as heard), body (≤ 4 lines), footer (source · tier badge · rate · pin).
/// Visual rules (04-app-flow): system font, ≥ 15 pt, one accent colour (tier badge outline), no gradients/glass,
/// RTL when the answer is Arabic. Text contrast holds over any page behind the 85% surface (primary at 0.7+).
public struct AnswerCardView: View {
    let model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(model: OverlayModel) { self.model = model }

    static let muted = Color.primary.opacity(0.7)

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .hidden:
                EmptyView()
            case .listening:
                chip(model.tr("Listening"), weight: .regular).transition(.identity)
            case .restarted:
                chip(model.tr("Transcription restarted"), weight: .medium).transition(.identity)
            default:
                card.id(model.questionID).transition(reduceMotion ? .opacity : .move(edge: .top))
            }
            Spacer(minLength: 0)
        }
        .frame(width: OverlayController.width, alignment: .topLeading)
    }

    private func chip(_ s: String, weight: Font.Weight) -> some View {
        Text(s).font(.system(size: 15, weight: weight)).foregroundStyle(Self.muted)
            .padding(12).frame(width: OverlayController.width, alignment: .leading).background(surface)
            .environment(\.layoutDirection, model.ar ? .rightToLeft : .leftToRight)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.question).font(.system(size: 15)).foregroundStyle(Self.muted).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, LocalIndex.lang(model.question) == "ar" ? .rightToLeft : .leftToRight)
            bodyText
            footer
        }
        .padding(12)
        .frame(width: OverlayController.width, alignment: .leading)
        .background(surface)
        .environment(\.layoutDirection, model.ar ? .rightToLeft : .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.question)
    }

    @ViewBuilder private var bodyText: some View {
        let spacing: CGFloat = model.ar ? 5 : 2
        switch model.state {
        case .searching:
            Text(model.tr("Searching your notes")).font(.system(size: 18)).foregroundStyle(Self.muted)
        case .notInNotes:
            Text(model.tr("Not in your notes")).font(.system(size: 18, weight: .medium)).foregroundStyle(.primary)
        case .failed:
            Text(model.tr("No answer. Try asking again.")).font(.system(size: 18)).foregroundStyle(.primary)
        default:
            Text((try? AttributedString(markdown: model.body,
                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(model.body))
                .font(.system(size: 18)).lineSpacing(spacing).lineLimit(4).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.state != .notInNotes {
                if !model.source.isEmpty {
                    Text(model.source).font(.system(size: 15)).foregroundStyle(Self.muted).lineLimit(1).truncationMode(.tail)
                        .layoutPriority(0)
                }
                if !model.badge.isEmpty {
                    Text(model.badge).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                        .frame(minWidth: 44).padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5))
                        .fixedSize().accessibilityLabel(model.badgeLabel)
                }
            }
            if model.aiOff {
                Text(model.tr("AI off")).font(.system(size: 15)).foregroundStyle(Self.muted).fixedSize()
                    .accessibilityLabel("AI is off")
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                button("hand.thumbsup", "Helpful", on: model.rating == 1) { model.rating = model.rating == 1 ? nil : 1 }
                button("hand.thumbsdown", "Not helpful", on: model.rating == -1) { model.rating = model.rating == -1 ? nil : -1 }
                button("pin", "Pin card", on: model.pinned) { model.pinned.toggle() }
            }
            .fixedSize()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.buttonsRect = $0 }
        }
    }

    /// No `.help` tooltip: AppKit draws tooltips in their own window, which is not share-hidden.
    private func button(_ symbol: String, _ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? symbol + ".fill" : symbol).font(.system(size: 16))
                .foregroundStyle(on ? Color.primary : Self.muted)
                .frame(width: 32, height: 32).contentShape(Rectangle())  // Fitts: the whole 32 pt square is the target
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.18), lineWidth: 1))
    }
}
#endif
