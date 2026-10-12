import Foundation
import HarborCore

struct MailArchiveStatus: Decodable, Equatable {
    struct Counts: Decodable, Equatable {
        let mailboxes: Int
        let mailboxesDone: Int
        let metadata: Int
        let captured: Int
        let unreadable: Int
        let tooLarge: Int
        let metadataOnly: Int
        let bodyBytes: Int
        let pages: Int
        enum CodingKeys: String, CodingKey {
            case mailboxes, metadata, captured, unreadable, pages
            case mailboxesDone = "mailboxes_done", tooLarge = "too_large"
            case metadataOnly = "metadata_only", bodyBytes = "body_bytes"
        }
    }
    let scanID: String
    let epoch: Int
    let status: String
    let discoveryDone: Bool
    let counts: Counts
    let warning: String
    let metrics: DirectMetrics?
    struct DirectMetrics: Decodable, Equatable {
        let visited: Int
        let unchanged: Int
        let body_reads: Int
        let mime_bytes: Int
        let source_seconds: Double
        let parse_seconds: Double
        let save_seconds: Double
    }
    enum CodingKeys: String, CodingKey {
        case epoch, status, counts, warning, metrics
        case scanID = "scan_id", discoveryDone = "discovery_done"
    }
    static func decode(_ value: Any) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

/// One owner-started scan. The database owns the folder queue and checkpoints;
/// RAM contains at most one metadata page and one 20-message body batch.
/// This never opens ~/Library/Mail and never changes a Mail message.
@MainActor final class MailArchiveIndexer {
    private let mail: any MailSelectionBridge
    private let worker: LocalWorker
    private let requestID: UUID
    init(mail: any MailSelectionBridge, worker: LocalWorker, requestID: UUID) {
        self.mail = mail; self.worker = worker; self.requestID = requestID
    }

