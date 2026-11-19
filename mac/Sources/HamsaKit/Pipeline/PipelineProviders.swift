import Foundation

/// T11b: THE provider chain of the live pipeline (ADR 002), built here and nowhere else.
/// Groq qwen3.8-27b -> Groq gpt-oss-120b (separate per-model quota) -> Gemini free tier, which is hard-set to
/// `mayReceiveNotes: false`: it only gets a request when the meeting row has `notes_consent = 1`.
public enum PipelineProviders {
    /// `key(account)` = API key for Keychain account `groq` / `gemini`; nil or empty = provider skipped, no request.
    public static func chain(key: (String) -> String?) -> [LLMProvider] {
        let groq = URL(string: "https://api.groq.com/openai/v1")!
        let gemini = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
        return [
            LLMProvider(name: "groq", baseURL: groq, model: "qwen/qwen3.8-27b", apiKey: key("groq") ?? "",
                        mayReceiveNotes: true, extra: ["reasoning_effort": "none"]),
            LLMProvider(name: "groq-gpt-oss", baseURL: groq, model: "openai/gpt-oss-120b", apiKey: key("groq") ?? "",
                        mayReceiveNotes: true, extra: ["reasoning_effort": "low", "include_reasoning": false]),
            LLMProvider(name: "gemini", baseURL: gemini, model: "gemini-3.5-flash", apiKey: key("gemini") ?? "",
                        mayReceiveNotes: false, extra: ["reasoning_effort": "minimal"]),
        ]
    }

    #if os(macOS)
    /// Keychain item (service `hamsa`, account = provider) via /usr/bin/security: items added with the
    /// `security` CLI trust only that tool, so a direct SecItem read from an unsigned binary would prompt.
    /// The key is never printed or logged.
    public static func keychainKey(_ account: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "hamsa", "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let key = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
    #endif
}
