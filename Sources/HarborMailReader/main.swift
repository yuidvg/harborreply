import Foundation
import MailStoreReadOnly

// Private IPC only. The parent never forwards this stream to diagnostics.
func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}
do {
    guard CommandLine.arguments.count == 2 else { throw StoreFailure.unavailable }
    let store = try ReadOnlyMailStore(root: CommandLine.arguments[1])
    while let entry = try store.next() {
        try emit(["key": entry.key, "fingerprint": entry.fingerprint, "mailbox": entry.mailboxHint])
        guard let action = readLine() else { exit(0) }
        if action == "read" {
            do { try emit(["content": try entry.content().base64EncodedString()]) }
            catch { try emit(["error": (error as? StoreFailure)?.rawValue ?? "unavailable"]) }
        } else if action != "skip" { throw StoreFailure.malformed }
    }
    try emit(["done": true])
} catch {
    try? emit(["error": (error as? StoreFailure)?.rawValue ?? "unavailable"])
    exit(1)
}
