import Foundation
import XCTest
import HarborCore
@testable import HarborReply

/// These exercise the shipping reader and private SQLite worker. Only the
/// read-only Mail boundary is simulated; no Mail, preferences or model is used.
@MainActor final class MailBodyTimeoutTests: XCTestCase {
    func testBodyAndHeaderTimeoutsIsolateExactLocatorsAndCacheOnlyRecoveredBodies() async throws {
        for stage in [MailEventStage.body, .headers] {
            let storage = try TimeoutStorage()
            defer { storage.remove() }
            let worker = LocalWorker(database: storage.database)
            let batch = TimeoutFixture.batch()
            let bridge = TimeoutBridge()
            bridge.bulkFailure = TimeoutFixture.error(.indexHydrateBatch, stage)
            bridge.scalarFailures[batch.locators[1].nativeID] = TimeoutFixture.error(.indexHydrate, .body)
            bridge.unavailableIDs = [batch.locators[2].nativeID]
            let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
            var requests: [Int] = []
            let reads = try await reader.read(batch: batch, willRequest: { requests.append($0) })

            XCTAssertEqual(reads.map(\.locator), batch.locators)
            XCTAssertEqual(reads.map { $0.message != nil }, [true, false, false, true])
            XCTAssertEqual(reads[1].failure, .unavailable)
            XCTAssertEqual(reads[1].mailContext?.operation, .indexHydrate)
            XCTAssertEqual(reads[1].mailContext?.stage, .body)
            XCTAssertEqual(reads[1].mailContext?.nativeCode, -1712)
            XCTAssertEqual(reads[2].mailContext?.stage, .headers)
            XCTAssertEqual(bridge.bodyBatches, [batch])
            XCTAssertEqual(bridge.scalarLocators, batch.locators.map { [$0] })
            XCTAssertEqual(requests, [4, 1, 1, 1, 1])
            XCTAssertEqual(reader.lastMetrics.bodyRequests, 8)
            XCTAssertEqual(reader.lastMetrics.timeoutFallbacks, 1)
            XCTAssertEqual(reader.lastMetrics.recoveredBodies, 2)
            XCTAssertEqual(reader.lastMetrics.unavailableBodies, 2)
            XCTAssertGreaterThanOrEqual(reader.lastMetrics.hydrationMilliseconds, reader.lastMetrics.fallbackMilliseconds)
            let cache = try await TimeoutFixture.lookup(worker, batch.locators)
            XCTAssertEqual(cache["hits"] as? Int, 2)
            XCTAssertEqual(cache["misses"] as? Int, 2)
            XCTAssertEqual(bridge.writeCalls, 0)
        }
    }

    func testRepeatValidatesRecoveredCacheAndOnlyRetriesPreviouslyUnavailableLocators() async throws {
        let storage = try TimeoutStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let original = TimeoutFixture.batch()
        let bridge = TimeoutBridge()
        bridge.bulkFailure = TimeoutFixture.error(.indexHydrateBatch, .body)
        bridge.scalarFailures[original.locators[1].nativeID] = TimeoutFixture.error(.indexHydrate, .headers)
        bridge.unavailableIDs = [original.locators[2].nativeID]
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
        _ = try await reader.read(batch: original)
        bridge.resetObservations()
        bridge.scalarFailures = [:]; bridge.unavailableIDs = []

        let next = TimeoutFixture.batch(scan: "repeat-scan.invalid")
        let reads = try await reader.read(batch: next)
        XCTAssertEqual(reads.map(\.locator), next.locators)
        XCTAssertEqual(reads.map(\.fromCache), [true, false, false, true])
        XCTAssertEqual(bridge.validationLocators, [[next.locators[0], next.locators[3]]])
        XCTAssertEqual(bridge.bodyBatches.count, 1)
        XCTAssertEqual(bridge.bodyBatches.first?.locators, Array(next.locators[1...2]))
        XCTAssertEqual(bridge.bodyBatches.first?.firstIndex, 12)
        XCTAssertEqual(bridge.bodyBatches.first?.expectedMailboxCount, 20)
        XCTAssertEqual(bridge.scalarLocators, next.locators[1...2].map { [$0] })
        XCTAssertEqual(reader.lastMetrics.bodyRequests, 4)
        XCTAssertEqual(reader.lastMetrics.recoveredBodies, 2)
        XCTAssertEqual(reader.lastMetrics.cacheHits, 2)

        bridge.resetObservations()
        let cached = try await reader.read(batch: next)
        XCTAssertTrue(cached.allSatisfy(\.fromCache))
        XCTAssertEqual(bridge.validationLocators, [next.locators])
        XCTAssertEqual(bridge.bodyBatches, [])
        XCTAssertEqual(bridge.scalarLocators, [])
        XCTAssertEqual(reader.lastMetrics.bodyRequests, 0)
        XCTAssertEqual(reader.lastMetrics.timeoutFallbacks, 0)
        XCTAssertEqual(bridge.writeCalls, 0)
        let cache = try await TimeoutFixture.lookup(worker, next.locators)
        XCTAssertEqual(cache["hits"] as? Int, 4)
    }

