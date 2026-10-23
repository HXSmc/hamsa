import Foundation

/// THE labels format for a call (`bench/calls/call-NN.labels.json`): the one definition used by
/// `hamsa-cli transcribe --labels`, `bench/make-synth-call.sh`, and later `bench-label` / `hamsa-cli rehearse` (T02a).
///
/// ```json
/// {"audio": {"them": "call-01.wav", "me": "call-01.me.wav"}, "provisional": true,
///  "items": [{"channel": "them", "start": 0.5, "end": 3.9, "text": "...", "is_question": true,
///             "tech": false, "verbatim": true, "lang": "ar"}]}
/// ```
/// - `audio`: channel → wav file name, relative to the labels file. One wav (them) or a pair (them + me).
/// - items: one per utterance (not only questions). `start`/`end` are seconds on the shared call timeline;
///   `end` of a question = `t_question_end_ms / 1000` (last voiced frame).
/// - `verbatim`: true = exact ground truth from a script (TTS, rehearsal); false = needs human labelling.
/// - `lang` is optional (`ar` / `en`).
/// - `cue` is optional: the topic cue shown for an own-words `rehearse` turn (`verbatim: false`, `text` empty until labelled).
public struct CallLabels: Codable, Sendable, Equatable {
    public var audio: [String: String]
    public var provisional: Bool
    public var items: [Item]

    public struct Item: Codable, Sendable, Equatable {
        public var channel: String
        public var start: Double
        public var end: Double
        public var text: String
        public var isQuestion: Bool
        public var tech: Bool
        public var verbatim: Bool
        public var lang: String?
        public var cue: String?

        enum CodingKeys: String, CodingKey {
            case channel, start, end, text, tech, verbatim, lang, cue
            case isQuestion = "is_question"
        }

        public init(channel: String, start: Double, end: Double, text: String, isQuestion: Bool,
                    tech: Bool = false, verbatim: Bool, lang: String? = nil, cue: String? = nil) {
            self.channel = channel; self.start = start; self.end = end; self.text = text
            self.isQuestion = isQuestion; self.tech = tech; self.verbatim = verbatim; self.lang = lang
            self.cue = cue
        }
    }

    public init(audio: [String: String], provisional: Bool, items: [Item]) {
        self.audio = audio; self.provisional = provisional; self.items = items
    }

    public static func load(_ url: URL) throws -> CallLabels {
        try JSONDecoder().decode(CallLabels.self, from: Data(contentsOf: url))
    }

    public var questions: [Item] { items.filter(\.isQuestion) }

    /// Reference transcript of one channel (items in time order), for WER.
    public func reference(channel: String) -> String {
        items.filter { $0.channel == channel }.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
    }
}
