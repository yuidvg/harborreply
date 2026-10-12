import Foundation
import HarborCore

struct MailBodyReadMetrics: Codable, Sendable {
    let lookupMilliseconds: Int
    let validationMilliseconds: Int
    let hydrationMilliseconds: Int
    let saveMilliseconds: Int
    let cacheHits: Int
    let cacheMisses: Int
    let bodyRequests: Int
    let fallbackMilliseconds: Int
    let timeoutFallbacks: Int
    let recoveredBodies: Int
    let unavailableBodies: Int

    init(lookupMilliseconds: Int, validationMilliseconds: Int, hydrationMilliseconds: Int,
         saveMilliseconds: Int, cacheHits: Int, cacheMisses: Int, bodyRequests: Int,
         fallbackMilliseconds: Int = 0, timeoutFallbacks: Int = 0,
         recoveredBodies: Int = 0, unavailableBodies: Int = 0) {
        self.lookupMilliseconds = lookupMilliseconds; self.validationMilliseconds = validationMilliseconds
        self.hydrationMilliseconds = hydrationMilliseconds; self.saveMilliseconds = saveMilliseconds
        self.cacheHits = cacheHits; self.cacheMisses = cacheMisses; self.bodyRequests = bodyRequests
        self.fallbackMilliseconds = fallbackMilliseconds; self.timeoutFallbacks = timeoutFallbacks
        self.recoveredBodies = recoveredBodies; self.unavailableBodies = unavailableBodies
    }

    private enum CodingKeys: String, CodingKey {
        case lookupMilliseconds, validationMilliseconds, hydrationMilliseconds, saveMilliseconds
        case cacheHits, cacheMisses, bodyRequests, fallbackMilliseconds, timeoutFallbacks, recoveredBodies, unavailableBodies
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(lookupMilliseconds: try values.decode(Int.self, forKey: .lookupMilliseconds),
            validationMilliseconds: try values.decode(Int.self, forKey: .validationMilliseconds),
            hydrationMilliseconds: try values.decode(Int.self, forKey: .hydrationMilliseconds),
            saveMilliseconds: try values.decode(Int.self, forKey: .saveMilliseconds),
            cacheHits: try values.decode(Int.self, forKey: .cacheHits),
            cacheMisses: try values.decode(Int.self, forKey: .cacheMisses),
            bodyRequests: try values.decode(Int.self, forKey: .bodyRequests),
            fallbackMilliseconds: try values.decodeIfPresent(Int.self, forKey: .fallbackMilliseconds) ?? 0,
            timeoutFallbacks: try values.decodeIfPresent(Int.self, forKey: .timeoutFallbacks) ?? 0,
            recoveredBodies: try values.decodeIfPresent(Int.self, forKey: .recoveredBodies) ?? 0,
            unavailableBodies: try values.decodeIfPresent(Int.self, forKey: .unavailableBodies) ?? 0)
    }
    static let empty = Self(lookupMilliseconds: 0, validationMilliseconds: 0,
        hydrationMilliseconds: 0, saveMilliseconds: 0, cacheHits: 0, cacheMisses: 0, bodyRequests: 0)
}

/// Serial native operations and the private worker are effects; cached values
/// are immutable snapshots. Live metadata does not prove unchanged remote bytes.
@MainActor final class MailBodyReader {
    private let mail: any MailSelectionBridge
    private let worker: LocalWorker
    private let requestID: UUID
    private(set) var lastMetrics = MailBodyReadMetrics.empty
    init(mail: any MailSelectionBridge, worker: LocalWorker, requestID: UUID) {
        self.mail = mail; self.worker = worker; self.requestID = requestID
    }

    func read(page: MailIndexPage, selected: [MailIndexLocator], offset: Int) async throws -> [MailIndexReadResult] {
        guard page.records.count <= MailIndexLimits.metadata, selected.count <= MailHistoryLimits.hydratedMessages,
              Set(page.records.map(\.nativeID)).count == page.records.count,
              Set(selected.map(\.nativeID)).count == selected.count,
              selected.allSatisfy({ page.records.contains($0) }) else { throw MailIndexError.invalidMetadata }
        try selected.forEach { try MailIndexLimits.validate(locator: $0) }
        let eligible = selected.filter { $0.messageSize <= MailBodyBatch.maximumBytes }
        let plans = try MailBodyBatchPlanner.plan(page: page.records, selected: eligible, offset: offset,
                                                  expectedCount: page.mailbox.messageCount)
        var results = Dictionary(uniqueKeysWithValues: selected.filter { $0.messageSize > MailBodyBatch.maximumBytes }
            .map { ($0.nativeID, MailIndexReadResult(locator: $0, failure: .tooLarge)) })
        for plan in plans {
            for value in try await read(batch: plan) { results[value.locator.nativeID] = value }
            try Task.checkCancellation()
        }
        return try selected.map {
            guard let value = results[$0.nativeID], value.locator == $0 else { throw MailIndexError.invalidMetadata }
            return value
        }
    }

