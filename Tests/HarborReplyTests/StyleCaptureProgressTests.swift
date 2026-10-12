import Foundation
import XCTest
import HarborCore
@testable import HarborReply

/// The shipping acquisition driver/worker, with only native Mail replaced by
/// a test-only bridge. No owner preferences, actual Mail or provider is used.
@MainActor final class StyleCaptureProgressTests: XCTestCase {
    func testNativeReadsAndRetainedSamplesAreSeparateAcknowledgedSteps() async throws {
        let bridge = StyleProgressBridge(senders: [owner, owner, owner, owner, "other@style.invalid"],
            outcomes: [.body("Please confirm the report."), .body("Please confirm the report."), .unavailable, .body("")])
        let storage = try StyleProgressStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let driver = LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID())
        var observations: [StyleCaptureProgress] = []
        _ = try await driver.run(account: bridge.account, address: owner, shared: [], tokenBudget: 4_096) {
            observations.append($0)
        }

        XCTAssertEqual(observations.first?.activity, .starting)
        XCTAssertNil(observations.first?.knownSentMessageCount, "Discovery has not returned a real denominator.")
        let discovery = try XCTUnwrap(observations.first { $0.phase == .collecting })
        XCTAssertEqual(discovery.knownFolderCount, 1)
        XCTAssertEqual(discovery.knownSentMessageCount, 5)
        XCTAssertEqual(discovery.headerTarget, 5)
        let reading = observations.filter { $0.activity == .readingBodies }
        XCTAssertEqual(reading.filter { $0.bodyAttempts > $0.bodyReadsCompleted }.map(\.bodyAttempts), [4])
        XCTAssertEqual(reading.filter { $0.bodyAttempts == $0.bodyReadsCompleted }.map(\.batchCompleted), [4],
                       "A native bulk GET acknowledges four validated results atomically, not fabricated per-item progress.")
        XCTAssertTrue(reading.allSatisfy { $0.batchRequested == 4 && $0.adoptedSamples == 0 },
                      "Receiving a body does not imply it was accepted and persisted.")
        let completed = try XCTUnwrap(observations.last)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.headersChecked, 5)
        XCTAssertEqual(completed.metadataExcluded, 1)
        XCTAssertEqual(completed.bodyAttempts, 4)
        XCTAssertEqual(completed.bodyReadsCompleted, 4)
        XCTAssertEqual(completed.bodyCaptured, 3)
        XCTAssertEqual(completed.adoptedSamples, 1)
        XCTAssertEqual(completed.skippedSamples, 3)
        XCTAssertEqual(completed.stopReason, .sourceExhausted)
        XCTAssertEqual(completed.foldersProcessed, 1)
        XCTAssertNil(completed.activeFolderIndex)
        XCTAssertLessThanOrEqual(completed.tokenUnits, completed.tokenBudget)
        XCTAssertEqual(bridge.hydrationRequestSizes, [4])
        XCTAssertTrue(observations.filter { $0.phase != .completed }.allSatisfy { $0.activity != .idle },
                      "An intermediate phase must never use a completion activity.")
        XCTAssertTrue(observations.filter { $0.activity == .readingHeaders }.allSatisfy { $0.batchRequested == 0 },
                      "A metadata page is not the current body-acquisition batch.")
        XCTAssertTrue(observations.filter { $0.activity == .savingSamples }.allSatisfy { $0.batchCompleted == 4 },
                      "Saving the acquired batch must not reset its acknowledged native-read count.")
        let saving = try XCTUnwrap(observations.firstIndex { $0.activity == .savingSamples && $0.adoptedSamples == 1 })
        let analyzing = try XCTUnwrap(observations.firstIndex { $0.phase == .analyzing })
        XCTAssertLessThan(saving, analyzing)
        let status = try await worker.call("style_capture_status") as? [String: Any]
        XCTAssertEqual(status?["pages"] as? Int, 1, "Native progress must not spawn one persistence process per body.")
        XCTAssertEqual(status?["status"] as? String, "published")
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertEqual(bridge.legacyReadCalls, 0, "Style acquisition must collect content without index identity/cache/header validation.")
    }

    func testCancellationAtEightOfTwentyKeepsAcknowledgedSamplesAndNeverPublishesTheRemainder() async throws {
        let bridge = StyleProgressBridge(senders: Array(repeating: owner, count: 20),
                                         outcomes: (1...20).map { .body("Fixture response \($0).") })
        let storage = try StyleProgressStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        var observations: [StyleCaptureProgress] = []
        let task = Task { @MainActor in
            try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID())
                .run(account: bridge.account, address: self.owner, shared: [], tokenBudget: 4_096) { value in
                    observations.append(value)
                    if value.activity == .readingBodies && value.bodyReadsCompleted == 8 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
        }
        do { _ = try await task.value; XCTFail("A cancelled capture must not publish.") }
        catch is CancellationError {}
        XCTAssertEqual(bridge.hydrationRequestSizes, [4, 4])
        let last = try XCTUnwrap(observations.last)
        XCTAssertEqual(last.batchRequested, 4)
        XCTAssertEqual(last.batchCompleted, 4)
        XCTAssertEqual(last.bodyAttempts, 8)
        XCTAssertEqual(last.bodyReadsCompleted, 8)
        XCTAssertEqual(last.bodyCaptured, 8)
        XCTAssertEqual(last.adoptedSamples, 4, "Only the first completed batch was acknowledged by the style journal.")
        XCTAssertFalse(observations.contains { $0.phase == .analyzing || $0.phase == .completed })
        let status = try await worker.call("style_capture_status") as? [String: Any]
        XCTAssertEqual(status?["status"] as? String, "cancelled")
        XCTAssertEqual(status?["pages"] as? Int, 1)
        XCTAssertEqual((status?["counts"] as? [String: Int])?["captured"], 4)
        let captureID = try XCTUnwrap(status?["capture_id"] as? String)
        do {
            _ = try await worker.call("style_capture_extract", ["capture_id": captureID])
            XCTFail("Retained partial samples must never permit publication after cancellation.")
        } catch let failure as AppFailure { XCTAssertEqual(failure.baseCode, "STYLE_CAPTURE_INCOMPLETE") }
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertEqual(bridge.legacyReadCalls, 0, "Style acquisition must collect content without index identity/cache/header validation.")
    }

    func testFailedNativeReadRemainsAnAttemptAndDoesNotClaimACompletedBatch() async throws {
        let bridge = StyleProgressBridge(senders: Array(repeating: owner, count: 4),
            outcomes: [.body("Fixture first."), .body("Fixture second."), .nativeFailure, .body("Fixture fourth.")])
        let storage = try StyleProgressStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        var observations: [StyleCaptureProgress] = []
        do {
            _ = try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID())
                .run(account: bridge.account, address: owner, shared: [], tokenBudget: 4_096) { observations.append($0) }
            XCTFail("The native failure must remain visible to the caller.")
        } catch let failure as AppFailure { XCTAssertEqual(failure.code, "TEST_NATIVE_READ_FAILED") }
        let last = try XCTUnwrap(observations.last)
        XCTAssertEqual(last.bodyAttempts, 4, "All four rows were requested before entering the native operation.")
        XCTAssertEqual(last.bodyReadsCompleted, 0, "The throwing native batch returned no validated array.")
        XCTAssertEqual(last.bodyCaptured, 0)
        XCTAssertEqual(last.batchRequested, 4)
        XCTAssertEqual(last.batchCompleted, 0)
        XCTAssertEqual(last.adoptedSamples, 0)
        XCTAssertFalse(observations.contains { $0.phase == .completed || $0.phase == .analyzing })
        let status = try await worker.call("style_capture_status") as? [String: Any]
        XCTAssertEqual(status?["status"] as? String, "cancelled")
        XCTAssertEqual(status?["pages"] as? Int, 0)
        XCTAssertEqual(bridge.hydrationRequestSizes, [4])
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertEqual(bridge.legacyReadCalls, 0, "Style acquisition must collect content without index identity/cache/header validation.")
    }

    private let owner = "owner@style.invalid"
}

