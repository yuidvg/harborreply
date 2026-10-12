import XCTest
import HarborCore
@testable import HarborReply

@MainActor final class ReportedFailuresTests: XCTestCase {
    func testResumeAfterMessageCountChangeRestartsOnlyAffectedMailbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LocalWorker(database: root.appendingPathComponent("fixture.invalid.sqlite"))
        let bridge = ChangedCountBridge()
        var last: MailArchiveStatus?
        try await MailArchiveIndexer(mail: bridge, worker: worker, requestID: UUID()).run(restart: false) { last = $0 }
        XCTAssertEqual(last?.status, "complete")
        XCTAssertEqual(bridge.cursors.count, 2)
        XCTAssertEqual(bridge.cursors.last?.offset, 0)
        XCTAssertNil(bridge.cursors.last?.expectedCount)
        XCTAssertEqual(bridge.discoveryCalls, 1)
    }
    func testRepeatedCountChangesStopAfterOneRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LocalWorker(database: root.appendingPathComponent("fixture.invalid.sqlite"))
        let bridge = ChangedCountBridge(alwaysFails: true)
        do {
            try await MailArchiveIndexer(mail: bridge, worker: worker, requestID: UUID()).run(restart: false) { _ in }
            XCTFail("an unstable folder must not be marked complete")
        } catch { XCTAssertEqual((error as? AppFailure)?.mailContext?.nativeCode, 9130) }
        XCTAssertEqual(bridge.cursors.count, 2)
    }
    func testPermissionFailureDoesNotRewindFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LocalWorker(database: root.appendingPathComponent("fixture.invalid.sqlite"))
        let bridge = ChangedCountBridge(nativeCode: -1743)
        do {
            try await MailArchiveIndexer(mail: bridge, worker: worker, requestID: UUID()).run(restart: false) { _ in }
            XCTFail("permission denied must fail")
        } catch { XCTAssertEqual((error as? AppFailure)?.mailContext?.nativeCode, -1743) }
        XCTAssertEqual(bridge.cursors.count, 1)
    }
    func testStyleProviderFailuresKeepTheirCauseInsteadOfMailInvalidResponse() {
        for (error, expected) in [(ChatGPTError.signInRequired as Error, "CHATGPT_signInRequired"),
                                  (ProviderError.http(429), "API_HTTP_429"),
                                  (URLError(.timedOut), "NETWORK_-1001")] {
            let failure = AppFailure.located(error, at: .styleCapture) as? AppFailure
            XCTAssertEqual(failure?.baseCode, expected)
            XCTAssertFalse(ReplyCoordinator.styleFailureMessage(for: failure!).contains("Mailから"))
        }
    }
}

@MainActor private final class ChangedCountBridge: MailSelectionBridge {
    let alwaysFails: Bool
    let nativeCode: Int
    init(alwaysFails: Bool = false, nativeCode: Int = 9130) { self.alwaysFails = alwaysFails; self.nativeCode = nativeCode }
    var cursors: [MailIndexCursor] = []
    var discoveryCalls = 0
    func indexMailboxes(after cursor: MailMailboxCursor?, limit: Int) async throws -> MailMailboxPage {
        discoveryCalls += 1
        return .init(scanID: cursor!.scanID, mailboxes: [.init(accountID: "account.invalid", path: ["Inbox"], name: "Inbox", messageCount: 1)], nextCursor: nil)
    }
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage {
        cursors.append(cursor)
        if cursor.expectedCount != nil || alwaysFails {
            let context = MailEventContext(operation: .indexPage, stage: .messageCount, nativeCode: nativeCode)
            throw AppFailure(context.code, mailContext: context)
        }
        return .init(mailbox: .init(accountID: cursor.accountID, path: cursor.mailboxPath, name: "Inbox", messageCount: 0), records: [], nextCursor: nil, scanID: cursor.scanID)
    }
    func capture() async throws -> MailTarget { throw AppFailure("TEST_UNEXPECTED") }
    func clearTracking() {}
    func canCaptureWithoutPrompt() async -> Bool { false }
    func createReply(to: MailTarget, replyAll: Bool, requestID: UUID) async throws -> DraftSnapshot { throw AppFailure("TEST_UNEXPECTED_WRITE") }
    func snapshot() async throws -> DraftSnapshot { throw AppFailure("TEST_UNEXPECTED") }
    func insert(_ text: String, expected: DraftSnapshot) async throws { throw AppFailure("TEST_UNEXPECTED_WRITE") }
    func history(for target: MailTarget?, limit: Int) async throws -> MailHistoryWindow { throw AppFailure("TEST_UNEXPECTED") }
    func hydrate(records: [MailHistoryItem]) async throws -> [MailHistoryMessage] { throw AppFailure("TEST_UNEXPECTED") }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] { throw AppFailure("TEST_UNEXPECTED") }
    func styleAccounts() async throws -> [MailAccountIdentity] { throw AppFailure("TEST_UNEXPECTED") }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] { throw AppFailure("TEST_UNEXPECTED") }
}
