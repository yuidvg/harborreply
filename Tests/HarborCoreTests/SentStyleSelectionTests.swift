import XCTest
@testable import HarborCore

final class SentStyleSelectionTests: XCTestCase {
    private func item(_ id: String, sender: String = "Author <author@fixture.invalid>", direction: MailHistoryDirection = .sent, account: String = "personal", date: Double = 1, size: Int = 100) -> MailHistoryItem {
        MailHistoryItem(id: id, windowID: "fixture-window", accountID: account, mailbox: "Sent", messageID: "\(id)@fixture.invalid", subject: "[FICTIONAL] \(id)", sender: sender, direction: direction, dateSent: Date(timeIntervalSince1970: date), messageSize: size)
    }
    private func window(_ items: [MailHistoryItem]) -> MailHistoryWindow {
        MailHistoryWindow(account: MailAccountIdentity(id: "personal", name: "架空本人", addresses: ["author@fixture.invalid", "team@fixture.invalid"]), items: items, sampledMailboxes: ["Sent"], perMailboxLimit: 256)
    }
    func testMatchingFromWithoutPersonalAccountDeclarationIsNotAuthorship() {
        XCTAssertTrue(SentStyleSelection.candidates(in: window([item("one")]), personalAccountIDs: [], excluding: []).isEmpty)
    }
    func testRequiresActualSentAccountAndOwnAddressExcludingSharedAddress() {
        let rows = [item("own"), item("received", direction: .received), item("unknown", direction: .unknown), item("other-account", account: "other"), item("someone", sender: "someone@fixture.invalid"), item("shared", sender: "team@fixture.invalid"), item("oversize", size: 2_097_153)]
        XCTAssertEqual(SentStyleSelection.candidates(in: window(rows), personalAccountIDs: ["personal"], excluding: ["team@fixture.invalid"]).map(\.id), ["own"])
    }
    func testSelectsThreeNewestDistinctEligibleMessagesFromBoundedWindow() {
        let rows = [item("old", date: 1), item("new", date: 5), item("new", date: 5), item("middle", date: 3), item("next", date: 4)]
        XCTAssertEqual(SentStyleSelection.candidates(in: window(rows), personalAccountIDs: ["personal"], excluding: []).map(\.id), ["new", "next", "middle"])
    }
    func testSenderParsingDoesNotAcceptMultipleAddressesOrHeaderInjection() {
        XCTAssertEqual(SentStyleSelection.address("Author <AUTHOR@fixture.invalid>"), "author@fixture.invalid")
        XCTAssertNil(SentStyleSelection.address("author@fixture.invalid, other@fixture.invalid"))
        XCTAssertNil(SentStyleSelection.address("author@fixture.invalid\nBcc: other@fixture.invalid"))
        XCTAssertNil(SentStyleSelection.address("<a@fixture.invalid> <b@fixture.invalid>"))
        XCTAssertNil(SentStyleSelection.address("a@fixture.invalid, Author <b@fixture.invalid>"))
    }
}
