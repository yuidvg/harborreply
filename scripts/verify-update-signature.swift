import Foundation
import CryptoKit
let args = CommandLine.arguments
// Keys here are PUBLIC. Private signing keys never enter arguments or this verifier.
guard args.count == 4, let rawKey = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
      let data = try? Data(contentsOf: URL(fileURLWithPath: args[2])),
      key.isValidSignature(signature, for: data) else {
    FileHandle.standardError.write(Data("Update signature does not match the configured public key.\n".utf8))
    exit(1)
}
