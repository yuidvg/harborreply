import Foundation
import XCTest
@testable import HarborCore
@testable import HarborReply

/// Executes the normal sender-selection and retry coordinator with the shipping
/// private worker. Only the native Mail boundary and settings write are replaced.
@MainActor final class StyleTimeoutCoordinatorTests: XCTestCase {
    func testReextractionFailureKeepsPreviouslyPublishedStyleVisible() async throws {
        let storage = try StyleCoordinatorStorage(); defer { storage.remove() }
        let bridge = StyleCoordinatorBridge(mode: .success)
        var settings = Settings(); settings.cloudEnabled = true; settings.chatgptModel = "fixture.invalid"
        let provider = FailingSecondStyleProvider()
        let coordinator = ReplyCoordinator(mail: bridge, database: storage.database, settings: settings,
            diagnosticsEnabled: false, chatGPT: ChatGPTConnection(activeID: ""), styleProvider: provider,
            persistStyleSelection: { _ in })
        defer { coordinator.clearSession() }
        coordinator.beginStyleExtraction()
        try await waitUntil { coordinator.choosingStyleAddress }
        coordinator.selectStyleAddress(accountID: bridge.account.id, address: bridge.owner)
        try await waitUntil { !coordinator.styleExtracting }
        XCTAssertEqual(coordinator.styleSummary?.explanation, "短い段落の文体。")
        let previous = coordinator.styleSummary
        coordinator.selectStyleAddress(accountID: bridge.account.id, address: bridge.owner)
        try await waitUntil { !coordinator.styleExtracting }
        XCTAssertEqual(coordinator.styleSummary, previous)
        XCTAssertTrue(coordinator.styleMessage.contains("API_HTTP_429"))
        let stored = try await coordinator.worker.call("overview") as? [String: Any]
        XCTAssertEqual((stored?["style_summary"] as? [String: Any])?["description"] as? String, previous?.explanation)
    }

    func testBodyAndHeaderTimeoutGuidancePreservesExactLocatedCode() {
        for operation in [MailEventOperation.indexHydrate, .indexHydrateBatch, .hydrate, .styleContents] {
            for stage in [MailEventStage.body, .headers] {
                let error = Self.failure(operation: operation, stage: stage, number: -1712)
                let located = AppFailure.located(error, at: .styleCapture)
                let guidance = ReplyCoordinator.styleFailureMessage(for: located)
                XCTAssertTrue(guidance.contains("本文取得が時間切れ"))
                XCTAssertTrue(guidance.contains("前回の文体は保持"))
                XCTAssertTrue(guidance.contains("やり直"))
                XCTAssertTrue(guidance.contains((located as? AppFailure)?.code ?? "MISSING_CODE"))
                XCTAssertFalse(guidance.contains("選び直"))
                XCTAssertFalse(guidance.contains("オートメーション"))
                XCTAssertEqual((located as? AppFailure)?.mailContext, error.mailContext)
            }
        }
    }

    func testMetadataPermissionAndMalformedCodesAreNotBodyTimeouts() {
        let metadata = ReplyCoordinator.styleFailureMessage(for:
            Self.failure(operation: .indexHydrateBatch, stage: .metadataNativeID, number: -1712))
        XCTAssertTrue(metadata.contains("応答が時間切れ"))
        XCTAssertFalse(metadata.contains("本文取得"))
        XCTAssertFalse(metadata.contains("選び直"))
        let permission = ReplyCoordinator.styleFailureMessage(for:
            Self.failure(operation: .indexHydrateBatch, stage: .body, number: -1743))
        XCTAssertTrue(permission.contains("オートメーション"))
        XCTAssertFalse(permission.contains("時間切れ"))
        let missingReference = ReplyCoordinator.styleFailureMessage(for:
            Self.failure(operation: .styleMailboxes, stage: .account, number: -1728))
        XCTAssertTrue(missingReference.contains("参照を解決できません"))
        XCTAssertTrue(missingReference.contains("差出人を選び直"))
        let unknown = ReplyCoordinator.styleFailureMessage(for:
            AppFailure("MAIL_INDEX_HYDRATE_BATCH_BODY_EVENT_-1712"))
        XCTAssertFalse(unknown.contains("時間切れ"), "The display-code substring is not trusted as structured native context.")
        XCTAssertFalse(unknown.contains("選び直"))
    }

