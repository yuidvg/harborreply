import XCTest
@testable import HarborCore

final class ProviderTests: XCTestCase {
    func testDisabledAndUnsafeEndpoint() throws {
        XCTAssertThrowsError(try ProviderConfiguration(enabled: false, endpoint: "https://api.fixture.invalid/v1/responses", model: "configured").checkedURL())
        for url in ["http://api.fixture.invalid", "https://user:secret@api.fixture.invalid", "https://api.fixture.invalid/?key=secret", "https://api.fixture.invalid/#x", "not-a-url"] {
            XCTAssertThrowsError(try ProviderConfiguration(enabled: true, endpoint: url, model: "configured").checkedURL())
        }
        XCTAssertEqual(try ProviderConfiguration(enabled: true, endpoint: "https://api.fixture.invalid/v1/responses", model: "configured").checkedURL().host, "api.fixture.invalid")
    }
    func testCompletedInvalidRefusedAndTruncated() throws {
        let valid = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"reply_body\":\"fictional\"}"}]}]}"#.utf8)
        XCTAssertEqual(String(decoding: try ResponsesProvider.parseResponse(valid), as: UTF8.self), #"{"reply_body":"fictional"}"#)
        for data in [#"{"status":"incomplete","output":[]}"#, #"{"status":"completed","output":[{"content":[{"type":"refusal"}]}]}"#, #"{"status":"completed","output":[{"content":[{"type":"output_text","text":"broken json"}]}]}"#, "broken"] {
            XCTAssertThrowsError(try ResponsesProvider.parseResponse(Data(data.utf8)))
        }
    }
    func testNoRedirectEvenSameHost() {
        let delegate = NoRedirectDelegate()
        let url = URL(string: "https://api.fixture.invalid")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var called = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { redirected in called = true; XCTAssertNil(redirected) }
        XCTAssertTrue(called); session.invalidateAndCancel()
    }
    func testLateAsyncCompletionCannotInsert() async throws {
        var session = ReplySession()
        let target = MailTarget(id: "test", account: "fictional", messageID: "a@fixture.invalid", subject: "Test", sender: "a@fixture.invalid", body: "")
        let draft = DraftSnapshot(id: "draft", fields: ["original"])
        session.capture(target); session.track(draft); session.transition(.generating)
        let id = session.requestID; let rev = session.revision
        let late = Task { try? await Task.sleep(nanoseconds: 10_000_000); return "late reply" }
        session.cancel(); _ = await late.value; session.transition(.ready)
        XCTAssertFalse(session.insertionPermit(id: id, revision: rev, target: target, draft: draft))
    }
}