    func testMetadataIdentityPermissionsShapesAndUntypedErrorsNeverTriggerFallback() async throws {
        let failures: [AppFailure] = [
            TimeoutFixture.error(.indexHydrateBatch, .body, number: -1743),
            TimeoutFixture.error(.indexHydrateBatch, .body, number: -1700),
            TimeoutFixture.error(.indexHydrateBatch, .metadata),
            TimeoutFixture.error(.indexHydrateBatch, .metadataNativeID),
            TimeoutFixture.error(.indexHydrateBatch, .messageCount),
            TimeoutFixture.error(.indexHydrateBatch, .attachments),
            TimeoutFixture.error(.indexHydrateBatch, .body, shape: true),
            TimeoutFixture.error(.indexHydrate, .body),
            AppFailure("MAIL_INDEX_HYDRATE_BATCH_BODY_EVENT_-1712")
        ]
        for failure in failures {
            let storage = try TimeoutStorage()
            defer { storage.remove() }
            let worker = LocalWorker(database: storage.database)
            let bridge = TimeoutBridge(); bridge.bulkFailure = failure
            let batch = TimeoutFixture.batch()
            let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
            do {
                _ = try await reader.read(batch: batch)
                XCTFail("Only the typed content-get timeout permits another read.")
            } catch let error as AppFailure { XCTAssertEqual(error.code, failure.code) }
            XCTAssertEqual(bridge.bodyBatches, [batch])
            XCTAssertEqual(bridge.scalarLocators, [])
            XCTAssertEqual(reader.lastMetrics.bodyRequests, 4)
            XCTAssertEqual(reader.lastMetrics.timeoutFallbacks, 0)
            let cache = try await TimeoutFixture.lookup(worker, batch.locators)
            XCTAssertEqual(cache["hits"] as? Int, 0)
            XCTAssertEqual(bridge.writeCalls, 0)
        }
    }

    func testMalformedBulkResponseDoesNotUseScalarCompatibilityRetry() async throws {
        for shape in [TimeoutBridge.Shape.empty, .extra, .wrongLocator] {
            let storage = try TimeoutStorage()
            defer { storage.remove() }
            let worker = LocalWorker(database: storage.database)
            let bridge = TimeoutBridge(); bridge.bulkShape = shape
            let batch = TimeoutFixture.batch()
            let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
            do { _ = try await reader.read(batch: batch); XCTFail("Malformed bulk data must be rejected.") }
            catch let error as MailIndexError { XCTAssertEqual(error, .invalidMetadata) }
            XCTAssertEqual(bridge.scalarLocators, [])
            XCTAssertEqual(reader.lastMetrics.timeoutFallbacks, 0)
            let cache = try await TimeoutFixture.lookup(worker, batch.locators)
            XCTAssertEqual(cache["hits"] as? Int, 0)
        }
    }

    func testWrongScalarLocatorOrShapeRejectsWholeRetryWithoutSavingEarlierRecoveredBody() async throws {
        for shape in [TimeoutBridge.Shape.empty, .extra, .wrongLocator] {
            let storage = try TimeoutStorage()
            defer { storage.remove() }
            let worker = LocalWorker(database: storage.database)
            let bridge = TimeoutBridge()
            let batch = TimeoutFixture.batch()
            bridge.bulkFailure = TimeoutFixture.error(.indexHydrateBatch, .body)
            bridge.scalarShapes[batch.locators[1].nativeID] = shape
            let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
            do { _ = try await reader.read(batch: batch); XCTFail("Unmatched scalar data must be rejected.") }
            catch let error as MailIndexError { XCTAssertEqual(error, .invalidMetadata) }
            XCTAssertEqual(bridge.scalarLocators, batch.locators.prefix(2).map { [$0] })
            XCTAssertEqual(reader.lastMetrics.bodyRequests, 6)
            let cache = try await TimeoutFixture.lookup(worker, batch.locators)
            XCTAssertEqual(cache["hits"] as? Int, 0)
            XCTAssertEqual(bridge.writeCalls, 0)
        }
    }

