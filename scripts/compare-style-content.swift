import AppKit
import Darwin
import Foundation
import HarborCore

// External, explicitly authorized read-only comparison. Mail text, addresses,
// native identifiers and checksums remain in memory and never enter its report.
private enum ContentComparisonPhase: String, Codable {
    case discovery, legacyFirst, contentSecond, contentFirst, legacySecond
}
private enum ContentComparisonOutcome: String, Codable { case passed, partial, blocked, failed, skipped }
private enum ContentComparisonBlock: String, Codable {
    case senderNotConfigured, configuredSenderMissing, noContiguousFourMessageSample
}
private struct ContentComparisonFailure: Codable {
    let category: DiagnosticFailureCode
    let operation: MailEventOperation?
    let stage: MailEventStage?
    let nativeCode: Int?
    let cancelled: Bool
    init(_ error: Error) {
        let failure = error as? AppFailure
        category = failure?.diagnosticFailure ?? .unknown
        operation = failure?.mailContext?.operation
        stage = failure?.mailContext?.stage
        nativeCode = failure?.mailContext?.nativeCode
        cancelled = error is CancellationError
    }
}
private struct ContentComparisonSpan: Codable {
    let stage: DiagnosticTimingStage
    let samples: Int
    let totalMilliseconds: Int
    let maximumMilliseconds: Int
}
private struct ContentComparisonMeasurement: Codable {
    let phase: ContentComparisonPhase
    let outcome: ContentComparisonOutcome
    let milliseconds: Double
    let requested: Int
    let responses: Int
    let captured: Int
    let sourceBodyBytes: Int
    let bodyByteEquality: Bool?
    let comparedBodies: Int
    let nativeIdentityGets: Int
    let contentGets: Int
    let headerGets: Int
    let native: [MailBodyBatchMetrics]
    let spans: [ContentComparisonSpan]
    let unavailableNativeCodes: [Int]
    let deadlineReached: Bool
    let failure: ContentComparisonFailure?
}
private struct ContentComparisonReport: Codable {
    let schemaVersion = 1
    let realMailConsent = true
    let phaseDeadlineSeconds = 90
    let totalDeadlineSeconds = 180
    let maximumMessages = 4
    let maximumMetadataRecords = 32
    let maximumDeclaredSourceBytes = 2 * 1_024 * 1_024
    let sameFourMessagesAcrossABBA = true
    let equalityIncludesOnlyBodyUTF8Bytes = true
    let contentPathFetchesHeadersOrAttachments = false
    let contentScopePreparedDuringDiscovery: Bool
    let fullArchiveTested = false
    let mailWritesExecuted = false
    let ownerStateWritten = false
    let privateDatabaseCreated = false
    let modelCalled = false
    let keychainRead = false
    let uiAccepted = false
    let directMailStorageRead = false
    let nativeRangesMayFallBack = true
    let getterCountsAreExplicitSitesNotOpaqueMailWork = true
    let phasesContainNestedTimings = true
    let outcome: ContentComparisonOutcome
    let blockedReason: ContentComparisonBlock?
    let selectedMessages: Int
    let metadataRecordsExamined: Int
    let milliseconds: Double
    let measurements: [ContentComparisonMeasurement]
}
private struct ContentComparisonClock {
    private let start = DispatchTime.now().uptimeNanoseconds
    var milliseconds: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
}
private struct PrivateContentComparisonSample {
    let legacy: MailBodyBatch
    let content: StyleContentBatch
}
private struct PrivateContentComparisonRead {
    let bodies: [Data?]
    let unavailableNativeCodes: [Int]
}

@MainActor private final class ContentComparisonReadOnlyMail: MailSelectionBridge {
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
    func styleCandidates(cursor: MailIndexCursor, limit: Int) async throws -> StyleCandidatePage {
        try await live.styleCandidates(cursor: cursor, limit: limit)
    }
    func styleContents(batch: StyleContentBatch) async throws -> [StyleContentRead] { try await live.styleContents(batch: batch) }
}

