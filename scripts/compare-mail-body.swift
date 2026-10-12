import AppKit
import Darwin
import Foundation
import HarborCore

// External opt-in benchmark only. The product has no benchmark/demo CLI.
// Locators and message contents are used in memory and in a wrapper-owned 0700
// cache, never in this fixed aggregate report, arguments or diagnostics.
private enum ComparisonPhase: String, Codable {
    case discovery, scalarFirst, bulkSecond, cacheWarm, bulkFirst, scalarSecond
    case scalarComparable, bulkComparable, cacheComparable
}
private enum ComparisonOutcome: String, Codable { case passed, partial, blocked, failed, skipped }
private enum BlockReason: String, Codable {
    case senderNotConfigured, configuredSenderMissing, noContiguousSample, totalDeadline
}
private struct ComparisonFailure: Codable {
    let category: DiagnosticFailureCode
    let operation: MailEventOperation?
    let stage: MailEventStage?
    let nativeCode: Int?
    let cancelled: Bool
    init(_ error: Error) {
        let value = error as? AppFailure
        category = value?.diagnosticFailure ?? .unknown
        operation = value?.mailContext?.operation
        stage = value?.mailContext?.stage
        nativeCode = value?.mailContext?.nativeCode
        cancelled = error is CancellationError
    }
}
private struct ComparisonSpan: Codable {
    let stage: DiagnosticTimingStage
    let samples: Int
    let totalMilliseconds: Int
    let maximumMilliseconds: Int
}
private struct ComparisonReadFailure: Codable {
    let failure: MailIndexFailure
    let operation: MailEventOperation?
    let stage: MailEventStage?
    let nativeCode: Int?
}
private struct ComparisonMeasurement: Codable {
    let phase: ComparisonPhase
    let outcome: ComparisonOutcome
    let milliseconds: Double
    let requested: Int
    let responses: Int
    let captured: Int
    let sourceBytes: Int
    let matchesScalar: Bool?
    let commonComparedMessages: Int
    let matchesBulk: Bool?
    let bulkComparedMessages: Int
    let readFailures: [ComparisonReadFailure]
    let deadlineReached: Bool
    let failure: ComparisonFailure?
    let cache: MailBodyReadMetrics?
    let native: [MailBodyBatchMetrics]
    let spans: [ComparisonSpan]
}
private struct ComparisonReport: Codable {
    let schemaVersion = 2
    let realMailConsent = true
    let phaseDeadlineSeconds = 90
    let totalDeadlineSeconds = 180
    let maximumMessages = 4
    let maximumMetadataRecords = 32
    let maximumDeclaredSourceBytes = 2 * 1_024 * 1_024
    let fullArchiveTested = false
    let mailWritesExecuted = false
    let ownerStateWritten = false
    let modelCalled = false
    let keychainRead = false
    let uiAccepted = false
    let directMailStorageRead = false
    let networkProviderCalled = false
    let equalityIncludesBodyHeadersAndAttachments = true
    let equalityExcludesCacheOriginAnnotation = true
    let equalityComparesOnlyCommonSuccessfullyCapturedMessages = true
    let cacheWarmUsesLiveMetadataButDoesNotRefetchSourceBytes = true
    let nativeRangesMayFallBack = true
    let phasesContainNestedTimings = true
    let comparableSubsetSelectedAfterInitialReadResults = true
    let outcome: ComparisonOutcome
    let blockedReason: BlockReason?
    let selectedMessages: Int
    let metadataRecordsExamined: Int
    let milliseconds: Double
    let privateStateRemoved: Bool
    let measurements: [ComparisonMeasurement]
}
private struct ComparisonClock {
    private let start = DispatchTime.now().uptimeNanoseconds
    var milliseconds: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
}

