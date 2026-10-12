import XCTest
@testable import HarborCore

final class MailIndexTests: XCTestCase {
    private func cursor(offset: Int = 0, count: Int? = nil, path: [String] = ["Archive", "2026"]) -> MailIndexCursor {
        .init(accountID: "fixture-account", mailboxPath: path, offset: offset, expectedCount: count, scanID: "fixture-scan")
    }
    private func locator(_ id: Int, path: [String] = ["Archive", "2026"], role: MailHistoryDirection = .unknown) -> MailIndexLocator {
        .init(accountID: "fixture-account", mailboxPath: path, nativeID: String(id), messageID: "<\(id)@fixture.invalid>",
              subject: "[FICTIONAL] subject \(id)", sender: "author@fixture.invalid", messageSize: 256, role: role, scanID: "fixture-scan")
    }
    private func page(offset: Int, count: Int, limit: Int = 128) -> MailIndexPage {
        let amount = min(limit, count - offset)
        let rows = (0..<amount).map { locator(offset + $0 + 1) }
        let next = offset + amount < count ? cursor(offset: offset + amount, count: count) : nil
        return .init(mailbox: .init(accountID: "fixture-account", path: ["Archive", "2026"], name: "2026", messageCount: count),
                     records: rows, nextCursor: next, scanID: "fixture-scan")
    }
    func testFullCatalogPagingCrossesOld768WindowWithBoundedPageMemory() throws {
        let total = 10_003
        var next = cursor(count: total); var observed = 0; var requests = 0; var peakRows = 0
        while true {
            let result = page(offset: next.offset, count: total)
            try MailIndexLimits.validate(page: result, for: next, limit: 128)
            observed += result.records.count; requests += 1; peakRows = max(peakRows, result.records.count)
            guard let following = result.nextCursor else { break }
            next = following
        }
        XCTAssertEqual(observed, total); XCTAssertEqual(requests, (total + 127) / 128); XCTAssertEqual(peakRows, 128)
    }
    func testChangedCountAndWrongCheckpointNeverAdvancePage() {
        XCTAssertThrowsError(try MailIndexLimits.validate(page: page(offset: 128, count: 301), for: cursor(offset: 128, count: 300), limit: 128)) {
            XCTAssertEqual($0 as? MailIndexError, .cursorInvalidated)
        }
        let original = page(offset: 0, count: 300)
        let wrong = MailIndexPage(mailbox: original.mailbox, records: original.records, nextCursor: cursor(offset: 129, count: 300), scanID: "fixture-scan")
        XCTAssertThrowsError(try MailIndexLimits.validate(page: wrong, for: cursor(count: 300), limit: 128))
        let earlyDone = MailIndexPage(mailbox: original.mailbox, records: original.records, nextCursor: nil, scanID: "fixture-scan")
        XCTAssertThrowsError(try MailIndexLimits.validate(page: earlyDone, for: cursor(count: 300), limit: 128))
    }
    func testDuplicateIDsForgedRolesAndOtherSameNamedFolderAreRejected() {
        let original = page(offset: 0, count: 2)
        for rows in [[locator(1), locator(1)], [locator(1), locator(2, role: .sent)], [locator(1), locator(2, path: ["Another archive", "2026"])]] {
            let wrong = MailIndexPage(mailbox: original.mailbox, records: rows, nextCursor: nil, scanID: "fixture-scan")
            XCTAssertThrowsError(try MailIndexLimits.validate(page: wrong, for: cursor(count: 2), limit: 128))
        }
    }
    func testCursorRoundTripResumesNestedDFSAndLegacyWorkerCursor() throws {
        let discovery = MailMailboxCursor(scanID: "fixture-scan", accountOffset: 2, expectedAccountCount: 4, stack: [
            .init(accountID: "fixture-account", nextChild: 3, expectedChildCount: 9),
            .init(accountID: "fixture-account", parentPath: ["Archive"], nextChild: 7, expectedChildCount: 15)
        ])
        XCTAssertEqual(try JSONDecoder().decode(MailMailboxCursor.self, from: JSONEncoder().encode(discovery)), discovery)
        let legacy = Data(#"{"accountID":"fixture-account","mailboxPath":["Archive","2026"],"offset":128,"expectedCount":300,"scanID":"fixture-scan"}"#.utf8)
        let decoded = try JSONDecoder().decode(MailIndexCursor.self, from: legacy)
        XCTAssertFalse(decoded.isLocal); XCTAssertNil(decoded.role)
        try MailIndexLimits.validate(cursor: decoded, limit: 128)
    }
    func testLiteralNamesLocalNamespaceAndNativeIDsAreValidatedWithoutPathInterpretation() throws {
        // Slash, quotes and AppleScript-like text remain one literal Mail name.
        let literal = locator(1, path: ["Archive/2026", "\" & send message --"])
        XCTAssertNoThrow(try MailIndexLimits.validate(locator: literal))
        XCTAssertThrowsError(try MailIndexLimits.validate(path: ["Fixture"], accountID: MailIndexLimits.localAccountID, isLocal: false))
        XCTAssertNoThrow(try MailIndexLimits.validate(path: ["Fixture"], accountID: MailIndexLimits.localAccountID, isLocal: true))
        let injected = MailIndexLocator(accountID: "fixture-account", mailboxPath: ["Fixture"], nativeID: "1;send", messageID: "", subject: "[FICTIONAL]", sender: "author@fixture.invalid", scanID: "fixture-scan")
        XCTAssertThrowsError(try MailIndexLimits.validate(locator: injected))
        XCTAssertThrowsError(try MailIndexLimits.validate(cursor: cursor(), limit: 129))
    }
    func testIndividualReadFailuresAreSeparateFromSuccessfulMessages() throws {
        let row = locator(1)
        let failure = MailIndexReadResult(locator: row, failure: .tooLarge)
        XCTAssertNil(failure.message); XCTAssertEqual(failure.failure, .tooLarge)
        XCTAssertEqual(try JSONDecoder().decode(MailIndexReadResult.self, from: JSONEncoder().encode(failure)), failure)
    }
}
