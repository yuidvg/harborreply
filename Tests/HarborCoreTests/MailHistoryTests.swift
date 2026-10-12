import XCTest
@testable import HarborCore

final class MailHistoryTests: XCTestCase {
    private let account = MailAccountIdentity(id: "fixture-account", name: "Fictional account", addresses: ["author@example.invalid"])

    private func row(id: String = "101", window: String = "fixture-window", accountID: String = "fixture-account",
                     size: Int = 128, direction: MailHistoryDirection = .unknown) -> MailHistoryItem {
        .init(id: id, windowID: window, accountID: accountID, mailbox: "Fixture mailbox",
              messageID: "<\(id)@example.invalid>", subject: "架空の日程確認", sender: "author@example.invalid",
              direction: direction, messageSize: size)
    }
    private func window(_ rows: [MailHistoryItem]) -> MailHistoryWindow {
        .init(account: account, items: rows, sampledMailboxes: ["Fixture mailbox"], perMailboxLimit: 256)
    }
    private func target(_ row: MailHistoryItem, body: String = "架空の本文", headers: String = "") -> MailTarget {
        .init(id: row.id, account: row.accountID + ":" + row.mailbox, messageID: row.messageID,
              subject: row.subject, sender: row.sender, body: body, headers: headers)
    }

    func testMetadataDoesNotPromiseCompleteChronologicalCoverageOrInferSentFromSender() throws {
        let r = row()
        let sample = window([r])
        XCTAssertTrue(sample.isPartial)
        XCTAssertFalse(sample.orderingGuaranteed)
        XCTAssertEqual(r.direction, .unknown)
        XCTAssertEqual(r.sender, sample.account.addresses.first)
        XCTAssertNoThrow(try MailHistoryLimits.validate(records: [r], in: sample))
    }

    func testMailboxLimitMustBeExplicitAndBounded() {
        XCTAssertNoThrow(try MailHistoryLimits.validate(limit: 1))
        XCTAssertNoThrow(try MailHistoryLimits.validate(limit: 256))
        for limit in [0, -1, 257, Int.max] {
            XCTAssertThrowsError(try MailHistoryLimits.validate(limit: limit)) { XCTAssertEqual($0 as? MailHistoryError, .limitExceeded) }
        }
    }

    func testHydrationCannotSubstituteRowWindowOrAccount() {
        let original = row()
        let sample = window([original])
        XCTAssertThrowsError(try MailHistoryLimits.validate(records: [row(window: "older-window")], in: sample)) {
            XCTAssertEqual($0 as? MailHistoryError, .staleWindow)
        }
        XCTAssertThrowsError(try MailHistoryLimits.validate(records: [row(accountID: "another-account")], in: sample)) {
            XCTAssertEqual($0 as? MailHistoryError, .invalidMetadata)
        }
        XCTAssertThrowsError(try MailHistoryLimits.validate(records: [row(direction: .sent)], in: sample)) {
            XCTAssertEqual($0 as? MailHistoryError, .staleWindow)
        }
    }

    func testHydrationBoundsRejectDuplicatesLargeMessageAndTwentyFirstBody() {
        let rows = (1...21).map { row(id: String($0)) }
        let sample = window(rows)
        XCTAssertNoThrow(try MailHistoryLimits.validate(records: Array(rows.prefix(20)), in: sample))
        XCTAssertThrowsError(try MailHistoryLimits.validate(records: rows, in: sample)) {
            XCTAssertEqual($0 as? MailHistoryError, .limitExceeded)
        }
        XCTAssertThrowsError(try MailHistoryLimits.validate(records: [rows[0], rows[0]], in: sample)) {
            XCTAssertEqual($0 as? MailHistoryError, .invalidMetadata)
        }
        let huge = row(size: MailHistoryLimits.messageBytes + 1)
        XCTAssertThrowsError(try MailHistoryLimits.validate(records: [huge], in: window([huge]))) {
            XCTAssertEqual($0 as? MailHistoryError, .messageTooLarge)
        }
    }

    func testContentBoundUsesCombinedUTF8BytesAndRejectsChangedIdentity() {
        let r = row()
        let body = String(repeating: "あ", count: MailHistoryLimits.messageBytes / 3)
        XCTAssertNoThrow(try MailHistoryLimits.validate(content: target(r, body: body), for: r))
        XCTAssertThrowsError(try MailHistoryLimits.validate(content: target(r, body: body, headers: "From: author@example.invalid"), for: r)) {
            XCTAssertEqual($0 as? MailHistoryError, .messageTooLarge)
        }
        XCTAssertThrowsError(try MailHistoryLimits.validate(content: target(row(id: "102")), for: r)) {
            XCTAssertEqual($0 as? MailHistoryError, .changedMessage)
        }
    }

    func testHydratedAttachmentCountPreservesSourceScopeAndDirection() throws {
        let metadata = row(direction: .sent)
        let hydrated = MailHistoryMessage(item: metadata.withAttachmentCount(2), target: target(metadata))
        XCTAssertEqual(metadata.attachmentCount, 0) // Not queried by metadata acquisition.
        XCTAssertEqual(hydrated.item.attachmentCount, 2)
        XCTAssertEqual(hydrated.item.accountID, metadata.accountID)
        XCTAssertEqual(hydrated.item.direction, .sent)
        XCTAssertNoThrow(try MailHistoryLimits.validate(content: hydrated.target, for: hydrated.item))
        let encoded = try JSONEncoder().encode(hydrated)
        XCTAssertEqual(try JSONDecoder().decode(MailHistoryMessage.self, from: encoded), hydrated)
    }
}
