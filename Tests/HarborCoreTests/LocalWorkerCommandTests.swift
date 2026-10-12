import XCTest
@testable import HarborCore

final class LocalWorkerCommandTests: XCTestCase {
    func testErrorCodeIdentifiesCommandAndRejectsUntrustedText() {
        let allowed: Set<String> = ["INDEX_CHECKPOINT_CHANGED", "LOCAL_OPERATION_FAILED"]
        XCTAssertEqual(LocalWorkerCommand.indexPage.failureCode("INDEX_CHECKPOINT_CHANGED", allowed: allowed),
                       "WORKER_INDEX_PAGE__INDEX_CHECKPOINT_CHANGED")
        XCTAssertEqual(LocalWorkerCommand.prepare.failureCode("PRIVATE_BODY_FROM_AUTHOR@FIXTURE.INVALID", allowed: allowed),
                       "WORKER_PREPARE__LOCAL_OPERATION_FAILED")
        XCTAssertNil(LocalWorkerCommand(rawValue: "subject@fixture.invalid"))
        XCTAssertEqual(Set(LocalWorkerCommand.allCases.map(\.rawValue)).count, LocalWorkerCommand.allCases.count)
    }
}