    func testUnconfiguredModelDoesNotCollectMailOrPublishLocalSubstitute() async throws {
        let storage = try StyleCoordinatorStorage(); defer { storage.remove() }
        let bridge = StyleCoordinatorBridge(mode: .success)
        let coordinator = makeCoordinator(bridge, storage)
        coordinator.beginStyleExtraction()
        try await waitUntil { coordinator.choosingStyleAddress }
        coordinator.selectStyleAddress(accountID: bridge.account.id, address: bridge.owner)
        try await waitUntil { !coordinator.styleExtracting }
        XCTAssertEqual(bridge.bodyBatches.count, 0)
        XCTAssertEqual(coordinator.tab, 2)
        XCTAssertNil(coordinator.styleSummary)
    }

    func testCollectorConcatenatesEveryBodyWithoutSelectingSamples() async throws {
        let bridge = StyleCoordinatorBridge(mode: .success)
        let text = try await MailStyleCapture(mail: bridge).collect(account: bridge.account, address: bridge.owner,
            shared: [], characterLimit: 55, progress: { _ in })
        XCTAssertEqual(text.characters, 55)
        XCTAssertEqual(text.messages, 2)
        XCTAssertEqual(text.text, String("Please confirm fixture response 1.\n\nPlease confirm fixture response 2.".prefix(55)))
        XCTAssertEqual(bridge.legacyReadCalls, 0)
        XCTAssertEqual(bridge.bodyBatches.count, 1)
    }

    func testUnavailableBodiesAreReportedAndMalformedResponseFails() async throws {
        let bridge = StyleCoordinatorBridge(mode: .oneBodyTimeout)
        var latest: StyleTextProgress?
        let text = try await MailStyleCapture(mail: bridge).collect(account: bridge.account, address: bridge.owner,
            shared: [], characterLimit: 1024) { latest = $0 }
        XCTAssertEqual(text.messages, 3); XCTAssertEqual(latest?.unavailable, 1)
        let invalid = StyleCoordinatorBridge(mode: .invalidContent)
        do {
            _ = try await MailStyleCapture(mail: invalid).collect(account: invalid.account, address: invalid.owner,
                shared: [], characterLimit: 1024, progress: { _ in })
            XCTFail("invalid body envelope accepted")
        } catch { XCTAssertEqual(invalid.bodyBatches.count, 1) }
    }

    func testCancelledOldDiscoveryCannotRestoreFailureOrResumeAction() async throws {
        let storage = try StyleCoordinatorStorage()
        defer { storage.remove() }
        let bridge = StyleCoordinatorBridge(mode: .delayedAccountFailure)
        let coordinator = makeCoordinator(bridge, storage)
        defer { coordinator.clearSession() }
        coordinator.beginStyleExtraction()
        try await waitUntil { bridge.accountCalls == 1 }
        coordinator.stopStyleExtraction()
        let cancelledMessage = coordinator.styleMessage
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(coordinator.styleExtracting)
        XCTAssertFalse(coordinator.choosingStyleAddress)
        XCTAssertFalse(coordinator.styleCanResume)
        XCTAssertEqual(coordinator.styleMessage, cancelledMessage)
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertEqual(bridge.legacyReadCalls, 0)
    }

