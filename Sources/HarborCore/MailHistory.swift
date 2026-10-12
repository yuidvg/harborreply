import Foundation

/// Direction is supplied by the native mailbox's role, never inferred from From.
public enum MailHistoryDirection: String, Codable, Sendable {
    case received, sent, unknown
}

public struct MailAccountIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let addresses: [String]
    public init(id: String, name: String, addresses: [String]) {
        self.id = id; self.name = name; self.addresses = addresses
    }
}

/// Metadata only. The native bridge retains its object reference separately.
public struct MailHistoryItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let windowID: String
    public let accountID: String
    public let mailbox: String
    public let messageID: String
    public let subject: String
    public let sender: String
    public let direction: MailHistoryDirection
    public let dateSent: Date?
    public let dateReceived: Date?
    public let messageSize: Int
    /// Metadata uses zero without fetching attachments. A hydrated message
    /// supplies the actual attachment count; no attachment content is read.
    public let attachmentCount: Int

    public init(id: String, windowID: String, accountID: String, mailbox: String, messageID: String,
                subject: String, sender: String, direction: MailHistoryDirection,
                dateSent: Date? = nil, dateReceived: Date? = nil, messageSize: Int = 0, attachmentCount: Int = 0) {
        self.id = id; self.windowID = windowID; self.accountID = accountID; self.mailbox = mailbox
        self.messageID = messageID; self.subject = subject; self.sender = sender; self.direction = direction
        self.dateSent = dateSent; self.dateReceived = dateReceived; self.messageSize = messageSize
        self.attachmentCount = attachmentCount
    }

    public func withAttachmentCount(_ count: Int) -> MailHistoryItem {
        .init(id: id, windowID: windowID, accountID: accountID, mailbox: mailbox, messageID: messageID,
              subject: subject, sender: sender, direction: direction, dateSent: dateSent, dateReceived: dateReceived,
              messageSize: messageSize, attachmentCount: count)
    }
}

/// A bounded sample of public Mail collections. No date coverage is promised.
public struct MailHistoryWindow: Codable, Equatable, Sendable {
    public let account: MailAccountIdentity
    public let items: [MailHistoryItem]
    public let sampledMailboxes: [String]
    public let perMailboxLimit: Int
    public let isPartial: Bool
    public let orderingGuaranteed: Bool
    public let capturedAt: Date
    public init(account: MailAccountIdentity, items: [MailHistoryItem], sampledMailboxes: [String],
                perMailboxLimit: Int, isPartial: Bool = true, orderingGuaranteed: Bool = false,
                capturedAt: Date = Date()) {
        self.account = account; self.items = items; self.sampledMailboxes = sampledMailboxes
        self.perMailboxLimit = perMailboxLimit; self.isPartial = isPartial
        self.orderingGuaranteed = orderingGuaranteed; self.capturedAt = capturedAt
    }
}

/// Plaintext content and headers for one explicitly selected metadata row.
/// This is not an original MIME archive and does not include attachment data.
public struct MailHistoryMessage: Codable, Equatable, Sendable {
    public let item: MailHistoryItem
    public let target: MailTarget
    public init(item: MailHistoryItem, target: MailTarget) { self.item = item; self.target = target }
}

public enum MailHistoryError: String, LocalizedError, Sendable {
    case unavailable = "MAIL_HISTORY_UNAVAILABLE"
    case accountSelectionRequired = "MAIL_HISTORY_ACCOUNT_SELECTION_REQUIRED"
    case limitExceeded = "MAIL_HISTORY_LIMIT_EXCEEDED"
    case staleWindow = "MAIL_HISTORY_STALE_WINDOW"
    case changedMessage = "MAIL_HISTORY_MESSAGE_CHANGED"
    case invalidMetadata = "MAIL_HISTORY_INVALID_METADATA"
    case messageTooLarge = "MAIL_HISTORY_MESSAGE_TOO_LARGE"
    public var errorDescription: String? { rawValue }
}

/// Pure checks shared by the native adapter and fictional tests. Limits bound
/// returned objects/content; Mail's own collection-count cost is undocumented.
public enum MailHistoryLimits {
    public static let perMailbox = 256
    public static let metadata = 768
    public static let hydratedMessages = 20
    public static let messageBytes = 2 * 1_024 * 1_024

    public static func validate(limit: Int) throws {
        guard (1...perMailbox).contains(limit) else { throw MailHistoryError.limitExceeded }
    }

    public static func validate(records: [MailHistoryItem], in window: MailHistoryWindow) throws {
        guard records.count <= hydratedMessages else { throw MailHistoryError.limitExceeded }
        guard window.items.count <= metadata else { throw MailHistoryError.invalidMetadata }
        guard Set(records.map(\.id)).count == records.count else { throw MailHistoryError.invalidMetadata }
        for row in records {
            guard row.accountID == window.account.id, !row.id.isEmpty, !row.windowID.isEmpty,
                  row.messageSize >= 0, row.attachmentCount >= 0 else { throw MailHistoryError.invalidMetadata }
            guard window.items.contains(row) else { throw MailHistoryError.staleWindow }
            guard row.messageSize <= messageBytes else { throw MailHistoryError.messageTooLarge }
        }
    }

    public static func validate(content: MailTarget, for row: MailHistoryItem) throws {
        guard content.id == row.id, content.account == row.accountID + ":" + row.mailbox,
              content.messageID == row.messageID, content.subject == row.subject, content.sender == row.sender else {
            throw MailHistoryError.changedMessage
        }
        guard content.body.utf8.count <= messageBytes,
              content.headers.utf8.count <= messageBytes - content.body.utf8.count else {
            throw MailHistoryError.messageTooLarge
        }
    }
}
