// Copyright 2026 Slava Staroverov. Based on Jot (Apache 2.0).
import Foundation
import XCTest
@testable import JotCore

private final class OpenAIProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class OpenAIClientTests: XCTestCase {
    private func client() -> OpenAIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAIProtocolStub.self]
        return OpenAIClient(apiKey: { "unit-test-only" }, session: URLSession(configuration: config))
    }

    override func tearDown() {
        OpenAIProtocolStub.handler = nil
        super.tearDown()
    }

    func testMultipartTranscriptionIncludesModelAndVocabulary() async throws {
        let marker = Data([0, 127, 255, 0, 42])
        OpenAIProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-only")
            XCTAssertTrue((request.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("multipart/form-data; boundary="))
            let body = request.httpBody ?? Data()
            XCTAssertTrue(body.range(of: marker) != nil, "Must upload real audio bytes, not just filename")
            let string = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(string.contains("name=\"model\""))
            XCTAssertTrue(string.contains("gpt-transcribe"))
            XCTAssertTrue(string.contains("name=\"keywords[]\""))
            XCTAssertTrue(string.contains("Harthill"))
            XCTAssertFalse(string.contains("evil\nword"))
            return (200, Data(#"{"text":"Привет, Harthill!"}"#.utf8))
        }
        let result = try await client().transcribe(flacData: marker, model: "gpt-transcribe",
                                                   vocabulary: ["Harthill", "evil\nword"], deadline: 15)
        XCTAssertEqual(result, "Привет, Harthill!")
    }

    func testKeyValidationDoesNotSendAKeyInURL() async {
        OpenAIProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models/gpt-transcribe")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-only")
            return (200, Data(#"{"id":"gpt-transcribe"}"#.utf8))
        }
        let result = await client().validateKey()
        XCTAssertEqual(result, .valid)
    }

    func testAuthFailureIsTypedAndNotLogged() async {
        OpenAIProtocolStub.handler = { _ in
            (401, Data(#"{"error":{"message":"Invalid key"}}"#.utf8))
        }
        do {
            _ = try await client().transcribe(flacData: Data([1]), model: "gpt-transcribe", deadline: 10)
            XCTFail("Expected auth error")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .auth)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCleanupUsesResponsesAndDisablesStorage() async throws {
        OpenAIProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-only")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
            XCTAssertEqual(body["store"] as? Bool, false)
            return (200, Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"Встреча в четверг."}]}]}"#.utf8))
        }
        let result = try await client().cleanup(prompt: "Встреча в среду. Нет, в четверг.",
                                               model: "gpt-6-luna", deadline: 10)
        XCTAssertEqual(result, "Встреча в четверг.")
    }

    func testUsageLimitsMapToActionableError() async {
        OpenAIProtocolStub.handler = { _ in
            (429, Data(#"{"error":{"message":"You exceeded your current quota, please check billing."}}"#.utf8))
        }
        do {
            _ = try await client().transcribe(flacData: Data([1]), model: "gpt-transcribe", deadline: 10)
            XCTFail("Expected quota error")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .rateLimitedDaily)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
