import XCTest
@testable import HarborCore

final class MailOperationGateTests: XCTestCase {
    func testCancellationBeforeAnEventSuppressesReadAndWrite() {
        let gate = MailOperationGate(); gate.cancel()
        XCTAssertFalse(gate.authorizeOperation(writing: false))
        XCTAssertFalse(gate.authorizeOperation(writing: true))
        XCTAssertFalse(gate.writeAttempted)
        XCTAssertEqual(gate.outcome, .cancelled)
    }

    func testCancellationAfterWritePermitReportsUncertainAndBlocksFurtherEvents() {
        let gate = MailOperationGate()
        XCTAssertTrue(gate.authorizeOperation(writing: false))
        XCTAssertTrue(gate.authorizeOperation(writing: true))
        gate.cancel()
        XCTAssertEqual(gate.outcome, .writeMayHaveCompleted)
        XCTAssertFalse(gate.authorizeOperation(writing: false))
        XCTAssertFalse(gate.authorizeOperation(writing: true))
    }

    func testReadCancellationHasNoPossibleWrite() {
        let gate = MailOperationGate()
        XCTAssertTrue(gate.authorizeOperation(writing: false))
        gate.cancel()
        XCTAssertEqual(gate.outcome, .cancelled)
        XCTAssertFalse(gate.writeAttempted)
    }

    func testQueuedWriteCancellationPreventsItsExecutionPermit() async {
        let queue = DispatchQueue(label: "fixture.cancel-queued-mail")
        let release = DispatchSemaphore(value: 0)
        let blocker = expectation(description: "queue blocked")
        queue.async { blocker.fulfill(); release.wait() }
        await fulfillment(of: [blocker], timeout: 1)
        let gate = MailOperationGate()
        let refused = expectation(description: "queued event refused")
        queue.async {
            XCTAssertFalse(gate.authorizeOperation(writing: true))
            refused.fulfill()
        }
        gate.cancel(); release.signal()
        await fulfillment(of: [refused], timeout: 1)
        XCTAssertEqual(gate.outcome, .cancelled)
        XCTAssertFalse(gate.writeAttempted)
    }

    func testFailedVerificationAfterPermittedFakeWriteRequiresPersistentWarning() {
        enum FixtureFailure: Error { case verification }
        let gate = MailOperationGate()
        var fictionalWrites = 0
        let result: Result<String, Error> = Result {
            XCTAssertTrue(gate.authorizeOperation(writing: true))
            fictionalWrites += 1
            XCTAssertTrue(gate.authorizeOperation(writing: false))
            throw FixtureFailure.verification
        }
        XCTAssertEqual(fictionalWrites, 1)
        XCTAssertEqual(gate.outcome, .active)
        XCTAssertTrue(gate.requiresWriteWarning(after: result))
    }

    func testFailedReadOrRefusedWriteCannotProduceWriteWarning() {
        enum FixtureFailure: Error { case read, cancelled }
        let read = MailOperationGate()
        XCTAssertTrue(read.authorizeOperation(writing: false))
        XCTAssertFalse(read.requiresWriteWarning(after: Result<Void, Error>.failure(FixtureFailure.read)))
        let refused = MailOperationGate(); refused.cancel()
        XCTAssertFalse(refused.authorizeOperation(writing: true))
        XCTAssertFalse(refused.requiresWriteWarning(after: Result<Void, Error>.failure(FixtureFailure.cancelled)))
    }

    func testSuccessfulWriteNeedsWarningOnlyWhenCompletionWasInvalidatedOrCancelled() {
        let gate = MailOperationGate()
        XCTAssertTrue(gate.authorizeOperation(writing: true))
        let success = Result<Void, Error>.success(())
        XCTAssertFalse(gate.requiresWriteWarning(after: success))
        XCTAssertTrue(gate.requiresWriteWarning(after: success, requestInvalidated: true))
        gate.cancel()
        XCTAssertTrue(gate.requiresWriteWarning(after: success))
    }
}
