import XCTest
@testable import HarborCore

final class ReplySessionTests: XCTestCase {
    let target = MailTarget(id: "1", account: "fixture", messageID: "a@fixture.invalid", subject: "Test", sender: "a@fixture.invalid", body: "Fictional")
    let draft = DraftSnapshot(id: "2", fields: ["sender@fixture.invalid", "quote", "signature"])
    func testInsertionExactlyOnce() {
        var s = ReplySession(); s.capture(target); s.track(draft); s.transition(.ready)
        XCTAssertTrue(s.insertionPermit(id: s.requestID, revision: s.revision, target: target, draft: draft))
        XCTAssertFalse(s.insertionPermit(id: s.requestID, revision: s.revision, target: target, draft: draft))
    }
    func testCancellationAndLateResult() {
        var s = ReplySession(); s.capture(target); let id = s.requestID; let rev = s.revision
        s.cancel(); XCTAssertFalse(s.isCurrent(id, rev))
        s.transition(.ready); XCTAssertFalse(s.isCurrent(id, rev))
    }
    func testTargetDraftAndRevisionChangesBlock() {
        var s = ReplySession(); s.capture(target); s.track(draft); s.transition(.ready)
        XCTAssertFalse(s.insertionPermit(id: s.requestID, revision: s.revision, target: target, draft: .init(id: "3", fields: draft.fields)))
        XCTAssertFalse(s.insertionPermit(id: s.requestID, revision: s.revision, target: target, draft: .init(id: "2", fields: ["edited"])))
        let revision = s.revision; s.invalidate(); s.transition(.ready)
        XCTAssertFalse(s.insertionPermit(id: s.requestID, revision: revision, target: target, draft: draft))
    }
}
