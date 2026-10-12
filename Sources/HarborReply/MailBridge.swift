import AppKit
import CoreServices
import HarborCore

/// The facade owns request epochs on the main actor. AppleScript and Apple event
/// descriptors remain on one serial queue; only immutable Sendable values cross.
@MainActor final class AppleMailBridge: MailClientBridge {
    private let queue = DispatchQueue(label: "local.harborreply.apple-events", qos: .userInitiated)
    private let engine: MailScriptEngine
    private var epoch: UInt64 = 0
    private var operations: [UUID: MailOperationGate] = [:]

    init() { engine = MailScriptEngine() }

    func clearTracking() {
        epoch &+= 1
        operations.values.forEach { $0.cancel() }
        let engine = engine
        queue.async { engine.clearTracking() }
    }

    /// Consent checks read no Mail content and never launch Mail or show a prompt.
    func canCaptureWithoutPrompt() async -> Bool {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.mail" }) else { return false }
        return (try? await run(.capture) { _, gate in
            guard gate.authorizeOperation(writing: false) else { throw CancellationError() }
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.mail")
            guard let address = target.aeDesc else { return false }
            return AEDeterminePermissionToAutomateTarget(address, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), false) == noErr
        }) ?? false
    }

    func capture() async throws -> MailTarget {
        try await run(.capture) { engine, gate in try engine.capture(gate: gate) }
    }
    func history(for target: MailTarget?, limit: Int) async throws -> MailHistoryWindow {
        try validate(.history) { try MailHistoryLimits.validate(limit: limit) }
        try requireRunning(.history, semanticCode: MailHistoryError.unavailable.rawValue)
        return try await run(.history) { engine, gate in try engine.history(for: target, limit: limit, gate: gate) }
    }
    func hydrate(records: [MailHistoryItem]) async throws -> [MailHistoryMessage] {
        if records.isEmpty { return [] }
        try requireRunning(.hydrate, semanticCode: MailHistoryError.unavailable.rawValue)
        return try await run(.hydrate) { engine, gate in try engine.hydrate(records: records, gate: gate) }
    }
    func indexMailboxes(after cursor: MailMailboxCursor?, limit: Int) async throws -> MailMailboxPage {
        try requireRunning(.indexMailboxes, semanticCode: MailIndexError.unavailable.rawValue)
        return try await run(.indexMailboxes) { engine, gate in try engine.indexMailboxes(after: cursor, limit: limit, gate: gate) }
    }
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage {
        try validate(.indexPage) { try MailIndexLimits.validate(cursor: cursor, limit: limit) }
        try requireRunning(.indexPage, semanticCode: MailIndexError.unavailable.rawValue)
        return try await run(.indexPage) { engine, gate in try engine.indexPage(cursor: cursor, limit: limit, gate: gate) }
    }
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult] {
        try validate(.indexHydrate) {
            guard locators.count <= MailHistoryLimits.hydratedMessages else { throw MailIndexError.limitExceeded }
        }
        if locators.isEmpty { return [] }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
            let context = MailEventContext(operation: .indexHydrate, stage: .preflight, nativeCode: nil, semanticCode: MailIndexError.unavailable.rawValue)
            return locators.map { .init(locator: $0, failure: .unavailable, mailContext: context) }
        }
        return try await run(.indexHydrate) { engine, gate in try engine.hydrateIndexed(locators: locators, gate: gate) }
    }
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult] {
        try validate(.indexHydrate) { try batch.validate() }
        try requireRunning(.indexHydrate, semanticCode: MailIndexError.unavailable.rawValue)
        return try await run(.indexHydrate) { engine, gate in try engine.hydrateIndexedBatch(batch, gate: gate) }
    }
    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int]) async throws -> [Bool] {
        if locators.isEmpty, attachmentCounts.isEmpty { return [] }
        try validate(.indexHydrate) {
            try MailBodyBatch(locators: locators).validate()
            guard attachmentCounts.count == locators.count, attachmentCounts.allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) }) else {
                throw MailIndexError.invalidLocator
            }
        }
        try requireRunning(.indexHydrate, semanticCode: MailIndexError.unavailable.rawValue)
        return try await run(.indexHydrate) { engine, gate in
            try engine.validateCachedIndexed(locators: locators, attachmentCounts: attachmentCounts, gate: gate)
        }
    }
    func bodyReadMetrics() async -> [MailBodyBatchMetrics] {
        (try? await run(.indexHydrate) { engine, _ in engine.bodyReadMetrics() }) ?? []
    }
    func styleCandidates(cursor: MailIndexCursor, limit: Int) async throws -> StyleCandidatePage {
        try validate(.styleCandidates) { try StyleContentLimits.validate(cursor: cursor, limit: limit) }
        try requireRunning(.styleCandidates, semanticCode: MailStyleDiscoveryError.unavailable.rawValue)
        return try await run(.styleCandidates) { engine, gate in try engine.styleCandidates(cursor: cursor, limit: limit, gate: gate) }
    }
    func styleContents(batch: StyleContentBatch) async throws -> [StyleContentRead] {
        try validate(.styleContents) { try batch.validate() }
        try requireRunning(.styleContents, semanticCode: MailStyleDiscoveryError.unavailable.rawValue)
        return try await run(.styleContents) { engine, gate in try engine.styleContents(batch: batch, gate: gate) }
    }
    func styleAccounts() async throws -> [MailAccountIdentity] {
        try requireRunning(.styleAccounts, semanticCode: MailStyleDiscoveryError.unavailable.rawValue)
        return try await run(.styleAccounts) { engine, gate in try engine.styleAccounts(gate: gate) }
    }
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox] {
        try validate(.styleMailboxes) { try MailStyleDiscovery.validate(accountID: accountID) }
        try requireRunning(.styleMailboxes, semanticCode: MailStyleDiscoveryError.unavailable.rawValue)
        return try await run(.styleMailboxes) { engine, gate in try engine.styleMailboxes(accountID: accountID, gate: gate) }
    }
    func createReply(to target: MailTarget, replyAll: Bool, requestID: UUID) async throws -> DraftSnapshot {
        try await run(.create) { engine, gate in try engine.createReply(to: target, replyAll: replyAll, requestID: requestID, gate: gate) }
    }
    func snapshot() async throws -> DraftSnapshot {
        try await run(.snapshot) { engine, gate in try engine.snapshot(gate: gate) }
    }
    func insert(_ text: String, expected: DraftSnapshot) async throws {
        try await run(.insert) { engine, gate in try engine.insert(text, expected: expected, gate: gate) }
    }

    private static func located(_ error: Error, operation: MailEventOperation, stage: MailEventStage) -> Error {
        if error is CancellationError { return error }
        if let error = error as? AppFailure, error.mailContext != nil { return error }
        let prior = error as? AppFailure
        let semanticCode = prior?.baseCode ?? (error as? MailHistoryError)?.rawValue ??
            (error as? MailIndexError)?.rawValue ?? (error as? MailStyleDiscoveryError)?.rawValue ??
            (error as? StyleContentError)?.rawValue
        let context = MailEventContext(operation: operation, stage: stage, nativeCode: nil, semanticCode: semanticCode)
        return AppFailure(context.code, mailContext: context, location: prior?.location,
                          baseCode: prior?.baseCode, writeUncertain: prior?.writeUncertain ?? false)
    }
    private func validate(_ operation: MailEventOperation, _ body: () throws -> Void) throws {
        do { try body() }
        catch { throw Self.located(error, operation: operation, stage: .input) }
    }
    private func requireRunning(_ operation: MailEventOperation, semanticCode: String) throws {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
            let context = MailEventContext(operation: operation, stage: .preflight, nativeCode: nil, semanticCode: semanticCode)
            throw AppFailure(context.code, mailContext: context)
        }
    }

    private func run<Value: Sendable>(_ mailOperation: MailEventOperation, _ operation: @escaping @Sendable (MailScriptEngine, MailOperationGate) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let id = UUID(); let requestedEpoch = epoch; let gate = MailOperationGate()
        operations[id] = gate
        defer { operations[id] = nil }
        let engine = engine; let queue = queue; let queuedAt = DiagnosticTimer()
        let result: Result<Value, Error> = await withTaskCancellationHandler {
            if Task.isCancelled { gate.cancel() }
            return await withCheckedContinuation { continuation in
                queue.async {
                    Diagnostics.timing(.mailQueueWait, started: queuedAt, request: id, mailOperation: mailOperation)
                    let result: Result<Value, Error> = autoreleasepool {
                        Result {
                            guard gate.outcome == .active else { throw CancellationError() }
                            return try operation(engine, gate)
                        }
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { gate.cancel() }
        if gate.requiresWriteWarning(after: result, requestInvalidated: requestedEpoch != epoch || Task.isCancelled) {
            if case let .failure(error) = result, !(error is CancellationError) {
                let located = Self.located(error, operation: mailOperation, stage: .response) as? AppFailure
                // Preserve the exact failed getter and original numeric cause;
                // uncertainty is independent of the display code's spelling.
                throw AppFailure(located?.code ?? "MAIL_\(mailOperation.rawValue.uppercased())_RESPONSE_FAILED",
                                 mailContext: located?.mailContext, location: located?.location,
                                 baseCode: located?.baseCode, writeUncertain: true)
            }
            let context = MailEventContext(operation: mailOperation, stage: .request, nativeCode: nil,
                                           semanticCode: "MAIL_CANCELLED_WRITE_UNCERTAIN_PARTIAL_WRITE_POSSIBLE")
            throw AppFailure(context.code, mailContext: context, writeUncertain: true)
        }
        guard !Task.isCancelled, gate.outcome == .active, requestedEpoch == epoch else { throw CancellationError() }
        do { return try result.get() }
        catch { throw Self.located(error, operation: mailOperation, stage: .response) }
    }
}

/// Identity-bearing, mutable AppleScript state is deliberately isolated to the
/// facade's FIFO queue. No method is called from the main actor or another queue.
private final class MailScriptEngine: @unchecked Sendable {
    private var script: NSAppleScript?
    private var targetDescriptor: NSAppleEventDescriptor?
    private var draftDescriptor: NSAppleEventDescriptor?
    private var capturedTarget: MailTarget?
    private var attemptedInsert = false
    private var historyWindow: MailHistoryWindow?
    private var historyDescriptors: [String: NSAppleEventDescriptor] = [:]
    private var bodyMetrics: [MailBodyBatchMetrics] = []
    func bodyReadMetrics() -> [MailBodyBatchMetrics] { bodyMetrics }
    private func retain(_ metrics: [MailBodyBatchMetrics]) {
        bodyMetrics = Array((bodyMetrics + metrics).suffix(128))
    }
    func clearTracking() {
        // Discarding the script also clears its capture-scoped Sent reference
        // cache; no opaque Mail references survive an epoch reset.
        script = nil; targetDescriptor = nil; draftDescriptor = nil; capturedTarget = nil; attemptedInsert = false
        historyWindow = nil; historyDescriptors = [:]
    }

    private func call(_ operation: String, _ values: [NSAppleEventDescriptor] = [], gate: MailOperationGate) throws -> NSAppleEventDescriptor {
        let eventOperation = operation == "style_content_scalar" ? MailEventOperation.styleContents :
            operation == "index_hydrate_measured" ? MailEventOperation.indexHydrate :
            (MailEventOperation(rawValue: operation) ?? .unknown)
        if script == nil {
            do {
                script = NSAppleScript(source: try MailBridgeResource.source())
            } catch {
                let context = MailEventContext(operation: eventOperation, stage: .scriptResource, nativeCode: nil,
                                               semanticCode: (error as? AppFailure)?.code ?? "MAIL_SCRIPT_RESOURCE_FAILED")
                throw AppFailure(context.code, mailContext: context)
            }
        }
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272, targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: "perform"), forKeyword: 0x736E616D)
        event.setParam(Self.list([.init(string: operation), Self.list(values)]), forKeyword: 0x2D2D2D2D)
        var error: NSDictionary?
        guard let script else {
            let context = MailEventContext(operation: eventOperation, stage: .scriptResource, nativeCode: nil,
                                           semanticCode: "MAIL_SCRIPT_COMPILE_FAILED")
            throw AppFailure(context.code, mailContext: context)
        }
        // Cancellation before this permit suppresses the event. Cancellation
        // after a write permit cannot undo a blocking Apple event: report unsure.
        guard gate.authorizeOperation(writing: operation == "create" || operation == "insert") else { throw CancellationError() }
        let eventTimer = DiagnosticTimer()
        let result = script.executeAppleEvent(event, error: &error)
        Diagnostics.timing(.mailEvent, started: eventTimer, mailOperation: eventOperation)
        if let error {
            // Only the original numeric status crosses the boundary. Apple's
            // error text/brief message may contain private email values.
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            let context = MailEventContext(operation: eventOperation, stage: .scriptExecution, nativeCode: number)
            throw AppFailure(context.code, mailContext: context)
        }
        if eventOperation == .styleContents, result.descriptorType == 0x6C697374,
           result.atIndex(1)?.stringValue == "HARBOR_STYLE_CONTENT_FAILURE_V1" {
            let (context, metrics) = try StyleContentNativeDecoder.failure(result)
            retain(metrics)
            throw AppFailure(context.code, mailContext: context)
        }
        // The static script supplies a fixed, numeric-only failure envelope,
        // preserving getter stage for all error numbers, not just coercions.
        if result.descriptorType == 0x6C697374, result.numberOfItems == 3,
           result.atIndex(1)?.stringValue == "HARBOR_MAIL_FAILURE_V1" {
            guard let number = result.atIndex(2), let stage = result.atIndex(3),
                  number.descriptorType == 0x6C6F6E67, stage.descriptorType == 0x6C6F6E67 else {
                let context = MailEventContext(operation: eventOperation, stage: .response, nativeCode: nil,
                                               semanticCode: "MAIL_FAILURE_ENVELOPE_INVALID")
                throw AppFailure(context.code, mailContext: context)
            }
            let context = MailEventContext.fromScript(operation: eventOperation, number: Int(number.int32Value),
                                                       stageNumber: Int(stage.int32Value))
            throw AppFailure(context.code, mailContext: context)
        }
        return result
    }
    private static func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (offset, value) in values.enumerated() { list.insert(value, at: offset + 1) }
        return list
    }
    private func strings(_ value: NSAppleEventDescriptor) -> [String] {
        guard value.numberOfItems > 0 else { return [] }
        return (1...value.numberOfItems).map { i in
            guard let child = value.atIndex(i) else { return "" }
            if child.numberOfItems > 0 { return strings(child).joined(separator: "\u{001F}") }
            return child.stringValue ?? ""
        }
    }
    func capture(gate: MailOperationGate) throws -> MailTarget {
        let descriptor = try call("capture", gate: gate)
        let fields = decode(.capture) { strings(descriptor) }
        guard fields.count == 7 else { throw AppFailure("MAIL_CAPTURE_SHAPE") }
        targetDescriptor = descriptor
        let target = MailTarget(id: fields[0], account: fields[1], messageID: fields[2], subject: fields[3], sender: fields[4], body: fields[5], headers: fields[6])
        capturedTarget = target
        return target
    }

    /// Only parsing is measured here; the blocking native event has its own span.
    private func decode<Value>(_ operation: MailEventOperation, _ body: () throws -> Value) rethrows -> Value {
        let timer = DiagnosticTimer()
        defer { Diagnostics.timing(.mailDecode, started: timer, mailOperation: operation) }
        return try body()
    }

    func styleCandidates(cursor: MailIndexCursor, limit: Int, gate: MailOperationGate) throws -> StyleCandidatePage {
        let result = try call("style_candidates", [indexCursorDescriptor(cursor), Self.integer(limit)], gate: gate)
        let decoded = try decode(.styleCandidates) { try StyleContentNativeDecoder.candidates(result, cursor: cursor, limit: limit) }
        retain(decoded.metrics)
        return decoded.page
    }
    func styleContents(batch: StyleContentBatch, gate: MailOperationGate) throws -> [StyleContentRead] {
        func rows(_ candidates: [StyleCandidate]) -> NSAppleEventDescriptor {
            Self.list(candidates.map { Self.list([Self.integer($0.position), .init(string: $0.sender), Self.integer($0.messageSize)]) })
        }
        func read(_ candidates: [StyleCandidate], operation: String) throws -> [StyleContentRead] {
            let partial = StyleContentBatch(cursor: batch.cursor, candidates: candidates)
            let result = try call(operation, [indexCursorDescriptor(batch.cursor), rows(candidates)], gate: gate)
            let decoded = try decode(.styleContents) { try StyleContentNativeDecoder.contents(result, batch: partial) }
            retain(decoded.metrics)
            return decoded.reads
        }
        do { return try read(batch.candidates, operation: "style_contents") }
        catch {
            guard let context = (error as? AppFailure)?.mailContext, context.operation == .styleContents,
                  context.stage == .body, !context.isShapeFailure,
                  [-1708, -1712].contains(context.nativeCode ?? 0) else { throw error }
            // Each fallback is a content-only call with a fresh cancellation
            // permit. Failed bulk values are discarded before any scalar read.
            let reads = try batch.candidates.flatMap { try read([$0], operation: "style_content_scalar") }
            try StyleContentLimits.validate(reads: reads, for: batch)
            return reads
        }
    }
    func styleAccounts(gate: MailOperationGate) throws -> [MailAccountIdentity] {
        let result = try call("style_accounts", gate: gate)
        return try decode(.styleAccounts) { try MailMetadataDecoder.styleAccounts(result) }
    }

    func styleMailboxes(accountID: String, gate: MailOperationGate) throws -> [MailIndexMailbox] {
        try MailStyleDiscovery.validate(accountID: accountID)
        let result = try call("style_mailboxes", [.init(string: accountID)], gate: gate)
        return try decode(.styleMailboxes) { try MailMetadataDecoder.styleMailboxes(result, accountID: accountID) }
    }

    func history(for target: MailTarget?, limit: Int, gate: MailOperationGate) throws -> MailHistoryWindow {
        try MailHistoryLimits.validate(limit: limit)
        let expected: NSAppleEventDescriptor
        if let target {
            guard target == capturedTarget, let descriptor = targetDescriptor else { throw MailHistoryError.staleWindow }
            expected = descriptor
        } else { expected = Self.list([]) }
        // Only one bounded window owns native references. A failed replacement
        // cannot leave older references available to another request.
        historyWindow = nil; historyDescriptors = [:]
        let token = UUID().uuidString
        let result = try call("history", [.init(string: token), expected, .init(int32: Int32(limit))], gate: gate)
        let decoded = try decode(.history) {
            try MailMetadataDecoder.historyWindow(result, windowID: token, limit: limit, capturedAt: Date())
        }
        guard let metadata = result.atIndex(2) else { throw MailHistoryError.invalidMetadata }
        let descriptors = try decoded.sourceIndices.mapValues { index in
            guard let descriptor = metadata.atIndex(index + 1) else { throw MailHistoryError.invalidMetadata }
            return descriptor
        }
        historyWindow = decoded.window; historyDescriptors = descriptors
        return decoded.window
    }

    func hydrate(records: [MailHistoryItem], gate: MailOperationGate) throws -> [MailHistoryMessage] {
        guard let window = historyWindow, let token = window.items.first?.windowID else { throw MailHistoryError.staleWindow }
        try MailHistoryLimits.validate(records: records, in: window)
        let expectedRows = try records.map { row -> NSAppleEventDescriptor in
            guard let descriptor = historyDescriptors[row.id] else { throw MailHistoryError.staleWindow }
            return descriptor
        }
        let result = try call("hydrate", [.init(string: token), Self.list(expectedRows)], gate: gate)
        guard result.numberOfItems == records.count else { throw MailHistoryError.invalidMetadata }
        return try decode(.hydrate) {
            try records.enumerated().map { offset, expected in
                guard let descriptor = result.atIndex(offset + 1) else { throw MailHistoryError.changedMessage }
                return try MailMetadataDecoder.hydratedMessage(descriptor, expected: expected)
            }
        }
    }

    private static func integer(_ value: Int) -> NSAppleEventDescriptor { .init(int32: Int32(value)) }
    private static func texts(_ values: [String]) -> NSAppleEventDescriptor { list(values.map { .init(string: $0) }) }
    private static func date(_ value: Date?) -> NSAppleEventDescriptor {
        value.map { .init(date: $0) } ?? .init(typeCode: 0x6D736E67) // AppleScript missing value.
    }
    private func discoveryDescriptor(_ cursor: MailMailboxCursor) throws -> NSAppleEventDescriptor {
        try MailMetadataDecoder.validate(discovery: cursor)
        let frames = cursor.stack.map { frame in
            Self.list([.init(string: frame.accountID), Self.texts(frame.parentPath), Self.integer(frame.nextChild),
                       Self.integer(frame.expectedChildCount ?? -1), .init(boolean: frame.isLocal)])
        }
        return Self.list([.init(string: cursor.scanID), Self.integer(cursor.accountOffset), Self.integer(cursor.expectedAccountCount ?? -1),
                          .init(boolean: cursor.localPhase), Self.list(frames)])
    }
    func indexMailboxes(after cursor: MailMailboxCursor?, limit: Int, gate: MailOperationGate) throws -> MailMailboxPage {
        guard (1...MailIndexLimits.folders).contains(limit) else { throw MailIndexError.limitExceeded }
        let cursor = cursor ?? .init(scanID: UUID().uuidString)
        let result = try call("index_mailboxes", [try discoveryDescriptor(cursor), Self.integer(limit)], gate: gate)
        return try decode(.indexMailboxes) { try MailMetadataDecoder.discoveryPage(result, for: cursor, limit: limit) }
    }

    private func indexCursorDescriptor(_ cursor: MailIndexCursor) -> NSAppleEventDescriptor {
        Self.list([.init(string: cursor.accountID), Self.texts(cursor.mailboxPath), Self.integer(cursor.offset),
                   Self.integer(cursor.expectedCount ?? -1), .init(string: cursor.scanID), .init(boolean: cursor.isLocal),
                   .init(string: cursor.role?.rawValue ?? "unknown")])
    }
    private func locatorDescriptor(_ row: MailIndexLocator) -> NSAppleEventDescriptor {
        Self.list([.init(string: row.accountID), Self.texts(row.mailboxPath), .init(string: row.nativeID),
                   .init(string: row.messageID), .init(string: row.subject), .init(string: row.sender), Self.date(row.dateSent),
                   Self.date(row.dateReceived), .init(string: String(row.messageSize)), .init(string: row.role.rawValue),
                   .init(boolean: row.isLocal), .init(string: row.scanID)])
    }
    func indexPage(cursor: MailIndexCursor, limit: Int, gate: MailOperationGate) throws -> MailIndexPage {
        try MailIndexLimits.validate(cursor: cursor, limit: limit)
        let result = try call("index_page", [indexCursorDescriptor(cursor), Self.integer(limit)], gate: gate)
        return try decode(.indexPage) { try MailMetadataDecoder.indexPage(result, for: cursor, limit: limit) }
    }

    func hydrateIndexed(locators: [MailIndexLocator], gate: MailOperationGate) throws -> [MailIndexReadResult] {
        guard locators.count <= MailHistoryLimits.hydratedMessages else { throw MailIndexError.limitExceeded }
        return try locators.map { locator in
            do { try MailIndexLimits.validate(locator: locator) }
            catch {
                return .init(locator: locator, failure: .invalidLocator, mailContext:
                    .init(operation: .indexHydrate, stage: .input, nativeCode: nil, semanticCode: MailIndexFailure.invalidLocator.rawValue))
            }
            if locator.messageSize > MailHistoryLimits.messageBytes {
                return .init(locator: locator, failure: .tooLarge, mailContext:
                    .init(operation: .indexHydrate, stage: .messageSize, nativeCode: nil, semanticCode: MailIndexFailure.tooLarge.rawValue))
            }
            // A permit per message allows cancellation to suppress the rest of
            // a large body batch without touching capture/draft tracking.
            let result = try call("index_hydrate_measured", [Self.list([locatorDescriptor(locator)])], gate: gate)
            let decoded = try decode(.indexHydrate) { try MailBodyNativeDecoder.messages(result, expected: [locator]) }
            retain(decoded.metrics)
            guard let message = decoded.messages.first else { throw MailIndexError.invalidMetadata }
            return message
        }
    }

    func hydrateIndexedBatch(_ batch: MailBodyBatch, gate: MailOperationGate) throws -> [MailIndexReadResult] {
        try batch.validate()
        guard let firstIndex = batch.firstIndex, let expectedCount = batch.expectedMailboxCount else {
            return try hydrateIndexed(locators: batch.locators, gate: gate)
        }
        let result = try call("index_hydrate_batch", [Self.list(batch.locators.map(locatorDescriptor)),
            Self.integer(firstIndex), Self.integer(expectedCount)], gate: gate)
        let decoded = try decode(.indexHydrate) { try MailBodyNativeDecoder.messages(result, expected: batch.locators) }
        retain(decoded.metrics)
        return decoded.messages
    }

    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int], gate: MailOperationGate) throws -> [Bool] {
        let result = try call("index_cache_validate", [Self.list(locators.map(locatorDescriptor)),
            Self.list(attachmentCounts.map(Self.integer))], gate: gate)
        let decoded = try decode(.indexHydrate) { try MailBodyNativeDecoder.cached(result, count: locators.count) }
        retain(decoded.metrics)
        return decoded.valid
    }

    func createReply(to target: MailTarget, replyAll: Bool, requestID: UUID, gate: MailOperationGate) throws -> DraftSnapshot {
        guard capturedTarget == target, let targetDescriptor else { throw AppFailure("MAIL_NO_MATCHING_TARGET") }
        let d = try call("create", [.init(string: requestID.uuidString), targetDescriptor, .init(boolean: replyAll)], gate: gate)
        draftDescriptor = d; attemptedInsert = false
        return try decode(.create) { try makeSnapshot(d) }
    }
    private func makeSnapshot(_ d: NSAppleEventDescriptor) throws -> DraftSnapshot {
        let fields = strings(d)
        guard fields.count == 8 else { throw AppFailure("MAIL_DRAFT_SHAPE") }
        return .init(id: fields[0], fields: fields)
    }
    func snapshot(gate: MailOperationGate) throws -> DraftSnapshot {
        let result = try call("snapshot", gate: gate)
        return try decode(.snapshot) { try makeSnapshot(result) }
    }
    func insert(_ text: String, expected: DraftSnapshot, gate: MailOperationGate) throws {
        guard !attemptedInsert, let d = draftDescriptor, let t = targetDescriptor,
              try snapshot(gate: gate) == expected else { throw AppFailure("MAIL_DRAFT_CHANGED_OR_ATTEMPTED") }
        attemptedInsert = true
        let result = try call("insert", [d, .init(string: text), t], gate: gate)
        let after = try decode(.insert) { try makeSnapshot(result) }
        let normalize: (String) -> String = { $0.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        guard after.id == expected.id, after.fields.enumerated().allSatisfy({ i, v in i == 3 || v == expected.fields[i] }),
              normalize(after.fields[3]) == normalize(text + "\n\n" + expected.fields[3]) else {
            throw AppFailure("MAIL_INSERT_UNCERTAIN_PARTIAL_WRITE_POSSIBLE")
        }
    }
}
