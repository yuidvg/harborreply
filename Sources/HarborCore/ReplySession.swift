import Foundation

public enum ReplyPhase: String, Codable, Sendable {
    case idle, captured, editing, listening, retrieving, generating, validating, ready, inserted, failed, cancelled, needsResolution
}

public struct MailTarget: Codable, Equatable, Sendable {
    public let id: String
    public let account: String
    public let messageID: String
    public let subject: String
    public let sender: String
    public let body: String
    public let headers: String
    public init(id: String, account: String, messageID: String, subject: String, sender: String, body: String, headers: String = "") {
        self.id = id; self.account = account; self.messageID = messageID; self.subject = subject
        self.sender = sender; self.body = body; self.headers = headers
    }
}

public struct DraftSnapshot: Equatable, Sendable {
    public let id: String
    public let fields: [String]
    public init(id: String, fields: [String]) { self.id = id; self.fields = fields }
}

/// Value state machine. Side effects must obtain a permit immediately before writing.
public struct ReplySession: Sendable {
    public private(set) var requestID = UUID()
    public private(set) var revision = 0
    public private(set) var phase: ReplyPhase = .idle
    public private(set) var target: MailTarget?
    public private(set) var draft: DraftSnapshot?
    public private(set) var insertionAttempted = false

    public init() {}
    public mutating func capture(_ target: MailTarget) {
        self = ReplySession(); self.target = target; phase = .captured
    }
    public mutating func invalidate(_ phase: ReplyPhase = .editing) {
        revision += 1; self.phase = phase
    }
    public mutating func transition(_ next: ReplyPhase) { phase = next }
    public mutating func track(_ draft: DraftSnapshot) { self.draft = draft }
    public func isCurrent(_ id: UUID, _ rev: Int) -> Bool {
        id == requestID && rev == revision && phase != .cancelled && !insertionAttempted
    }
    public mutating func insertionPermit(id: UUID, revision: Int, target: MailTarget, draft: DraftSnapshot) -> Bool {
        guard isCurrent(id, revision), phase == .ready, target == self.target,
              self.draft == draft else { return false }
        insertionAttempted = true // Even an uncertain failure may have written: never retry.
        return true
    }
    public mutating func cancel() { invalidate(.cancelled) }
}

@MainActor public protocol MailClientBridge {
    func capture() async throws -> MailTarget
    func createReply(to: MailTarget, replyAll: Bool, requestID: UUID) async throws -> DraftSnapshot
    func snapshot() async throws -> DraftSnapshot
    func insert(_ text: String, expected: DraftSnapshot) async throws
}
