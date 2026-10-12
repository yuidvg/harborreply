import XCTest
@testable import HarborCore

final class SentStyleReadBudgetTests: XCTestCase {
    func testReadAttemptsAreBoundedIndependentlyOfArchiveSizeAndFailures() throws {
        var measured: [(attempts: Int, batches: Int)] = []
        for corpusSize in [128, 4_096, 100_000] {
            var budget = SentStyleReadBudget()
            var remaining = corpusSize
            var batches = 0
            var peakBatch = 0
            while true {
                let count = budget.batchCount(for: remaining)
                guard count > 0 else { break }
                try budget.reserve(count)
                // Empty/failed reads consume attempts even though the token
                // budget and returned-byte count cannot stop this corpus.
                try budget.record(Array(repeating: 0, count: count))
                remaining -= count; batches += 1; peakBatch = max(peakBatch, count)
            }
            XCTAssertEqual(budget.bodyAttempts, min(corpusSize, 1_024))
            XCTAssertEqual(budget.capturedBytes, 0)
            XCTAssertLessThanOrEqual(peakBatch, 20)
            measured.append((budget.bodyAttempts, batches))
        }
        XCTAssertEqual(measured[1].attempts, measured[2].attempts)
        XCTAssertEqual(measured[1].batches, measured[2].batches)
        XCTAssertEqual(measured[2].batches, 52)
    }

    func testWorstCaseNativeBytesStayBelowCapAndUnusedResidualCannotStartRead() throws {
        var budget = SentStyleReadBudget()
        var peakBatch = 0
        while true {
            let count = budget.batchCount(for: Int.max)
            guard count > 0 else { break }
            try budget.reserve(count)
            try budget.record(Array(repeating: SentStyleReadBudget.defaultMaximumReadBytes, count: count))
            peakBatch = max(peakBatch, count)
        }
        XCTAssertEqual(budget.bodyAttempts, 30)
        XCTAssertLessThanOrEqual(budget.capturedBytes, 64 * 1_024 * 1_024)
        XCTAssertLessThan(budget.maximumCapturedBytes - budget.capturedBytes, budget.maximumReadBytes)
        XCTAssertTrue(budget.isExhausted)
        XCTAssertLessThanOrEqual(peakBatch, 20)
        XCTAssertThrowsError(try budget.reserve(1))
    }

    func testActualUTF8BytesAreChargedAndLaterBatchUsesRemainingWorstCaseAllowance() throws {
        let fictional = "ご確認をお願いいたします。"
        let bytes = fictional.utf8.count
        XCTAssertGreaterThan(bytes, fictional.count)
        var budget = try SentStyleReadBudget(maximumBodyAttempts: 100, maximumCapturedBytes: 300,
                                            maximumReadBytes: 100)
        XCTAssertEqual(budget.batchCount(for: 20), 3)
        try budget.reserve(3)
        try budget.record([bytes, bytes, bytes])
        XCTAssertEqual(budget.capturedBytes, bytes * 3)
        XCTAssertEqual(budget.batchCount(for: 20), (300 - bytes * 3) / 100)
        let next = budget.batchCount(for: 20)
        try budget.reserve(next)
        try budget.record(Array(repeating: 100, count: next))
        XCTAssertLessThanOrEqual(budget.capturedBytes, 300)
        XCTAssertEqual(budget.batchCount(for: 1), 0)
    }

    func testPendingAndInvalidReportsNeverAuthorizeAnotherReadOrPartlyChargeBytes() throws {
        var budget = try SentStyleReadBudget(maximumBodyAttempts: 8, maximumCapturedBytes: 400,
                                            maximumReadBytes: 100)
        try budget.reserve(3)
        XCTAssertEqual(budget.bodyAttempts, 3)
        XCTAssertEqual(budget.batchCount(for: 1), 0)
        XCTAssertThrowsError(try budget.reserve(1)) { XCTAssertEqual($0 as? SentStyleReadBudgetError, .reservationPending) }
        XCTAssertThrowsError(try budget.record([30, 40])) { XCTAssertEqual($0 as? SentStyleReadBudgetError, .unexpectedResultCount) }
        XCTAssertThrowsError(try budget.record([30, 40, 101])) { XCTAssertEqual($0 as? SentStyleReadBudgetError, .invalidReadSize) }
        XCTAssertThrowsError(try budget.record([30, 40, -1])) { XCTAssertEqual($0 as? SentStyleReadBudgetError, .invalidReadSize) }
        XCTAssertEqual(budget.capturedBytes, 0)
        XCTAssertEqual(budget.batchCount(for: 1), 0)
        try budget.record([30, 40, 0])
        XCTAssertEqual(budget.capturedBytes, 70)
        XCTAssertEqual(budget.bodyAttempts, 3)
        XCTAssertEqual(budget.batchCount(for: 20), 3)
    }

    func testZeroExhaustedAndInvalidLimitsFailClosedWithoutArithmeticOverflow() throws {
        let none = try SentStyleReadBudget(maximumBodyAttempts: 0, maximumCapturedBytes: 0)
        XCTAssertTrue(none.isExhausted); XCTAssertEqual(none.batchCount(for: Int.max), 0)
        for (attempts, bytes, read, batch) in [(-1, 400, 100, 20), (4, -1, 100, 20),
                                             (4, 400, 0, 20), (4, 400, 100, 21)] {
            XCTAssertThrowsError(try SentStyleReadBudget(maximumBodyAttempts: attempts, maximumCapturedBytes: bytes,
                                                        maximumReadBytes: read, maximumBatchReads: batch))
        }
        var maximum = try SentStyleReadBudget(maximumBodyAttempts: Int.max, maximumCapturedBytes: Int.max,
                                             maximumReadBytes: Int.max)
        XCTAssertEqual(maximum.batchCount(for: Int.max), 1)
        try maximum.reserve(1); try maximum.record([Int.max])
        XCTAssertEqual(maximum.capturedBytes, Int.max)
        XCTAssertEqual(maximum.batchCount(for: Int.max), 0)
        XCTAssertTrue(maximum.isExhausted)
    }
}
