import XCTest
@testable import HamsaKit

final class AnswerLLMTests: XCTestCase {
    func testSSEDelta() {
        XCTAssertEqual(SSE.delta(#"data: {"choices":[{"delta":{"content":"L4 "}}]}"#), "L4 ")
        XCTAssertNil(SSE.delta("data: [DONE]"))
        XCTAssertNil(SSE.delta(": keep-alive"))
        XCTAssertNil(SSE.delta(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
    }

    func testPromptCarriesStyleAndRefusalRule() {
        let m = AnswerPrompt.messages(question: "وش الـGPU؟", snippets: ["L4 in Riyadh"], styleLines: ["طيب خلني اشرح"])
        XCTAssertTrue(m[0]["content"]!.contains("Not in your notes"))
        XCTAssertTrue(m[0]["content"]!.contains("طيب خلني اشرح"))
        XCTAssertTrue(m[1]["content"]!.contains("[1] L4 in Riyadh"))
    }

    #if canImport(Darwin)
    /// Fake transport. Hosts: down.test -> 503, up.test -> two tokens, hang.test -> one token then stays open,
    /// break.test -> one token then the connection drops.
    /// Counts requests per host and records torn-down (stopLoading) requests.
    final class Fake: URLProtocol, @unchecked Sendable {
        static let lock = NSLock()
        nonisolated(unsafe) static var hits: [String: Int] = [:]
        nonisolated(unsafe) static var stopped = 0
        static func reset() { lock.withLock { hits = [:]; stopped = 0 } }
        static func count(_ host: String? = nil) -> Int { lock.withLock { host.map { hits[$0, default: 0] } ?? hits.values.reduce(0, +) } }
        static func stoppedCount() -> Int { lock.withLock { stopped } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let host = request.url!.host!
            Self.lock.withLock { Self.hits[host, default: 0] += 1 }
            let down = host == "down.test"
            let resp = HTTPURLResponse(url: request.url!, statusCode: down ? 503 : 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if host == "hang.test" {
                client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"L4 \"}}]}\n\n".utf8))
                return  // never finishes: only a cancel ends it
            }
            if host == "break.test" {
                client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"L4 \"}}]}\n\n".utf8))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {  // drop after the token was read
                    self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                }
                return
            }
            if !down {
                let body = "data: {\"choices\":[{\"delta\":{\"content\":\"L4 \"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"GPU\"}}]}\n\ndata: [DONE]\n\n"
                client?.urlProtocol(self, didLoad: Data(body.utf8))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { Self.lock.withLock { Self.stopped += 1 } }
    }

    override func setUp() { Fake.reset() }

    func llm(_ hosts: [(name: String, host: String, key: String)] = [("groq", "down.test", "k"), ("gemini", "up.test", "k")],
             geminiMayReceiveNotes: Bool = true) -> AnswerLLM {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Fake.self]
        return AnswerLLM(providers: hosts.map {
            LLMProvider(name: $0.name, baseURL: URL(string: "https://\($0.host)/v1")!, model: "m", apiKey: $0.key,
                        mayReceiveNotes: $0.name != "gemini" || geminiMayReceiveNotes)
        }, session: URLSession(configuration: cfg))
    }

    func collect(_ l: AnswerLLM, notesConsent: Bool = false) async throws -> (text: String, used: Set<String>) {
        var out = "", used = Set<String>()
        for try await (p, t) in l.stream(question: "q", snippets: ["s"], styleLines: [], confidential: false, notesConsent: notesConsent) {
            out += t; used.insert(p)
        }
        return (out, used)
    }

    func testFallsThroughToNextProvider() async throws {
        let r = try await collect(llm())
        XCTAssertEqual(r.text, "L4 GPU")
        XCTAssertEqual(r.used, ["gemini"])
    }

    func testConfidentialSendsNothing() async {
        do {
            for try await _ in llm().stream(question: "q", snippets: [], styleLines: [], confidential: true) {}
            XCTFail("expected confidential error")
        } catch {
            XCTAssertEqual(error as? AnswerLLM.LLMError, .confidential)
        }
        XCTAssertEqual(Fake.count(), 0)
    }

    func testMissingPrimaryKeyGoesToGeminiWithoutRequest() async throws {
        let r = try await collect(llm([("groq", "down.test", ""), ("gemini", "up.test", "k")]))
        XCTAssertEqual(r.text, "L4 GPU")
        XCTAssertEqual(r.used, ["gemini"])
        XCTAssertEqual(Fake.count("down.test"), 0)
        XCTAssertEqual(Fake.count("up.test"), 1)
    }

    func testNoNotesConsentKeepsGeminiOut() async throws {
        let l = llm(geminiMayReceiveNotes: false)
        do {
            _ = try await collect(l)
            XCTFail("expected allFailed")
        } catch {
            XCTAssertEqual(error as? AnswerLLM.LLMError, .allFailed(["gemini: no notes consent", "groq: HTTP 503"]))
        }
        XCTAssertEqual(Fake.count("up.test"), 0)
        XCTAssertEqual(Fake.count("down.test"), 1)
        let r = try await collect(l, notesConsent: true)
        XCTAssertEqual(r.text, "L4 GPU")
        XCTAssertEqual(r.used, ["gemini"])
        XCTAssertEqual(Fake.count("up.test"), 1)
    }

    func testFailureAfterFirstTokenThrowsWithoutFallback() async {
        var out = ""
        do {
            for try await (_, t) in llm([("groq", "break.test", "k"), ("gemini", "up.test", "k")])
                .stream(question: "q", snippets: ["s"], styleLines: [], confidential: false) { out += t }
            XCTFail("expected the dropped connection to throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(out, "L4 ")
        XCTAssertEqual(Fake.count("up.test"), 0, "must not restart the answer on the next provider")
    }

    func testCancelMidStreamTearsDownWithin200ms() async throws {
        let l = llm([("groq", "hang.test", "k"), ("gemini", "up.test", "k")])
        let (firstToken, gotToken) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            for try await _ in l.stream(question: "q", snippets: ["s"], styleLines: [], confidential: false) { gotToken.yield() }
        }
        for await _ in firstToken { break }
        let t0 = ContinuousClock.now
        task.cancel()
        _ = await task.result
        XCTAssertLessThan(t0.duration(to: .now), .milliseconds(200))
        for _ in 0..<50 where Fake.stoppedCount() == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Fake.stoppedCount(), 1, "request not torn down")
        XCTAssertEqual(Fake.count(), 1, "cancel must not fall through to the next provider")
    }
    #endif
}
