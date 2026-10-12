import Foundation
import CryptoKit

/// Public release metadata only. Signature verification precedes JSON interpretation.
public struct UpdatePolicy: Codable, Equatable, Sendable {
    public let schema: Int
    public let sequence: Int
    public let minimumBuild: Int
    public let deadline: Date
    public let issuedAt: Date
    public let expiresAt: Date

    public enum Failure: Error { case invalidSignature, invalidPolicy, rollback }
    public static func verify(_ envelope: Data, publicKey: Data, previousSequence: Int = 0) throws -> Self {
        struct Envelope: Decodable { let payload: String; let signature: String }
        guard envelope.count <= 32_768 else { throw Failure.invalidPolicy }
        let wrapped = try JSONDecoder().decode(Envelope.self, from: envelope)
        guard let payload = Data(base64Encoded: wrapped.payload),
              let signature = Data(base64Encoded: wrapped.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else { throw Failure.invalidSignature }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let policy = try decoder.decode(Self.self, from: payload)
        guard policy.schema == 1, policy.sequence > 0, policy.minimumBuild > 0,
              policy.expiresAt > policy.issuedAt, policy.deadline >= policy.issuedAt else { throw Failure.invalidPolicy }
        guard policy.sequence >= previousSequence else { throw Failure.rollback }
        return policy
    }

    public func restriction(currentBuild: Int, now: Date) -> String? {
        if now >= deadline && currentBuild < minimumBuild {
            return "このバージョンは更新が必要です。文章をコピーしてから、メニューの「アップデートを確認…」で更新してください。"
        }
        if now >= expiresAt || issuedAt.timeIntervalSince(now) > 300 {
            return "更新情報を確認するためインターネットに接続してください。確認できるまで新しい生成を停止しています。"
        }
        return nil
    }
}
