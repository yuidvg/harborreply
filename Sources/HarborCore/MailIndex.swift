import Foundation

/// Names are Mail's object hierarchy, not filesystem paths. No native object
/// references or mail content enter a persisted discovery checkpoint.
public struct MailIndexFolderCursor: Codable, Equatable, Sendable {
    public let accountID: String
    public let parentPath: [String]
    public let nextChild: Int
    public let expectedChildCount: Int?
    public let isLocal: Bool
    public init(accountID: String, parentPath: [String] = [], nextChild: Int = 0,
                expectedChildCount: Int? = nil, isLocal: Bool = false) {
        self.accountID = accountID; self.parentPath = parentPath; self.nextChild = nextChild
        self.expectedChildCount = expectedChildCount; self.isLocal = isLocal
    }
}

public struct MailMailboxCursor: Codable, Equatable, Sendable {
    public let scanID: String
    public let accountOffset: Int
    public let expectedAccountCount: Int?
    public let localPhase: Bool
    public let stack: [MailIndexFolderCursor]
    public init(scanID: String, accountOffset: Int = 0, expectedAccountCount: Int? = nil,
                localPhase: Bool = false, stack: [MailIndexFolderCursor] = []) {
        self.scanID = scanID; self.accountOffset = accountOffset; self.expectedAccountCount = expectedAccountCount
        self.localPhase = localPhase; self.stack = stack
    }
}

public struct MailIndexMailbox: Codable, Equatable, Sendable {
    public let accountID: String
    public let path: [String]
    public let name: String
    public let messageCount: Int
    public let role: MailHistoryDirection
    public let isLocal: Bool
    public init(accountID: String, path: [String], name: String, messageCount: Int,
                role: MailHistoryDirection = .unknown, isLocal: Bool = false) {
        self.accountID = accountID; self.path = path; self.name = name; self.messageCount = messageCount
        self.role = role; self.isLocal = isLocal
    }
}

public struct MailMailboxPage: Codable, Equatable, Sendable {
    public let scanID: String
    public let mailboxes: [MailIndexMailbox]
    public let accounts: [MailAccountIdentity]
    public let nextCursor: MailMailboxCursor?
    public init(scanID: String, mailboxes: [MailIndexMailbox], accounts: [MailAccountIdentity] = [], nextCursor: MailMailboxCursor?) {
        self.scanID = scanID; self.mailboxes = mailboxes; self.accounts = accounts; self.nextCursor = nextCursor
    }
}

public struct MailIndexCursor: Codable, Equatable, Sendable {
    public let accountID: String
    public let mailboxPath: [String]
    public let offset: Int
    public let expectedCount: Int?
    public let scanID: String
    public let isLocal: Bool
    /// Advisory only. The native adapter always recomputes the mailbox role.
    public let role: MailHistoryDirection?
    public init(accountID: String, mailboxPath: [String], offset: Int = 0, expectedCount: Int? = nil,
                scanID: String, isLocal: Bool = false, role: MailHistoryDirection? = nil) {
        self.accountID = accountID; self.mailboxPath = mailboxPath; self.offset = offset
        self.expectedCount = expectedCount; self.scanID = scanID; self.isLocal = isLocal; self.role = role
    }
    private enum CodingKeys: String, CodingKey { case accountID, mailboxPath, offset, expectedCount, scanID, isLocal, role }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(String.self, forKey: .accountID); mailboxPath = try c.decode([String].self, forKey: .mailboxPath)
        offset = try c.decode(Int.self, forKey: .offset); expectedCount = try c.decodeIfPresent(Int.self, forKey: .expectedCount)
        scanID = try c.decode(String.self, forKey: .scanID); isLocal = try c.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
        role = try c.decodeIfPresent(MailHistoryDirection.self, forKey: .role)
    }
}

/// Stable locator plus captured metadata. Hydration resolves only this mailbox
/// and its native message ID, then checks the captured metadata again.
public struct MailIndexLocator: Codable, Equatable, Sendable {
    public let accountID: String
    public let mailboxPath: [String]
    public let nativeID: String
    public let messageID: String
    public let subject: String
    public let sender: String
    public let dateSent: Date?
    public let dateReceived: Date?
    public let messageSize: Int
    public let role: MailHistoryDirection
    public let isLocal: Bool
    public let scanID: String
    public init(accountID: String, mailboxPath: [String], nativeID: String, messageID: String, subject: String,
                sender: String, dateSent: Date? = nil, dateReceived: Date? = nil, messageSize: Int = 0,
                role: MailHistoryDirection = .unknown, isLocal: Bool = false, scanID: String) {
        self.accountID = accountID; self.mailboxPath = mailboxPath; self.nativeID = nativeID; self.messageID = messageID
        self.subject = subject; self.sender = sender; self.dateSent = dateSent; self.dateReceived = dateReceived
        self.messageSize = messageSize; self.role = role; self.isLocal = isLocal; self.scanID = scanID
    }
}

public struct MailIndexPage: Codable, Equatable, Sendable {
    public let mailbox: MailIndexMailbox
    public let records: [MailIndexLocator]
    public let nextCursor: MailIndexCursor?
    public let scanID: String
    public init(mailbox: MailIndexMailbox, records: [MailIndexLocator], nextCursor: MailIndexCursor?, scanID: String) {
        self.mailbox = mailbox; self.records = records; self.nextCursor = nextCursor; self.scanID = scanID
    }
}

