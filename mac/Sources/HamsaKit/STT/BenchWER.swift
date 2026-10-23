import Foundation

/// T02: word error rate + the per-clip result every bench engine returns. Platform-free (Linux builds it).
public enum BenchWER {
    /// Probe.normalize (tashkeel, alef/yaa/taa-marbuta, digits, case) plus: punctuation and invisible
    /// format marks (RTL mark etc.) become spaces, then split into words.
    public static func words(_ s: String) -> [String] {
        let cleaned = String(String.UnicodeScalarView(Probe.normalize(s).unicodeScalars.map { u -> Unicode.Scalar in
            let p = u.properties.generalCategory
            switch p {
            case .format, .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol, .otherSymbol:
                return " "
            default: return u
            }
        }))
        return cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Word-level Levenshtein distance (substitutions + deletions + insertions) between normalized texts.
    public static func errors(ref: String, hyp: String) -> (errors: Int, refWords: Int) {
        let r = words(ref), h = words(hyp)
        guard !r.isEmpty else { return (h.count, 0) }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return (prev[h.count], r.count)
    }

    /// Corpus WER = total errors / total reference words.
    public static func wer(_ pairs: [(ref: String, hyp: String)]) -> Double {
        var e = 0, n = 0
        for p in pairs { let x = errors(ref: p.ref, hyp: p.hyp); e += x.errors; n += x.refWords }
        return n == 0 ? 0 : Double(e) / Double(n)
    }

    /// Lag per final word: first time (seconds, stream clock) the word showed up at its index in any
    /// hypothesis, minus the word's end time in the audio. `hyps` are (time, text) in arrival order.
    public static func wordLags(finalWords: [(word: String, end: Double)], hyps: [(time: Double, text: String)]) -> [Double] {
        let hw = hyps.map { (time: $0.time, words: words($0.text)) }
        var lags: [Double] = []
        for (i, fw) in finalWords.enumerated() {
            let w = words(fw.word).first ?? ""
            guard let seen = hw.first(where: { $0.words.count > i && $0.words[i] == w }) else { continue }
            lags.append(max(0, seen.time - fw.end))
        }
        return lags
    }
}

/// What an engine returns for one clip.
public struct BenchClip: Sendable {
    public var text: String
    /// Partial lag per word in seconds (empty when the engine gave no timing).
    public var lags: [Double]
    public init(text: String, lags: [Double]) { self.text = text; self.lags = lags }
}
