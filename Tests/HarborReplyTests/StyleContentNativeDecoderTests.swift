import Foundation
import XCTest
import HarborCore
@testable import HarborReply

final class StyleContentNativeDecoderTests: XCTestCase {
    private var cursor: MailIndexCursor {
        .init(accountID: "fixture-account", mailboxPath: ["Sent"], expectedCount: 128, scanID: "fixture-scan", role: .sent)
    }
    private func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.list()
        values.enumerated().forEach { descriptor.insert($0.element, at: $0.offset + 1) }
        return descriptor
    }
    private func text(_ value: String) -> NSAppleEventDescriptor { .init(string: value) }
    private func int(_ value: Int) -> NSAppleEventDescriptor { .init(int32: Int32(value)) }
    private func metrics(_ mode: String, count: Int, contentGets: Int = 0, extraHeaders: Int = 0) -> NSAppleEventDescriptor {
        list([text(mode), int(count), list([2, 3, 0, 0].map(int)), list([0, contentGets, extraHeaders, 0].map(int))])
    }
    private func candidate(_ position: Int) -> StyleCandidate {
        .init(position: position, sender: "author@fixture.invalid", messageSize: 42)
    }
    private func candidateRow(_ position: Int) -> NSAppleEventDescriptor {
        list([int(position), text("author@fixture.invalid"), int(42)])
    }
    private func bodyRow(_ position: Int, body: String = "Fictional body", code: Int = 0) -> NSAppleEventDescriptor {
        list([int(position), text(body), int(code)])
    }
    private func contents(_ rows: [NSAppleEventDescriptor], measured: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        list([text("HARBOR_STYLE_CONTENTS_V1"), list(rows), measured ?? metrics("style_contents", count: rows.count, contentGets: 1)])
    }
    func testOnlySenderSizePositionsDecodeAndNextCursorFollowsFreshCount() throws {
        let descriptor = list([text("HARBOR_STYLE_CANDIDATES_V1"), int(4), list([candidateRow(1), candidateRow(2)]), metrics("style_candidates", count: 2)])
        let result = try StyleContentNativeDecoder.candidates(descriptor, cursor: cursor, limit: 2)
        XCTAssertEqual(result.page.records, [candidate(1), candidate(2)])
        XCTAssertEqual(result.page.nextCursor?.offset, 2)
        XCTAssertEqual(result.page.nextCursor?.expectedCount, 4)
        XCTAssertEqual(result.metrics.first?.mode, .styleCandidates)
        XCTAssertEqual(result.metrics.first?.headersGets, 0)
    }
    func testMalformedCandidateColumnsAndUnexpectedPositionFailWithoutMailCalls() {
        for rows in [[candidateRow(2), candidateRow(1)], [candidateRow(1)],
                     [list([int(1), list([text("private fixture malformed")]), int(42)]), candidateRow(2)]] {
            let descriptor = list([text("HARBOR_STYLE_CANDIDATES_V1"), int(2), list(rows), metrics("style_candidates", count: 2)])
            XCTAssertThrowsError(try StyleContentNativeDecoder.candidates(descriptor, cursor: cursor, limit: 2))
        }
    }
    func testContentsRetainUnavailablePositionAndHealthySibling() throws {
        let batch = StyleContentBatch(cursor: cursor, candidates: [candidate(1), candidate(2)])
        let result = try StyleContentNativeDecoder.contents(contents([bodyRow(1), bodyRow(2, body: "", code: -1712)],
            measured: metrics("style_contents_fallback", count: 2, contentGets: 2)), batch: batch)
        XCTAssertEqual(result.reads[0].body, "Fictional body")
        XCTAssertNil(result.reads[1].body)
        XCTAssertEqual(result.reads[1].nativeCode, -1712)
        XCTAssertEqual(result.metrics.first?.contentGets, 2)
    }
    func testUnexpectedPermissionCodeWrongOrderSizeAndHeaderRequestsAreRejected() {
        let batch = StyleContentBatch(cursor: cursor, candidates: [candidate(1), candidate(2)])
        for descriptor in [contents([bodyRow(2), bodyRow(1)]), contents([bodyRow(1)]),
            contents([bodyRow(1), bodyRow(2, body: "", code: -1743)]),
            contents([bodyRow(1), bodyRow(2, body: "private malformed", code: -1712)]),
            contents([bodyRow(1, body: String(repeating: "a", count: 250_001)), bodyRow(2)]),
            contents([bodyRow(1), bodyRow(2)], measured: metrics("style_contents", count: 2, contentGets: 1, extraHeaders: 1))] {
            XCTAssertThrowsError(try StyleContentNativeDecoder.contents(descriptor, batch: batch))
        }
    }
    func testFailedBulkMetricsPreserveOriginalNumericStageWithoutPrivateText() throws {
        let descriptor = list([text("HARBOR_STYLE_CONTENT_FAILURE_V1"),
            list([text("HARBOR_MAIL_FAILURE_V1"), int(-1712), int(9164)]), metrics("style_contents_failure", count: 4, contentGets: 1)])
        let (context, measured) = try StyleContentNativeDecoder.failure(descriptor)
        XCTAssertEqual(context.operation, .styleContents)
        XCTAssertEqual(context.stage, .body)
        XCTAssertEqual(context.nativeCode, -1712)
        XCTAssertFalse(context.isShapeFailure)
        XCTAssertEqual(measured.first?.mode, .styleContentsFailure)
        XCTAssertEqual(measured.first?.contentGets, 1)
        XCTAssertEqual(measured.first?.contentMilliseconds, 3)
    }
}