    func read(batch: MailBodyBatch, useCache: Bool = true,
              willRequest: (Int) -> Void = { _ in }) async throws -> [MailIndexReadResult] {
        try batch.validate()
        try Task.checkCancellation()
        var lookupMs = 0, validationMs = 0, hydrationMs = 0, saveMs = 0, requests = 0
        var fallbackMs = 0, timeoutFallbacks = 0, recoveredBodies = 0, unavailableBodies = 0
        var cached: [Int: MailIndexReadResult] = [:]
        defer {
            lastMetrics = .init(lookupMilliseconds: lookupMs, validationMilliseconds: validationMs,
                hydrationMilliseconds: hydrationMs, saveMilliseconds: saveMs, cacheHits: cached.count,
                cacheMisses: batch.locators.count - cached.count, bodyRequests: requests,
                fallbackMilliseconds: fallbackMs, timeoutFallbacks: timeoutFallbacks,
                recoveredBodies: recoveredBodies, unavailableBodies: unavailableBodies)
        }
        if useCache {
            let timer = DiagnosticTimer()
            let locators = try batch.locators.map { try MailSnapshotPayload.encode($0) }
            let response = try await worker.call("mail_body_cache_lookup", ["locators": locators])
            lookupMs = timer.elapsedMilliseconds
            Diagnostics.timing(.bodyCacheLookup, started: timer, request: requestID, count: batch.locators.count)
            try Task.checkCancellation()
            guard let envelope = response as? [String: Any], let slots = envelope["slots"] as? [Any],
                  slots.count == batch.locators.count else { throw MailIndexError.invalidMetadata }
            let candidates = try slots.enumerated().compactMap { index, value -> (Int, MailIndexReadResult)? in
                if value is NSNull { return nil }
                guard let row = value as? [String: Any] else { throw MailIndexError.invalidMetadata }
                return (index, try Self.cached(row, expected: batch.locators[index]))
            }
            if !candidates.isEmpty {
                let timer = DiagnosticTimer()
                let valid = try await mail.validateCachedIndexed(locators: candidates.map { $0.1.locator },
                    attachmentCounts: candidates.map { $0.1.message?.item.attachmentCount ?? -1 })
                validationMs = timer.elapsedMilliseconds
                Diagnostics.timing(.bodyCacheValidation, started: timer, request: requestID, count: candidates.count)
                try Task.checkCancellation()
                guard valid.count == candidates.count else { throw MailIndexError.invalidMetadata }
                cached = Dictionary(uniqueKeysWithValues: zip(candidates, valid).compactMap {
                    $0.1 ? ($0.0.0, $0.0.1) : nil
                })
            }
        }
        let misses = batch.locators.indices.filter { cached[$0] == nil }
        var results = cached
        var fresh: [MailIndexReadResult] = []
        for indices in Self.contiguous(misses) {
            try Task.checkCancellation()
            let subbatch = MailBodyBatch(locators: indices.map { batch.locators[$0] },
                firstIndex: batch.firstIndex.map { $0 + indices[0] }, expectedMailboxCount: batch.expectedMailboxCount)
            requests += indices.count
            willRequest(indices.count)
            let reads: [MailIndexReadResult]
            do {
                let timer = DiagnosticTimer()
                defer {
                    hydrationMs += timer.elapsedMilliseconds
                    Diagnostics.timing(.bodyBulkRead, started: timer, request: requestID, count: indices.count)
                }
                reads = try await mail.hydrateIndexedBatch(subbatch)
            } catch {
                try Task.checkCancellation()
                guard Self.isBodyTimeout(error, operation: .indexHydrateBatch) else { throw error }
                timeoutFallbacks += 1
                // A timed-out bulk response proves no per-message success. Do
                // not reuse any partial bytes: scalar reads repeat the native
                // before/after identity checks for these exact locators only.
                var isolated: [MailIndexReadResult] = []
                for locator in subbatch.locators {
                    try Task.checkCancellation()
                    requests += 1
                    willRequest(1)
                    let timer = DiagnosticTimer()
                    let read: MailIndexReadResult
                    do {
                        defer {
                            let elapsed = timer.elapsedMilliseconds
                            hydrationMs += elapsed; fallbackMs += elapsed
                            Diagnostics.timing(.bodyScalarRetry, started: timer, request: requestID, count: 1)
                        }
                        read = try await isolatedRead(locator)
                    }
                    try Task.checkCancellation()
                    if read.message != nil, read.failure == nil { recoveredBodies += 1 }
                    if read.failure == .unavailable { unavailableBodies += 1 }
                    isolated.append(read)
                }
                reads = isolated
            }
            try Task.checkCancellation()
            guard reads.count == indices.count, zip(reads, subbatch.locators).allSatisfy({ $0.locator == $1 }) else {
                throw MailIndexError.invalidMetadata
            }
            for (index, read) in zip(indices, reads) { results[index] = read }
            fresh.append(contentsOf: reads)
        }
        if !fresh.isEmpty {
            let timer = DiagnosticTimer()
            for rows in try MailSnapshotPayload.batches(fresh.map(MailSnapshotPayload.record)) {
                _ = try await worker.call("mail_body_cache_store", ["records": rows])
                try Task.checkCancellation()
            }
            saveMs = timer.elapsedMilliseconds
            Diagnostics.timing(.bodyCacheSave, started: timer, request: requestID, count: fresh.count)
        }
        return try batch.locators.indices.map {
            guard let result = results[$0] else { throw MailIndexError.invalidMetadata }
            return result
        }
    }

