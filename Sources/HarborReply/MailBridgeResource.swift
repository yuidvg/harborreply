import CryptoKit
import Foundation

/// Only bundled public code is read or hashed here, never mail/runtime data.
enum MailBridgeResource {
    static func source() throws -> String {
        guard let url = Bundle.module.url(forResource: "MailBridge", withExtension: "applescript", subdirectory: "Resources") else {
            throw AppFailure("MAIL_SCRIPT_RESOURCE_MISSING")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func fingerprint() throws -> String {
        SHA256.hash(data: Data(try source().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
