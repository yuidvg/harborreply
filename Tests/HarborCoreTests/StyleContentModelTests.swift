import XCTest
@testable import HarborCore

final class StyleContentModelTests: XCTestCase {
    private var cursor: MailIndexCursor {
        .init(accountID: "fixture-account", mailboxPath: ["Sent"], expectedCount: 128, scanID: "fixture-scan", role: .sent)
    }
    private func candidate(_ position: Int, size: Int = 42) -> StyleCandidate {
        .init(position: position, sender: "author@fixture.invalid", messageSize: size)
    }
    func testPositionSamplesAreImmutableCodableValuesWithoutMessageIdentities() throws {
        let batch = StyleContentBatch(cursor: cursor, candidates: [candidate(1), candidate(3)])
        try batch.validate()
        let data = try JSONEncoder().encode(batch)
        XCTAssertEqual(try JSONDecoder().decode(StyleContentBatch.self, from: data), batch)
        let text = String(decoding: data, as: UTF8.self)
        for identity in ["nativeID", "messageID", "subject", "dateSent", "headers", "attachments"] { XCTAssertFalse(text.contains(identity)) }
    }
    func testLocalBoundsRejectDuplicateReversedOversizedOrNonSentInputs() {
        for records in [[candidate(1), candidate(1)], [candidate(2), candidate(1)], [candidate(0)],
                        [candidate(1, size: StyleContentBatch.maximumBytes + 1)], (1...5).map({ candidate($0) })] {
            XCTAssertThrowsError(try StyleContentBatch(cursor: cursor, candidates: records).validate())
        }
        let inbox = MailIndexCursor(accountID: cursor.accountID, mailboxPath: ["Inbox"], scanID: cursor.scanID, role: .received)
        XCTAssertThrowsError(try StyleContentBatch(cursor: inbox, candidates: [candidate(1)]).validate())
    }
    func testPagingUsesReturnedCountWithoutRecheckingPriorMailboxCount() throws {
        let records = (1...4).map({ candidate($0) })
        let page = StyleCandidatePage(cursor: cursor, records: records, nextCursor: nil,
            mailbox: .init(accountID: cursor.accountID, path: cursor.mailboxPath, name: "Sent", messageCount: 4, role: .sent))
        try page.validate(for: cursor, limit: 128)
        XCTAssertEqual(page.mailbox.messageCount, 4)
        let changedOrder = StyleCandidatePage(cursor: cursor, records: Array(records.reversed()), nextCursor: nil, mailbox: page.mailbox)
        XCTAssertThrowsError(try changedOrder.validate(for: cursor, limit: 128))
    }
    func testBodyShapeAndByteCharacterBoundsAreValidatedLocally() throws {
        let batch = StyleContentBatch(cursor: cursor, candidates: [candidate(1), candidate(2)])
        try StyleContentLimits.validate(reads: [.init(candidate: candidate(1), body: "Fictional text"),
            .init(candidate: candidate(2), nativeCode: -1712)], for: batch)
        for reads in [[StyleContentRead(candidate: candidate(1), body: "Fictional text")],
                      [.init(candidate: candidate(2), body: "Fictional text"), .init(candidate: candidate(1), body: "Other text")],
                      [.init(candidate: candidate(1), nativeCode: -1743), .init(candidate: candidate(2), body: "text")],
                      [.init(candidate: candidate(1), body: String(repeating: "a", count: 250_001)), .init(candidate: candidate(2), body: "text")],
                      [.init(candidate: candidate(1), body: String(repeating: "a\u{0301}", count: 125_001)), .init(candidate: candidate(2), body: "text")]] {
            XCTAssertThrowsError(try StyleContentLimits.validate(reads: reads, for: batch))
        }
    }
}