    private func isolatedRead(_ locator: MailIndexLocator) async throws -> MailIndexReadResult {
        do {
            let reads = try await mail.hydrateIndexed(locators: [locator])
            try Task.checkCancellation()
            guard reads.count == 1, let read = reads.first, read.locator == locator else {
                throw MailIndexError.invalidMetadata
            }
            return read
        } catch {
            try Task.checkCancellation()
            guard Self.isBodyTimeout(error, operation: .indexHydrate),
                  let context = (error as? AppFailure)?.mailContext else { throw error }
            return .init(locator: locator, failure: .unavailable, mailContext: context)
        }
    }

    /// Compatibility retry is restricted to a content-get timeout, never an
    /// ambiguous identity, malformed shape, permissions or metadata failure.
    private static func isBodyTimeout(_ error: Error, operation: MailEventOperation) -> Bool {
        guard let context = (error as? AppFailure)?.mailContext else { return false }
        return context.operation == operation && context.nativeCode == -1712 && !context.isShapeFailure &&
            (context.stage == .body || context.stage == .headers)
    }

    /// A missing middle item must not cause a range to fetch an unrelated body.
    private static func contiguous(_ indices: [Int]) -> [[Int]] {
        indices.reduce(into: [[Int]]()) { groups, index in
            if let last = groups.last?.last, index == last + 1 { groups[groups.count - 1].append(index) }
            else { groups.append([index]) }
        }
    }

    private static func cached(_ row: [String: Any], expected: MailIndexLocator) throws -> MailIndexReadResult {
        guard row["snapshotOrigin"] as? String == "apple_mail_body_cache_snapshot",
              row["snapshotHashVerified"] as? Bool == true, row["liveVerified"] as? Bool == false,
              row["bodyStatus"] as? String == "captured", let body = row["body"] as? String,
              let headers = row["headers"] as? String, let count = row["attachmentCount"] as? Int,
              count >= 0, body.unicodeScalars.count <= 250_000, headers.unicodeScalars.count <= 32_768 else {
            throw MailIndexError.invalidMetadata
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let locator = try decoder.decode(MailIndexLocator.self, from: JSONSerialization.data(withJSONObject: row))
        guard locator == expected else { throw MailIndexError.invalidMetadata }
        let item = MailHistoryItem(id: locator.nativeID, windowID: locator.scanID, accountID: locator.accountID,
            mailbox: locator.mailboxPath.joined(separator: "/"), messageID: locator.messageID, subject: locator.subject,
            sender: locator.sender, direction: locator.role, dateSent: locator.dateSent, dateReceived: locator.dateReceived,
            messageSize: locator.messageSize, attachmentCount: count)
        let target = MailTarget(id: item.id, account: item.accountID + ":" + item.mailbox, messageID: item.messageID,
            subject: item.subject, sender: item.sender, body: body, headers: headers)
        try MailHistoryLimits.validate(content: target, for: item)
        return .init(locator: locator, message: .init(item: item, target: target), fromCache: true)
    }
}