// Wrap the identity-bearing native facade, forwarding all read APIs. Any future
// accidental draft mutation fails closed at the harness boundary.
@MainActor private final class ComparisonReadOnlyMail: MailSelectionBridge {
    private let live = AppleMailBridge()
    private(set) var writesAttempted = 0
    func clearTracking() { live.clearTracking() }
    func canCaptureWithoutPrompt() async -> Bool { await live.canCaptureWithoutPrompt() }
    func capture() async throws -> MailTarget { try await live.capture() }
    func createReply(to: MailTarget, replyAll: Bool, requestID: UUID) async throws -> DraftSnapshot {
        writesAttempted += 1; throw AppFailure("COMPARISON_MAIL_WRITES_FORBIDDEN")
    }
    func snapshot() async throws -> DraftSnapshot { throw AppFailure("COMPARISON_MAIL_WRITES_FORBIDDEN") }
    func insert(_ text: String, expected: DraftSnapshot) async throws {
        writesAttempted += 1; throw AppFailure("COMPARISON_MAIL_WRITES_FORBIDDEN")
    }
    func history(for target: MailTarget?, limit: Int) async throws -> MailHistoryWindow { try await live.history(for: target, limit: limit) }
    func hydrate(records: [MailHistoryItem]) async throws -> [MailHistoryMessage] { try await live.hydrate(records: records) }
    func indexMailboxes(after cursor: MailMailboxCursor?, limit: Int) async throws -> MailMailboxPage {
        try await live.indexMailboxes(after: cursor, limit: limit)
    }
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage { try await live.indexPage(cursor: cursor, limit: limit) }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] { try await live.hydrateIndexed(locators: locators) }
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult] { try await live.hydrateIndexedBatch(batch) }
    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int]) async throws -> [Bool] {
        try await live.validateCachedIndexed(locators: locators, attachmentCounts: attachmentCounts)
    }
    func bodyReadMetrics() async -> [MailBodyBatchMetrics] { await live.bodyReadMetrics() }
    func styleAccounts() async throws -> [MailAccountIdentity] { try await live.styleAccounts() }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] { try await live.styleMailboxes(accountID: accountID) }
}

// Side effects, phase deadlines and private temporary state have shared identity;
// all report values above are immutable and contain no free-form error strings.
@MainActor private final class MailBodyComparison {
    private let mail: ComparisonReadOnlyMail
    private let reader: MailBodyReader
    private let elapsed = ComparisonClock()
    private var measurements: [ComparisonMeasurement] = []
    private var metadataCount = 0
    private var selectedCount = 0
    private var blockedReason: BlockReason?
    private var baseline: [MailIndexReadResult]?
    private var bulkReference: [MailIndexReadResult]?
    private var lastCache = MailBodyReadMetrics.empty
    private var outcome = ComparisonOutcome.blocked

