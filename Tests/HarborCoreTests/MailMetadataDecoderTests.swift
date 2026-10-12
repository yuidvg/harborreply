import Foundation
import XCTest
@testable import HarborCore

/// Native descriptor fixtures exercise the parser without sending any events.
final class MailMetadataDecoderTests: XCTestCase {
    private let scan = "fixture-scan"
    private let account = "fixture-account"
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func list(_ children: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let value = NSAppleEventDescriptor.list()
        children.enumerated().forEach { value.insert($0.element, at: $0.offset + 1) }
        return value
    }
    private func text(_ value: String) -> NSAppleEventDescriptor { .init(string: value) }
    private var missing: NSAppleEventDescriptor { .init(typeCode: 0x6D736E67) }
    private func path(_ names: [String] = ["Sent"]) -> NSAppleEventDescriptor { list(names.map(text)) }
    private func identity() -> NSAppleEventDescriptor { list([text(account), text("Fixture account"), list([text("author@fixture.invalid")])]) }
    private func mailbox(count: Int = 1, local: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        list([text(account), path(), text("Sent"), text(String(count)), text("sent"), local ?? .init(boolean: false)])
    }
    private func locator(id: String = "42", subject: NSAppleEventDescriptor? = nil,
                         sent: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        list([text(account), path(), text(id), text("<42@fixture.invalid>"), subject ?? text("[FICTIONAL] subject"),
              text("author@fixture.invalid"), sent ?? .init(date: date), missing, text("256"), text("sent"), .init(boolean: false), text(scan)])
    }
    private func historyRow(id: String = "42", role: String = "sent") -> NSAppleEventDescriptor {
        list([text(id), text(account), text("Sent"), text("<42@fixture.invalid>"), text("[FICTIONAL] subject"),
              text("author@fixture.invalid"), text(role), .init(date: date), missing, text("256"), .init(int32: 0)])
    }
    private var cursor: MailIndexCursor { .init(accountID: account, mailboxPath: ["Sent"], scanID: scan, role: .sent) }

