import AppKit
import Foundation
import HarborCore

// External, opt-in verification executable. Never copied into the product.
// Only fixed enums, counts, durations and numeric failure context are serialized.
private enum LiveStage: String, Codable {
    case accounts, sentDiscovery, mailboxDiscovery, indexStart, metadata, hydration
    case indexSave, search, styleStart, styleSave, styleExtract
}
private struct LiveFailure: Codable {
    let category: DiagnosticFailureCode
    let operation: MailEventOperation?
    let stage: MailEventStage?
    let nativeCode: Int?
    init(_ error: Error) {
        let failure = error as? AppFailure
        category = failure?.diagnosticFailure ?? .unknown
        operation = failure?.mailContext?.operation
        stage = failure?.mailContext?.stage
        nativeCode = failure?.mailContext?.nativeCode
    }
}
private struct LiveStep: Codable {
    let stage: LiveStage
    let elapsedMilliseconds: Int
    let count: Int?
    let succeeded: Bool
    let failure: LiveFailure?
}
private struct LiveTiming: Codable {
    let stage: DiagnosticTimingStage
    let operation: MailEventOperation?
    let worker: LocalWorkerCommand?
    let elapsedMilliseconds: Int
}
private struct LiveReport: Codable {
    let version = 1
    var consentPresent = false
    var succeeded = false
    var temporaryStateRemoved = false
    let productionUIExecuted = false
    let mailWritesExecuted = false
    let modelCalled = false
    let fullArchiveTested = false
    let personalAuthorshipVerified = false
    var accountCount = 0
    var folderCount = 0
    var metadataCount = 0
    var indexedMetadataCount = 0
    var bodyAttempts = 0
    var bodiesCaptured = 0
    var searchMatches = 0
    var styleSamples = 0
    var sourcePhraseCount = 0
    var styleDescriptionPresent = false
    var fabricatedStyleExamplesAbsent = false
    var sourcePhrasesVerified = false
    var steps: [LiveStep] = []
    var timings: [LiveTiming] = []
    var failure: LiveFailure?
}

@MainActor private final class LiveVerification {
    // Owns only bounded diagnostic results and one isolated temporary worker DB.
    private let mail = AppleMailBridge()
    private let worker: LocalWorker
    private let accountIndex: Int
    private let addressIndex: Int
    var report: LiveReport

    init(database: URL, accountIndex: Int, addressIndex: Int) {
        worker = LocalWorker(database: database)
        self.accountIndex = accountIndex; self.addressIndex = addressIndex
        report = LiveReport(); report.consentPresent = true
    }

    private func step<Value>(_ stage: LiveStage, count: ((Value) -> Int)? = nil,
                             _ body: () async throws -> Value) async throws -> Value {
        let timer = DiagnosticTimer()
        do {
            let result = try await body()
            report.steps.append(.init(stage: stage, elapsedMilliseconds: timer.elapsedMilliseconds,
                                      count: count.map { $0(result) }, succeeded: true, failure: nil))
            return result
        } catch {
            report.steps.append(.init(stage: stage, elapsedMilliseconds: timer.elapsedMilliseconds,
                                      count: nil, succeeded: false, failure: .init(error)))
            throw error
        }
    }

