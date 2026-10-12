import XCTest
@testable import HarborReply
@testable import HarborCore

final class StyleTextAnalysisTests: XCTestCase {
    func testMalformedModelJSONHasAStyleResponseError() async {
        do {
            _ = try await StyleTextAnalysis.analyze("fixture.invalid", provider: InvalidStyleProvider())
            XCTFail("invalid JSON accepted")
        } catch {
            XCTAssertEqual((error as? AppFailure)?.baseCode, "STYLE_EXTRACTION_INVALID_RESPONSE")
        }
    }
    func testOneModelRequestReceivesExactlyTheConcatenatedText() async throws {
        let provider = RecordingStyleProvider()
        let input = "quoted fixture.invalid\n\nquoted fixture.invalid"
        let result = try await StyleTextAnalysis.analyze(input, provider: provider)
        XCTAssertEqual(result, "簡潔な文体。")
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
        let context = try JSONSerialization.jsonObject(with: calls[0]) as? [String: String]
        XCTAssertEqual(context?["sent_mail_text"], input)
    }
}
private actor RecordingStyleProvider: LLMProvider {
    var calls: [Data] = []
    func generate(context: Data, schema: Data, instructions: String) async throws -> GenerationResult {
        calls.append(context)
        return .init(output: Data("{\"description\":\"簡潔な文体。\"}".utf8), elapsed: 0, inputTokens: nil, outputTokens: nil)
    }
}

private struct InvalidStyleProvider: LLMProvider {
    func generate(context: Data, schema: Data, instructions: String) async throws -> GenerationResult {
        .init(output: Data("not JSON fixture.invalid".utf8), elapsed: 0, inputTokens: nil, outputTokens: nil)
    }
}
