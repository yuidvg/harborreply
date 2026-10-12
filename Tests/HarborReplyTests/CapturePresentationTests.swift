import Foundation
import XCTest
import HarborCore
@testable import HarborReply

/// Tests the real coordinator without Apple events, preferences, credentials or
/// provider calls. Synthetic messages and this bridge exist only in this target.
@MainActor final class CapturePresentationTests: XCTestCase {
    func testSelectionFailureShowsGuidanceOnceAndRetryCapturesNewTarget() async throws {
        let failure = captureFailure(9101)
        let bridge = ScriptedSelectionBridge(results: [.failure(failure), .success(Self.target)])
        let storage = try PrivateTestStorage()
        defer { storage.remove() }
        let coordinator = makeCoordinator(bridge, storage)
        defer { coordinator.clearSession() }

        coordinator.captureMail()
        try await waitUntil { coordinator.session.phase == .failed && !coordinator.busy }
        XCTAssertNil(coordinator.session.target)
        XCTAssertEqual(coordinator.message, MailCaptureError.selectionRequired.userMessage)
        XCTAssertTrue(coordinator.message.contains("1通"))
        XCTAssertEqual(coordinator.captureErrorCode, "MAIL_CAPTURE_SELECTION_EVENT_9101")
        XCTAssertTrue(coordinator.actionNotice.isEmpty, "Capture errors must stay in the target island.")
        XCTAssertTrue(coordinator.replyBody.isEmpty)
        XCTAssertEqual(bridge.captureCalls, 1)
        XCTAssertEqual(bridge.writeCalls, 0)

        coordinator.captureMail()
        XCTAssertTrue(coordinator.captureErrorCode.isEmpty, "A retry must immediately dismiss the old diagnostic.")
        try await waitUntil { coordinator.session.target == Self.target && coordinator.session.phase == .editing }
        XCTAssertTrue(coordinator.captureErrorCode.isEmpty)
        XCTAssertTrue(coordinator.actionNotice.isEmpty)
        XCTAssertEqual(bridge.captureCalls, 2)
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertFalse(coordinator.chatGPT.isSignedIn)
        XCTAssertTrue(coordinator.chatGPT.accounts.isEmpty)
        // Finish the ordinary local overview/search before removing the private
        // database; neither routine has access to any owner archive.
        try await waitUntil { coordinator.coverage.hasPrefix("0 通 /") && !coordinator.relatedLoading }
        _ = try await coordinator.worker.call("overview")
        XCTAssertEqual(coordinator.session.phase, .editing)
        XCTAssertEqual(bridge.unexpectedReadCalls, 0)
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testNativeFailuresRetainExactCodesAndAreNotSelectionFailures() async throws {
        for number in [-1743, -1712, -1708, -1700] {
            let failure = captureFailure(number)
            let bridge = ScriptedSelectionBridge(results: [.failure(failure)])
            let storage = try PrivateTestStorage()
            defer { storage.remove() }
            let coordinator = makeCoordinator(bridge, storage)
            defer { coordinator.clearSession() }
            coordinator.captureMail()
            try await waitUntil { coordinator.session.phase == .failed && !coordinator.busy }
            XCTAssertEqual(coordinator.captureErrorCode, "MAIL_CAPTURE_SELECTION_EVENT_\(number)")
            XCTAssertEqual(coordinator.message, failure.code)
            XCTAssertFalse(coordinator.message.contains("1通"))
            XCTAssertNil(failure.mailContext?.captureError)
            XCTAssertNotEqual(failure.diagnosticFailure, .selectionRequired)
            XCTAssertTrue(coordinator.actionNotice.isEmpty)
            XCTAssertNil(coordinator.session.target)
            XCTAssertEqual(bridge.writeCalls, 0)
            XCTAssertEqual(bridge.unexpectedReadCalls, 0)
        }
    }

    func testOversizedMessageGetsItsOwnGuidanceWithoutSelectingATarget() async throws {
        let bridge = ScriptedSelectionBridge(results: [.failure(captureFailure(9102, stage: 9177))])
        let storage = try PrivateTestStorage()
        defer { storage.remove() }
        let coordinator = makeCoordinator(bridge, storage)
        defer { coordinator.clearSession() }
        coordinator.captureMail()
        try await waitUntil { coordinator.session.phase == .failed && !coordinator.busy }
        XCTAssertEqual(coordinator.message, MailCaptureError.messageTooLarge.userMessage)
        XCTAssertEqual(coordinator.captureErrorCode, "MAIL_CAPTURE_METADATA_SIZE_EVENT_9102")
        XCTAssertFalse(coordinator.message.contains("1通"))
        XCTAssertNil(coordinator.session.target)
        XCTAssertTrue(coordinator.actionNotice.isEmpty)
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testCancellationAndIntentEditsClearSelectionDiagnostics() async throws {
        let bridge = ScriptedSelectionBridge(results: [.failure(captureFailure(9101)), .failure(captureFailure(9101))])
        let storage = try PrivateTestStorage()
        defer { storage.remove() }
        let coordinator = makeCoordinator(bridge, storage)
        defer { coordinator.clearSession() }
        coordinator.captureMail()
        try await waitUntil { coordinator.session.phase == .failed }
        XCTAssertFalse(coordinator.captureErrorCode.isEmpty)
        coordinator.cancel()
        XCTAssertEqual(coordinator.session.phase, .cancelled)
        XCTAssertTrue(coordinator.captureErrorCode.isEmpty)
        XCTAssertTrue(coordinator.actionNotice.isEmpty)

        coordinator.captureMail()
        try await waitUntil { coordinator.session.phase == .failed }
        XCTAssertFalse(coordinator.captureErrorCode.isEmpty)
        coordinator.intent = "依頼を明確にする"
        XCTAssertEqual(coordinator.session.phase, .editing)
        XCTAssertTrue(coordinator.captureErrorCode.isEmpty)
        XCTAssertTrue(coordinator.actionNotice.isEmpty)
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testRequiredUpdateBlocksNewWorkWithoutDiscardingText() async throws {
        let bridge = ScriptedSelectionBridge(results: [])
        let storage = try PrivateTestStorage()
        defer { storage.remove() }
        let coordinator = makeCoordinator(bridge, storage)
        defer { coordinator.clearSession() }
        coordinator.intent = "Fictional instruction"
        coordinator.replyBody = "Fictional draft"
        coordinator.updateRestriction = "Update required"
        coordinator.generate()
        coordinator.prepareReply()
        await coordinator.insertReady()
        XCTAssertEqual(coordinator.message, "Update required")
        XCTAssertEqual(coordinator.intent, "Fictional instruction")
        XCTAssertEqual(coordinator.replyBody, "Fictional draft")
        XCTAssertEqual(bridge.captureCalls, 0)
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertFalse(coordinator.busy)
    }

    func testRelatedSelectionDefaultsOnInvalidatesAndResetsWithTarget() async throws {
        let bridge = ScriptedSelectionBridge(results: [.success(Self.target)])
        let storage = try PrivateTestStorage()
        defer { storage.remove() }
        let coordinator = makeCoordinator(bridge, storage)
        defer { coordinator.clearSession() }
        XCTAssertTrue(coordinator.relatedIsSelected("synthetic-related"))
        let revision = coordinator.session.revision
        coordinator.setRelatedSelected("synthetic-related", false)
        XCTAssertFalse(coordinator.relatedIsSelected("synthetic-related"))
        XCTAssertGreaterThan(coordinator.session.revision, revision)
        coordinator.captureMail()
        XCTAssertTrue(coordinator.relatedIsSelected("synthetic-related"))
        try await waitUntil { coordinator.session.target == Self.target && !coordinator.relatedLoading }
        _ = try await coordinator.worker.call("overview")
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    private func makeCoordinator(_ bridge: ScriptedSelectionBridge, _ storage: PrivateTestStorage) -> ReplyCoordinator {
        Diagnostics.configure(enabled: false, persist: false)
        return ReplyCoordinator(mail: bridge, database: storage.database, settings: Settings(), diagnosticsEnabled: false,
                                chatGPT: ChatGPTConnection(activeID: ""))
    }

    private func captureFailure(_ number: Int, stage: Int = 9160) -> AppFailure {
        let context = MailEventContext.fromScript(operation: .capture, number: number, stageNumber: stage)
        return AppFailure(context.code, mailContext: context)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let timeout = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < timeout else {
                XCTFail("The coordinator did not reach the expected state.")
                throw AppFailure("TEST_COORDINATOR_TIMEOUT")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static let target = MailTarget(
        id: "capture-test-target", account: "capture-test-account", messageID: "target@capture.invalid",
        subject: "Fixture request", sender: "operator@capture.invalid", body: "Please confirm the document.",
        headers: "From: operator@capture.invalid\nTo: owner@capture.invalid\nMessage-ID: <target@capture.invalid>"
    )
}

private struct PrivateTestStorage {
    let directory: URL
    var database: URL { directory.appendingPathComponent("archive.sqlite") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("harborreply-capture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor private final class ScriptedSelectionBridge: MailSelectionBridge {
    private var results: [Result<MailTarget, Error>]
    private(set) var captureCalls = 0
    private(set) var writeCalls = 0
    private(set) var unexpectedReadCalls = 0
    init(results: [Result<MailTarget, Error>]) { self.results = results }
    func capture() async throws -> MailTarget {
        captureCalls += 1
        guard !results.isEmpty else { throw AppFailure("TEST_CAPTURE_SCRIPT_EXHAUSTED") }
        return try results.removeFirst().get()
    }
    func clearTracking() {}
    func canCaptureWithoutPrompt() async -> Bool { false }
    func createReply(to: MailTarget, replyAll: Bool, requestID: UUID) async throws -> DraftSnapshot {
        writeCalls += 1; throw AppFailure("TEST_UNEXPECTED_MAIL_WRITE")
    }
    func snapshot() async throws -> DraftSnapshot {
        unexpectedReadCalls += 1; throw AppFailure("TEST_UNEXPECTED_DRAFT_READ")
    }
    func insert(_ text: String, expected: DraftSnapshot) async throws {
        writeCalls += 1; throw AppFailure("TEST_UNEXPECTED_MAIL_WRITE")
    }
    func history(for target: MailTarget?, limit: Int) async throws -> MailHistoryWindow { throw unexpectedRead() }
    func hydrate(records: [MailHistoryItem]) async throws -> [MailHistoryMessage] { throw unexpectedRead() }
    func indexMailboxes(after cursor: MailMailboxCursor?, limit: Int) async throws -> MailMailboxPage { throw unexpectedRead() }
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage { throw unexpectedRead() }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] { throw unexpectedRead() }
    func styleAccounts() async throws -> [MailAccountIdentity] { throw unexpectedRead() }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] { throw unexpectedRead() }
    private func unexpectedRead() -> AppFailure {
        unexpectedReadCalls += 1; return AppFailure("TEST_UNEXPECTED_MAIL_READ")
    }
}
