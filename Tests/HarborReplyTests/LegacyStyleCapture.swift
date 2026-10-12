import Foundation
import HarborCore
@testable import HarborReply

/// Content collection for the explicitly selected sender's Sent folder.
/// This path does not use the index's native identity/attachment checkpoints.
@MainActor final class LegacyStyleCapture {
    private let mail: any MailSelectionBridge
    private let worker: LocalWorker
    private let requestID: UUID
    init(mail: any MailSelectionBridge, worker: LocalWorker, requestID: UUID) {
        self.mail = mail; self.worker = worker; self.requestID = requestID
    }

    func run(account: MailAccountIdentity, address: String, shared: [String], tokenBudget: Int,
             progress: (StyleCaptureProgress) -> Void, restart: Bool = false) async throws -> Any {
        guard let selected = SentStyleSelection.address(address), selected.utf8.count <= 320,
              account.addresses.compactMap(SentStyleSelection.address).contains(selected),
              !shared.compactMap(SentStyleSelection.address).contains(selected) else {
            throw AppFailure("STYLE_PERSONAL_ADDRESS_REQUIRED")
        }
        let startedAt = Date()
        var phase = StyleCapturePhase.discovering
        var knownFolderCount: Int?, knownSentMessageCount: Int?, headerTarget: Int?
        var foldersProcessed = 0, checked = 0, metadataExcluded = 0
        var activeFolderIndex: Int?
        var bodyAttempts = 0, bodyReadsCompleted = 0, bodyCaptured = 0
        var adoptedSamples = 0, skippedSamples = 0, tokenUnits = 0
        var stopReason: StyleCaptureStopReason?
        var readBudget = SentStyleReadBudget()
        func report(_ activity: StyleCaptureActivity, requested: Int = 0, completed: Int = 0) {
            progress(.init(phase: phase, activity: activity, startedAt: startedAt,
                knownFolderCount: knownFolderCount, knownSentMessageCount: knownSentMessageCount,
                headerTarget: headerTarget, foldersProcessed: foldersProcessed, activeFolderIndex: activeFolderIndex,
                headersChecked: checked, metadataExcluded: metadataExcluded, bodyAttempts: bodyAttempts,
                bodyReadsCompleted: bodyReadsCompleted, bodyCaptured: bodyCaptured,
                adoptedSamples: adoptedSamples, skippedSamples: skippedSamples, tokenUnits: tokenUnits,
                tokenBudget: tokenBudget, batchRequested: requested, batchCompleted: completed, stopReason: stopReason))
        }
        try Task.checkCancellation(); report(.starting)
        let configuration: [String: Any] = ["account_id": account.id, "address": selected,
            "own_addresses": account.addresses, "shared_addresses": shared,
            "author_confirmed": true, "token_budget": tokenBudget]
        var state = try await call("style_capture_start", configuration.merging(["restart": restart]) { _, rhs in rhs })
        let prior = state["checkpoint"] as? [String: Any]
        if (prior != nil && prior?["collection_mode"] as? String != "sent_contents") ||
           (state["acquisition_done"] as? Bool == true && (state["counts"] as? [String: Int])?["captured"] == 0) {
            // Indexed checkpoints cannot be interpreted as content positions.
            // The previous published profile remains until this capture succeeds.
            state = try await call("style_capture_start", configuration.merging(["restart": true]) { _, rhs in rhs })
        }
        guard let captureID = state["capture_id"] as? String, !captureID.isEmpty else {
            throw AppFailure("STYLE_CAPTURE_RESPONSE_INVALID")
        }
        var checkpoint: Any = state["checkpoint"] ?? NSNull()
        let saved: StyleContentContinuation?
        if checkpoint is NSNull { saved = nil }
        else {
            do {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let value = try decoder.decode(StyleContentContinuation.self,
                    from: JSONSerialization.data(withJSONObject: checkpoint))
                try value.validate(accountID: account.id, captureID: captureID)
                guard value.candidates.allSatisfy({ $0.sender == selected }) else { throw MailIndexError.invalidMetadata }
                saved = value
            } catch { throw AppFailure("STYLE_CAPTURE_CHECKPOINT_CHANGED") }
        }
        let counts = state["counts"] as? [String: Int] ?? [:]
        adoptedSamples = counts["captured"] ?? 0; tokenUnits = counts["token_estimate"] ?? 0
        skippedSamples = (state["skipped"] as? [String: Int] ?? [:]).values.reduce(0, +)
        if let saved {
            checked = saved.headersChecked; metadataExcluded = saved.metadataExcluded
            bodyAttempts = saved.bodyAttempts; bodyReadsCompleted = saved.bodyReadsCompleted; bodyCaptured = saved.bodyCaptured
            knownFolderCount = saved.folderCount; knownSentMessageCount = saved.sentCount
            headerTarget = min(saved.sentCount, 4_096)
            guard checked == counts["candidates_checked"] else { throw AppFailure("STYLE_CAPTURE_CHECKPOINT_CHANGED") }
        }
        let durable = try await call("style_capture_read_budget", ["capture_id": captureID])
        guard let reserved = durable["reserved_attempts"] as? Int, let charged = durable["captured_bytes"] as? Int,
              let pending = durable["unresolved_bytes"] as? Int, charged >= 0, pending >= 0,
              pending <= SentStyleReadBudget.defaultMaximumCapturedBytes - charged else {
            throw AppFailure("STYLE_CAPTURE_RESPONSE_INVALID")
        }
        readBudget = try .init(resumingBodyAttempts: reserved, capturedBytes: charged + pending)
        var capped = false
        var firstReadFailure: MailEventContext?
        do {
            try Task.checkCancellation()
            if state["acquisition_done"] as? Bool != true,
               adoptedSamples >= 512 || state["budget_reached"] as? Bool == true {
                stopReason = adoptedSamples >= 512 ? .sampleLimit : .tokenBudget
                report(.finishingAcquisition)
                state = try await call("style_capture_finish", ["capture_id": captureID, "status": "complete", "source_exhausted": false])
                try Task.checkCancellation()
            }
            if state["acquisition_done"] as? Bool != true {
                report(.discoveringMailboxes)
                let boxes = try await Diagnostics.measure(.styleDiscovery, request: requestID) {
                    try await mail.styleMailboxes(accountID: account.id)
                }
                try Task.checkCancellation()
                guard boxes.count <= MailIndexLimits.folders,
                      boxes.allSatisfy({ $0.accountID == account.id && $0.role == .sent && !$0.isLocal &&
                          (0...Int(Int32.max)).contains($0.messageCount) }) else {
                    throw AppFailure("STYLE_SENT_MAILBOX_INVALID")
                }
                if let saved {
                    guard boxes.indices.contains(saved.folderIndex), boxes[saved.folderIndex].path == saved.pageCursor.mailboxPath else {
                        throw AppFailure("STYLE_CAPTURE_CHECKPOINT_CHANGED")
                    }
                }
                knownFolderCount = boxes.count; knownSentMessageCount = boxes.reduce(0) { $0 + $1.messageCount }
                headerTarget = min(knownSentMessageCount ?? 0, 4_096); phase = .collecting
                for (folderIndex, box) in boxes.enumerated() {
                    if capped { break }
                    if let saved, folderIndex < saved.folderIndex { foldersProcessed += 1; continue }
                    activeFolderIndex = folderIndex + 1
                    var cursor: MailIndexCursor? = .init(accountID: account.id, mailboxPath: box.path,
                        expectedCount: box.messageCount, scanID: captureID, role: .sent)
                    var resumed = saved.flatMap { $0.folderIndex == folderIndex ? $0 : nil }
                    if let resumed { cursor = resumed.pageCursor }
                    while let current = cursor, !capped {
                        try Task.checkCancellation()
                        let candidates: [StyleCandidate], nextCursor: MailIndexCursor?
                        var offset = 0, pageScanned = 0
                        var firstBatch = true
                        if let stored = resumed {
                            candidates = stored.candidates; nextCursor = stored.nextCursor
                            offset = stored.nextBodyOffset; firstBatch = false; resumed = nil
                        } else {
                            let limit = min(MailIndexLimits.metadata, 4_096 - checked)
                            if limit == 0 { stopReason = .headerLimit; capped = true; break }
                            report(.readingHeaders)
                            let page = try await Diagnostics.measure(.styleMetadata, request: requestID) {
                                try await mail.styleCandidates(cursor: current, limit: limit)
                            }
                            try Task.checkCancellation(); try page.validate(for: current, limit: limit)
                            pageScanned = page.records.count; checked += pageScanned
                            candidates = page.records.filter {
                                SentStyleSelection.address($0.sender) == selected && $0.messageSize <= MailBodyBatch.maximumBytes
                            }.map { .init(position: $0.position, sender: selected, messageSize: $0.messageSize) }
                            metadataExcluded += page.records.count - candidates.count
                            nextCursor = page.nextCursor
                        }
                        if !firstBatch && offset == candidates.count { cursor = nextCursor; continue }
                        repeat {
                            try Task.checkCancellation()
                            let allowance = min(4, readBudget.batchCount(for: (candidates.count - offset) * 2) / 2)
                            if allowance == 0 && offset < candidates.count { stopReason = .readLimit; capped = true; break }
                            let pending = candidates.dropFirst(offset).prefix(allowance)
                            var bytes = 0
                            let batchCandidates = pending.prefix { candidate in
                                guard bytes + candidate.messageSize <= MailBodyBatch.maximumBytes else { return false }
                                bytes += candidate.messageSize; return true
                            }
                            let batch = StyleContentBatch(cursor: current, candidates: Array(batchCandidates))
                            let count = batch.candidates.count
                            var reads: [StyleContentRead] = []
                            let attemptID = UUID().uuidString
                            if count > 0 {
                                _ = try await call("style_capture_read_reserve", ["capture_id": captureID, "attempt_id": attemptID, "reads": count * 2])
                                try Task.checkCancellation(); try readBudget.reserve(count * 2)
                                bodyAttempts += count; report(.readingBodies, requested: count)
                                reads = try await Diagnostics.measure(.styleBody, request: requestID, count: count) {
                                    try await mail.styleContents(batch: batch)
                                }
                                try Task.checkCancellation()
                                try StyleContentLimits.validate(reads: reads, for: batch)
                                let sizes = reads.map { $0.body?.utf8.count ?? 0 }
                                _ = try await call("style_capture_read_charge", ["capture_id": captureID, "attempt_id": attemptID, "captured_bytes": sizes.reduce(0, +)])
                                try Task.checkCancellation(); try readBudget.record(Array(repeating: 0, count: count) + sizes)
                                bodyReadsCompleted += count; bodyCaptured += reads.filter { $0.body != nil }.count
                                if firstReadFailure == nil, let unavailable = reads.first(where: { $0.body == nil }), let code = unavailable.nativeCode {
                                    firstReadFailure = .init(operation: .styleContents, stage: .body, nativeCode: code)
                                }
                                report(.readingBodies, requested: count, completed: count)
                            }
                            try Task.checkCancellation()
                            let rows: [[String: Any]] = reads.map { ["position": $0.candidate.position,
                                "mailbox_path": current.mailboxPath, "sender": $0.candidate.sender,
                                "body": $0.body as Any? ?? NSNull(), "nativeCode": $0.nativeCode as Any? ?? NSNull()] }
                            let ipcBatches = rows.isEmpty ? [[]] : try MailSnapshotPayload.batches(rows)
                            var committed = 0
                            for rows in ipcBatches {
                                committed += rows.count
                                let continuation = StyleContentContinuation(folderIndex: folderIndex, pageCursor: current,
                                    nextCursor: nextCursor, candidates: candidates, nextBodyOffset: offset + committed,
                                    pageCompleted: offset + committed == candidates.count,
                                    headersChecked: checked, metadataExcluded: metadataExcluded, bodyAttempts: bodyAttempts,
                                    bodyReadsCompleted: bodyReadsCompleted, bodyCaptured: bodyCaptured, cachedBodies: 0,
                                    budgetAttempts: readBudget.bodyAttempts, capturedBytes: readBudget.capturedBytes,
                                    folderCount: boxes.count, sentCount: knownSentMessageCount ?? 0)
                                let next = try MailSnapshotPayload.encode(continuation)
                                report(.savingSamples, requested: count, completed: count)
                                try Task.checkCancellation()
                                state = try await call("style_capture_content_page", ["capture_id": captureID,
                                    "expected_checkpoint": checkpoint, "checkpoint": next, "records": rows,
                                    "candidates_checked": firstBatch ? pageScanned : 0, "done": false])
                                firstBatch = false; checkpoint = next
                                try Task.checkCancellation()
                                let counts = state["counts"] as? [String: Int] ?? [:]
                                adoptedSamples = counts["captured"] ?? 0; tokenUnits = counts["token_estimate"] ?? 0
                                skippedSamples = (state["skipped"] as? [String: Int] ?? [:]).values.reduce(0, +)
                                report(.savingSamples, requested: count, completed: count)
                                capped = state["budget_reached"] as? Bool == true || adoptedSamples >= 512 || readBudget.isExhausted
                                if capped { break }
                            }
                            offset += count
                        } while offset < candidates.count && !capped
                        if checked >= 4_096 && !capped { stopReason = .headerLimit; capped = true }
                        cursor = nextCursor
                    }
                    if cursor == nil && !capped { foldersProcessed += 1 }
                }
                try Task.checkCancellation(); activeFolderIndex = nil
                if stopReason == nil {
                    stopReason = adoptedSamples >= 512 ? .sampleLimit : state["budget_reached"] as? Bool == true ? .tokenBudget :
                        readBudget.isExhausted ? .readLimit : .sourceExhausted
                }
                report(.finishingAcquisition)
                _ = try await call("style_capture_finish", ["capture_id": captureID, "status": "complete", "source_exhausted": !capped])
                try Task.checkCancellation()
            }
            phase = .analyzing; report(.analyzing)
            let result = try await Diagnostics.measure(.styleExtract, request: requestID) {
                try await worker.call("style_capture_extract", ["capture_id": captureID])
            }
            try Task.checkCancellation(); phase = .completed; report(.idle)
            return result
        } catch {
            let w = worker
            _ = await Task.detached { try? await w.call("style_capture_finish", ["capture_id": captureID, "status": "cancelled"]) }.value
            if (error as? AppFailure)?.baseCode == "STYLE_INDEXED_SENT_EXAMPLES_REQUIRED", let context = firstReadFailure {
                throw AppFailure("STYLE_EXAMPLES_UNAVAILABLE__" + context.code, mailContext: context, location: .styleCapture)
            }
            throw error
        }
    }
    private func call(_ command: String, _ values: [String: Any]) async throws -> [String: Any] {
        let value = try await Diagnostics.measure(.styleSave, request: requestID) { try await worker.call(command, values) }
        guard let result = value as? [String: Any] else { throw AppFailure("STYLE_CAPTURE_RESPONSE_INVALID") }
        return result
    }
}
