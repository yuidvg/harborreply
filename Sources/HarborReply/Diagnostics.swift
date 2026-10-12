import Foundation
import HarborCore

enum Diagnostics {
    static let preferenceKey = "contentFreeDiagnosticsEnabled"
    static var directory: URL {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HarborReply", isDirectory: true)
    }
    static let log = DiagnosticLog(directory: directory)
    static func timing(_ stage: DiagnosticTimingStage, started: DiagnosticTimer, request: UUID? = nil,
                       mailOperation: MailEventOperation? = nil, workerCommand: LocalWorkerCommand? = nil, count: Int? = nil) {
        log.record(.init(event: .stageTimed, request: request, elapsedMilliseconds: started.elapsedMilliseconds,
                         count: count, timingStage: stage, mailOperation: mailOperation, workerCommand: workerCommand))
    }
    /// Callers remain on their existing actor; this wrapper adds no tasks or cancellation behavior.
    @MainActor static func measure<Value>(_ stage: DiagnosticTimingStage, request: UUID? = nil,
                                         count: Int? = nil, _ operation: () async throws -> Value) async rethrows -> Value {
        let timer = DiagnosticTimer()
        defer { timing(stage, started: timer, request: request, count: count) }
        return try await operation()
    }
    static func record(_ event: DiagnosticEvent, request: UUID? = nil, phase: ReplyPhase? = nil,
                       failure: DiagnosticFailure? = nil, numericCode: Int? = nil, elapsed: Double? = nil, count: Int? = nil,
                       location: DiagnosticLocation? = nil, failureCode: DiagnosticFailureCode? = nil,
                       mailStage: MailEventStage? = nil) {
        log.record(.init(event: event, request: request, phase: phase, failure: failure, numericCode: numericCode,
                         elapsedMilliseconds: elapsed.flatMap { $0.isFinite ? Int(min(86_400_000, max(0, $0 * 1000))) : nil }, count: count,
                         location: location, failureCode: failureCode, mailStage: mailStage))
    }
    static func configure(enabled: Bool, persist: Bool = true) {
        if persist { UserDefaults.standard.set(enabled, forKey: preferenceKey) }
        log.setEnabled(enabled)
        if enabled { record(.loggingEnabled) }
    }
}
