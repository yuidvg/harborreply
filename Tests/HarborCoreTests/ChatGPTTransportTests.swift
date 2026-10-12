import Foundation
import XCTest
@testable import HarborCore

final class ChatGPTTransportTests: XCTestCase {
    func testMissingContentTypeStillRejectsTruncatedRefusedAndHTMLBodies() async throws {
        for fixture in [TruncatedProtocol.self, RefusedProtocol.self, HTMLProtocol.self] {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [fixture]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let provider = ChatGPTProvider(accessToken: "fixture.invalid", model: "fixture.invalid", session: session)
            do {
                _ = try await provider.generate(context: Data("{}".utf8), schema: Data("{}".utf8), instructions: "fixture.invalid")
                XCTFail("invalid response accepted")
            } catch { }
        }
    }
    func testCompletedSSEWithoutContentTypeIsAccepted() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MissingTypeSSEProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = ChatGPTProvider(accessToken: "fixture.invalid", model: "fixture.invalid", session: session)
        let result = try await provider.generate(context: Data("{}".utf8), schema: Data("{}".utf8), instructions: "fixture.invalid")
        let value = try JSONSerialization.jsonObject(with: result.output) as? [String: String]
        XCTAssertEqual(value?["description"], "簡潔な文体。")
    }
    func testCompletedJSONResponseIsAcceptedWhenServerDoesNotStream() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompletedJSONProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = ChatGPTProvider(accessToken: "fixture.invalid", model: "fixture.invalid", session: session)
        let result = try await provider.generate(context: Data("{}".utf8), schema: Data("{}".utf8), instructions: "fixture.invalid")
        let value = try JSONSerialization.jsonObject(with: result.output) as? [String: String]
        XCTAssertEqual(value?["description"], "簡潔な文体。")
    }
}
private final class CompletedJSONProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json; charset=utf-8"])!
        let data = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"description\":\"簡潔な文体。\"}"}]}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MissingTypeSSEProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        let event = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"description\":\"簡潔な文体。\"}"}]}]}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(("data: " + event + "\n\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private class FailedBodyProtocol: URLProtocol {
    class var payload: String { "" }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class TruncatedProtocol: FailedBodyProtocol {
    override class var payload: String { "data: {\"type\":\"response.created\"}\n\n" }
}
private final class RefusedProtocol: FailedBodyProtocol {
    override class var payload: String { "data: {\"type\":\"response.refusal.done\"}\n\n" }
}
private final class HTMLProtocol: FailedBodyProtocol {
    override class var payload: String { "<html>fixture.invalid</html>" }
}
