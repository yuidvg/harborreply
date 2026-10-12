import XCTest
@testable import HarborCore

final class MailEventContextTests: XCTestCase {
    func testCaptureSelectionGuardPreservesNumericLocationAndUserResolution() throws {
        let context = MailEventContext.fromScript(operation: .capture, number: 9101, stageNumber: 9160)
        XCTAssertEqual(context.nativeCode, 9101)
        XCTAssertEqual(context.stage, .selection)
        XCTAssertEqual(context.code, "MAIL_CAPTURE_SELECTION_EVENT_9101")
        XCTAssertEqual(context.semanticCode, MailCaptureError.selectionRequired.rawValue)
        XCTAssertEqual(context.captureError, .selectionRequired)
        XCTAssertEqual(context.captureError?.diagnosticFailure, .selectionRequired)
        XCTAssertEqual(context.captureError?.userMessage, "Apple Mailの一覧で対象メールを1通だけ選び、もう一度読み込んでください。")
        XCTAssertFalse(context.isShapeFailure)
        XCTAssertEqual(try JSONDecoder().decode(MailEventContext.self, from: JSONEncoder().encode(context)), context)
    }

    func testCaptureLimitGuardHasInputLimitGuidanceWithoutChangingNativeErrors() {
        let limit = MailEventContext.fromScript(operation: .capture, number: 9102, stageNumber: 9177)
        XCTAssertEqual(limit.captureError, .messageTooLarge)
        XCTAssertEqual(limit.captureError?.diagnosticFailure, .inputLimit)
        XCTAssertEqual(limit.code, "MAIL_CAPTURE_METADATA_SIZE_EVENT_9102")
        for number in [-1700, -1708, -1743, 9160, 9999] {
            let native = MailEventContext.fromScript(operation: .capture, number: number, stageNumber: 9160)
            XCTAssertNil(native.captureError)
            XCTAssertNil(native.semanticCode)
        }
        for operation: MailEventOperation in [.history, .indexPage, .create, .unknown] {
            XCTAssertNil(MailEventContext.fromScript(operation: operation, number: 9101, stageNumber: 9160).captureError)
        }
        XCTAssertNil(MailEventContext(operation: .history, stage: .selection, nativeCode: 9101,
                                     semanticCode: MailCaptureError.selectionRequired.rawValue).captureError)
    }

    func testNativeCoercionAndExplicitShapeHaveDifferentOriginalNumbers() {
        let native = MailEventContext.fromScript(operation: .indexPage, number: 9273, stageNumber: 9173)
        let shape = MailEventContext.fromScript(operation: .indexPage, number: 9173, stageNumber: 9171)
        XCTAssertEqual(native.nativeCode, -1700)
        XCTAssertEqual(native.stage, .metadataSubject)
        XCTAssertEqual(native.code, "MAIL_INDEX_PAGE_METADATA_SUBJECT_EVENT_-1700")
        XCTAssertFalse(native.isShapeFailure)
        XCTAssertEqual(shape.nativeCode, 9173)
        XCTAssertEqual(shape.stage, .metadataSubject)
        XCTAssertEqual(shape.code, "MAIL_INDEX_PAGE_METADATA_SUBJECT_SHAPE_9173")
        XCTAssertTrue(shape.isShapeFailure)
    }

    func testEveryMappedNativeStageReconstructsOriginalCoercionWithoutGuessingUnknownNumbers() {
        for number in Array(9160...9195) + Array(9301...9307) {
            guard let stage = MailEventStage.scriptStage(number) else { continue }
            let context = MailEventContext.fromScript(operation: .indexHydrate, number: number + 100)
            XCTAssertEqual(context.nativeCode, -1700)
            XCTAssertEqual(context.stage, stage)
        }
        let unknown = MailEventContext.fromScript(operation: .indexPage, number: 9299, stageNumber: 9173)
        XCTAssertEqual(unknown.nativeCode, 9299)
        XCTAssertEqual(unknown.stage, .metadataSubject)
    }

    func testReturnedRowAndRangeCacheFailuresAreSeparateFromIDPropertyRead() {
        for (number, stage) in [(9193, MailEventStage.metadataRow), (9194, .rangeCapability), (9195, .rangeCapabilityUpdate)] {
            let context = MailEventContext.fromScript(operation: .indexPage, number: -1708, stageNumber: number)
            XCTAssertEqual(context.stage, stage)
            XCTAssertEqual(context.nativeCode, -1708)
            XCTAssertNotEqual(context.code, "MAIL_INDEX_PAGE_METADATA_NATIVE_ID_EVENT_-1708")
        }
    }

    func testScalarGetterFailureKeepsMethodPropertyAndOriginalNumber() throws {
        let stages: [MailEventStage] = [.metadataNativeIDScalar, .metadataMessageIDScalar, .metadataSubjectScalar,
            .metadataSenderScalar, .metadataDateSentScalar, .metadataDateReceivedScalar, .metadataSizeScalar]
        for (offset, stage) in stages.enumerated() {
            let scalar = MailEventContext.fromScript(operation: .indexPage, number: -1708, stageNumber: 9301 + offset)
            XCTAssertEqual(scalar.stage, stage)
            XCTAssertEqual(scalar.nativeCode, -1708)
            XCTAssertEqual(scalar.code, "MAIL_INDEX_PAGE_\(stage.rawValue.uppercased())_EVENT_-1708")
            XCTAssertFalse(scalar.isShapeFailure)
            XCTAssertEqual(try JSONDecoder().decode(MailEventContext.self, from: JSONEncoder().encode(scalar)), scalar)
            let range = MailEventContext.fromScript(operation: .indexPage, number: -1708, stageNumber: 9171 + offset)
            XCTAssertNotEqual(range.code, scalar.code)
        }
    }

