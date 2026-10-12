import XCTest
@testable import HarborCore

final class DiagnosticLogTests: XCTestCase {
    func testDisabledLogCreatesNothingAndStoppingTakesEffect() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        log.record(.init(event: .appStarted))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        log.setEnabled(true); log.record(.init(event: .loggingEnabled))
        let file = directory.appendingPathComponent("diagnostics.jsonl")
        let before = try Data(contentsOf: file)
        log.setEnabled(false); log.record(.init(event: .operationFailed))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }
    func testSchemaHasOnlyTypedMetadataAndBoundedRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory, maxBytes: 1024); log.setEnabled(true)
        let record = DiagnosticRecord(event: .operationFailed, request: UUID(), phase: .failed, failure: .mail,
                                      numericCode: -1743, elapsedMilliseconds: 4, count: 2,
                                      location: .mailCapture, failureCode: .appleEvent, mailStage: .metadataNativeIDScalar)
        for _ in 0..<100 { log.record(record) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        let allowed: Set<String> = ["timestamp", "event", "request", "phase", "failure", "numericCode", "elapsedMilliseconds", "count", "location", "failureCode", "mailStage"]
        for file in files {
            let data = try Data(contentsOf: file); XCTAssertLessThanOrEqual(data.count, 1024)
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                XCTAssertEqual(Set(fields.keys), allowed)
            }
        }
    }
    func testTypedLocationsAndFailureCodesRejectPrivateStringsAndDropUnmodeledFields() throws {
        let fixture = "author@fixture.invalid /private/fictional/mail.eml [FICTIONAL] quoted subject"
        let record = DiagnosticRecord(event: .operationFailed, failure: .mail, numericCode: -1700,
                                      location: .mailIndexMetadata, failureCode: .coercion, mailStage: .metadataNativeIDScalar)
        let encoder = JSONEncoder()
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        XCTAssertEqual(fields["location"] as? String, "mail.index.metadata")
        XCTAssertEqual(fields["failureCode"] as? String, "coercion")
        XCTAssertEqual(fields["numericCode"] as? Int, -1700)
        XCTAssertEqual(fields["mailStage"] as? String, "metadata_native_id_scalar")
        for field in ["location", "failureCode", "mailStage"] {
            var invalid = fields; invalid[field] = fixture
            XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticRecord.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
        XCTAssertNil(DiagnosticLocation(rawValue: fixture))
        XCTAssertNil(DiagnosticFailureCode(rawValue: fixture))
        fields["errorMessage"] = fixture; fields["sourcePath"] = fixture
        let decoded = try JSONDecoder().decode(DiagnosticRecord.self, from: JSONSerialization.data(withJSONObject: fields))
        let roundtrip = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        XCTAssertFalse(roundtrip.contains(fixture)); XCTAssertFalse(roundtrip.contains("errorMessage"))
        XCTAssertFalse(roundtrip.contains("sourcePath"))
    }
    func testOldRecordsDecodeWithoutLocationsAndAllSupportedLocationsRemainFixedCodes() throws {
        let encoder = JSONEncoder()
        let old = DiagnosticRecord(event: .operationFailed, failure: .mail, numericCode: -1700)
        let bytes = try encoder.encode(old)
        let decoded = try JSONDecoder().decode(DiagnosticRecord.self, from: bytes)
        XCTAssertNil(decoded.location); XCTAssertNil(decoded.failureCode); XCTAssertNil(decoded.mailStage)
        let oldFields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(oldFields["location"]); XCTAssertNil(oldFields["failureCode"])
        for location in DiagnosticLocation.allCases {
            let record = DiagnosticRecord(event: .operationFailed, numericCode: -1700,
                                          location: location, failureCode: .coercion)
            let roundtrip = try JSONDecoder().decode(DiagnosticRecord.self, from: encoder.encode(record))
            XCTAssertEqual(roundtrip.location, location)
            XCTAssertNotNil(location.rawValue.range(of: "^[a-z_.]+$", options: .regularExpression))
        }
        for code in DiagnosticFailureCode.allCases {
            XCTAssertNotNil(code.rawValue.range(of: "^[a-z_]+$", options: .regularExpression))
        }
    }
    func testTimingUnitsUseMonotonicDurationAndClampBeforeIntegerConversion() {
        XCTAssertEqual(DiagnosticTimer.milliseconds(.milliseconds(1_234)), 1_234)
        XCTAssertEqual(DiagnosticTimer.milliseconds(.microseconds(1_999)), 1)
        XCTAssertEqual(DiagnosticTimer.milliseconds(.milliseconds(-1)), 0)
        XCTAssertEqual(DiagnosticTimer.milliseconds(.seconds(Int64.max)), 86_400_000)
        let timer = DiagnosticTimer()
        XCTAssertGreaterThanOrEqual(timer.elapsedMilliseconds, 0)
    }
    func testTimingsRemainBoundedInMemoryWhenDiskLoggingIsDisabled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticLog(directory: directory)
        for index in 0..<200 {
            log.record(.init(event: .stageTimed, elapsedMilliseconds: index, count: index,
                             timingStage: .workerLaunch, workerCommand: .styleCaptureExtract))
        }
        log.record(.init(event: .operationFailed))
        let timings = log.recentTimings()
        XCTAssertEqual(timings.count, 128)
        XCTAssertEqual(timings.first?.elapsedMilliseconds, 72)
        XCTAssertEqual(timings.last?.elapsedMilliseconds, 199)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        log.setEnabled(true)
        log.record(.init(event: .stageTimed, elapsedMilliseconds: 200, timingStage: .mailEvent,
                         mailOperation: .indexPage))
        XCTAssertEqual(log.recentTimings().count, 128)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("diagnostics.jsonl").path))
    }
    func testTimingMetadataCannotEncodePrivateStageOrCommandStrings() throws {
        let record = DiagnosticRecord(event: .stageTimed, request: UUID(), elapsedMilliseconds: 12,
                                      count: 20, timingStage: .styleBody,
                                      mailOperation: .indexHydrate, workerCommand: .styleCapturePage)
        let encoder = JSONEncoder()
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["timestamp", "event", "request", "elapsedMilliseconds", "count", "timingStage", "mailOperation", "workerCommand"])
        XCTAssertEqual(fields["timingStage"] as? String, "style.body")
        XCTAssertEqual(fields["mailOperation"] as? String, "index_hydrate")
        XCTAssertEqual(fields["workerCommand"] as? String, "style_capture_page")
        for field in ["timingStage", "mailOperation", "workerCommand"] {
            var invalid = fields; invalid[field] = "owner@fixture.invalid /private/fictional/mail.eml [FICTIONAL] subject"
            XCTAssertThrowsError(try JSONDecoder().decode(DiagnosticRecord.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
        for stage in DiagnosticTimingStage.allCases {
            XCTAssertNotNil(stage.rawValue.range(of: "^[a-z_.]+$", options: .regularExpression))
        }
    }
}