    func testScalarPermissionOrMetadataFailureStopsRemainingRetriesAndKeepsExistingCache() async throws {
        for failure in [TimeoutFixture.error(.indexHydrate, .body, number: -1743),
                        TimeoutFixture.error(.indexHydrate, .metadata),
                        TimeoutFixture.error(.indexHydrate, .body, shape: true)] {
            let storage = try TimeoutStorage()
            defer { storage.remove() }
            let worker = LocalWorker(database: storage.database)
            let bridge = TimeoutBridge()
            let batch = TimeoutFixture.batch()
            try await TimeoutFixture.seed(worker, [batch.locators[0]])
            bridge.bulkFailure = TimeoutFixture.error(.indexHydrateBatch, .body)
            bridge.scalarFailures[batch.locators[1].nativeID] = failure
            let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
            do { _ = try await reader.read(batch: batch); XCTFail("A safety failure cannot become unavailable content.") }
            catch let error as AppFailure { XCTAssertEqual(error.code, failure.code) }
            XCTAssertEqual(bridge.scalarLocators, [[batch.locators[1]]])
            XCTAssertEqual(reader.lastMetrics.bodyRequests, 4)
            XCTAssertEqual(reader.lastMetrics.unavailableBodies, 0)
            let cache = try await TimeoutFixture.lookup(worker, batch.locators)
            XCTAssertEqual(cache["hits"] as? Int, 1)
            XCTAssertEqual(bridge.writeCalls, 0)
        }
    }

    func testCancellationDuringIsolationPreventsNextReadAndUncommittedCacheSave() async throws {
        let storage = try TimeoutStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = TimeoutBridge()
        let batch = TimeoutFixture.batch()
        bridge.bulkFailure = TimeoutFixture.error(.indexHydrateBatch, .body)
        bridge.cancelAfterScalar = 1
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
        let task = Task { @MainActor in try await reader.read(batch: batch) }
        do { _ = try await task.value; XCTFail("Cancelled acquisition must not continue or save.") }
        catch is CancellationError {}
        XCTAssertEqual(bridge.scalarLocators, [[batch.locators[0]]])
        XCTAssertEqual(reader.lastMetrics.bodyRequests, 5)
        let cache = try await TimeoutFixture.lookup(worker, batch.locators)
        XCTAssertEqual(cache["hits"] as? Int, 0)
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testCancellationDuringBulkTimeoutPreventsAnyRetry() async throws {
        let storage = try TimeoutStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = TimeoutBridge()
        let batch = TimeoutFixture.batch()
        bridge.bulkFailure = TimeoutFixture.error(.indexHydrateBatch, .body)
        bridge.cancelAfterBulk = true
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: UUID())
        let task = Task { @MainActor in try await reader.read(batch: batch) }
        do { _ = try await task.value; XCTFail("A timeout after cancellation must not trigger retries.") }
        catch is CancellationError {}
        XCTAssertEqual(bridge.scalarLocators, [])
        XCTAssertEqual(reader.lastMetrics.bodyRequests, 4)
        XCTAssertEqual(reader.lastMetrics.timeoutFallbacks, 0)
        let cache = try await TimeoutFixture.lookup(worker, batch.locators)
        XCTAssertEqual(cache["hits"] as? Int, 0)
    }

