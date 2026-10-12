import Foundation

public enum MailOperationCancellationOutcome: Sendable, Equatable {
    case active, cancelled, writeMayHaveCompleted
}

/// Shared cancellation at a serial blocking-API boundary. The lock makes the
/// execution permit and cancellation one decision; it never contains mail data.
public final class MailOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var attemptedWrite = false

    public init() {}

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    public func authorizeOperation(writing: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        attemptedWrite = attemptedWrite || writing
        return true
    }

    public var writeAttempted: Bool {
        lock.lock(); defer { lock.unlock() }
        return attemptedWrite
    }

    public var outcome: MailOperationCancellationOutcome {
        lock.lock(); defer { lock.unlock() }
        return !cancelled ? .active : attemptedWrite ? .writeMayHaveCompleted : .cancelled
    }

    /// A write permit cannot be undone. A failed verification/response after
    /// that permit is as uncertain as cancellation, even if the event returned.
    public func requiresWriteWarning<Value>(after result: Result<Value, Error>, requestInvalidated: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard attemptedWrite else { return false }
        if cancelled || requestInvalidated { return true }
        if case .failure = result { return true }
        return false
    }
}
