#if os(macOS)
import SwiftUI

/// T12: state of the answer overlay (04-app-flow Journey 2). Fed with LivePipeline events; the newest question owns
/// the card, T2 upgrades a T1 snippet in place, a prepared T0 card is never replaced by the T2 refusal.
/// `aiOff` mirrors the meeting's stored privacy state (LiveStore) or an LLM outage; the overlay never writes it back.
@MainActor @Observable
public final class OverlayModel {
    public enum State: String, Sendable { case empty, searching, card, snippet, streaming, notInNotes, answer, restarted }

    public private(set) var questionID: Int?
    public private(set) var question = ""
    /// Tier of the text in the body: T0 card, T1 snippet, T2 AI.
    public private(set) var tier: String?
    public private(set) var text = ""
    public private(set) var provider: String?
    public private(set) var streaming = false
    public private(set) var visible = false
    public var pinned = false { didSet { scheduleFade() } }
    public var rating: Int?
    public var aiOff = false
    /// STT worker restarted (STTSupervisor generation > 1); cleared by the next question.
    public var sttRestarted = false

    public static let fadeSeconds = 20
    static let refusal = "Not in your notes"
    @ObservationIgnored private var fade: Task<Void, Never>?
    /// Where the footer buttons are (hosting-view coordinates, top-left origin): the only part that takes clicks.
    @ObservationIgnored var buttonsRect: CGRect = .zero

    public init() {}

    public var state: State {
        if !visible { return sttRestarted ? .restarted : .empty }
        if tier == nil { return .searching }
        if tier == "T2", text.contains(Self.refusal) { return .notInNotes }
        if streaming { return .streaming }
        switch tier { case "T0": return .card; case "T1": return .snippet; default: return .answer }
    }

    public func apply(_ e: LivePipeline.Event) {
        switch e {
        case let .question(id, _, q):
            guard id != questionID else { return }
            withAnimation(.easeOut(duration: 0.15)) {  // the only animation (04-app-flow visual rules)
                questionID = id; question = q; tier = nil; text = ""; provider = nil
                streaming = false; pinned = false; rating = nil; sttRestarted = false; visible = true
            }
        case let .answer(qid, t, body, p, done):
            guard qid == questionID else { return }  // an older question's answer
            if t == "T1", tier == "T0" { return }  // the prepared card beats the top snippet
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let refusal = trimmed.contains(Self.refusal), maybeRefusal = !refusal && Self.refusal.hasPrefix(trimmed)
            if t == "T2", tier == "T0", refusal || maybeRefusal { return }  // a matched card is never replaced by "not in notes"
            // A streaming "Not in…" would blank the snippet word by word: keep it until the refusal is complete.
            if t == "T2", tier == "T1", maybeRefusal { streaming = !done; scheduleFade(); return }
            tier = t; text = body; provider = p; streaming = t == "T2" && !done; visible = true
        }
        scheduleFade()
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

    /// T1 text is "heading\nsnippet": the heading is the source line in the footer.
    var source: String {
        switch tier {
        case "T0": return "Prepared card"
        case "T1": return String(text.prefix { $0 != "\n" })
        case "T2": return provider ?? ""
        default: return ""
        }
    }

    var body: String {
        tier == "T1" ? String(text.drop { $0 != "\n" }.dropFirst()) : text
    }

    var badge: String { ["T0": "Card", "T1": "Note", "T2": "AI"][tier ?? ""] ?? "" }
    var rtl: Bool { LocalIndex.lang(body.isEmpty ? question : body) == "ar" }
}

/// T12 answer card: header (question as heard), body (≤ 4 lines), footer (source · tier badge · rate · pin).
/// Visual rules (04-app-flow): system font, ≥ 15 pt, one accent colour (tier badge), no gradients/glass,
/// RTL when the answer is Arabic.
public struct AnswerCardView: View {
    let model: OverlayModel
    public init(model: OverlayModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .empty:
                Text("Listening").font(.system(size: 15)).foregroundStyle(.secondary).padding(12).background(surface)
            case .restarted:
                Text("Transcription restarted").font(.system(size: 15, weight: .medium)).padding(12).background(surface)
            default:
                card.id(model.questionID).transition(.move(edge: .top))
            }
            Spacer(minLength: 0)
        }
        .frame(width: OverlayController.width, alignment: .topLeading)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.question).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, LocalIndex.lang(model.question) == "ar" ? .rightToLeft : .leftToRight)
            bodyText
            footer
        }
        .padding(12)
        .frame(width: OverlayController.width, alignment: .leading)
        .background(surface)
        .environment(\.layoutDirection, model.rtl ? .rightToLeft : .leftToRight)
    }

    @ViewBuilder private var bodyText: some View {
        switch model.state {
        case .searching:
            Text("Searching your notes").font(.system(size: 17)).foregroundStyle(.secondary)
        case .notInNotes:
            Text("Not in your notes").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
        default:
            Text(model.body).font(.system(size: 17)).lineLimit(4).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.source.isEmpty {
                Text(model.source).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if !model.badge.isEmpty {
                Text(model.streaming ? "\(model.badge) …" : model.badge)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
            }
            if model.aiOff {
                Text("AI off").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 1))
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                button("hand.thumbsup", "Helpful", on: model.rating == 1) { model.rating = model.rating == 1 ? nil : 1 }
                button("hand.thumbsdown", "Not helpful", on: model.rating == -1) { model.rating = model.rating == -1 ? nil : -1 }
                button("pin", "Pin card", on: model.pinned) { model.pinned.toggle() }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.buttonsRect = $0 }
        }
    }

    private func button(_ symbol: String, _ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? symbol + ".fill" : symbol).font(.system(size: 15))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())  // Fitts: whole 28 pt square is the target
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
#endif