    private func object(_ command: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        guard let result = try await worker.call(command, payload) as? [String: Any] else { throw AppFailure("LIVE_RESPONSE_INVALID") }
        return result
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private func record(_ locator: MailIndexLocator, read: MailIndexReadResult?) throws -> [String: Any] {
        guard var row = try encode(locator) as? [String: Any] else { throw AppFailure("LIVE_RESPONSE_INVALID") }
        if let message = read?.message, read?.failure == nil,
           message.target.body.unicodeScalars.count <= 250_000, message.target.headers.unicodeScalars.count <= 32_768 {
            row["body"] = message.target.body; row["headers"] = message.target.headers
            row["attachmentCount"] = message.item.attachmentCount; row["bodyStatus"] = "captured"
        } else { row["bodyStatus"] = "metadata_only" }
        guard try JSONSerialization.data(withJSONObject: row).count <= 1_500_000 else { throw AppFailure("LIVE_INPUT_LIMIT") }
        return row
    }

    private func query(from messages: [MailHistoryMessage]) -> String? {
        messages.lazy.flatMap { $0.target.body.components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .first { word in
                (3...32).contains(word.utf8.count) && word.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            }
    }

    func run() async throws {
        let accounts = try await step(.accounts, count: { $0.count }) { try await mail.styleAccounts() }
        report.accountCount = accounts.count
        guard accounts.indices.contains(accountIndex) else { throw AppFailure("LIVE_ACCOUNT_SELECTION_REQUIRED") }
        let account = accounts[accountIndex]
        guard account.addresses.indices.contains(addressIndex),
              let address = SentStyleSelection.address(account.addresses[addressIndex]) else { throw AppFailure("LIVE_ADDRESS_SELECTION_REQUIRED") }
        let sent = try await step(.sentDiscovery, count: { $0.count }) { try await mail.styleMailboxes(accountID: account.id) }
        let discovered = try await step(.mailboxDiscovery, count: { $0.mailboxes.count }) {
            try await mail.indexMailboxes(after: nil, limit: 2)
        }
        let boxes = (sent + discovered.mailboxes).reduce(into: [MailIndexMailbox]()) { values, box in
            if values.count < 2, !values.contains(where: { $0.accountID == box.accountID && $0.path == box.path && $0.isLocal == box.isLocal }) {
                values.append(box)
            }
        }
        report.folderCount = boxes.count
        guard !boxes.isEmpty else { throw AppFailure("LIVE_MAILBOX_UNAVAILABLE") }
        let state = try await step(.indexStart) { try await object("index_start", ["restart": true]) }
        guard let scan = state["scan_id"] as? String, let epoch = state["epoch"] as? Int else { throw AppFailure("LIVE_RESPONSE_INVALID") }
        let identity: [String: Any] = ["scan_id": scan, "epoch": epoch]
        _ = try await object("index_discovery", identity.merging([
            "expected_checkpoint": NSNull(), "checkpoint": NSNull(), "mailboxes": try encode(Array(boxes.prefix(1))),
            "accounts": try encode(accounts), "done": true
        ], uniquingKeysWith: { _, new in new }))

        // Exactly one bounded metadata page per selected folder. Never drain a
        // whole folder or infer completeness from this diagnostic sample.
        var pages: [MailIndexPage] = []
        for box in boxes {
            let cursor = MailIndexCursor(accountID: box.accountID, mailboxPath: box.path, expectedCount: box.messageCount,
                                         scanID: scan, isLocal: box.isLocal, role: box.role)
            pages.append(try await step(.metadata, count: { $0.records.count }) { try await mail.indexPage(cursor: cursor, limit: 16) })
        }
        report.metadataCount = pages.reduce(0) { $0 + $1.records.count }
        let sourceCandidates = pages.flatMap(\.records).filter {
            $0.accountID == account.id && $0.role == .sent && !$0.isLocal && SentStyleSelection.address($0.sender) == address &&
                (0...MailHistoryLimits.messageBytes).contains($0.messageSize)
        }
        let readCandidates = Array(sourceCandidates.prefix(3))
        report.bodyAttempts = readCandidates.count
        let reads = readCandidates.isEmpty ? [] : try await step(.hydration, count: { $0.filter { $0.message != nil }.count }) {
            try await mail.hydrateIndexed(locators: readCandidates)
        }
        guard reads.count == readCandidates.count, zip(reads, readCandidates).allSatisfy({ $0.0.locator == $0.1 }) else { throw AppFailure("LIVE_RESPONSE_INVALID") }
        let messages = reads.compactMap(\.message)
        report.bodiesCaptured = messages.count

        // Upsert one sampled folder. A partial folder remains pending, so
        // index_next would otherwise return it again rather than the next box.
        // The second folder's native decoding is independently checked above.
        for _ in boxes.prefix(1) {
            let pending = try await object("index_next", identity)
            guard let mailboxID = pending["mailbox_id"] as? String, let expected = pending["cursor"],
                  let cursorObject = expected as? [String: Any], let accountID = cursorObject["accountID"] as? String,
                  let path = cursorObject["mailboxPath"] as? [String],
                  let page = pages.first(where: { $0.mailbox.accountID == accountID && $0.mailbox.path == path }) else { throw AppFailure("LIVE_RESPONSE_INVALID") }
            let records = try page.records.map { locator in try record(locator, read: reads.first { $0.locator == locator }) }
            let checkpoint = try page.nextCursor.map(encode) ?? NSNull()
            _ = try await step(.indexSave) { try await object("index_page", identity.merging([
                "mailbox_id": mailboxID, "expected_checkpoint": expected, "checkpoint": checkpoint,
                "records": records, "done": page.nextCursor == nil
            ], uniquingKeysWith: { _, new in new })) }
            report.indexedMetadataCount += records.count
        }
        _ = try await object("index_finish", identity.merging(["status": "paused"], uniquingKeysWith: { _, new in new }))
        guard !messages.isEmpty else { throw AppFailure("LIVE_SENT_SOURCES_UNAVAILABLE") }
        guard let query = query(from: messages) else { throw AppFailure("LIVE_SEARCH_QUERY_UNAVAILABLE") }
        let matches = try await step(.search, count: { $0.count }) {
            guard let results = try await worker.call("search", ["query": query]) as? [Any], !results.isEmpty else {
                throw AppFailure("LIVE_SEARCH_RESPONSE_INVALID")
            }
            return results
        }
        report.searchMatches = matches.count

        // Extraction uses only the very same <=3 genuine Sent body snapshots.
        // Authorship is a diagnostic assumption, explicitly unverified in output.
        let style = try await step(.styleStart) { try await object("style_capture_start", [
            "account_id": account.id, "address": address, "own_addresses": account.addresses,
            "shared_addresses": [], "author_confirmed": true, "token_budget": 131_072, "restart": true
        ]) }
        guard let captureID = style["capture_id"] as? String else { throw AppFailure("LIVE_RESPONSE_INVALID") }
        let sourceRows = try reads.filter { $0.message != nil }.map { try record($0.locator, read: $0) }
        _ = try await step(.styleSave) { try await object("style_capture_page", [
            "capture_id": captureID, "expected_checkpoint": NSNull(), "checkpoint": ["sequence": 1],
            "records": sourceRows, "candidates_checked": sourceCandidates.count, "done": false
        ]) }
        _ = try await object("style_capture_finish", ["capture_id": captureID, "status": "complete", "source_exhausted": false])
        let summary = try await step(.styleExtract) { try await object("style_capture_extract", ["capture_id": captureID]) }
        report.styleSamples = summary["example_count"] as? Int ?? 0
        report.styleDescriptionPresent = !(summary["description"] as? String ?? "").isEmpty
        report.fabricatedStyleExamplesAbsent = summary["examples"] == nil && summary["example_origin"] == nil
        let phrases = summary["source_phrases"] as? [String] ?? []
        report.sourcePhraseCount = phrases.count
        report.sourcePhrasesVerified = phrases.allSatisfy { phrase in messages.contains { $0.target.body.components(separatedBy: .newlines).contains(phrase) } }
        guard report.styleSamples > 0, report.styleDescriptionPresent, report.fabricatedStyleExamplesAbsent, report.sourcePhrasesVerified else { throw AppFailure("LIVE_STYLE_RESPONSE_INVALID") }
        report.succeeded = true
    }

    func finish() -> LiveReport {
        report.timings = Diagnostics.log.recentTimings().compactMap { record in
            record.timingStage.map { .init(stage: $0, operation: record.mailOperation, worker: record.workerCommand,
                                           elapsedMilliseconds: record.elapsedMilliseconds ?? 0) }
        }
        return report
    }
}

@main private struct LiveMailMain {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--allow-real-mail" else { emit(LiveReport()); exit(64) }
        let accountIndex: Int
        let addressIndex: Int
        switch args.count {
        case 1: accountIndex = 0; addressIndex = 0
        case 5 where args[1] == "--account-index" && args[3] == "--address-index":
            guard let account = Int(args[2]), let address = Int(args[4]), account >= 0, address >= 0 else { emit(LiveReport()); exit(64) }
            accountIndex = account; addressIndex = address
        default: emit(LiveReport()); exit(64)
        }
        _ = NSApplication.shared
        Diagnostics.configure(enabled: false, persist: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harborreply-live-state-" + UUID().uuidString, isDirectory: true)
        var report = await runIsolated(directory: directory, accountIndex: accountIndex, addressIndex: addressIndex)
        report.temporaryStateRemoved = !FileManager.default.fileExists(atPath: directory.path)
        if !report.temporaryStateRemoved { report.succeeded = false }
        emit(report)
        exit(report.succeeded ? 0 : 1)
    }
    @MainActor private static func runIsolated(directory: URL, accountIndex: Int, addressIndex: Int) async -> LiveReport {
        defer { try? FileManager.default.removeItem(at: directory) }
        var report = LiveReport(); report.consentPresent = true
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let verification = LiveVerification(database: directory.appendingPathComponent("isolated.sqlite"), accountIndex: accountIndex, addressIndex: addressIndex)
            do { try await verification.run() }
            catch { verification.report.failure = .init(error) }
            report = verification.finish()
        } catch { report.failure = .init(error) }
        // The caller serializes only after deferred private-state removal.
        return report
    }
    private static func emit(_ report: LiveReport) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(report) else { return }
        data.append(10); FileHandle.standardOutput.write(data)
    }
}
