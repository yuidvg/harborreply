import XCTest
@testable import HarborCore

final class MailStyleDiscoveryTests: XCTestCase {
    func testAddressChoicesPreserveAliasesWithoutDeclaringPersonalAuthorship() throws {
        let identity = MailAccountIdentity(id: "fixture-account", name: "[FICTIONAL] Mail",
            addresses: ["author@fixture.invalid", "shared@fixture.invalid"])
        try MailStyleDiscovery.validate(identities: [identity])
        XCTAssertEqual(identity.addresses.count, 2)
        let row = MailHistoryItem(id: "1", windowID: "fixture-window", accountID: identity.id, mailbox: "Sent",
            messageID: "1@fixture.invalid", subject: "[FICTIONAL]", sender: "author@fixture.invalid", direction: .sent)
        XCTAssertTrue(SentStyleSelection.candidates(in: .init(account: identity, items: [row], sampledMailboxes: ["Sent"], perMailboxLimit: 1),
            personalAccountIDs: [], excluding: []).isEmpty)
    }
    func testDuplicateOversizedAndLocalAccountIdentitiesAreRejected() {
        let identity = MailAccountIdentity(id: "fixture-account", name: "[FICTIONAL]", addresses: [])
        XCTAssertThrowsError(try MailStyleDiscovery.validate(identities: [identity, identity]))
        XCTAssertThrowsError(try MailStyleDiscovery.validate(identities: (0..<33).map {
            .init(id: "fixture-\($0)", name: "[FICTIONAL]", addresses: [])
        }))
        XCTAssertThrowsError(try MailStyleDiscovery.validate(accountID: MailIndexLimits.localAccountID))
        XCTAssertThrowsError(try MailStyleDiscovery.validate(identities: [.init(id: "fixture-account", name: "[FICTIONAL]",
            addresses: (0..<33).map { "alias\($0)@fixture.invalid" })]))
    }
    func testOnlyGenuineAccountScopedSentIsAccepted() throws {
        let sent = MailIndexMailbox(accountID: "fixture-account", path: ["Archive", "Sent"], name: "Sent", messageCount: 10_003, role: .sent)
        try MailStyleDiscovery.validate(mailboxes: [sent], accountID: "fixture-account")
        XCTAssertThrowsError(try MailStyleDiscovery.validate(mailboxes: [sent], accountID: "other-fixture"))
        XCTAssertThrowsError(try MailStyleDiscovery.validate(mailboxes: [sent, sent], accountID: "fixture-account"))
        for role in [MailHistoryDirection.received, .unknown] {
            let wrong = MailIndexMailbox(accountID: "fixture-account", path: ["Sent"], name: "Sent", messageCount: 10, role: role)
            XCTAssertThrowsError(try MailStyleDiscovery.validate(mailboxes: [wrong], accountID: "fixture-account"))
        }
    }
    func testNamedSentFolderOrAddressMatchCannotBypassRoleAndPathChecks() {
        let local = MailIndexMailbox(accountID: MailIndexLimits.localAccountID, path: ["Sent"], name: "Sent", messageCount: 10, role: .sent, isLocal: true)
        XCTAssertThrowsError(try MailStyleDiscovery.validate(mailboxes: [local], accountID: "fixture-account"))
        let mismatch = MailIndexMailbox(accountID: "fixture-account", path: ["Archive", "Sent"], name: "Inbox", messageCount: 10, role: .sent)
        XCTAssertThrowsError(try MailStyleDiscovery.validate(mailboxes: [mismatch], accountID: "fixture-account"))
    }
    func testReadErrorStagesExposeOnlyFixedSafeCodes() throws {
        XCTAssertEqual(MailReadCoercion.code(for: 9162), "MAIL_CAPTURE_ACCOUNT_COERCION")
        XCTAssertEqual(MailReadCoercion.code(for: 9167), "MAIL_STYLE_SENT_COERCION")
        XCTAssertNil(MailReadCoercion.code(for: -1700))
        for number in 9160...9170 {
            let code = try XCTUnwrap(MailReadCoercion.code(for: number))
            XCTAssertNotNil(code.range(of: "^MAIL_[A-Z_]+_COERCION$", options: .regularExpression))
            XCTAssertFalse(code.contains("@"))
        }
    }
}