public enum MailIndexFailure: String, Codable, Sendable {
    case notFound = "MAIL_INDEX_MESSAGE_NOT_FOUND"
    case changed = "MAIL_INDEX_MESSAGE_CHANGED"
    case tooLarge = "MAIL_INDEX_MESSAGE_TOO_LARGE"
    case unavailable = "MAIL_INDEX_READ_UNAVAILABLE"
    case invalidLocator = "MAIL_INDEX_INVALID_LOCATOR"
    case mailboxCoercion = "MAIL_INDEX_MAILBOX_COERCION"
    case metadataCoercion = "MAIL_INDEX_METADATA_COERCION"
    case bodyCoercion = "MAIL_INDEX_BODY_COERCION"
}

public struct MailIndexReadResult: Codable, Equatable, Sendable {
    public let locator: MailIndexLocator
    public let message: MailHistoryMessage?
    public let failure: MailIndexFailure?
    public let mailContext: MailEventContext?
    public let fromCache: Bool
    public init(locator: MailIndexLocator, message: MailHistoryMessage? = nil, failure: MailIndexFailure? = nil,
                mailContext: MailEventContext? = nil, fromCache: Bool = false) {
        self.locator = locator; self.message = message; self.failure = failure; self.mailContext = mailContext
        self.fromCache = fromCache
    }
    private enum CodingKeys: String, CodingKey { case locator, message, failure, mailContext, fromCache }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locator = try c.decode(MailIndexLocator.self, forKey: .locator)
        message = try c.decodeIfPresent(MailHistoryMessage.self, forKey: .message)
        failure = try c.decodeIfPresent(MailIndexFailure.self, forKey: .failure)
        mailContext = try c.decodeIfPresent(MailEventContext.self, forKey: .mailContext)
        fromCache = try c.decodeIfPresent(Bool.self, forKey: .fromCache) ?? false
    }
}

public enum MailIndexError: String, LocalizedError, Sendable {
    case unavailable = "MAIL_INDEX_UNAVAILABLE"
    case cursorInvalidated = "MAIL_INDEX_CURSOR_INVALIDATED"
    case invalidMetadata = "MAIL_INDEX_INVALID_METADATA"
    case limitExceeded = "MAIL_INDEX_LIMIT_EXCEEDED"
    case invalidLocator = "MAIL_INDEX_INVALID_LOCATOR"
    public var errorDescription: String? { rawValue }
}

public enum MailIndexLimits {
    public static let localAccountID = "__harborreply_local__"
    public static let folders = 32
    public static let metadata = 128
    public static let depth = 32
    public static let discoverySteps = 64

    public static func validate(path: [String], accountID: String, isLocal: Bool) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 16_384,
              path.count <= depth, path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16_384 }),
              (accountID == localAccountID) == isLocal else { throw MailIndexError.invalidLocator }
    }
    public static func validate(cursor: MailIndexCursor, limit: Int) throws {
        try validate(path: cursor.mailboxPath, accountID: cursor.accountID, isLocal: cursor.isLocal)
        guard !cursor.mailboxPath.isEmpty, !cursor.scanID.isEmpty, cursor.scanID.utf8.count <= 128,
              cursor.offset >= 0, cursor.offset <= Int(Int32.max),
              cursor.expectedCount.map({ $0 >= cursor.offset && $0 <= Int(Int32.max) }) ?? true else { throw MailIndexError.invalidLocator }
        guard (1...metadata).contains(limit) else { throw MailIndexError.limitExceeded }
    }
    public static func validate(locator: MailIndexLocator) throws {
        try validate(path: locator.mailboxPath, accountID: locator.accountID, isLocal: locator.isLocal)
        guard !locator.mailboxPath.isEmpty, !locator.scanID.isEmpty, locator.scanID.utf8.count <= 128,
              locator.nativeID.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              Int64(locator.nativeID).map({ $0 > 0 }) == true, locator.messageSize >= 0,
              [locator.messageID, locator.subject, locator.sender].allSatisfy({ $0.utf8.count <= 16_384 }) else {
            throw MailIndexError.invalidLocator
        }
    }
    public static func validate(page: MailIndexPage, for cursor: MailIndexCursor, limit: Int) throws {
        try validate(cursor: cursor, limit: limit)
        let box = page.mailbox
        guard page.scanID == cursor.scanID, box.accountID == cursor.accountID, box.path == cursor.mailboxPath,
              box.isLocal == cursor.isLocal, box.messageCount >= cursor.offset else { throw MailIndexError.invalidMetadata }
        if let expected = cursor.expectedCount, expected != box.messageCount { throw MailIndexError.cursorInvalidated }
        guard page.records.count == min(limit, box.messageCount - cursor.offset),
              Set(page.records.map(\.nativeID)).count == page.records.count else { throw MailIndexError.invalidMetadata }
        for row in page.records {
            try validate(locator: row)
            guard row.accountID == box.accountID, row.mailboxPath == box.path, row.isLocal == box.isLocal,
                  row.role == box.role, row.scanID == cursor.scanID else { throw MailIndexError.invalidMetadata }
        }
        let nextOffset = cursor.offset + page.records.count
        if let next = page.nextCursor {
            try validate(cursor: next, limit: limit)
            guard nextOffset < box.messageCount, next.accountID == cursor.accountID, next.mailboxPath == cursor.mailboxPath,
                  next.offset == nextOffset, next.expectedCount == box.messageCount, next.scanID == cursor.scanID,
                  next.isLocal == cursor.isLocal else { throw MailIndexError.invalidMetadata }
        } else if nextOffset != box.messageCount { throw MailIndexError.invalidMetadata }
    }
}