    func testFailedBulkDurationAndSeparateScalarRetryDurationAreRecorded() async throws {
        let storage = try TimeoutStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = TimeoutBridge()
        let batch = TimeoutFixture.batch()
        bridge.bulkFailure = TimeoutFixture.error(.indexHydrateBatch, .body)
        bridge.bulkDelayNanoseconds = 8_000_000
        bridge.scalarDelayNanoseconds = 2_000_000
        let request = UUID()
        let reader = MailBodyReader(mail: bridge, worker: worker, requestID: request)
        _ = try await reader.read(batch: batch, useCache: false)
        let spans = Diagnostics.log.recentTimings().filter { $0.request == request }
        let failedBulk = try XCTUnwrap(spans.first { $0.timingStage == .bodyBulkRead })
        XCTAssertGreaterThan(try XCTUnwrap(failedBulk.elapsedMilliseconds), 0)
        XCTAssertEqual(failedBulk.count, 4)
        XCTAssertEqual(spans.filter { $0.timingStage == .bodyScalarRetry }.count, 4)
        XCTAssertGreaterThan(reader.lastMetrics.fallbackMilliseconds, 0)
        XCTAssertGreaterThan(reader.lastMetrics.hydrationMilliseconds, reader.lastMetrics.fallbackMilliseconds)
    }

    func testNewRecoveryMetricsDecodeOlderReportsWithoutInventingCounts() throws {
        let old: [String: Int] = ["lookupMilliseconds": 1, "validationMilliseconds": 2,
            "hydrationMilliseconds": 3, "saveMilliseconds": 4, "cacheHits": 5,
            "cacheMisses": 6, "bodyRequests": 7]
        let value = try JSONDecoder().decode(MailBodyReadMetrics.self,
            from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(value.fallbackMilliseconds, 0)
        XCTAssertEqual(value.timeoutFallbacks, 0)
        XCTAssertEqual(value.recoveredBodies, 0)
        XCTAssertEqual(value.unavailableBodies, 0)
        XCTAssertEqual(value.bodyRequests, 7)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(MailBodyReadMetrics.self, from: data)
        XCTAssertEqual(decoded.fallbackMilliseconds, 0)
    }

    func testStyleResumeUsesAcknowledgedOffsetWithoutDuplicatingHeaderOrSampleCounters() async throws {
        let storage = try TimeoutStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = ResumeBoundaryBridge()
        let cancelled = Task { @MainActor in
            try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
                account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 4_096) { value in
                    if value.activity == .savingSamples && value.adoptedSamples == 4 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
        }
        do { _ = try await cancelled.value; XCTFail("The first acknowledged group must remain resumable.") }
        catch is CancellationError {}
        let retained = try await TimeoutFixture.styleStatus(worker)
        let captureID = try XCTUnwrap(retained["capture_id"] as? String)
        XCTAssertEqual((retained["counts"] as? [String: Int])?["candidates_checked"], 8)
        XCTAssertEqual((retained["counts"] as? [String: Int])?["captured"], 4)
        XCTAssertEqual(retained["pages"] as? Int, 1)
        XCTAssertEqual((retained["checkpoint"] as? [String: Any])?["nextBodyOffset"] as? Int, 4)
        bridge.resetObservations()
        let result = try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
            account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 4_096, progress: { _ in })
        XCTAssertEqual((result as? [String: Any])?["extraction_status"] as? String, "ready")
        let published = try await TimeoutFixture.styleStatus(worker)
        XCTAssertEqual(published["capture_id"] as? String, captureID)
        XCTAssertEqual((published["counts"] as? [String: Int])?["candidates_checked"], 8)
        XCTAssertEqual((published["counts"] as? [String: Int])?["records_received"], 8)
        XCTAssertEqual((published["counts"] as? [String: Int])?["captured"], 8)
        XCTAssertEqual(published["pages"] as? Int, 2)
        XCTAssertEqual(bridge.headerOffsets, [], "Use acknowledged sender/size candidates locally; do not re-identify the saved page.")
        XCTAssertEqual(bridge.bodyBatches.map { $0.candidates.map(\.position) }, [[5, 6, 7, 8]])
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertEqual(bridge.legacyReadCalls, 0)
    }

