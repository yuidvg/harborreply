import Foundation
import XCTest
import HarborCore
@testable import HarborReply

/// Shipping reader + real private worker; only the native Mail boundary is fake.
/// The test bridge never accesses owner preferences, Mail or a model.
@MainActor final class MailBodyReaderTests: XCTestCase {
    func testCrossScanCacheHitValidatesLiveMetadataAndAttachmentsWithoutBodyRequests() async throws {
        let storage = try BodyReaderStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = BodyReaderBridge()
        let original = BodyReaderFixture.batch(count: 3, scan: "original-scan.invalid", firstIndex: 5, mailboxCount: 12)
        bridge.attachmentCounts = Dictionary(uniqueKeysWithValues: zip(original.locators, [2, 1, 3]).map { ($0.0.nativeID, $0.1) })
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
        let fresh = try await reader.read(batch: original)
        XCTAssertTrue(fresh.allSatisfy { !$0.fromCache })
        XCTAssertEqual(bridge.bodyBatches, [original])
        XCTAssertEqual(reader.lastMetrics.bodyRequests, 3)
        XCTAssertEqual(reader.lastMetrics.cacheHits, 0)
        bridge.resetObservations()

        let current = BodyReaderFixture.batch(count: 3, scan: "new-scan.invalid", firstIndex: 5, mailboxCount: 12)
        let hits = try await reader.read(batch: current)
        XCTAssertEqual(hits.map(\.locator), current.locators)
        XCTAssertTrue(hits.allSatisfy(\.fromCache))
        XCTAssertEqual(hits.map { $0.message?.target.body }, fresh.map { $0.message?.target.body })
        XCTAssertEqual(bridge.validationLocators, [current.locators], "Rebound scan identity must be validated against live Mail.")
        XCTAssertEqual(bridge.validationAttachmentCounts, [[2, 1, 3]])
        XCTAssertEqual(bridge.bodyBatches, [])
        XCTAssertEqual(reader.lastMetrics.cacheHits, 3)
        XCTAssertEqual(reader.lastMetrics.cacheMisses, 0)
        XCTAssertEqual(reader.lastMetrics.bodyRequests, 0)
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testRejectedLiveAttachmentValidationRefetchesAndReplacesPriorSnapshot() async throws {
        let storage = try BodyReaderStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = BodyReaderBridge()
        let batch = BodyReaderFixture.batch(count: 1)
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
        _ = try await reader.read(batch: batch)
        bridge.resetObservations()
        bridge.rejectedNativeIDs = Set(batch.locators.map(\.nativeID))
        bridge.attachmentCounts[batch.locators[0].nativeID] = 2
        bridge.bodySuffix = "Updated fixture bytes."

        let current = BodyReaderFixture.batch(count: 1, scan: "second-scan.invalid")
        let fresh = try await reader.read(batch: current)
        XCTAssertEqual(bridge.validationLocators, [current.locators])
        XCTAssertEqual(bridge.validationAttachmentCounts, [[1]], "Validate the stored attachment count, not a newly assumed count.")
        XCTAssertEqual(bridge.bodyBatches, [current])
        XCTAssertFalse(try XCTUnwrap(fresh.first).fromCache)
        XCTAssertEqual(fresh.first?.message?.item.attachmentCount, 2)
        XCTAssertTrue(fresh.first?.message?.target.body.contains("Updated fixture bytes.") == true)
        XCTAssertEqual(reader.lastMetrics.cacheHits, 0)
        XCTAssertEqual(reader.lastMetrics.bodyRequests, 1)

        bridge.rejectedNativeIDs = []
        bridge.resetObservations()
        let updated = try await reader.read(batch: current)
        XCTAssertTrue(try XCTUnwrap(updated.first).fromCache)
        XCTAssertEqual(bridge.validationAttachmentCounts, [[2]])
        XCTAssertEqual(bridge.bodyBatches, [])
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testChangedHeaderFingerprintRefetchesInsteadOfReturningOldBody() async throws {
        let storage = try BodyReaderStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = BodyReaderBridge()
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
        _ = try await reader.read(batch: BodyReaderFixture.batch(count: 1))
        bridge.resetObservations()
        let changed = BodyReaderFixture.locator(0, scan: "new-scan.invalid", subject: "Changed fictional subject")
        let batch = MailBodyBatch(locators: [changed], firstIndex: 1, expectedMailboxCount: 1)
        let results = try await reader.read(batch: batch)
        XCTAssertFalse(try XCTUnwrap(results.first).fromCache)
        XCTAssertEqual(results.first?.message?.target.subject, "Changed fictional subject")
        XCTAssertEqual(bridge.validationLocators, [], "The worker rejected the stale fingerprint before live validation.")
        XCTAssertEqual(bridge.bodyBatches, [batch])
        XCTAssertEqual(reader.lastMetrics.cacheMisses, 1)
        XCTAssertEqual(reader.lastMetrics.bodyRequests, 1)
    }

    func testMixedCacheHolesOnlyFetchTheirTrueContiguousPositions() async throws {
        for cachedIndices in [[0, 2], [0, 3]] {
            let storage = try BodyReaderStorage()
            defer { storage.remove() }
            let worker = LocalWorker(database: storage.database)
            let bridge = BodyReaderBridge()
            let original = BodyReaderFixture.batch(count: 4, firstIndex: 11, mailboxCount: 20)
            try await BodyReaderFixture.seed(worker: worker, locators: cachedIndices.map { original.locators[$0] })
            let current = BodyReaderFixture.batch(count: 4, scan: "new-scan.invalid", firstIndex: 11, mailboxCount: 20)
            let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
            let results = try await reader.read(batch: current)
            XCTAssertEqual(results.map(\.locator), current.locators)
            XCTAssertEqual(results.enumerated().filter { $0.element.fromCache }.map(\.offset), cachedIndices)
            XCTAssertEqual(bridge.validationLocators, [cachedIndices.map { current.locators[$0] }])
            let misses = current.locators.indices.filter { !cachedIndices.contains($0) }
            XCTAssertEqual(bridge.bodyBatches.flatMap(\.locators), misses.map { current.locators[$0] })
            if cachedIndices == [0, 2] {
                XCTAssertEqual(bridge.bodyBatches.map(\.firstIndex), [12, 14])
                XCTAssertEqual(bridge.bodyBatches.map { $0.locators.count }, [1, 1])
            } else {
                XCTAssertEqual(bridge.bodyBatches.map(\.firstIndex), [12])
                XCTAssertEqual(bridge.bodyBatches.map { $0.locators.count }, [2])
            }
            XCTAssertTrue(bridge.bodyBatches.allSatisfy { $0.expectedMailboxCount == 20 })
            XCTAssertEqual(reader.lastMetrics.cacheHits, 2)
            XCTAssertEqual(reader.lastMetrics.bodyRequests, 2)
            XCTAssertEqual(bridge.writeCalls, 0)
        }
    }

    func testFilteredPageNeverReadsUnselectedNeighbours() async throws {
        let storage = try BodyReaderStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = BodyReaderBridge()
        let locators = (0..<6).map { BodyReaderFixture.locator($0) }
        let mailbox = MailIndexMailbox(accountID: BodyReaderFixture.accountID, path: ["Sent"], name: "Sent",
            messageCount: 10, role: .sent)
        let page = MailIndexPage(mailbox: mailbox, records: locators, nextCursor: nil, scanID: BodyReaderFixture.scanID)
        let selected = [0, 2, 3, 5].map { locators[$0] }
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
        let results = try await reader.read(page: page, selected: selected, offset: 4)
        XCTAssertEqual(results.map(\.locator), selected)
        XCTAssertEqual(bridge.bodyBatches.flatMap(\.locators), selected)
        XCTAssertEqual(bridge.bodyBatches.map(\.firstIndex), [5, 7, 10])
        XCTAssertEqual(bridge.bodyBatches.map { $0.locators.count }, [1, 2, 1])
        XCTAssertTrue(bridge.bodyBatches.allSatisfy { $0.expectedMailboxCount == 10 })
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testWrongNativeLocatorCountAndOrderFailClosedWithoutCachingResults() async throws {
        for shape in [BodyReaderBridge.Shape.short, .extra, .reversed, .wrongLocator] {
            let storage = try BodyReaderStorage()
            defer { storage.remove() }
            let worker = LocalWorker(database: storage.database)
            let bridge = BodyReaderBridge()
            bridge.shape = shape
            let batch = BodyReaderFixture.batch(count: 4)
            let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
            var requested = 0
            do {
                _ = try await reader.read(batch: batch, willRequest: { requested += $0 })
                XCTFail("A malformed native response must not be returned or cached: \(shape).")
            } catch let error as MailIndexError { XCTAssertEqual(error, .invalidMetadata) }
            XCTAssertEqual(requested, 4)
            XCTAssertEqual(reader.lastMetrics.bodyRequests, 4)
            XCTAssertEqual(bridge.bodyBatches, [batch])
            let response = try await BodyReaderFixture.lookup(worker: worker, locators: batch.locators)
            XCTAssertEqual(response["hits"] as? Int, 0)
            XCTAssertEqual(response["misses"] as? Int, 4)
            XCTAssertEqual(bridge.writeCalls, 0)
        }
    }

    func testWrongLiveValidationShapeDoesNotHydrateOrTrustAnyCacheHit() async throws {
        let storage = try BodyReaderStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = BodyReaderBridge()
        let batch = BodyReaderFixture.batch(count: 3)
        try await BodyReaderFixture.seed(worker: worker, locators: batch.locators)
        bridge.truncateValidation = true
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
        do {
            _ = try await reader.read(batch: batch)
            XCTFail("A malformed live metadata result must not be accepted.")
        } catch let error as MailIndexError { XCTAssertEqual(error, .invalidMetadata) }
        XCTAssertEqual(bridge.validationLocators, [batch.locators])
        XCTAssertEqual(bridge.bodyBatches, [])
        XCTAssertEqual(reader.lastMetrics.cacheHits, 0)
        XCTAssertEqual(reader.lastMetrics.bodyRequests, 0)
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testCancelledReturnedBatchCannotSaveBodiesOrReadTheNextBatch() async throws {
        let storage = try BodyReaderStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = BodyReaderBridge()
        bridge.cancelAfterHydration = true
        let rows = (0..<8).map { BodyReaderFixture.locator($0) }
        let mailbox = MailIndexMailbox(accountID: BodyReaderFixture.accountID, path: ["Sent"], name: "Sent",
            messageCount: 8, role: .sent)
        let page = MailIndexPage(mailbox: mailbox, records: rows, nextCursor: nil, scanID: BodyReaderFixture.scanID)
        let task = Task { @MainActor in
            try await MailBodyReader(mail: bridge, worker: worker, requestID: UUID()).read(page: page, selected: rows, offset: 0)
        }
        do { _ = try await task.value; XCTFail("Cancellation must be observed before cache save or the next body request.") }
        catch is CancellationError {}
        XCTAssertEqual(bridge.bodyBatches.count, 1)
        XCTAssertEqual(bridge.bodyBatches.first?.locators, Array(rows.prefix(4)))
        XCTAssertEqual(bridge.bodyBatches.first?.firstIndex, 1)
        let lookup = try await BodyReaderFixture.lookup(worker: worker, locators: Array(rows.prefix(4)))
        XCTAssertEqual(lookup["hits"] as? Int, 0)
        let overview = try await worker.call("overview") as? [String: Any]
        XCTAssertNotEqual((overview?["style_summary"] as? [String: Any])?["extraction_status"] as? String, "ready")
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testDuplicateAndOutOfPageOversizedSelectionsRejectBeforeDictionaryOrWorker() async throws {
        let storage = try BodyReaderStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = BodyReaderBridge()
        let oversized = BodyReaderFixture.locator(0, size: MailBodyBatch.maximumBytes + 1)
        let rows = [oversized, BodyReaderFixture.locator(1)]
        let mailbox = MailIndexMailbox(accountID: BodyReaderFixture.accountID, path: ["Sent"], name: "Sent",
            messageCount: 2, role: .sent)
        let page = MailIndexPage(mailbox: mailbox, records: rows, nextCursor: nil, scanID: BodyReaderFixture.scanID)
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
        let absent = BodyReaderFixture.locator(99, size: MailBodyBatch.maximumBytes + 1)
        for selected in [[oversized, oversized], [absent]] {
            do {
                _ = try await reader.read(page: page, selected: selected, offset: 0)
                XCTFail("Oversized rows still require unique identities and exact original-page membership.")
            } catch let error as MailIndexError { XCTAssertEqual(error, .invalidMetadata) }
        }
        XCTAssertEqual(bridge.bodyBatches, [])
        XCTAssertEqual(bridge.validationLocators, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.database.path),
                       "Reject malformed selection before a worker can create private runtime state.")
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testPlannerBoundsAndNegativeSizesRejectBeforeOverflowArithmetic() throws {
        let valid = BodyReaderFixture.locator(0)
        XCTAssertThrowsError(try MailBodyBatchPlanner.plan(page: [valid], selected: [valid],
            offset: Int.max, expectedCount: 1)) { error in
                XCTAssertEqual(error as? MailIndexError, .invalidMetadata)
        }
        XCTAssertThrowsError(try MailBodyBatchPlanner.plan(page: [valid], selected: [valid],
            offset: 0, expectedCount: Int.max)) { error in
                XCTAssertEqual(error as? MailIndexError, .invalidMetadata)
        }
        let negative = BodyReaderFixture.locator(0, size: Int.min)
        let next = BodyReaderFixture.locator(1)
        XCTAssertThrowsError(try MailBodyBatchPlanner.plan(page: [negative, next], selected: [negative, next],
            offset: 0, expectedCount: 2)) { error in
                XCTAssertEqual(error as? MailIndexError, .invalidLocator)
        }
    }
}

private struct BodyReaderStorage {
    let directory: URL
    var database: URL { directory.appendingPathComponent("archive.sqlite") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("harborreply-body-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private enum BodyReaderFixture {
    static let accountID = "body-reader@fixture.invalid"
    static let scanID = "body-reader-scan.invalid"
    static func locator(_ index: Int, scan: String = scanID, subject: String? = nil, size: Int = 256) -> MailIndexLocator {
        .init(accountID: accountID, mailboxPath: ["Sent"], nativeID: "\(101 + index * 37)",
              messageID: "message-\(index)@fixture.invalid", subject: subject ?? "Fictional message \(index)",
              sender: "owner@fixture.invalid", messageSize: size, role: .sent, scanID: scan)
    }
    static func batch(count: Int, scan: String = scanID, firstIndex: Int = 1, mailboxCount: Int? = nil) -> MailBodyBatch {
        .init(locators: (0..<count).map { locator($0, scan: scan) }, firstIndex: firstIndex,
              expectedMailboxCount: mailboxCount ?? count)
    }
    static func result(_ locator: MailIndexLocator, attachments: Int = 1, suffix: String = "") -> MailIndexReadResult {
        let item = MailHistoryItem(id: locator.nativeID, windowID: locator.scanID, accountID: locator.accountID,
            mailbox: locator.mailboxPath.joined(separator: "/"), messageID: locator.messageID, subject: locator.subject,
            sender: locator.sender, direction: locator.role, dateSent: locator.dateSent, dateReceived: locator.dateReceived,
            messageSize: locator.messageSize, attachmentCount: attachments)
        let target = MailTarget(id: item.id, account: item.accountID + ":" + item.mailbox, messageID: item.messageID,
            subject: item.subject, sender: item.sender, body: "Complete fictional body \(item.id). \(suffix)",
            headers: "Message-ID: <\(item.messageID)>\nFrom: \(item.sender)\nTo: recipient@fixture.invalid\n")
        return .init(locator: locator, message: .init(item: item, target: target))
    }
    @MainActor static func seed(worker: LocalWorker, locators: [MailIndexLocator]) async throws {
        let rows = try locators.map { try MailSnapshotPayload.record(result($0)) }
        _ = try await worker.call("mail_body_cache_store", ["records": rows])
    }
    @MainActor static func lookup(worker: LocalWorker, locators: [MailIndexLocator]) async throws -> [String: Any] {
        let rows = try locators.map { try MailSnapshotPayload.encode($0) }
        let value = try await worker.call("mail_body_cache_lookup", ["locators": rows])
        return try XCTUnwrap(value as? [String: Any])
    }
}

@MainActor private final class BodyReaderBridge: MailSelectionBridge {
    enum Shape { case valid, short, extra, reversed, wrongLocator }
    var shape = Shape.valid
    var rejectedNativeIDs: Set<String> = []
    var attachmentCounts: [String: Int] = [:]
    var truncateValidation = false
    var cancelAfterHydration = false
    var bodySuffix = ""
    private(set) var bodyBatches: [MailBodyBatch] = []
    private(set) var validationLocators: [[MailIndexLocator]] = []
    private(set) var validationAttachmentCounts: [[Int]] = []
    private(set) var writeCalls = 0

    func resetObservations() {
        bodyBatches = []; validationLocators = []; validationAttachmentCounts = []
    }
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult] {
        try batch.validate()
        bodyBatches.append(batch)
        let values = batch.locators.map { BodyReaderFixture.result($0, attachments: attachmentCounts[$0.nativeID] ?? 1, suffix: bodySuffix) }
        if cancelAfterHydration { withUnsafeCurrentTask { $0?.cancel() } }
        switch shape {
        case .valid: return values
        case .short: return Array(values.dropLast())
        case .extra: return values + values.prefix(1)
        case .reversed: return values.reversed()
        case .wrongLocator:
            return [BodyReaderFixture.result(BodyReaderFixture.locator(99))] + values.dropFirst()
        }
    }
    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int]) async throws -> [Bool] {
        validationLocators.append(locators); validationAttachmentCounts.append(attachmentCounts)
        let valid = locators.map { !rejectedNativeIDs.contains($0.nativeID) }
        return truncateValidation ? Array(valid.dropLast()) : valid
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
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage { throw unexpectedRead() }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] { throw unexpectedRead() }
    func styleAccounts() async throws -> [MailAccountIdentity] { throw unexpectedRead() }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] { throw unexpectedRead() }
    private func unexpectedRead() -> AppFailure { AppFailure("TEST_UNEXPECTED_MAIL_READ") }
}