@MainActor private final class StyleContentComparison {
    private let mail = ContentComparisonReadOnlyMail()
    private let elapsed = ContentComparisonClock()
    private var measurements: [ContentComparisonMeasurement] = []
    private var outcome = ContentComparisonOutcome.blocked
    private var block: ContentComparisonBlock?
    private var metadataCount = 0
    private var selectedCount = 0
    private var baseline: [Data?]?
    private var contentScopePrepared = false

    private func spans(since timestamp: Date) -> [ContentComparisonSpan] {
        let records = Diagnostics.log.recentTimings().filter { $0.timestamp >= timestamp }
        return DiagnosticTimingStage.allCases.compactMap { stage in
            let values = records.filter { $0.timingStage == stage }.compactMap(\.elapsedMilliseconds)
            return values.isEmpty ? nil : .init(stage: stage, samples: values.count,
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
    private func sample() async throws -> PrivateContentComparisonSample? {
        let settings = Settings.load()
        guard let accountID = settings.styleAccountID,
              let address = settings.styleSenderAddress.flatMap(SentStyleSelection.address),
              !settings.sharedAddresses.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
                .compactMap({ SentStyleSelection.address(String($0)) }).contains(address) else {
            block = .senderNotConfigured; return nil
        }
        let accounts = try await mail.styleAccounts()
        guard let account = accounts.first(where: { $0.id == accountID }),
              account.addresses.compactMap(SentStyleSelection.address).contains(address) else {
            block = .configuredSenderMissing; return nil
        }
        let boxes = try await mail.styleMailboxes(accountID: accountID)
        guard boxes.count <= MailIndexLimits.folders,
              boxes.allSatisfy({ $0.accountID == accountID && $0.role == .sent && !$0.isLocal }) else {
            throw AppFailure("COMPARISON_SENT_MAILBOX_INVALID")
        }
        guard let box = boxes.first(where: { $0.messageCount >= 4 }) else {
            block = .noContiguousFourMessageSample; return nil
        }
        let cursor = MailIndexCursor(accountID: accountID, mailboxPath: box.path,
            expectedCount: box.messageCount, scanID: UUID().uuidString, role: .sent)
        let limit = min(32, box.messageCount)
        let page = try await mail.indexPage(cursor: cursor, limit: limit)
        try MailIndexLimits.validate(page: page, for: cursor, limit: limit)
        guard page.mailbox.accountID == accountID, page.mailbox.role == .sent, !page.mailbox.isLocal else {
            throw AppFailure("COMPARISON_SENT_MAILBOX_INVALID")
        }
        metadataCount = page.records.count
        let first = (0...max(0, page.records.count-4)).first { offset in
            let rows = page.records.dropFirst(offset).prefix(4)
            return rows.count == 4 && rows.allSatisfy {
                SentStyleSelection.address($0.sender) == address && (1...MailHistoryLimits.messageBytes).contains($0.messageSize)
            } && rows.reduce(0, { $0 + $1.messageSize }) <= StyleContentBatch.maximumBytes
        }
        guard let first else { block = .noContiguousFourMessageSample; return nil }
        let rows = Array(page.records.dropFirst(first).prefix(4))
        let legacy = MailBodyBatch(locators: rows, firstIndex: first+1, expectedMailboxCount: box.messageCount)
        let content = StyleContentBatch(cursor: cursor, candidates: rows.enumerated().map {
            StyleCandidate(position: first+$0.offset+1, sender: $0.element.sender, messageSize: $0.element.messageSize)
        })
        try legacy.validate(); try content.validate()
        // Prepare the selected account/Sent scope once, matching the normal
        // app's styleCandidates → styleContents sequence. Its setup GETs and
        // time belong to discovery, never to the timed content body phase.
        let prepared = try await mail.styleCandidates(cursor: cursor, limit: min(4, box.messageCount))
        try prepared.validate(for: cursor, limit: min(4, box.messageCount))
        contentScopePrepared = true
        selectedCount = rows.count
        return .init(legacy: legacy, content: content)
    }
    private func legacy(_ batch: MailBodyBatch) async throws -> PrivateContentComparisonRead {
        let results = try await mail.hydrateIndexedBatch(batch)
        guard results.count == batch.locators.count,
              zip(results, batch.locators).allSatisfy({ $0.0.locator == $0.1 }) else {
            throw AppFailure("COMPARISON_RESPONSE_INVALID")
        }
        return .init(bodies: results.map { $0.message.map { Data($0.target.body.utf8) } },
                     unavailableNativeCodes: results.compactMap { $0.message == nil ? $0.mailContext?.nativeCode : nil })
    }
    private func contents(_ batch: StyleContentBatch) async throws -> PrivateContentComparisonRead {
        let reads = try await mail.styleContents(batch: batch)
        try StyleContentLimits.validate(reads: reads, for: batch)
        return .init(bodies: reads.map { $0.body.map { Data($0.utf8) } }, unavailableNativeCodes: reads.compactMap(\.nativeCode))
    }
    private func measure(_ phase: ContentComparisonPhase, content: Bool,
                         operation: @escaping @MainActor () async throws -> PrivateContentComparisonRead) async {
        let before = Date(); let clock = ContentComparisonClock()
        let nativeStart = await mail.bodyReadMetrics()
        let allowance = min(90_000, max(0, 180_000 - Int(elapsed.milliseconds)))
        guard allowance > 0 else {
            measurements.append(.init(phase: phase, outcome: .skipped, milliseconds: 0, requested: 4,
                responses: 0, captured: 0, sourceBodyBytes: 0, bodyByteEquality: nil, comparedBodies: 0,
                nativeIdentityGets: 0, contentGets: 0, headerGets: 0, native: [], spans: [],
                unavailableNativeCodes: [], deadlineReached: true, failure: nil))
            return
        }
        do {
            let (value, expired) = try await bounded(operation)
            guard value.bodies.count == 4 else { throw AppFailure("COMPARISON_RESPONSE_INVALID") }
            let measured = Array((await mail.bodyReadMetrics()).dropFirst(nativeStart.count))
            let captured = value.bodies.compactMap { $0 }
            let identityGets = measured.reduce(0) { $0 + $1.beforeGets + $1.afterGets }
            let headerGets = measured.reduce(0) { $0 + $1.headersGets }
            let compared = baseline.map { original in zip(original, value.bodies).compactMap { pair -> Bool? in
                guard let first = pair.0, let second = pair.1 else { return nil }; return first == second
            } } ?? []
            let equal: Bool? = baseline == nil ? nil : (compared.isEmpty ? nil : compared.allSatisfy { $0 })
            let expected = !measured.isEmpty && (!content || measured.allSatisfy {
                [.styleContents, .styleContentsFallback].contains($0.mode) && $0.beforeGets == 0 && $0.afterGets == 0 && $0.headersGets == 0
            })
            measurements.append(.init(phase: phase, outcome: captured.count == 4 && equal != false && expected && !expired ? .passed : .partial,
                milliseconds: clock.milliseconds, requested: 4, responses: value.bodies.count, captured: captured.count,
                sourceBodyBytes: captured.reduce(0) { $0 + $1.count }, bodyByteEquality: equal, comparedBodies: compared.count,
                nativeIdentityGets: identityGets, contentGets: measured.reduce(0) { $0 + $1.contentGets },
                headerGets: headerGets, native: measured, spans: spans(since: before),
                unavailableNativeCodes: value.unavailableNativeCodes.filter { [-1708, -1712].contains($0) },
                deadlineReached: expired, failure: nil))
            if phase == .legacyFirst { baseline = value.bodies }
        } catch {
            let measured = Array((await mail.bodyReadMetrics()).dropFirst(nativeStart.count))
            measurements.append(.init(phase: phase, outcome: .failed, milliseconds: clock.milliseconds,
                requested: 4, responses: 0, captured: 0, sourceBodyBytes: 0, bodyByteEquality: nil, comparedBodies: 0,
                nativeIdentityGets: measured.reduce(0) { $0 + $1.beforeGets + $1.afterGets },
                contentGets: measured.reduce(0) { $0 + $1.contentGets }, headerGets: measured.reduce(0) { $0 + $1.headersGets },
                native: measured, spans: spans(since: before), unavailableNativeCodes: [],
                deadlineReached: clock.milliseconds >= Double(allowance), failure: .init(error)))
        }
    }
    func run() async {
        let before = Date(); let clock = ContentComparisonClock()
        let nativeStart = await mail.bodyReadMetrics()
        let sample: PrivateContentComparisonSample
        do {
            let (value, expired) = try await bounded { try await self.sample() }
            let measured = Array((await mail.bodyReadMetrics()).dropFirst(nativeStart.count))
            measurements.append(.init(phase: .discovery, outcome: value == nil ? .blocked : (expired ? .partial : .passed),
                milliseconds: clock.milliseconds, requested: 0, responses: metadataCount, captured: 0, sourceBodyBytes: 0,
                bodyByteEquality: nil, comparedBodies: 0, nativeIdentityGets: 0, contentGets: 0, headerGets: 0,
                native: measured, spans: spans(since: before), unavailableNativeCodes: [], deadlineReached: expired, failure: nil))
            guard let value, !expired else { outcome = value == nil ? .blocked : .partial; return }
            sample = value
        } catch {
            let measured = Array((await mail.bodyReadMetrics()).dropFirst(nativeStart.count))
            measurements.append(.init(phase: .discovery, outcome: .failed, milliseconds: clock.milliseconds,
                requested: 0, responses: metadataCount, captured: 0, sourceBodyBytes: 0,
                bodyByteEquality: nil, comparedBodies: 0, nativeIdentityGets: 0, contentGets: 0, headerGets: 0,
                native: measured, spans: spans(since: before), unavailableNativeCodes: [],
                deadlineReached: clock.milliseconds >= 90_000, failure: .init(error)))
            outcome = .failed; return
        }
        await measure(.legacyFirst, content: false) { try await self.legacy(sample.legacy) }
        await measure(.contentSecond, content: true) { try await self.contents(sample.content) }
        await measure(.contentFirst, content: true) { try await self.contents(sample.content) }
        await measure(.legacySecond, content: false) { try await self.legacy(sample.legacy) }
        let phases = measurements.filter { $0.phase != .discovery }
        outcome = mail.writesAttempted == 0 && phases.count == 4 && phases.allSatisfy({ $0.outcome == .passed }) &&
            phases.dropFirst().allSatisfy({ $0.bodyByteEquality == true && $0.comparedBodies == 4 }) ? .passed : .partial
    }
    func report() -> ContentComparisonReport {
        .init(contentScopePreparedDuringDiscovery: contentScopePrepared,
              outcome: mail.writesAttempted == 0 ? outcome : .failed, blockedReason: block,
              selectedMessages: selectedCount, metadataRecordsExamined: metadataCount,
              milliseconds: elapsed.milliseconds, measurements: measurements)
    }
}

@main private struct CompareStyleContent {
    @MainActor static func main() async {
        guard Array(CommandLine.arguments.dropFirst()) == ["--allow-real-mail"] else { exit(64) }
        guard let path = ProcessInfo.processInfo.environment["HARBOR_STYLE_CONTENT_COMPARE_PARENT"],
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("harborreply-style-content-comparison."),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { exit(64) }
        _ = NSApplication.shared
        Diagnostics.configure(enabled: false, persist: false)
        let comparison = StyleContentComparison()
        await comparison.run()
        let report = comparison.report()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(report) else { exit(1) }
        data.append(10); FileHandle.standardOutput.write(data)
        exit(report.outcome == .passed ? 0 : 1)
    }
}