    func testStyleResumeCollectsCurrentRemainingContentWithoutReidentifyingSavedSamples() async throws {
        let storage = try TimeoutStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = ResumeBoundaryBridge()
        let cancelled = Task { @MainActor in
            try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
                account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 4_096) { value in
                    if value.activity == .savingSamples && value.adoptedSamples == 4 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
        }
        do { _ = try await cancelled.value; XCTFail("Stop at the acknowledged continuation.") }
        catch is CancellationError {}
        bridge.resetObservations(); bridge.changedBody = true
        let result = try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
            account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 4_096, progress: { _ in })
        XCTAssertEqual((result as? [String: Any])?["extraction_status"] as? String, "ready")
        XCTAssertEqual(bridge.bodyBatches.map { $0.candidates.map(\.position) }, [[5, 6, 7, 8]])
        let retained = try await TimeoutFixture.styleStatus(worker)
        XCTAssertEqual((retained["counts"] as? [String: Int])?["captured"], 8)
        XCTAssertEqual((retained["counts"] as? [String: Int])?["candidates_checked"], 8)
        XCTAssertEqual(retained["pages"] as? Int, 2)
        XCTAssertEqual(bridge.legacyReadCalls, 0, "A content snapshot never re-identifies or validates the already committed prefix.")
        XCTAssertEqual(bridge.writeCalls, 0)
    }

    func testCompletedStyleAcquisitionRetriesAnalysisWithoutAnyMailCall() async throws {
        let storage = try TimeoutStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = ResumeBoundaryBridge()
        let cancelled = Task { @MainActor in
            try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
                account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 4_096) { value in
                    if value.phase == .analyzing { withUnsafeCurrentTask { $0?.cancel() } }
                }
        }
        do { _ = try await cancelled.value; XCTFail("Cancel between acquisition and local publication.") }
        catch is CancellationError {}
        let acquired = try await TimeoutFixture.styleStatus(worker)
        let captureID = try XCTUnwrap(acquired["capture_id"] as? String)
        XCTAssertEqual(acquired["acquisition_done"] as? Bool, true)
        XCTAssertEqual((acquired["counts"] as? [String: Int])?["captured"], 8)
        bridge.resetObservations(); bridge.forbidReads = true
        let result = try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
            account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 4_096, progress: { _ in })
        XCTAssertEqual((result as? [String: Any])?["extraction_status"] as? String, "ready")
        let published = try await TimeoutFixture.styleStatus(worker)
        XCTAssertEqual(published["capture_id"] as? String, captureID)
        XCTAssertEqual(published["pages"] as? Int, 2)
        XCTAssertEqual(bridge.mailboxCalls, 0)
        XCTAssertEqual(bridge.headerOffsets, [])
        XCTAssertEqual(bridge.bodyBatches, [])
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertEqual(bridge.legacyReadCalls, 0)
    }

    func testStyleReadLimitWithRoomForOneAttemptRefusesTwoAttemptFallbackBatch() async throws {
        let storage = try TimeoutStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = ResumeBoundaryBridge()
        let startedValue = try await worker.call("style_capture_start", [
            "account_id": bridge.account.id, "address": bridge.owner, "own_addresses": bridge.account.addresses,
            "author_confirmed": true, "token_budget": 4_096])
        let started = try XCTUnwrap(startedValue as? [String: Any])
        let captureID = try XCTUnwrap(started["capture_id"] as? String)
        let readBytes = SentStyleReadBudget.defaultMaximumReadBytes
        // Numeric test setup: leave exactly one worst-case read, which cannot
        // authorize the initial body request plus its one permitted retry.
        let first = UUID().uuidString
        _ = try await worker.call("style_capture_read_reserve", ["capture_id": captureID, "attempt_id": first, "reads": 28])
        _ = try await worker.call("style_capture_read_charge", ["capture_id": captureID, "attempt_id": first,
            "captured_bytes": 27 * readBytes])
        let second = UUID().uuidString
        _ = try await worker.call("style_capture_read_reserve", ["capture_id": captureID, "attempt_id": second, "reads": 3])
        _ = try await worker.call("style_capture_read_charge", ["capture_id": captureID, "attempt_id": second,
            "captured_bytes": SentStyleReadBudget.defaultMaximumCapturedBytes - readBytes - 27 * readBytes])
        var observations: [StyleCaptureProgress] = []
        do {
            _ = try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
                account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 4_096,
                progress: { observations.append($0) })
            XCTFail("No samples were acquired and none may be fabricated at the read limit.")
        } catch let error as AppFailure { XCTAssertEqual(error.baseCode, "STYLE_INDEXED_SENT_EXAMPLES_REQUIRED") }
        XCTAssertEqual(observations.first { $0.activity == .finishingAcquisition }?.stopReason, .readLimit)
        XCTAssertFalse(observations.contains { $0.stopReason == .sourceExhausted })
        XCTAssertEqual(bridge.bodyBatches, [], "Header discovery does not authorize a body GET beyond the 2N bound.")
        let status = try await TimeoutFixture.styleStatus(worker)
        XCTAssertEqual((status["coverage"] as? [String: Any])?["source_exhausted"] as? Bool, false)
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertEqual(bridge.legacyReadCalls, 0)
    }

    func testMalformedOrInvalidVersionedContinuationUsesFixedCheckpointCodeBeforeMail() async throws {
        for malformedJSON in [true, false] {
            let storage = try TimeoutStorage()
            defer { storage.remove() }
            let worker = LocalWorker(database: storage.database)
            let bridge = ResumeBoundaryBridge()
            let cancelled = Task { @MainActor in
                try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
                    account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 4_096) { value in
                        if value.activity == .savingSamples && value.adoptedSamples == 4 {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    }
            }
            do { _ = try await cancelled.value; XCTFail("Retain a valid acknowledged continuation first.") }
            catch is CancellationError {}
            let stateValue = try await worker.call("style_capture_start", [
                "account_id": bridge.account.id, "address": bridge.owner, "own_addresses": bridge.account.addresses,
                "author_confirmed": true, "token_budget": 4_096, "restart": false])
            let state = try XCTUnwrap(stateValue as? [String: Any])
            let captureID = try XCTUnwrap(state["capture_id"] as? String)
            let previous = try XCTUnwrap(state["checkpoint"] as? [String: Any])
            var changed = previous
            if malformedJSON { changed.removeValue(forKey: "pageCursor") }
            else { changed["nextBodyOffset"] = 999 }
            _ = try await worker.call("style_capture_content_page", ["capture_id": captureID,
                "expected_checkpoint": previous, "checkpoint": changed, "records": [], "candidates_checked": 0])
            bridge.resetObservations(); bridge.forbidReads = true
            do {
                _ = try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
                    account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 4_096, progress: { _ in })
                XCTFail("An invalid continuation must not authorize another Mail read.")
            } catch let error as AppFailure { XCTAssertEqual(error.code, "STYLE_CAPTURE_CHECKPOINT_CHANGED") }
            XCTAssertEqual(bridge.mailboxCalls, 0)
            XCTAssertEqual(bridge.headerOffsets, [])
            XCTAssertEqual(bridge.bodyBatches, [])
            XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertEqual(bridge.legacyReadCalls, 0)
        }
    }

    func testAcknowledgedTokenLimitFinishesAfterCancellationWithoutAnotherMailCall() async throws {
        let storage = try TimeoutStorage()
        defer { storage.remove() }
        let worker = LocalWorker(database: storage.database)
        let bridge = ResumeBoundaryBridge()
        let cancelled = Task { @MainActor in
            try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
                account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 128) { value in
                    if value.activity == .savingSamples && value.adoptedSamples == 2 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
        }
        do { _ = try await cancelled.value; XCTFail("Stop after the limit is acknowledged but before acquisition finish.") }
        catch is CancellationError {}
        let retained = try await TimeoutFixture.styleStatus(worker)
        let captureID = try XCTUnwrap(retained["capture_id"] as? String)
        XCTAssertEqual(retained["budget_reached"] as? Bool, true)
        XCTAssertEqual(retained["acquisition_done"] as? Bool, false)
        XCTAssertEqual((retained["counts"] as? [String: Int])?["captured"], 2)
        bridge.resetObservations(); bridge.forbidReads = true
        var observations: [StyleCaptureProgress] = []
        let result = try await LegacyStyleCapture(mail: bridge, worker: worker, requestID: UUID()).run(
            account: bridge.account, address: bridge.owner, shared: [], tokenBudget: 128,
            progress: { observations.append($0) })
        XCTAssertEqual((result as? [String: Any])?["extraction_status"] as? String, "ready")
        XCTAssertEqual(observations.last?.phase, .completed)
        XCTAssertEqual(observations.last?.stopReason, .tokenBudget)
        let published = try await TimeoutFixture.styleStatus(worker)
        XCTAssertEqual(published["capture_id"] as? String, captureID)
        XCTAssertEqual(published["pages"] as? Int, 1)
        XCTAssertEqual((published["counts"] as? [String: Int])?["captured"], 2)
        XCTAssertEqual((published["coverage"] as? [String: Any])?["source_exhausted"] as? Bool, false)
        XCTAssertEqual(bridge.mailboxCalls, 0)
        XCTAssertEqual(bridge.headerOffsets, [])
        XCTAssertEqual(bridge.bodyBatches, [])
        XCTAssertEqual(bridge.writeCalls, 0)
        XCTAssertEqual(bridge.legacyReadCalls, 0)
    }
}

