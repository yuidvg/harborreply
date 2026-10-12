import Foundation

public enum SentStyleReadBudgetError: Error, Equatable, Sendable {
    case invalidLimit
    case invalidReservation
    case reservationPending
    case unexpectedResultCount
    case invalidReadSize
    case capturedByteLimitExceeded
}

/// A single acquisition's native-read limits, independent of corpus size and
/// the token budget for accepted authored text. Reserve before calling Mail;
/// failures still count as attempts. Returned UTF-8 body/header bytes are
/// charged afterward. This does not measure Mail's internal I/O or allocations.
public struct SentStyleReadBudget: Sendable {
    public static let defaultMaximumBodyAttempts = 1_024
    public static let defaultMaximumCapturedBytes = 64 * 1_024 * 1_024
    public static let defaultMaximumReadBytes = MailHistoryLimits.messageBytes + 32_768 * 4
    public static let defaultMaximumBatchReads = MailHistoryLimits.hydratedMessages

    public let maximumBodyAttempts: Int
    public let maximumCapturedBytes: Int
    public let maximumReadBytes: Int
    public let maximumBatchReads: Int
    public private(set) var bodyAttempts = 0
    public private(set) var capturedBytes = 0
    private var reservedReads: Int?

    public init() {
        maximumBodyAttempts = Self.defaultMaximumBodyAttempts
        maximumCapturedBytes = Self.defaultMaximumCapturedBytes
        maximumReadBytes = Self.defaultMaximumReadBytes
        maximumBatchReads = Self.defaultMaximumBatchReads
    }

    /// Restores acknowledged acquisition limits, with no pending reservation.
    public init(resumingBodyAttempts: Int, capturedBytes: Int) throws {
        self.init()
        guard (0...maximumBodyAttempts).contains(resumingBodyAttempts),
              (0...maximumCapturedBytes).contains(capturedBytes) else { throw SentStyleReadBudgetError.invalidLimit }
        bodyAttempts = resumingBodyAttempts
        self.capturedBytes = capturedBytes
    }

    public init(maximumBodyAttempts: Int, maximumCapturedBytes: Int,
                maximumReadBytes: Int = Self.defaultMaximumReadBytes,
                maximumBatchReads: Int = Self.defaultMaximumBatchReads) throws {
        guard maximumBodyAttempts >= 0, maximumCapturedBytes >= 0,
              maximumReadBytes > 0, (1...Self.defaultMaximumBatchReads).contains(maximumBatchReads) else {
            throw SentStyleReadBudgetError.invalidLimit
        }
        self.maximumBodyAttempts = maximumBodyAttempts
        self.maximumCapturedBytes = maximumCapturedBytes
        self.maximumReadBytes = maximumReadBytes
        self.maximumBatchReads = maximumBatchReads
    }

    public var isExhausted: Bool {
        bodyAttempts >= maximumBodyAttempts || maximumCapturedBytes - capturedBytes < maximumReadBytes
    }

    /// Reserve only when even the worst permissible result of the entire next
    /// batch fits. A small remaining allowance never authorizes an unbounded
    /// native read on the hope that its real text will be shorter.
    public func batchCount(for eligibleCount: Int) -> Int {
        guard eligibleCount > 0, reservedReads == nil else { return 0 }
        return min(eligibleCount, maximumBatchReads, maximumBodyAttempts - bodyAttempts,
                   (maximumCapturedBytes - capturedBytes) / maximumReadBytes)
    }

    public mutating func reserve(_ count: Int) throws {
        guard reservedReads == nil else { throw SentStyleReadBudgetError.reservationPending }
        guard count > 0, count <= batchCount(for: count) else {
            throw SentStyleReadBudgetError.invalidReservation
        }
        bodyAttempts += count
        reservedReads = count
    }

    /// One value per attempted native read, including zero for a failed read.
    /// Count/size inconsistencies retain the reservation and block new reads;
    /// no partly validated report changes the captured-byte counter.
    public mutating func record(_ byteCounts: [Int]) throws {
        guard let reservedReads, byteCounts.count == reservedReads else {
            throw SentStyleReadBudgetError.unexpectedResultCount
        }
        var remaining = maximumCapturedBytes - capturedBytes
        for count in byteCounts {
            guard (0...maximumReadBytes).contains(count) else { throw SentStyleReadBudgetError.invalidReadSize }
            guard count <= remaining else { throw SentStyleReadBudgetError.capturedByteLimitExceeded }
            remaining -= count
        }
        capturedBytes = maximumCapturedBytes - remaining
        self.reservedReads = nil
    }
}