    private func makeCoordinator(_ bridge: StyleCoordinatorBridge, _ storage: StyleCoordinatorStorage,
                                 settings: Settings? = nil, persist: @escaping (Settings) throws -> Void = { _ in }) -> ReplyCoordinator {
        Diagnostics.configure(enabled: false, persist: false)
        var value = settings ?? Settings()
        value.styleTokenBudget = 4_096
        return ReplyCoordinator(mail: bridge, database: storage.database, settings: value,
            diagnosticsEnabled: false, chatGPT: ChatGPTConnection(activeID: ""), persistStyleSelection: persist)
    }
    private func state(_ coordinator: ReplyCoordinator) async throws -> [String: Any] {
        let value = try await coordinator.worker.call("style_capture_status")
        return try XCTUnwrap(value as? [String: Any])
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("The normal coordinator did not reach the expected state.")
                throw AppFailure("TEST_STYLE_COORDINATOR_TIMEOUT")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    fileprivate static func failure(operation: MailEventOperation = .indexHydrateBatch,
                                    stage: MailEventStage = .body, number: Int = -1712) -> AppFailure {
        let context = MailEventContext(operation: operation, stage: stage, nativeCode: number)
        return .init(context.code, mailContext: context)
    }
}

private struct StyleCoordinatorStorage {
    let directory: URL
    var database: URL { directory.appendingPathComponent("archive.sqlite") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("harborreply-style-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor private final class StyleCoordinatorBridge: MailSelectionBridge {
    enum Mode: Equatable { case success, contentTimeoutOnce, oneBodyTimeout, invalidContent, delayedAccountFailure }
    let owner = "owner@coordinator-style.invalid"
    let account = MailAccountIdentity(id: "coordinator-style.invalid", name: "Test account", addresses: ["owner@coordinator-style.invalid"])
    private let mode: Mode
    private(set) var accountCalls = 0
    private(set) var discoveryCalls = 0
    private(set) var bodyBatches: [StyleContentBatch] = []
    private(set) var legacyReadCalls = 0
    private(set) var writeCalls = 0
    init(mode: Mode) { self.mode = mode }
    private var mailbox: MailIndexMailbox {
        .init(accountID: account.id, path: ["Sent"], name: "Sent", messageCount: 4, role: .sent)
    }
    func styleAccounts() async throws -> [MailAccountIdentity] {
        accountCalls += 1
        if mode == .delayedAccountFailure {
            try? await Task.sleep(for: .milliseconds(40))
            throw StyleTimeoutCoordinatorTests.failure(operation: .styleAccounts, stage: .account, number: -1743)
        }
        return [account]
    }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] {
        discoveryCalls += 1
        guard accountID == account.id else { throw MailStyleDiscoveryError.accountChanged }
        return [mailbox]
    }
    func styleCandidates(cursor: MailIndexCursor, limit: Int) async throws -> StyleCandidatePage {
        let records = (cursor.offset..<min(4, cursor.offset + limit)).map {
            StyleCandidate(position: $0 + 1, sender: owner, messageSize: 100)
        }
        return .init(cursor: cursor, records: records, nextCursor: nil, mailbox: mailbox)
    }
    func styleContents(batch: StyleContentBatch) async throws -> [StyleContentRead] {
        try batch.validate()
        bodyBatches.append(batch)
        if mode == .contentTimeoutOnce && bodyBatches.count == 1 {
            throw StyleTimeoutCoordinatorTests.failure(operation: .styleContents)
        }
        if mode == .invalidContent { throw StyleContentError.invalidShape }
        return batch.candidates.map { candidate in
            mode == .oneBodyTimeout && candidate.position == 3 ?
                .init(candidate: candidate, body: nil, nativeCode: -1712) :
                .init(candidate: candidate, body: "Please confirm fixture response \(candidate.position).")
        }
    }
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage {
        legacyReadCalls += 1; throw unexpectedRead()
    }
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult] {
        legacyReadCalls += 1; throw unexpectedRead()
    }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] {
        legacyReadCalls += 1; throw unexpectedRead()
    }
    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int]) async throws -> [Bool] {
        legacyReadCalls += 1; throw unexpectedRead()
    }
    func capture() async throws -> MailTarget { throw unexpectedRead() }
    func clearTracking() {}
    func canCaptureWithoutPrompt() async -> Bool { false }
    func createReply(to: MailTarget, replyAll: Bool, requestID: UUID) async throws -> DraftSnapshot {
        writeCalls += 1; throw AppFailure("TEST_UNEXPECTED_MAIL_WRITE")
    }
    func snapshot() async throws -> DraftSnapshot { throw unexpectedRead() }
    func insert(_ text: String, expected: DraftSnapshot) async throws {
        writeCalls += 1; throw AppFailure("TEST_UNEXPECTED_MAIL_WRITE")
    }
    func history(for target: MailTarget?, limit: Int) async throws -> MailHistoryWindow { throw unexpectedRead() }
    func hydrate(records: [MailHistoryItem]) async throws -> [MailHistoryMessage] { throw unexpectedRead() }
    func indexMailboxes(after cursor: MailMailboxCursor?, limit: Int) async throws -> MailMailboxPage { throw unexpectedRead() }
    private func unexpectedRead() -> AppFailure { AppFailure("TEST_UNEXPECTED_MAIL_READ") }
}

private actor FailingSecondStyleProvider: LLMProvider {
    private var calls = 0
    func generate(context: Data, schema: Data, instructions: String) async throws -> GenerationResult {
        calls += 1
        if calls > 1 { throw ProviderError.http(429) }
        return .init(output: Data(#"{"description":"短い段落の文体。"}"#.utf8), elapsed: 0, inputTokens: nil, outputTokens: nil)
    }
}
