import Foundation
import Security

struct Settings: Codable {
    var cloudEnabled = false
    var endpoint = ""
    var model = ""
    var useChatGPT: Bool?
    var chatgptModel: String?
    var usesChatGPT: Bool { useChatGPT ?? endpoint.isEmpty }
    var ownAddresses = ""
    var sharedAddresses = ""
    // A one-time in-app authorship declaration, scoped to Mail's account ID.
    // Optional so old settings decode without discarding existing preferences.
    var personalMailAccounts: [String]?
    var styleAccountID: String?
    var styleSenderAddress: String?
    var styleCharacterLimit: Int?
    var effectiveStyleCharacterLimit: Int { max(1_024, min(styleCharacterLimit ?? 32_768, 131_072)) }
    var styleTokenBudget: Int?
    var effectiveStyleTokenBudget: Int { max(1_024, min(styleTokenBudget ?? 32_768, 131_072)) }
    var style = "簡潔で丁寧。依頼・禁止・条件は明確に保つ。根拠のない承認や期限を追加しない。"
    var autoInsert = false
    var autoCaptureMail: Bool?
    var capturesMailAutomatically: Bool { autoCaptureMail ?? false }
    var sessionMinutes = 30
    static var directory: URL {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HarborReply", isDirectory: true)
    }
    static func load() -> Settings {
        (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))) ?? Settings()
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = Self.directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum KeyStore {
    static func getOptional(endpoint: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.harborreply.api", kSecAttrAccount as String: endpoint, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw AppFailure("KEYCHAIN_READ_FAILED") }
        return value
    }
    static func set(_ key: String, endpoint: String) throws {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.harborreply.api", kSecAttrAccount as String: endpoint]
        var insert = match; insert[kSecValueData as String] = Data(key.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(match as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary) == errSecSuccess else { throw AppFailure("KEYCHAIN_UPDATE_FAILED") }
        } else if status != errSecSuccess { throw AppFailure("KEYCHAIN_SAVE_FAILED") }
    }
    static func get(endpoint: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.harborreply.api", kSecAttrAccount as String: endpoint, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw AppFailure("API_KEY_REQUIRED") }
        return value
    }
}
