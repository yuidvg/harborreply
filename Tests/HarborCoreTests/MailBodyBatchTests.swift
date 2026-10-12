import XCTest
@testable import HarborCore

final class MailBodyBatchTests: XCTestCase {
    private func row(_ id: Int, account: String = "fixture-account", size: Int = 42) -> MailIndexLocator {
        .init(accountID: account, mailboxPath: ["Sent"], nativeID: String(id), messageID: "\(id)@fixture.invalid",
            subject: "Fictional subject", sender: "author@fixture.invalid", messageSize: size, role: .sent, scanID: "fixture-scan")
    }
    func testOnlyBoundedContiguousCapturedPositionsMayUseBulk() throws {
        XCTAssertNoThrow(try MailBodyBatch(locators: [row(42), row(9)], firstIndex: 129, expectedMailboxCount: 256).validate())
        XCTAssertNoThrow(try MailBodyBatch(locators: [row(42)]).validate()) // Native IDs do not establish collection positions.
        for batch in [MailBodyBatch(locators: []), MailBodyBatch(locators: (1...5).map { row($0) }),
                      MailBodyBatch(locators: [row(1)], firstIndex: 1),
                      MailBodyBatch(locators: [row(1)], firstIndex: 0, expectedMailboxCount: 10),
                      MailBodyBatch(locators: [row(1), row(2)], firstIndex: 10, expectedMailboxCount: 10),
                      MailBodyBatch(locators: [row(1)], firstIndex: 1, expectedMailboxCount: Int.max)] {
            XCTAssertThrowsError(try batch.validate())
        }
    }
    func testMixedMailboxDuplicateIdentityAndAggregateBytesAreRejected() {
        for batch in [MailBodyBatch(locators: [row(1), row(1)]),
                      MailBodyBatch(locators: [row(1), row(2, account: "different-account")]),
                      MailBodyBatch(locators: [row(1, size: 1_048_577), row(2, size: 1_048_576)]),
                      MailBodyBatch(locators: [row(1, size: Int.max)])] {
            XCTAssertThrowsError(try batch.validate())
        }
    }
}