    func testUnknownNativeErrorNumbersKeepGetterStageAndOperation() {
        for number in [-1728, -1712, -1743, -600, 9137] {
            let context = MailEventContext.fromScript(operation: .indexHydrate, number: number, stageNumber: 9188)
            XCTAssertEqual(context.nativeCode, number)
            XCTAssertEqual(context.code, "MAIL_INDEX_HYDRATE_MESSAGE_LOOKUP_EVENT_\(number)")
        }
        XCTAssertNotEqual(MailEventContext.fromScript(operation: .indexMailboxes, number: -1700, stageNumber: 9187).code,
                          MailEventContext.fromScript(operation: .indexPage, number: -1700, stageNumber: 9187).code)
    }

    func testAllOperationsIncludeFixedLocationEvenWithoutNumberOrKnownStage() {
        let operations: [MailEventOperation] = [.capture, .history, .hydrate, .indexMailboxes, .indexPage, .indexHydrate,
                                               .styleAccounts, .styleMailboxes, .create, .snapshot, .insert, .unknown]
        for operation in operations {
            let context = MailEventContext.fromScript(operation: operation, number: -1700)
            XCTAssertEqual(context.code, "MAIL_\(operation.rawValue.uppercased())_REQUEST_EVENT_-1700")
            XCTAssertFalse(context.code.hasPrefix("MAIL_EVENT_"))
            let missing = MailEventContext.fromScript(operation: operation, number: nil, stageNumber: 123456)
            XCTAssertEqual(missing.code, "MAIL_\(operation.rawValue.uppercased())_REQUEST_FAILED")
        }
    }

    func testKnownScriptChecksKeepSemanticMeaningAlongsideNumericLocation() {
        XCTAssertEqual(MailEventContext.fromScript(operation: .styleMailboxes, number: 9143, stageNumber: 9178).semanticCode,
                       MailStyleDiscoveryError.sentUnavailable.rawValue)
        XCTAssertEqual(MailEventContext.fromScript(operation: .history, number: 9111, stageNumber: 9181).semanticCode,
                       MailHistoryError.accountSelectionRequired.rawValue)
        XCTAssertEqual(MailEventContext.fromScript(operation: .hydrate, number: 9122, stageNumber: 9169).semanticCode,
                       MailHistoryError.changedMessage.rawValue)
        XCTAssertEqual(MailEventContext.fromScript(operation: .indexPage, number: 9130, stageNumber: 9180).semanticCode,
                       MailIndexError.cursorInvalidated.rawValue)
        let unknown = MailEventContext.fromScript(operation: .indexPage, number: -1728, stageNumber: 9188)
        XCTAssertNil(unknown.semanticCode)
        XCTAssertEqual(unknown.nativeCode, -1728)
    }

    func testWriteUncertaintySemanticSurvivesLocatedDisplayCodeAndRoundTrip() throws {
        let code = "MAIL_CANCELLED_WRITE_UNCERTAIN_PARTIAL_WRITE_POSSIBLE"
        let context = MailEventContext(operation: .insert, stage: .request, nativeCode: nil, semanticCode: code)
        XCTAssertEqual(context.code, "MAIL_INSERT_REQUEST_FAILED")
        XCTAssertEqual(context.semanticCode, code)
        XCTAssertEqual(try JSONDecoder().decode(MailEventContext.self, from: JSONEncoder().encode(context)), context)
    }

    func testSafeContextRejectsPrivateStringsOnInitializationAndDecoding() throws {
        let secret = "[FICTIONAL] subject author@fixture.invalid"
        let context = MailEventContext(operation: .indexPage, stage: .metadataSubject, nativeCode: -1700, semanticCode: secret)
        XCTAssertNil(context.semanticCode)
        let encoded = try JSONEncoder().encode(context)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))
        let input = try JSONSerialization.data(withJSONObject: ["operation": "index_page", "stage": "metadata_subject",
            "nativeCode": -1700, "semanticCode": secret, "isShapeFailure": false])
        XCTAssertNil(try JSONDecoder().decode(MailEventContext.self, from: input).semanticCode)
        XCTAssertNil(MailEventOperation(rawValue: secret))
        XCTAssertNil(MailEventStage(rawValue: secret))
    }

    func testIndividualIndexFailurePreservesContextAndLegacyResultsDecodeWithoutIt() throws {
        let locator = MailIndexLocator(accountID: "fixture-account", mailboxPath: ["Inbox"], nativeID: "42",
            messageID: "42@fixture.invalid", subject: "[FICTIONAL]", sender: "author@fixture.invalid", scanID: "fixture-scan")
        let context = MailEventContext.fromScript(operation: .indexHydrate, number: 9265, stageNumber: 9165)
        let result = MailIndexReadResult(locator: locator, failure: .bodyCoercion, mailContext: context)
        XCTAssertEqual(try JSONDecoder().decode(MailIndexReadResult.self, from: JSONEncoder().encode(result)), result)
        let legacy = MailIndexReadResult(locator: locator, failure: .notFound)
        XCTAssertNil(try JSONDecoder().decode(MailIndexReadResult.self, from: JSONEncoder().encode(legacy)).mailContext)
    }
}