    func run(restart: Bool, progress: (MailArchiveStatus) -> Void) async throws {
        var state = try await call("index_start", ["restart": restart])
        let scanID = state["scan_id"] as? String ?? ""
        guard !scanID.isEmpty, let epoch = state["epoch"] as? Int else { throw AppFailure("INDEX_RESPONSE_INVALID") }
        let identity: [String: Any] = ["scan_id": scanID, "epoch": epoch]
        var location: DiagnosticLocation = .mailIndexDiscovery
        do {
            try Task.checkCancellation()
            progress(try MailArchiveStatus.decode(state))
            while state["discovery_done"] as? Bool != true {
                try Task.checkCancellation()
                let expected = state["discovery_checkpoint"] ?? NSNull()
                location = .mailIndexDiscovery
                let cursor: MailMailboxCursor = expected is NSNull ? .init(scanID: scanID) : try decode(expected)
                let page = try await Diagnostics.measure(.indexDiscovery, request: requestID) {
                    try await mail.indexMailboxes(after: cursor, limit: MailIndexLimits.folders)
                }
                try Task.checkCancellation()
                guard page.scanID == scanID, page.mailboxes.count <= MailIndexLimits.folders,
                      page.nextCursor?.scanID == scanID || page.nextCursor == nil else { throw AppFailure("INDEX_RESPONSE_INVALID") }
                state = try await call("index_discovery", identity.merging([
                    "expected_checkpoint": expected, "checkpoint": try encodeOptional(page.nextCursor),
                    "mailboxes": try encode(page.mailboxes), "accounts": try encode(page.accounts),
                    "done": page.nextCursor == nil
                ], uniquingKeysWith: { _, new in new }))
                try Task.checkCancellation()
                progress(try MailArchiveStatus.decode(state))
            }
            var rewoundMailboxes = Set<String>()
            while true {
                try Task.checkCancellation()
                let pending = try await call("index_next", identity)
                try Task.checkCancellation()
                guard let mailboxID = pending["mailbox_id"] as? String else { break }
                guard var expected = pending["cursor"], !(expected is NSNull) else { throw AppFailure("INDEX_RESPONSE_INVALID") }
                location = .mailIndexMetadata
                let cursor: MailIndexCursor = try decode(expected)
                let page: MailIndexPage
                do {
                    page = try await Diagnostics.measure(.indexMetadata, request: requestID) {
                        try await mail.indexPage(cursor: cursor, limit: MailIndexLimits.metadata)
                    }
                } catch {
                    let context = (error as? AppFailure)?.mailContext
                    guard context?.operation == .indexPage, context?.stage == .messageCount,
                          context?.nativeCode == 9130, context?.isShapeFailure == false,
                          rewoundMailboxes.insert(mailboxID).inserted else { throw error }
                    try Task.checkCancellation()
                    state = try await call("index_rewind_mailbox", identity.merging([
                        "mailbox_id": mailboxID, "expected_checkpoint": expected
                    ], uniquingKeysWith: { _, new in new }))
                    progress(try MailArchiveStatus.decode(state))
                    continue
                }
                try Task.checkCancellation()
                guard page.scanID == scanID, page.records.count <= MailIndexLimits.metadata,
                      page.mailbox.accountID == cursor.accountID, page.mailbox.path == cursor.mailboxPath,
                      page.records.allSatisfy({ $0.scanID == scanID && $0.accountID == cursor.accountID && $0.mailboxPath == cursor.mailboxPath }),
                      page.nextCursor?.scanID == scanID || page.nextCursor == nil else { throw AppFailure("INDEX_RESPONSE_INVALID") }
                var processed = 0
                if page.records.isEmpty {
                    guard page.nextCursor == nil else { throw AppFailure("INDEX_PAGE_NO_PROGRESS") }
                    state = try await call("index_page", identity.merging([
                        "mailbox_id": mailboxID, "expected_checkpoint": expected,
                        "checkpoint": NSNull(), "records": [], "done": true
                    ], uniquingKeysWith: { _, new in new }))
                }
                while processed < page.records.count {
                    try Task.checkCancellation()
                    let locators = Array(page.records[processed..<min(processed + MailHistoryLimits.hydratedMessages, page.records.count)])
                    location = .mailIndexBody
                    let results = try await Diagnostics.measure(.indexBody, request: requestID, count: locators.count) {
                        try await MailBodyReader(mail: mail, worker: worker, requestID: requestID)
                            .read(page: page, selected: locators, offset: cursor.offset)
                    }
                    try Task.checkCancellation()
                    guard results.count == locators.count, zip(results, locators).allSatisfy({ $0.0.locator == $0.1 }) else { throw AppFailure("INDEX_BODY_RESPONSE_INVALID") }
                    for result in results {
                        if let context = result.mailContext {
                            Diagnostics.record(.operationFailed, failure: .mail, numericCode: context.nativeCode,
                                               count: 1, location: .mailIndexBody,
                                               failureCode: AppFailure(context.code, mailContext: context).diagnosticFailure)
                        }
                    }
                    location = .mailIndexCheckpoint
                    // Commit small byte batches separately. Every committed
                    // prefix advances the native offset, even on cancellation.
                    for batch in try MailSnapshotPayload.batches(results.map(MailSnapshotPayload.record)) {
                        try Task.checkCancellation()
                        processed += batch.count
                        let last = processed == page.records.count
                        let done = last && page.nextCursor == nil
                        let checkpoint: Any
                        if done { checkpoint = NSNull() }
                        else if last, let next = page.nextCursor { checkpoint = try encode(next) }
                        else {
                            checkpoint = try encode(MailIndexCursor(accountID: cursor.accountID, mailboxPath: cursor.mailboxPath,
                                offset: cursor.offset + processed, expectedCount: page.mailbox.messageCount,
                                scanID: scanID, isLocal: cursor.isLocal, role: cursor.role))
                        }
                        state = try await call("index_page", identity.merging([
                            "mailbox_id": mailboxID, "expected_checkpoint": expected,
                            "checkpoint": checkpoint, "records": batch, "done": done
                        ], uniquingKeysWith: { _, new in new }))
                        expected = checkpoint
                        try Task.checkCancellation()
                        progress(try MailArchiveStatus.decode(state))
                    }
                }
            }
            try Task.checkCancellation()
            state = try await call("index_finish", identity.merging(["status": "complete"], uniquingKeysWith: { _, new in new }))
            progress(try MailArchiveStatus.decode(state))
        } catch {
            // Persist a pause even when the Task is cancelled. Calls already
            // committed in the worker are never rolled back by the UI.
            let scoped = (error as? AppFailure)?.location != nil ? error : AppFailure.located(error, at: location)
            let warning = (scoped as? AppFailure)?.code ?? (error is CancellationError ? "" : "MAIL_INDEX_INTERRUPTED")
            let w = worker
            let paused = await Task.detached {
                try? await w.call("index_finish", identity.merging(["status": "paused", "warning": warning], uniquingKeysWith: { _, new in new }))
            }.value
            if let paused, let status = try? MailArchiveStatus.decode(paused) { progress(status) }
            throw scoped
        }
    }
    private func call(_ command: String, _ values: [String: Any]) async throws -> [String: Any] {
        do {
            let value = try await Diagnostics.measure(.indexSave, request: requestID) {
                try await worker.call(command, values)
            }
            guard let result = value as? [String: Any] else { throw AppFailure("INDEX_RESPONSE_INVALID") }
            return result
        } catch { throw AppFailure.located(error, at: .mailIndexCheckpoint) }
    }
    private func decode<T: Decodable>(_ value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func encode<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    private func encodeOptional<T: Encodable>(_ value: T?) throws -> Any {
        if let value { return try encode(value) }; return NSNull()
    }
}

/// Shared byte and scalar limits for both archive indexing and scoped Sent reads.
enum MailSnapshotPayload {
    static func encode<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    static func record(_ result: MailIndexReadResult) throws -> [String: Any] {
        var row = try encode(result.locator) as? [String: Any] ?? [:]
        if result.fromCache { row["cacheSnapshot"] = true }
        if let message = result.message, result.failure == nil {
            if message.target.body.unicodeScalars.count <= 250_000, message.target.headers.unicodeScalars.count <= 32_768 {
                row["body"] = message.target.body; row["headers"] = message.target.headers
                row["attachmentCount"] = message.item.attachmentCount; row["bodyStatus"] = "captured"
            } else { row["bodyStatus"] = "too_large"; row["failure"] = "MAIL_INDEX_MESSAGE_TOO_LARGE" }
        } else {
            row["bodyStatus"] = result.failure == .tooLarge ? "too_large" : "unreadable"
            row["failure"] = result.mailContext?.code ?? result.failure?.rawValue ?? "MAIL_INDEX_READ_UNAVAILABLE"
        }
        // JSON escapes and combining characters can exceed IPC even when the
        // native body cap passed. Preserve searchable metadata and continue.
        if try JSONSerialization.data(withJSONObject: row).count > 1_500_000 {
            row.removeValue(forKey: "body"); row.removeValue(forKey: "headers")
            row["bodyStatus"] = "too_large"; row["failure"] = "MAIL_INDEX_MESSAGE_TOO_LARGE"
        }
        return row
    }
    static func batches(_ records: [[String: Any]]) throws -> [[[String: Any]]] {
        var result: [[[String: Any]]] = []; var batch: [[String: Any]] = []; var bytes = 2
        for record in records {
            let size = try JSONSerialization.data(withJSONObject: record).count + 1
            guard size <= 1_500_000 else { throw AppFailure("LOCAL_RECORD_SIZE_LIMIT") }
            if bytes + size > 1_500_000 { result.append(batch); batch = []; bytes = 2 }
            batch.append(record); bytes += size
        }
        if !batch.isEmpty { result.append(batch) }
        return result
    }
}
