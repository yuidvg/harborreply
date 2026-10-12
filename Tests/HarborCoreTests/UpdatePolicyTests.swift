import XCTest
import CryptoKit
@testable import HarborCore

final class UpdatePolicyTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private func envelope(minimum: Int = 28, sequence: Int = 28) throws -> Data {
        let payload = Data("""
        {"schema":1,"sequence":\(sequence),"minimumBuild":\(minimum),"issuedAt":"2026-10-12T00:00:00Z","deadline":"2026-10-15T00:00:00Z","expiresAt":"2027-01-10T00:00:00Z"}
        """.utf8)
        return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(),
            "signature": key.signature(for: payload).base64EncodedString()])
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testMandatoryDeadlineAndExpiry() throws {
        let policy = try UpdatePolicy.verify(envelope(), publicKey: key.publicKey.rawRepresentation)
        XCTAssertNil(policy.restriction(currentBuild: 27, now: date("2026-10-14T00:00:00Z")))
        XCTAssertNotNil(policy.restriction(currentBuild: 27, now: date("2026-10-15T00:00:00Z")))
        XCTAssertNil(policy.restriction(currentBuild: 28, now: date("2026-10-15T00:00:00Z")))
        XCTAssertNotNil(policy.restriction(currentBuild: 28, now: date("2027-01-10T00:00:00Z")))
    }
    func testWrongKeyTamperAndRollbackAreRejected() throws {
        let data = try envelope()
        XCTAssertThrowsError(try UpdatePolicy.verify(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertThrowsError(try UpdatePolicy.verify(data, publicKey: key.publicKey.rawRepresentation, previousSequence: 29))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        object["payload"] = Data("{}".utf8).base64EncodedString()
        XCTAssertThrowsError(try UpdatePolicy.verify(JSONSerialization.data(withJSONObject: object), publicKey: key.publicKey.rawRepresentation))
    }
    func testInvalidSignedPolicyAndFutureClockFailClosed() throws {
        XCTAssertThrowsError(try UpdatePolicy.verify(envelope(minimum: 0), publicKey: key.publicKey.rawRepresentation))
        let policy = try UpdatePolicy.verify(envelope(), publicKey: key.publicKey.rawRepresentation)
        XCTAssertNotNil(policy.restriction(currentBuild: 28, now: date("2026-10-11T00:00:00Z")))
    }
}
