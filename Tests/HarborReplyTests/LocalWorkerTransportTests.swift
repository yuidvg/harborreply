import XCTest
@testable import HarborReply

final class LocalWorkerTransportTests: XCTestCase {
    func testConcurrentRequestsKeepTheirResponsesAndCommittedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LocalWorker(database: root.appendingPathComponent("fixture.invalid.sqlite"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let result = try await worker.call("case_create", ["label": "case-\(index).invalid"])
                    XCTAssertNotNil((result as? [String: Any])?["id"])
                }
            }
            try await group.waitForAll()
        }
        let cases = try await worker.call("cases") as? [[String: Any]]
        XCTAssertEqual(cases?.count, 12)
        do { _ = try await worker.call("message", ["id": "missing.invalid"]); XCTFail("expected missing message") }
        catch { }
        let afterFailure = try await worker.call("cases") as? [[String: Any]]
        XCTAssertEqual(afterFailure?.count, 12)
    }

    func testFixedContractDoesNotCreateDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LocalWorker(database: root.appendingPathComponent("fixture.invalid.sqlite"))
        let result = try await worker.call("contract") as? [String: Any]
        XCTAssertNotNil(result?["schema"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