    func testLocalAppleScriptMetadataDescriptorUsesTheSameStrictWireContract() throws {
        // This script returns static test data. It has no application target and
        // sends no Apple events to Mail or any other process.
        let source = #"""
        set box to {"fixture-account", {"Sent"}, "Sent", "1", "sent", false}
        set row to {"fixture-account", {"Sent"}, "42", "<42@fixture.invalid>", "[FICTIONAL] subject", "author@fixture.invalid", missing value, missing value, "256", "sent", false, "fixture-scan"}
        return {box, {row}, {}, "fixture-scan"}
        """#
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        let response = script.executeAndReturnError(&error)
        XCTAssertNil(error)
        let page = try MailMetadataDecoder.indexPage(response, for: cursor, limit: 128)
        XCTAssertEqual(page.records.first?.nativeID, "42"); XCTAssertFalse(page.mailbox.isLocal)
        XCTAssertNil(page.records.first?.dateSent); XCTAssertNil(page.records.first?.dateReceived)
    }

    func testNativeDatesMissingValuesAndBooleanEncodingsDecodeWithoutCoercingLists() throws {
        let row = try MailMetadataDecoder.locator(locator())
        XCTAssertEqual(row.dateSent, date); XCTAssertNil(row.dateReceived); XCTAssertEqual(row.nativeID, "42")
        XCTAssertEqual(row.sender, "author@fixture.invalid"); XCTAssertEqual(row.role, .sent)
        for boolean in [NSAppleEventDescriptor(boolean: false), NSAppleEventDescriptor(descriptorType: 0x66616C73, data: Data())] {
            XCTAssertFalse(try MailMetadataDecoder.mailbox(mailbox(local: boolean)).isLocal)
        }
        XCTAssertThrowsError(try MailMetadataDecoder.mailbox(mailbox(local: .init(int32: 0))))
        XCTAssertThrowsError(try MailMetadataDecoder.locator(locator(subject: list([text("[FICTIONAL]")]))))
        XCTAssertThrowsError(try MailMetadataDecoder.locator(locator(sent: list([]))))
    }

    func testPageChecksExpectedScanMailboxRoleCountAndNativeIdentity() throws {
        let valid = list([mailbox(), list([locator()]), list([]), text(scan)])
        let page = try MailMetadataDecoder.indexPage(valid, for: cursor, limit: 128)
        XCTAssertEqual(page.records.count, 1); XCTAssertNil(page.nextCursor)
        for invalid in [list([mailbox(), list([locator()]), list([]), text("different-scan")]),
                        list([mailbox(count: 2), list([locator(), locator()]), list([]), text(scan)]),
                        list([mailbox(), list([locator(id: "0")]), list([]), text(scan)])] {
            XCTAssertThrowsError(try MailMetadataDecoder.indexPage(invalid, for: cursor, limit: 128))
        }
        let changedCount = MailIndexCursor(accountID: account, mailboxPath: ["Sent"], expectedCount: 2, scanID: scan)
        XCTAssertThrowsError(try MailMetadataDecoder.indexPage(valid, for: changedCount, limit: 128)) {
            XCTAssertEqual($0 as? MailIndexError, .cursorInvalidated)
        }
    }

    func testMalformedAndOversizedPageListsCannotReturnAPartialSuccess() {
        let tooMany = list([mailbox(count: 129), list((0..<129).map { locator(id: String($0 + 1)) }), list([]), text(scan)])
        XCTAssertThrowsError(try MailMetadataDecoder.indexPage(tooMany, for: cursor, limit: 128))
        for invalid in [text(""), list([]), list([mailbox(), text("not a list"), list([]), text(scan)])] {
            XCTAssertThrowsError(try MailMetadataDecoder.indexPage(invalid, for: cursor, limit: 128))
        }
        XCTAssertThrowsError(try MailMetadataDecoder.locator(locator(subject: text(String(repeating: "a", count: 16_385)))))
    }

    func testDiscoveryCursorRejectsWrongPrimitiveTypesAndCrossScanResume() throws {
        let frame = list([text(account), path([]), .init(int32: 0), .init(int32: 1), .init(boolean: false)])
        let next = list([text(scan), .init(int32: 1), .init(int32: 1), .init(boolean: false), list([frame])])
        let request = MailMailboxCursor(scanID: scan)
        let result = list([text(scan), list([mailbox()]), list([identity()]), next])
        let decoded = try MailMetadataDecoder.discoveryPage(result, for: request, limit: 32)
        XCTAssertEqual(decoded.nextCursor?.stack.first?.nextChild, 0)
        XCTAssertEqual(decoded.accounts.first?.addresses, ["author@fixture.invalid"])
        let wrongPrimitive = list([text(scan), text("1"), .init(int32: 1), .init(boolean: false), list([frame])])
        XCTAssertThrowsError(try MailMetadataDecoder.discoveryCursor(wrongPrimitive))
        XCTAssertThrowsError(try MailMetadataDecoder.discoveryCursor(.init(int32: 0)))
        let otherScan = list([text("other"), .init(int32: 1), .init(int32: 1), .init(boolean: false), list([frame])])
        XCTAssertThrowsError(try MailMetadataDecoder.discoveryPage(list([text(scan), list([]), list([]), otherScan]), for: request, limit: 32))
    }

    func testHistoryDedupKeepsGenuineSentRoleAndTheMatchingNativeReferencePosition() throws {
        let response = list([identity(), list([historyRow(role: "unknown"), historyRow(role: "sent"), historyRow(role: "unknown")]),
                             list([text("Sent"), text("Sent")]), text(scan)])
        let decoded = try MailMetadataDecoder.historyWindow(response, windowID: scan, limit: 256, capturedAt: date)
        XCTAssertEqual(decoded.window.items.count, 1); XCTAssertEqual(decoded.window.items.first?.direction, .sent)
        XCTAssertEqual(decoded.sourceIndices["42"], 1); XCTAssertEqual(decoded.window.sampledMailboxes, ["Sent"])
        XCTAssertEqual(decoded.window.capturedAt, date)
        XCTAssertThrowsError(try MailMetadataDecoder.historyWindow(response, windowID: "other", limit: 256, capturedAt: date)) {
            XCTAssertEqual($0 as? MailHistoryError, .invalidMetadata)
        }
    }

    func testHydrationPreservesMetadataIdentityAndCombinedBodyBudget() throws {
        let expected = try MailMetadataDecoder.historyItem(historyRow(), windowID: scan)
        let valid = list([historyRow(), text("[FICTIONAL] body"), text("From: author@fixture.invalid"), .init(int32: 1)])
        let message = try MailMetadataDecoder.hydratedMessage(valid, expected: expected)
        XCTAssertEqual(message.item.attachmentCount, 1); XCTAssertEqual(message.target.body, "[FICTIONAL] body")
        XCTAssertThrowsError(try MailMetadataDecoder.hydratedMessage(list([historyRow(id: "43"), text(""), text(""), .init(int32: 0)]), expected: expected)) {
            XCTAssertEqual($0 as? MailHistoryError, .changedMessage)
        }
        let tooLarge = list([historyRow(), text(String(repeating: "a", count: MailHistoryLimits.messageBytes)), text("x"), .init(int32: 0)])
        XCTAssertThrowsError(try MailMetadataDecoder.hydratedMessage(tooLarge, expected: expected)) {
            XCTAssertEqual($0 as? MailHistoryError, .messageTooLarge)
        }
    }

    func testIndexedFailureRetainsOperationGetterAndOriginalNativeNumber() throws {
        let expected = try MailMetadataDecoder.locator(locator())
        let failure = list([list([locator(), text(""), text(""), .init(int32: 0), text(MailIndexFailure.bodyCoercion.rawValue),
                                 .init(int32: -1708), .init(int32: 9184)])])
        let result = try MailMetadataDecoder.indexedMessage(failure, expected: expected)
        XCTAssertNil(result.message); XCTAssertEqual(result.failure, .bodyCoercion)
        XCTAssertEqual(result.mailContext?.operation, .indexHydrate); XCTAssertEqual(result.mailContext?.nativeCode, -1708)
        XCTAssertEqual(result.mailContext?.stage, .accountEnabled)
        let malformed = list([list([locator(), text(""), text(""), .init(int32: 0), text(MailIndexFailure.bodyCoercion.rawValue), text("-1708"), .init(int32: 9184)])])
        XCTAssertThrowsError(try MailMetadataDecoder.indexedMessage(malformed, expected: expected))
    }

    func testIndexedChangedAndOversizedContentReturnIndividualFailures() throws {
        let expected = try MailMetadataDecoder.locator(locator())
        let changed = list([list([locator(id: "43"), text(""), text(""), .init(int32: 0), text(""), .init(int32: 0), .init(int32: 0)])])
        XCTAssertEqual(try MailMetadataDecoder.indexedMessage(changed, expected: expected).failure, .changed)
        let oversized = list([list([locator(), text(String(repeating: "a", count: MailHistoryLimits.messageBytes + 1)), text(""),
                                   .init(int32: 0), text(""), .init(int32: 0), .init(int32: 0)])])
        XCTAssertEqual(try MailMetadataDecoder.indexedMessage(oversized, expected: expected).failure, .tooLarge)
    }
}