private struct TimeoutStorage {
    let directory: URL
    var database: URL { directory.appendingPathComponent("archive.sqlite") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("harborreply-body-timeout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private enum TimeoutFixture {
    static func locator(_ index: Int, scan: String = "timeout-scan.invalid") -> MailIndexLocator {
        .init(accountID: "timeout-account@fixture.invalid", mailboxPath: ["Sent"], nativeID: "\(301 + 17 * index)",
              messageID: "timeout-\(index)@fixture.invalid", subject: "Fictional message \(index)",
              sender: "owner@fixture.invalid", messageSize: 256, role: .sent, scanID: scan)
    }
    static func batch(scan: String = "timeout-scan.invalid") -> MailBodyBatch {
        .init(locators: (0..<4).map { locator($0, scan: scan) }, firstIndex: 11, expectedMailboxCount: 20)
    }
    static func result(_ locator: MailIndexLocator) -> MailIndexReadResult {
        let item = MailHistoryItem(id: locator.nativeID, windowID: locator.scanID, accountID: locator.accountID,
            mailbox: locator.mailboxPath.joined(separator: "/"), messageID: locator.messageID, subject: locator.subject,
            sender: locator.sender, direction: locator.role, messageSize: locator.messageSize, attachmentCount: 1)
        let target = MailTarget(id: item.id, account: item.accountID + ":" + item.mailbox, messageID: item.messageID,
            subject: item.subject, sender: item.sender, body: "Complete fictional body \(item.id).",
            headers: "Message-ID: <\(item.messageID)>\nFrom: \(item.sender)\nTo: recipient@fixture.invalid\n")
        return .init(locator: locator, message: .init(item: item, target: target))
    }
    static func error(_ operation: MailEventOperation, _ stage: MailEventStage,
                      number: Int = -1712, shape: Bool = false) -> AppFailure {
        let context = MailEventContext(operation: operation, stage: stage, nativeCode: number, isShapeFailure: shape)
        return AppFailure(context.code, mailContext: context)
    }
    @MainActor static func seed(_ worker: LocalWorker, _ locators: [MailIndexLocator]) async throws {
        _ = try await worker.call("mail_body_cache_store", ["records": try locators.map { try MailSnapshotPayload.record(result($0)) }])
    }
    @MainActor static func lookup(_ worker: LocalWorker, _ locators: [MailIndexLocator]) async throws -> [String: Any] {
        let value = try await worker.call("mail_body_cache_lookup", ["locators": try locators.map(MailSnapshotPayload.encode)])
        return try XCTUnwrap(value as? [String: Any])
    }
    @MainActor static func styleStatus(_ worker: LocalWorker) async throws -> [String: Any] {
        let response = try await worker.call("style_capture_status")
        return try XCTUnwrap(response as? [String: Any])
    }
}

@MainActor private final class TimeoutBridge: MailSelectionBridge {
    enum Shape { case valid, empty, extra, wrongLocator }
    var bulkFailure: AppFailure?
    var scalarFailures: [String: AppFailure] = [:]
    var unavailableIDs: Set<String> = []
    var bulkShape = Shape.valid
    var scalarShapes: [String: Shape] = [:]
    var cancelAfterBulk = false
    var cancelAfterScalar: Int?
    var bulkDelayNanoseconds: UInt64 = 0
    var scalarDelayNanoseconds: UInt64 = 0
    private(set) var bodyBatches: [MailBodyBatch] = []
    private(set) var scalarLocators: [[MailIndexLocator]] = []
    private(set) var validationLocators: [[MailIndexLocator]] = []
    private(set) var writeCalls = 0

    func resetObservations() { bodyBatches = []; scalarLocators = []; validationLocators = [] }
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult] {
        try batch.validate()
        bodyBatches.append(batch)
        if bulkDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: bulkDelayNanoseconds) }
        if cancelAfterBulk { withUnsafeCurrentTask { $0?.cancel() } }
        if let bulkFailure { throw bulkFailure }
        return shaped(batch.locators.map(TimeoutFixture.result), as: bulkShape)
    }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] {
        scalarLocators.append(locators)
        if scalarDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: scalarDelayNanoseconds) }
        guard locators.count == 1, let locator = locators.first else { throw unexpectedRead() }
        if scalarLocators.count == cancelAfterScalar { withUnsafeCurrentTask { $0?.cancel() } }
        if let failure = scalarFailures[locator.nativeID] { throw failure }
        if unavailableIDs.contains(locator.nativeID) {
            return [.init(locator: locator, failure: .unavailable,
                mailContext: TimeoutFixture.error(.indexHydrate, .headers).mailContext)]
        }
        return shaped([TimeoutFixture.result(locator)], as: scalarShapes[locator.nativeID] ?? .valid)
    }
    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int]) async throws -> [Bool] {
        guard locators.count == attachmentCounts.count else { throw MailIndexError.invalidMetadata }
        validationLocators.append(locators)
        return locators.map { _ in true }
    }
    private func shaped(_ values: [MailIndexReadResult], as shape: Shape) -> [MailIndexReadResult] {
        switch shape {
        case .valid: return values
        case .empty: return []
        case .extra: return values + values.prefix(1)
        case .wrongLocator: return [TimeoutFixture.result(TimeoutFixture.locator(99))] + values.dropFirst()
        }
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
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage { throw unexpectedRead() }
    func styleAccounts() async throws -> [MailAccountIdentity] { throw unexpectedRead() }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] { throw unexpectedRead() }
    private func unexpectedRead() -> AppFailure { AppFailure("TEST_UNEXPECTED_MAIL_READ") }
}

