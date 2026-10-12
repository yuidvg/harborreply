import Foundation
import XCTest
import HarborCore
@testable import HarborReply

final class MailBodyNativeDecoderTests: XCTestCase {
    private func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.list()
        values.enumerated().forEach { descriptor.insert($0.element, at: $0.offset + 1) }
        return descriptor
    }
    private func text(_ value: String) -> NSAppleEventDescriptor { .init(string: value) }
    private func integer(_ value: Int) -> NSAppleEventDescriptor { .init(int32: Int32(value)) }
    private func locator(_ id: Int) -> MailIndexLocator {
        .init(accountID: "fixture-account", mailboxPath: ["Sent"], nativeID: String(id), messageID: "\(id)@fixture.invalid",
            subject: "Fictional subject \(id)", sender: "author@fixture.invalid", messageSize: 128, role: .sent, scanID: "fixture-scan")
    }
    private func metadata(_ id: Int) -> NSAppleEventDescriptor {
        let row = locator(id)
        return list([text(row.accountID), list(row.mailboxPath.map(text)), text(row.nativeID), text(row.messageID), text(row.subject),
            text(row.sender), .init(typeCode: 0x6D736E67), .init(typeCode: 0x6D736E67), text(String(row.messageSize)),
            text(row.role.rawValue), .init(boolean: false), text(row.scanID)])
    }
    private func row(_ id: Int, headers: String? = nil) -> NSAppleEventDescriptor {
        list([metadata(id), text("Fictional body \(id)"), text(headers ?? "Message-ID: <\(id)@fixture.invalid>\r\n"), integer(0), text(""), integer(0), integer(0)])
    }
    private func metrics(_ mode: String = "bulk", count: Int = 2, contentGets: Int = 1) -> NSAppleEventDescriptor {
        list([list([text(mode), integer(count), list([1,2,3,4].map(integer)), list([22,contentGets,mode == "cache_validation" ? 0 : 1,22].map(integer))])])
    }
    private func envelope(_ rows: [NSAppleEventDescriptor], measured: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        list([text("HARBOR_MAIL_BODY_V1"), list(rows), measured ?? metrics()])
    }
    func testExactOrderedRowsAndNumericMetricsDecode() throws {
        let result = try MailBodyNativeDecoder.messages(envelope([row(1),row(2)]), expected: [locator(1),locator(2)])
        XCTAssertEqual(result.messages.compactMap(\.message).map(\.target.body), ["Fictional body 1","Fictional body 2"])
        XCTAssertEqual(result.metrics.first?.mode, .bulk); XCTAssertEqual(result.metrics.first?.contentGets, 1)
        XCTAssertEqual(result.metrics.first?.beforeMilliseconds, 1)
    }
    func testChangedOrderHeaderBindingCountAndMalformedListsFailClosed() {
        let expected = [locator(1),locator(2)]
        for value in [envelope([row(2),row(1)]), envelope([row(1)]),
                      envelope([row(1, headers: "Message-ID: <2@fixture.invalid>"),row(2)]),
                      envelope([row(1, headers: "Message-ID: <1@fixture.invalid>\nMessage-ID: <1@fixture.invalid>"),row(2)]),
                      envelope([row(1),row(2)], measured: metrics(count: 1)),
                      envelope([row(1),row(2)], measured: text("private malformed value")), text("not an envelope")] {
            XCTAssertThrowsError(try MailBodyNativeDecoder.messages(value, expected: expected))
        }
    }
    func testCacheFlagsAreStrictBooleansAndRequireZeroBodyHeaderGetters() throws {
        let valid = list([text("HARBOR_MAIL_CACHE_V1"), list([.init(boolean:true),.init(boolean:false)]),
                          metrics("cache_validation", contentGets: 0)])
        let result = try MailBodyNativeDecoder.cached(valid, count: 2)
        XCTAssertEqual(result.valid, [true,false]); XCTAssertEqual(result.metrics.first?.headersGets,0)
        for invalid in [list([text("HARBOR_MAIL_CACHE_V1"),list([integer(1),integer(0)]),metrics("cache_validation",contentGets:0)]),
                        list([text("HARBOR_MAIL_CACHE_V1"),list([.init(boolean:true),.init(boolean:false)]),metrics("cache_validation")]),
                        list([text("HARBOR_MAIL_CACHE_V1"),list([.init(boolean:true)]),metrics("cache_validation",contentGets:0)])] {
            XCTAssertThrowsError(try MailBodyNativeDecoder.cached(invalid,count:2))
        }
    }
    func testContentOnlyModesCannotBypassIndexedBodyIdentityContract() {
        for mode in ["style_candidates", "style_contents", "style_contents_fallback", "style_contents_failure"] {
            XCTAssertThrowsError(try MailBodyNativeDecoder.messages(
                envelope([row(1), row(2)], measured: metrics(mode)), expected: [locator(1), locator(2)]))
        }
    }
}