private struct StyleProgressStorage {
    let directory: URL
    var database: URL { directory.appendingPathComponent("archive.sqlite") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("harborreply-style-progress-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor private final class StyleProgressBridge: MailSelectionBridge {
    enum Outcome { case body(String), unavailable, nativeFailure }
    let account = MailAccountIdentity(id: "style-test", name: "Style test", addresses: ["owner@style.invalid"])
    let senders: [String]
    private var outcomes: [Outcome]
    private(set) var hydrationRequestSizes: [Int] = []
    private(set) var writeCalls = 0
    init(senders: [String], outcomes: [Outcome]) { self.senders = senders; self.outcomes = outcomes }
    private var box: MailIndexMailbox {
        .init(accountID: account.id, path: ["Sent"], name: "Sent", messageCount: senders.count, role: .sent)
    }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] { [box] }
    private(set) var legacyReadCalls = 0
    func styleCandidates(cursor: MailIndexCursor, limit: Int) async throws -> StyleCandidatePage {
        let rows = senders.enumerated().dropFirst(cursor.offset).prefix(limit).map { index, sender in
            StyleCandidate(position: index + 1, sender: sender, messageSize: 100)
        }
        let offset = cursor.offset + rows.count
        let next = offset < senders.count ? MailIndexCursor(accountID: cursor.accountID, mailboxPath: cursor.mailboxPath,
            offset: offset, expectedCount: cursor.expectedCount, scanID: cursor.scanID, role: cursor.role) : nil
        return .init(cursor: cursor, records: rows, nextCursor: next, mailbox: box)
    }
    func styleContents(batch: StyleContentBatch) async throws -> [StyleContentRead] {
        hydrationRequestSizes.append(batch.candidates.count)
        return try batch.candidates.map { candidate in
            guard !outcomes.isEmpty else { throw AppFailure("TEST_OUTCOMES_EXHAUSTED") }
            switch outcomes.removeFirst() {
            case .unavailable: return .init(candidate: candidate, body: nil, nativeCode: -1712)
            case .nativeFailure: throw AppFailure("TEST_NATIVE_READ_FAILED")
            case let .body(body): return .init(candidate: candidate, body: body, nativeCode: nil)
            }
        }
    }
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage {
        legacyReadCalls += 1; throw unexpectedRead()
    }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] {
        legacyReadCalls += 1; throw unexpectedRead()
    }
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult] {
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
    func insert(_ text: String, expected: DraftSnapshot) async throws { writeCalls += 1; throw AppFailure("TEST_UNEXPECTED_MAIL_WRITE") }
    func history(for target: MailTarget?, limit: Int) async throws -> MailHistoryWindow { throw unexpectedRead() }
    func hydrate(records: [MailHistoryItem]) async throws -> [MailHistoryMessage] { throw unexpectedRead() }
    func indexMailboxes(after cursor: MailMailboxCursor?, limit: Int) async throws -> MailMailboxPage { throw unexpectedRead() }
    func styleAccounts() async throws -> [MailAccountIdentity] { throw unexpectedRead() }
    private func unexpectedRead() -> AppFailure { AppFailure("TEST_UNEXPECTED_MAIL_READ") }
}
