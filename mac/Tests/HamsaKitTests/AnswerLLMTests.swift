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
    final class Fake: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let down = request.url!.host == "down.test"
            let resp = HTTPURLResponse(url: request.url!, statusCode: down ? 503 : 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if !down {
                let body = "data: {\"choices\":[{\"delta\":{\"content\":\"L4 \"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"GPU\"}}]}\n\ndata: [DONE]\n\n"
                client?.urlProtocol(self, didLoad: Data(body.utf8))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func llm() -> AnswerLLM {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Fake.self]
        return AnswerLLM(providers: [
            LLMProvider(name: "groq", baseURL: URL(string: "https://down.test/v1")!, model: "m", apiKey: "k"),
            LLMProvider(name: "gemini", baseURL: URL(string: "https://up.test/v1")!, model: "m", apiKey: "k"),
        ], session: URLSession(configuration: cfg))
    }

    func testFallsThroughToNextProvider() async throws {
        var out = "", used = Set<String>()
        for try await (p, t) in llm().stream(question: "q", snippets: ["s"], styleLines: [], confidential: false) {
            out += t; used.insert(p)
        }
        XCTAssertEqual(out, "L4 GPU")
        XCTAssertEqual(used, ["gemini"])
    }

    func testConfidentialSendsNothing() async {
        do {
            for try await _ in llm().stream(question: "q", snippets: [], styleLines: [], confidential: true) {}
            XCTFail("expected confidential error")
        } catch {
            XCTAssertEqual(error as? AnswerLLM.LLMError, .confidential)
        }
    }
    #endif
}
