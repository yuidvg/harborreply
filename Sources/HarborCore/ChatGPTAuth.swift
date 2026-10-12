import Foundation
import CryptoKit
import Security

public enum ChatGPTError: String, Error, LocalizedError, Sendable {
    case cancelled, callback, expiredAttempt, identity, permission, signInRequired, unavailable, usageLimit, ineligible, invalidResponse, storage, listener
    public var errorDescription: String? { "CHATGPT_" + rawValue }
    public var userMessage: String {
        switch self {
        case .cancelled: "ChatGPTへの接続を取り消しました。"
        case .usageLimit: "ChatGPTの利用上限に達しました。「利用状況を管理」でアプリの上限を確認してください。"
        case .ineligible: "このアカウント・地域・ワークスペースではChatGPTプランを利用できません。"
        case .permission: "ログイン済みですが、ChatGPTプランの利用が許可されていません。設定から利用を許可してください。"
        case .signInRequired: "ChatGPTにもう一度ログインしてください。"
        case .callback, .identity: "ログインの確認に失敗しました。もう一度接続してください。"
        case .expiredAttempt: "ログインの待機時間が過ぎました。もう一度接続してください。"
        case .storage: "認証情報をキーチェーンに保存できませんでした。"
        case .listener: "ログインを受け取るローカル接続を開けませんでした。"
        case .unavailable: "ChatGPTへ接続できません。時間をおいて再試行してください。"
        case .invalidResponse: "生成が完了しなかったか、対応しない応答でした。本文は挿入しません。"
        }
    }
}

public enum ChatGPTOAuth {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public static func decode64(_ value: String) -> Data? {
        guard value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4))
    }
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTError.identity }
        return base64url(Data(bytes))
    }
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
    }
}

public struct ChatGPTAttempt: Sendable {
    public let state: String, nonce: String, verifier: String, redirect: URL
    public let clientID: String?, subject: String?, created: Date
    public init(redirect: URL, clientID: String? = nil, subject: String? = nil) throws {
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.port != nil, redirect.path == "/auth/callback", redirect.query == nil, redirect.fragment == nil else { throw ChatGPTError.callback }
        self.redirect = redirect; self.clientID = clientID; self.subject = subject; created = Date()
        state = try ChatGPTOAuth.random(); nonce = try ChatGPTOAuth.random(); verifier = try ChatGPTOAuth.random()
    }
    public func authorize(hostID: String, idTokenHint: String? = nil, requestConsent: Bool = false) -> URL {
        var values = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                      "response_type": "code", "redirect_uri": redirect.absoluteString, "scope": ChatGPTOAuth.scopes,
                      "resource": ChatGPTOAuth.resource, "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": ChatGPTOAuth.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))]
        if clientID == nil { values["agent_name_hint"] = "HarborReply" }
        if clientID != nil { values["id_token_hint"] = idTokenHint }
        if requestConsent { values["prompt"] = "consent" }
        var url = URLComponents(string: ChatGPTOAuth.issuer + "/api/accounts/authorize")!
        url.queryItems = values.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        return url.url!
    }
    public func exchangeFields(callback: URL, now: Date = Date()) throws -> [String: String] {
        guard now.timeIntervalSince(created) < 600 else { throw ChatGPTError.expiredAttempt }
        guard callback.scheme == redirect.scheme, callback.host == redirect.host, callback.port == redirect.port, callback.path == redirect.path,
              callback.fragment == nil, let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              Set(items.map(\.name)).count == items.count else { throw ChatGPTError.callback }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard fields["state"] == state else { throw ChatGPTError.callback }
        if fields["error"] != nil { throw ChatGPTError.cancelled }
        guard let issued = fields["client_id"] ?? clientID, issued.hasPrefix("oaiapp_"), issued.count < 512,
              clientID == nil || issued == clientID, let code = fields["code"], !code.isEmpty, code.count < 16_384 else { throw ChatGPTError.callback }
        return ["grant_type": "authorization_code", "client_id": issued, "code": code, "code_verifier": verifier,
                "redirect_uri": redirect.absoluteString, "resource": ChatGPTOAuth.resource]
    }
}

public struct ChatGPTIdentity: Sendable { public let subject: String; public let email: String }

/// Only RS256 from the pinned OpenAI JWKS is accepted. Security performs RSA verification.
public enum ChatGPTIdentityVerifier {
    public static func verify(_ token: String, jwks: Data, clientID: String, nonce: String?, expectedSubject: String? = nil, now: Date = Date()) throws -> ChatGPTIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard token.count < 32_768, parts.count == 3, let headerData = ChatGPTOAuth.decode64(parts[0]), let body = ChatGPTOAuth.decode64(parts[1]), let signature = ChatGPTOAuth.decode64(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String, let keys = (try JSONSerialization.jsonObject(with: jwks) as? [String: Any])?["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && ($0["use"] as? String ?? "sig") == "sig" && ($0["alg"] as? String ?? "RS256") == "RS256" }),
              let n = jwk["n"] as? String, let e = jwk["e"] as? String, let modulus = ChatGPTOAuth.decode64(n), let exponent = ChatGPTOAuth.decode64(e), modulus.count >= 256, modulus.count <= 1024 else { throw ChatGPTError.identity }
        let der = tagged(0x30, integer(modulus) + integer(exponent))
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: body) as? [String: Any], claims["iss"] as? String == ChatGPTOAuth.issuer,
              let sub = claims["sub"] as? String, !sub.isEmpty, let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970 - 5,
              let iat = claims["iat"] as? Double, iat <= now.timeIntervalSince1970 + 5,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 5,
              expectedSubject == nil || expectedSubject == sub else { throw ChatGPTError.identity }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID), audiences.count == 1 || claims["azp"] as? String == clientID,
              claims["azp"] == nil || claims["azp"] as? String == clientID,
              nonce == nil || claims["nonce"] as? String == nonce else { throw ChatGPTError.identity }
        return .init(subject: sub, email: claims["email"] as? String ?? "ChatGPTアカウント")
    }
    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 })); if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }; return tagged(0x02, bytes)
    }
    private static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        if content.count < 128 { return Data([tag, UInt8(content.count)]) + content }
        var n = content.count; var length: [UInt8] = []
        while n > 0 { length.insert(UInt8(n & 255), at: 0); n >>= 8 }
        return Data([tag, 0x80 | UInt8(length.count)] + length) + content
    }
}

public struct ChatGPTCredential: Codable, Sendable {
    public var accessToken: String, refreshToken: String?, idToken: String
    public var scopes: [String], expires: Date
    public var permitsPlan: Bool { scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke") }
    public static func parse(_ data: Data, previous: ChatGPTCredential? = nil, now: Date = Date()) throws -> ChatGPTCredential {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = value["access_token"] as? String, !token.isEmpty,
              (value["token_type"] as? String)?.lowercased() == "bearer",
              let expires = value["expires_in"] as? Double, expires > 0, expires <= 604_800,
              let id = value["id_token"] as? String ?? previous?.idToken else { throw ChatGPTError.invalidResponse }
        let scopes = (value["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
        return .init(accessToken: token, refreshToken: value["refresh_token"] as? String ?? previous?.refreshToken, idToken: id, scopes: scopes, expires: now.addingTimeInterval(expires))
    }
}
