import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// T03: helpers for bench-llm: Arabic answer check, percentiles, one timed streaming request.
public enum Probe {
    /// True when most letters are in Arabic Unicode blocks (English product terms in an Arabic answer are fine).
    public static func isArabic(_ s: String) -> Bool {
        // Counted per word, not per letter: answers keep tech terms in English, which are long Latin words.
        var arabic = 0, words = 0
        for w in s.split(whereSeparator: { $0.isWhitespace }) {
            let letters = w.unicodeScalars.filter { $0.properties.isAlphabetic }
            guard let first = letters.first else { continue }
            words += 1
            switch first.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: arabic += 1
            default: break
            }
        }
        return words > 0 && arabic * 2 >= words
    }

    /// Drops tashkeel/tatweel, unifies alef/yaa/taa-marbuta forms and digits, case-folds, trims.
    public static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue
            case 0x0622, 0x0623, 0x0625: out.append(Unicode.Scalar(UInt32(0x0627))!)
            case 0x0649: out.append(Unicode.Scalar(UInt32(0x064A))!)
            case 0x0629: out.append(Unicode.Scalar(UInt32(0x0647))!)
            case 0x0660...0x0669: out.append(Unicode.Scalar(0x30 + (u.value - 0x0660))!)
            case 0x06F0...0x06F9: out.append(Unicode.Scalar(0x30 + (u.value - 0x06F0))!)
            default: out.append(u)
            }
        }
        return String(out).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Arabic script, contains one of the `|`-separated expected facts (after normalizing both), 1...3 non-empty lines.
    public static func passes(answer: String, expected: String) -> Bool {
        let lines = answer.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard (1...3).contains(lines.count), isArabic(answer) else { return false }
        let text = normalize(answer)
        return expected.split(separator: "|").map { normalize(String($0)) }.contains { !$0.isEmpty && text.contains($0) }
    }

    /// Nearest-rank percentile, `p` in 0...100; 0 for an empty list.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    #if canImport(Darwin)
    /// One streaming request; ms from start to the first non-empty content delta.
    /// `limits` holds the response's `x-ratelimit*` headers (lowercased names).
    /// `extra` keys (e.g. `reasoning_effort`, `max_tokens`) are merged into the JSON body and override defaults.
    public static func timeToFirstToken(
        _ llm: AnswerLLM, _ p: LLMProvider, messages: [[String: String]], extra: [String: any Sendable] = [:]
    ) async -> (ttftMs: Double?, text: String, error: String?, limits: [String: String]) {
        let t0 = ContinuousClock.now
        var ttft: Double?
        var text = ""
        var limits: [String: String] = [:]
        do {
            var req = try llm.request(p, messages)
            if let body = req.httpBody, var obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                for (k, v) in extra { obj[k] = v }
                req.httpBody = try JSONSerialization.data(withJSONObject: obj)
            }
            req.timeoutInterval = 30
            let (bytes, resp) = try await llm.session.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            for (k, v) in (resp as? HTTPURLResponse)?.allHeaderFields ?? [:] {
                if let k = k as? String, k.lowercased().hasPrefix("x-ratelimit") { limits[k.lowercased()] = "\(v)" }
            }
            guard code == 200 else { return (nil, "", "HTTP \(code)", limits) }
            for try await line in bytes.lines {
                guard let t = SSE.delta(Substring(line)) else { continue }
                if ttft == nil {
                    let c = t0.duration(to: .now).components
                    ttft = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
                }
                text += t
            }
            return (ttft, text, ttft == nil ? "no content" : nil, limits)
        } catch {
            return (ttft, text, error.localizedDescription, limits)
        }
    }
    #endif
}
