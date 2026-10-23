import Foundation

/// Rule half of the question detector (03-tdd "Question detector", step 1). The card-similarity half
/// needs the on-device embedder (T05b) and joins it in T09.
public enum QuestionRules {
    // Saudi dialect + MSA interrogatives, stored normalised (see `normalizeArabic`).
    static let arabicCues: Set<String> = [
        "وش", "ايش", "شو", "ليش", "ليه", "كيف", "هل", "متي", "كم", "بكم", "وين", "فين", "مين", "منو",
        "ماذا", "لماذا", "اين", "كيفيه", "تقدر", "تقدرون", "تقدري", "ممكن", "عندكم", "فيه", "تشرح", "اشرح",
        "وشلون", "شلون", "ايه",
    ]
    static let englishStarters: Set<String> = [
        "what", "why", "how", "when", "where", "who", "which", "whose", "can", "could", "would", "will",
        "do", "does", "did", "is", "are", "was", "were", "should", "have", "has",
    ]
    static let englishPhrases = ["tell me", "explain", "walk me through", "i wonder", "any idea"]

    /// Unify common Arabic spelling variants and strip diacritics/tatweel so cues match ASR output.
    public static func normalizeArabic(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue                // harakat, dagger alef, tatweel
            case 0x0622, 0x0623, 0x0625: out.unicodeScalars.append("\u{0627}") // آ أ إ -> ا
            case 0x0649: out.unicodeScalars.append("\u{064A}")                 // ى -> ي
            case 0x0629: out.unicodeScalars.append("\u{0647}")                 // ة -> ه
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func tokens(_ s: String) -> [String] {
        normalizeArabic(s.lowercased())
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// 0 = no question cue. Each independent cue adds 1.
    public static func score(_ text: String) -> Int {
        let toks = tokens(text)
        var s = 0
        if text.contains("?") || text.contains("؟") { s += 1 }
        if let first = toks.first, englishStarters.contains(first) { s += 1 }
        // Arabic cues can sit anywhere ("الـGPU وش نوعه؟"); a leading و/ب/ف clitic is allowed.
        if toks.contains(where: { t in
            arabicCues.contains(t) || (t.count > 2 && ["و", "ب", "ف"].contains(String(t.prefix(1))) && arabicCues.contains(String(t.dropFirst())))
        }) { s += 1 }
        let lower = text.lowercased()
        if englishPhrases.contains(where: { lower.contains($0) }) { s += 1 }
        return s
    }
}