@MainActor private final class ResumeBoundaryBridge: MailSelectionBridge {
    let owner = "owner@resume-boundary.invalid"
    let account = MailAccountIdentity(id: "resume-account.invalid", name: "Resume boundary", addresses: ["owner@resume-boundary.invalid"])
    var changedBody = false
    var forbidReads = false
    private(set) var mailboxCalls = 0
    private(set) var headerOffsets: [Int] = []
    private(set) var bodyBatches: [StyleContentBatch] = []
    private(set) var legacyReadCalls = 0
    private(set) var writeCalls = 0
    private var box: MailIndexMailbox {
        .init(accountID: account.id, path: ["Sent"], name: "Sent", messageCount: 8, role: .sent)
    }
    func resetObservations() { mailboxCalls = 0; headerOffsets = []; bodyBatches = [] }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] {
        guard !forbidReads, accountID == account.id else { throw unexpectedRead() }
        mailboxCalls += 1; return [box]
    }
    func styleCandidates(cursor: MailIndexCursor, limit: Int) async throws -> StyleCandidatePage {
        guard !forbidReads else { throw unexpectedRead() }
        headerOffsets.append(cursor.offset)
        let rows = (cursor.offset..<min(8, cursor.offset + limit)).map {
            StyleCandidate(position: $0 + 1, sender: owner, messageSize: 256)
        }
        let nextOffset = cursor.offset + rows.count
        let next = nextOffset < 8 ? MailIndexCursor(accountID: cursor.accountID, mailboxPath: cursor.mailboxPath,
            offset: nextOffset, expectedCount: cursor.expectedCount, scanID: cursor.scanID, role: cursor.role) : nil
        return .init(cursor: cursor, records: rows, nextCursor: next, mailbox: box)
    }
    func styleContents(batch: StyleContentBatch) async throws -> [StyleContentRead] {
        guard !forbidReads else { throw unexpectedRead() }
        bodyBatches.append(batch)
        return batch.candidates.map { candidate in
            let body = changedBody && candidate.position == 8 ? "Changed fictional response 8." :
                "Distinct fictional response \(candidate.position)."
            return .init(candidate: candidate, body: body)
        }
    }
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage {
        legacyReadCalls += 1; throw unexpectedRead()
    }
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult] {
        legacyReadCalls += 1; throw unexpectedRead()
    }
    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int]) async throws -> [Bool] {
        legacyReadCalls += 1; throw unexpectedRead()
    }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] {
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
    func styleAccounts() async throws -> [MailAccountIdentity] { throw unexpectedRead() }
    private func unexpectedRead() -> AppFailure { AppFailure("TEST_UNEXPECTED_MAIL_READ") }
}