    init(directory: URL) {
        let mail = ComparisonReadOnlyMail()
        self.mail = mail
        reader = MailBodyReader(mail: mail, worker: LocalWorker(database: directory.appendingPathComponent("isolated.sqlite")), requestID: UUID())
    }
    private func spans(since timestamp: Date) -> [ComparisonSpan] {
        let records = Diagnostics.log.recentTimings().filter { $0.timestamp >= timestamp }
        return DiagnosticTimingStage.allCases.compactMap { stage in
            let values = records.filter { $0.timingStage == stage }.compactMap(\.elapsedMilliseconds)
            return values.isEmpty ? nil : ComparisonSpan(stage: stage, samples: values.count,
                totalMilliseconds: values.reduce(0, +), maximumMilliseconds: values.max() ?? 0)
        }
    }
    private func bounded<Value>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> (Value, Bool) {
        let remaining = min(90_000, max(0, 180_000 - Int(elapsed.milliseconds)))
        guard remaining > 0 else { throw CancellationError() }
        let task = Task { @MainActor in try await operation() }
        var expired = false
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(remaining)) }
            catch { return }
            expired = true; task.cancel()
        }
        defer { timeout.cancel() }
        return (try await task.value, expired)
    }
    private func sample() async throws -> MailBodyBatch? {
        let settings = Settings.load() // Read only; no Keychain or owner archive.
        guard let accountID = settings.styleAccountID,
              let address = settings.styleSenderAddress.flatMap(SentStyleSelection.address),
              !settings.sharedAddresses.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
                .compactMap({ SentStyleSelection.address(String($0)) }).contains(address) else {
            blockedReason = .senderNotConfigured; return nil
        }
        let accounts = try await mail.styleAccounts()
        guard let account = accounts.first(where: { $0.id == accountID }),
              account.addresses.compactMap(SentStyleSelection.address).contains(address) else {
            blockedReason = .configuredSenderMissing; return nil
        }
        let boxes = try await mail.styleMailboxes(accountID: account.id)
        guard boxes.count <= MailIndexLimits.folders,
              boxes.allSatisfy({ $0.accountID == accountID && $0.role == .sent && !$0.isLocal }) else {
            throw AppFailure("COMPARISON_SENT_MAILBOX_INVALID")
        }
        guard let box = boxes.first(where: { $0.messageCount > 0 }) else {
            blockedReason = .noContiguousSample; return nil
        }
        let cursor = MailIndexCursor(accountID: accountID, mailboxPath: box.path,
            expectedCount: box.messageCount, scanID: UUID().uuidString, role: .sent)
        let limit = min(32, box.messageCount)
        let page = try await mail.indexPage(cursor: cursor, limit: limit)
        try MailIndexLimits.validate(page: page, for: cursor, limit: limit)
        guard page.mailbox.role == .sent && !page.mailbox.isLocal else { throw AppFailure("COMPARISON_SENT_MAILBOX_INVALID") }
        metadataCount = page.records.count
        // Select the first contiguous eligible run. A body range cannot safely
        // skip mismatching sender/size rows or silently fetch unrelated messages.
        var run: [MailIndexLocator] = []
        var start = 0
        var bytes = 0
        for (offset, locator) in page.records.enumerated() {
            try Task.checkCancellation()
            let eligible = SentStyleSelection.address(locator.sender) == address &&
                (1...MailHistoryLimits.messageBytes).contains(locator.messageSize)
            if !eligible {
                if !run.isEmpty { break }
                continue
            }
            if run.isEmpty { start = offset }
            guard bytes <= 2 * 1_024 * 1_024 - locator.messageSize else { break }
            run.append(locator); bytes += locator.messageSize
            if run.count == 4 { break }
        }
        guard !run.isEmpty else { blockedReason = .noContiguousSample; return nil }
        selectedCount = run.count
        return MailBodyBatch(locators: run, firstIndex: start + 1, expectedMailboxCount: box.messageCount)
    }
    private func measure(_ phase: ComparisonPhase, batch: MailBodyBatch, cached: Bool?,
                         operation: @escaping @MainActor () async throws -> [MailIndexReadResult]) async -> [MailIndexReadResult]? {
        guard elapsed.milliseconds < 180_000 else {
            measurements.append(.init(phase: phase, outcome: .skipped, milliseconds: 0, requested: batch.locators.count,
                responses: 0, captured: 0, sourceBytes: 0, matchesScalar: nil, commonComparedMessages: 0,
                matchesBulk: nil, bulkComparedMessages: 0, readFailures: [], deadlineReached: true, failure: nil,
                cache: nil, native: [], spans: []))
            return nil
        }
        let before = Date(); let clock = ComparisonClock()
        let allowance = min(90_000, max(0, 180_000 - Int(elapsed.milliseconds)))
        let nativeStart = await mail.bodyReadMetrics()
        do {
            let (results, expired) = try await bounded(operation)
            guard results.count == batch.locators.count,
                  zip(results, batch.locators).allSatisfy({ $0.0.locator == $0.1 }) else {
                throw AppFailure("COMPARISON_RESPONSE_INVALID")
            }
            let common = Self.compare(reference: baseline, results: results)
            let bulkCommon = Self.compare(reference: bulkReference, results: results)
            let captured = results.compactMap(\.message)
            let native = await mail.bodyReadMetrics()
            let phaseNative = Array(native.dropFirst(nativeStart.count))
            let expectedPath: Bool
            switch phase {
            case .bulkSecond, .bulkFirst, .bulkComparable: expectedPath = phaseNative.contains { $0.mode == .bulk }
            case .cacheWarm, .cacheComparable: expectedPath = lastCache.cacheHits == batch.locators.count && lastCache.bodyRequests == 0
            default: expectedPath = true
            }
            measurements.append(.init(phase: phase, outcome: captured.count == results.count && common.matches != false && bulkCommon.matches != false && expectedPath && !expired ? .passed : .partial,
                milliseconds: clock.milliseconds, requested: batch.locators.count, responses: results.count,
                captured: captured.count, sourceBytes: captured.reduce(0) { $0 + $1.target.body.utf8.count + $1.target.headers.utf8.count },
                matchesScalar: common.matches, commonComparedMessages: common.count,
                matchesBulk: bulkCommon.matches, bulkComparedMessages: bulkCommon.count,
                readFailures: results.compactMap { result in result.failure.map {
                    ComparisonReadFailure(failure: $0, operation: result.mailContext?.operation,
                        stage: result.mailContext?.stage, nativeCode: result.mailContext?.nativeCode)
                } }, deadlineReached: expired, failure: nil,
                cache: cached.map { _ in lastCache }, native: phaseNative, spans: spans(since: before)))
            return results
        } catch {
            let native = await mail.bodyReadMetrics()
            measurements.append(.init(phase: phase, outcome: .failed, milliseconds: clock.milliseconds,
                requested: batch.locators.count, responses: 0, captured: 0, sourceBytes: 0, matchesScalar: nil,
                commonComparedMessages: 0, matchesBulk: nil, bulkComparedMessages: 0, readFailures: [],
                deadlineReached: clock.milliseconds >= Double(allowance),
                failure: .init(error), cache: cached.map { _ in lastCache },
                native: Array(native.dropFirst(nativeStart.count)), spans: spans(since: before)))
            return nil
        }
    }
    private static func compare(reference: [MailIndexReadResult]?, results: [MailIndexReadResult]) -> (count: Int, matches: Bool?) {
        guard let reference else { return (0, nil) }
        let common = results.compactMap { result -> (MailHistoryMessage, MailHistoryMessage)? in
            guard let message = result.message,
                  let original = reference.first(where: { $0.locator == result.locator })?.message else { return nil }
            return (original, message)
        }
        return (common.count, common.isEmpty ? nil : common.allSatisfy { $0.0 == $0.1 })
    }
    private func readBatches(_ batches: [MailBodyBatch], useCache: Bool) async throws -> [MailIndexReadResult] {
        var results: [MailIndexReadResult] = []
        var metrics: [MailBodyReadMetrics] = []
        defer {
            lastCache = .init(lookupMilliseconds: metrics.reduce(0) { $0 + $1.lookupMilliseconds },
                validationMilliseconds: metrics.reduce(0) { $0 + $1.validationMilliseconds },
                hydrationMilliseconds: metrics.reduce(0) { $0 + $1.hydrationMilliseconds },
                saveMilliseconds: metrics.reduce(0) { $0 + $1.saveMilliseconds },
                cacheHits: metrics.reduce(0) { $0 + $1.cacheHits },
                cacheMisses: metrics.reduce(0) { $0 + $1.cacheMisses },
                bodyRequests: metrics.reduce(0) { $0 + $1.bodyRequests })
        }
        for batch in batches {
            try Task.checkCancellation()
            do { results.append(contentsOf: try await reader.read(batch: batch, useCache: useCache)) }
            catch { metrics.append(reader.lastMetrics); throw error }
            metrics.append(reader.lastMetrics)
        }
        return results
    }
    func run() async {
        let start = Date(); let clock = ComparisonClock()
        let batch: MailBodyBatch
        do {
            let (value, expired) = try await bounded { try await self.sample() }
            measurements.append(.init(phase: .discovery, outcome: value == nil ? .blocked : .passed,
                milliseconds: clock.milliseconds, requested: 0, responses: metadataCount, captured: 0, sourceBytes: 0,
                matchesScalar: nil, commonComparedMessages: 0, matchesBulk: nil, bulkComparedMessages: 0, readFailures: [],
                deadlineReached: expired, failure: nil, cache: nil, native: [], spans: spans(since: start)))
            guard let value else { return }
            batch = value
        } catch {
            measurements.append(.init(phase: .discovery, outcome: .failed, milliseconds: clock.milliseconds,
                requested: 0, responses: metadataCount, captured: 0, sourceBytes: 0, matchesScalar: nil,
                commonComparedMessages: 0, matchesBulk: nil, bulkComparedMessages: 0, readFailures: [],
                deadlineReached: clock.milliseconds >= 90_000, failure: .init(error), cache: nil, native: [], spans: spans(since: start)))
            outcome = .failed; return
        }
        baseline = await measure(.scalarFirst, batch: batch, cached: nil) { try await self.mail.hydrateIndexed(locators: batch.locators) }
        guard baseline != nil else { outcome = .failed; return }
        let scalarFirst = baseline
        let bulk = await measure(.bulkSecond, batch: batch, cached: false) { try await self.readBatches([batch], useCache: false) }
        bulkReference = bulk
        var warm: [MailIndexReadResult]?
        if bulk != nil {
            warm = await measure(.cacheWarm, batch: batch, cached: true) { try await self.readBatches([batch], useCache: true) }
        }
        // Same values, reversed order: Mail's own in-memory/download cache can
        // affect all methods. These two repeats expose order bias, not eliminate it.
        let bulkAgain = await measure(.bulkFirst, batch: batch, cached: false) { try await self.readBatches([batch], useCache: false) }
        let scalarAgain = await measure(.scalarSecond, batch: batch, cached: nil) { try await self.mail.hydrateIndexed(locators: batch.locators) }
        if let scalarFirst, let scalarAgain, let bulk, let bulkAgain, let warm,
           let firstIndex = batch.firstIndex, let expectedCount = batch.expectedMailboxCount {
            let sources = [scalarFirst, scalarAgain, bulk, bulkAgain, warm]
            let common = batch.locators.filter { locator in sources.allSatisfy { rows in
                rows.first(where: { $0.locator == locator })?.message != nil
            } }
            if !common.isEmpty {
                do {
                    let planned = try MailBodyBatchPlanner.plan(page: batch.locators, selected: common,
                        offset: firstIndex - 1, expectedCount: expectedCount)
                    let envelope = MailBodyBatch(locators: common)
                    baseline = await measure(.scalarComparable, batch: envelope, cached: nil) {
                        try await self.mail.hydrateIndexed(locators: common)
                    }
                    if baseline != nil {
                        bulkReference = await measure(.bulkComparable, batch: envelope, cached: false) {
                            try await self.readBatches(planned, useCache: false)
                        }
                        if bulkReference != nil {
                            _ = await measure(.cacheComparable, batch: envelope, cached: true) {
                                try await self.readBatches(planned, useCache: true)
                            }
                        }
                    }
                } catch { outcome = .partial }
            }
        }
        let evaluated = measurements.filter { $0.phase != .discovery }
        outcome = mail.writesAttempted == 0 && evaluated.count >= 5 && evaluated.allSatisfy({ $0.outcome == .passed }) ? .passed : .partial
    }
    func report(privateStateRemoved: Bool) -> ComparisonReport {
        ComparisonReport(outcome: privateStateRemoved && mail.writesAttempted == 0 ? outcome : .failed,
            blockedReason: blockedReason, selectedMessages: selectedCount, metadataRecordsExamined: metadataCount,
            milliseconds: elapsed.milliseconds, privateStateRemoved: privateStateRemoved, measurements: measurements)
    }
}

@main private struct CompareMailBody {
    @MainActor static func main() async {
        guard Array(CommandLine.arguments.dropFirst()) == ["--allow-real-mail"] else { exit(64) }
        // A wrapper-owned parent is mandatory: executing the binary by itself
        // cannot choose an arbitrary owner-state directory for the real cache.
        guard let path = ProcessInfo.processInfo.environment["HARBOR_BODY_COMPARE_STATE_PARENT"],
              path.contains("harborreply-body-comparison."),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { exit(64) }
        _ = NSApplication.shared
        Diagnostics.configure(enabled: false, persist: false)
        let parent = URL(fileURLWithPath: path, isDirectory: true)
        let directory = parent.appendingPathComponent("isolated-cache-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { exit(1) }
        let comparison = MailBodyComparison(directory: directory)
        await comparison.run()
        try? FileManager.default.removeItem(at: directory)
        let removed = !FileManager.default.fileExists(atPath: directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if var data = try? encoder.encode(comparison.report(privateStateRemoved: removed)) {
            data.append(10); FileHandle.standardOutput.write(data)
        }
        exit(removed ? 0 : 1)
    }
}
