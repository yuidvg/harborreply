import Foundation

public enum DiagnosticEvent: String, Codable, Sendable {
    case loggingEnabled, appStarted, appStopping, phaseChanged, generationCompleted, operationFailed, workerCompleted, workerFailed
    case signInStarted, signInCompleted, signInFailed, signedOut, modelsListed, stageTimed
}
/// Fixed stage names separate nested costs; no source identifiers or content are accepted.
public enum DiagnosticTimingStage: String, Codable, CaseIterable, Sendable {
    case mailQueueWait = "mail.queue_wait", mailEvent = "mail.event", mailDecode = "mail.decode"
    case workerEncode = "worker.encode", workerQueueWait = "worker.queue_wait", workerLaunch = "worker.launch"
    case workerRequest = "worker.request", workerDecode = "worker.decode"
    case styleAccounts = "style.accounts", styleDiscovery = "style.discovery", styleMetadata = "style.metadata"
    case styleBody = "style.body", styleSave = "style.save", styleExtract = "style.extract"
    case bodyCacheLookup = "body.cache_lookup", bodyCacheValidation = "body.cache_validation"
    case bodyBulkRead = "body.bulk_read", bodyCacheSave = "body.cache_save"
    case bodyScalarRetry = "body.scalar_retry"
    case indexDiscovery = "index.discovery", indexMetadata = "index.metadata", indexBody = "index.body", indexSave = "index.save"
    case replyPrepare = "reply.prepare", replyProvider = "reply.provider", replyValidate = "reply.validate"
}

/// Wall-clock changes cannot change a measured span. Duration conversion is pure and bounded.
public struct DiagnosticTimer: Sendable {
    private let start: ContinuousClock.Instant
    public init() { start = ContinuousClock.now }
    public var elapsedMilliseconds: Int { Self.milliseconds(start.duration(to: .now)) }
    public static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let value = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
        return Int(max(0, min(86_400_000, value)))
    }
}
public enum DiagnosticFailure: String, Codable, Sendable {
    case mail, provider, localOperation, cancelled, unknown
}
public enum DiagnosticLocation: String, Codable, CaseIterable, Sendable {
    case mailCapture = "mail.capture"
    case mailDraftCreate = "mail.draft.create"
    case mailDraftSnapshot = "mail.draft.snapshot"
    case mailDraftInsert = "mail.draft.insert"
    case relatedPrepare = "related.prepare"
    case relatedIndexStatus = "related.index_status"
    case relatedOverview = "related.overview"
    case relatedSource = "related.source"
    case mailIndexDiscovery = "mail.index.discovery"
    case mailIndexMetadata = "mail.index.metadata"
    case mailIndexBody = "mail.index.body"
    case mailIndexCheckpoint = "mail.index.checkpoint"
    case styleAccounts = "mail.style.accounts"
    case styleSent = "mail.style.sent"
    case styleCapture = "mail.style.capture"
    case styleProvider = "style.provider", styleGenerate = "style.generate"
    case workerRequest = "worker.request"
    case workerProcess = "worker.process"
    case workerResponse = "worker.response"
}
public enum DiagnosticFailureCode: String, Codable, CaseIterable, Sendable {
    case appleEvent = "apple_event"
    case selectionRequired = "selection_required"
    case coercion
    case invalidResponse = "invalid_response"
    case workerFailure = "worker_failure"
    case inputLimit = "input_limit"
    case outputLimit = "output_limit"
    case timeout
    case searchBudget = "search_budget"
    case sourceChanged = "source_changed"
    case checkpointChanged = "checkpoint_changed"
    case unknown
}

/// This schema deliberately has no free-text field, URL, path, message ID or content hash.
public struct DiagnosticRecord: Codable, Sendable {
    public let timestamp: Date
    public let event: DiagnosticEvent
    public let request: UUID?
    public let phase: ReplyPhase?
    public let failure: DiagnosticFailure?
    public let location: DiagnosticLocation?
    public let failureCode: DiagnosticFailureCode?
    public let mailStage: MailEventStage?
    public let numericCode: Int?
    public let elapsedMilliseconds: Int?
    public let count: Int?
    public let timingStage: DiagnosticTimingStage?
    public let mailOperation: MailEventOperation?
    public let workerCommand: LocalWorkerCommand?
    public init(event: DiagnosticEvent, request: UUID? = nil, phase: ReplyPhase? = nil,
                failure: DiagnosticFailure? = nil, numericCode: Int? = nil, elapsedMilliseconds: Int? = nil, count: Int? = nil,
                location: DiagnosticLocation? = nil, failureCode: DiagnosticFailureCode? = nil,
                mailStage: MailEventStage? = nil, timingStage: DiagnosticTimingStage? = nil,
                mailOperation: MailEventOperation? = nil, workerCommand: LocalWorkerCommand? = nil) {
        timestamp = Date(); self.event = event; self.request = request; self.phase = phase; self.failure = failure
        self.location = location; self.failureCode = failureCode
        self.mailStage = mailStage
        self.timingStage = timingStage; self.mailOperation = mailOperation; self.workerCommand = workerCommand
        self.numericCode = numericCode.map { max(-100_000, min(100_000, $0)) }
        self.elapsedMilliseconds = elapsedMilliseconds.map { max(0, min(86_400_000, $0)) }
        self.count = count.map { max(0, min(1_000_000, $0)) }
    }
}

/// Owns a small local log file. The lock protects opt-in changes, writes and rotation.
/// It never opens a network connection. Readers must be explicitly authorized separately.
public final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let maxBytes: Int
    private var enabled = false
    private var timingRecords: [DiagnosticRecord] = []
    public init(directory: URL, maxBytes: Int = 1_048_576) { self.directory = directory; self.maxBytes = max(1024, maxBytes) }
    public func setEnabled(_ enabled: Bool) { lock.lock(); defer { lock.unlock() }; self.enabled = enabled }
    /// Bounded metadata-only RAM history remains available without creating files or opting in.
    public func recentTimings() -> [DiagnosticRecord] {
        lock.lock(); defer { lock.unlock() }; return timingRecords
    }
    public func record(_ record: DiagnosticRecord) {
        lock.lock(); defer { lock.unlock() }
        if record.event == .stageTimed, record.timingStage != nil {
            timingRecords.append(record)
            if timingRecords.count > 128 { timingRecords.removeFirst(timingRecords.count - 128) }
        }
        guard enabled else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let current = directory.appendingPathComponent("diagnostics.jsonl")
            let previous = directory.appendingPathComponent("diagnostics.previous.jsonl")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(record); data.append(0x0a)
            let size = ((try? fm.attributesOfItem(atPath: current.path)[.size]) as? NSNumber)?.intValue ?? 0
            if size + data.count > maxBytes {
                if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                if fm.fileExists(atPath: current.path) { try fm.moveItem(at: current, to: previous) }
            }
            if !fm.fileExists(atPath: current.path) { fm.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
            let file = try FileHandle(forWritingTo: current); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
        } catch {
            // Never fall back to raw error text, stdout or network reporting.
        }
    }
}
