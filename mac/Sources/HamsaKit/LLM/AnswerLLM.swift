import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// T11: T2 generated answer. OpenAI-compatible chat streaming with a provider fallback chain
/// (Groq -> Gemini -> ... ; a paid Claude/GLM key drops in as one more provider, no code change).
public struct LLMProvider: Sendable, Equatable {
    public let name: String
    public let baseURL: URL      // e.g. https://api.groq.com/openai/v1
    public let model: String
    public let apiKey: String
    public init(name: String, baseURL: URL, model: String, apiKey: String) {
        self.name = name; self.baseURL = baseURL; self.model = model; self.apiKey = apiKey
    }
}

public enum AnswerPrompt {
    /// `styleLines`: the owner's own recent sentences, so the answer copies their language and dialect.
    public static func messages(question: String, snippets: [String], styleLines: [String]) -> [[String: String]] {
        let style = styleLines.isEmpty
            ? "Saudi white dialect Arabic if the question is Arabic, otherwise English."
            : "Same language and dialect as these lines the user just said:\n" + styleLines.map { "- \($0)" }.joined(separator: "\n")
        let system = """
            You whisper answers to a founder during a live call. Answer ONLY from the notes below; if they do not \
            contain the answer, reply exactly: Not in your notes.
            Max 3 short lines. Keep product names and tech terms in English. \(style)
            """
        let notes = snippets.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
        return [["role": "system", "content": system], ["role": "user", "content": "Notes:\n\(notes)\n\nQuestion: \(question)"]]
    }
}

public enum SSE {
    /// One `data:` line of an OpenAI-style stream -> text delta; nil for keep-alives, `[DONE]` or non-text events.
    public static func delta(_ line: Substring) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any],
              let text = delta["content"] as? String, !text.isEmpty
        else { return nil }
        return text
    }
}

public struct AnswerLLM: Sendable {
    public enum LLMError: Error, Equatable { case confidential, allFailed([String]) }
    public let providers: [LLMProvider]
    let session: URLSession
    public init(providers: [LLMProvider], session: URLSession = .shared) {
        self.providers = providers; self.session = session
    }

    func request(_ p: LLMProvider, _ messages: [[String: String]]) throws -> URLRequest {
        var req = URLRequest(url: p.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": p.model, "messages": messages, "stream": true, "temperature": 0.2, "max_tokens": 160,
        ] as [String: Any])
        return req
    }

    #if canImport(Darwin)
    /// Streams text from the first provider that answers; falls through on HTTP/network errors.
    /// Cancel the consuming Task to stop (a newer question replaced this one).
    public func stream(question: String, snippets: [String], styleLines: [String], confidential: Bool)
        -> AsyncThrowingStream<(provider: String, text: String), Error>
    {
        AsyncThrowingStream { cont in
            let task = Task {
                if confidential { cont.finish(throwing: LLMError.confidential); return }
                let messages = AnswerPrompt.messages(question: question, snippets: snippets, styleLines: styleLines)
                var errors: [String] = []
                for p in providers {
                    do {
                        let (bytes, resp) = try await session.bytes(for: request(p, messages))
                        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                            errors.append("\(p.name): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"); continue
                        }
                        for try await line in bytes.lines {
                            if let t = SSE.delta(Substring(line)) { cont.yield((p.name, t)) }
                        }
                        cont.finish(); return
                    } catch is CancellationError {
                        cont.finish(); return
                    } catch {
                        errors.append("\(p.name): \(error.localizedDescription)")
                    }
                }
                cont.finish(throwing: LLMError.allFailed(errors))
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
    #endif
}
