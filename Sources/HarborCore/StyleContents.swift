import Foundation

/// Positional, read-only style sampling. These values are never Mail identities
/// and must not be used for related-mail evidence or draft insertion.
public struct StyleCandidate: Codable, Equatable, Sendable {
    public let position: Int
    public let sender: String
    public let messageSize: Int
    public func validate() throws { try StyleContentLimits.validate(candidate: self) }
    public init(position: Int, sender: String, messageSize: Int) {
        self.position = position; self.sender = sender; self.messageSize = messageSize
    }
}

public struct StyleCandidatePage: Codable, Equatable, Sendable {
    public let cursor: MailIndexCursor
    public let records: [StyleCandidate]
    public let nextCursor: MailIndexCursor?
    public let mailbox: MailIndexMailbox
    public func validate(for cursor: MailIndexCursor, limit: Int) throws {
        guard self.cursor == cursor else { throw StyleContentError.invalidShape }
        try StyleContentLimits.validate(page: self, limit: limit)
    }
    public init(cursor: MailIndexCursor, records: [StyleCandidate], nextCursor: MailIndexCursor?, mailbox: MailIndexMailbox) {
        self.cursor = cursor; self.records = records; self.nextCursor = nextCursor; self.mailbox = mailbox
    }
}

public struct StyleContentBatch: Codable, Equatable, Sendable {
    public static let maximumMessages = 4
    public static let maximumBytes = 2_097_152
    public static let maximumCharacters = 250_000
    public let cursor: MailIndexCursor
    public let candidates: [StyleCandidate]
    public init(cursor: MailIndexCursor, candidates: [StyleCandidate]) {
        self.cursor = cursor; self.candidates = candidates
    }
    public func validate() throws {
        try StyleContentLimits.validate(cursor: cursor, limit: 1)
        guard (1...Self.maximumMessages).contains(candidates.count) else { throw StyleContentError.limitExceeded }
        try candidates.forEach(StyleContentLimits.validate(candidate:))
        guard candidates.map(\.position) == candidates.map(\.position).sorted(),
              Set(candidates.map(\.position)).count == candidates.count,
              candidates.allSatisfy({ $0.position > cursor.offset }),
              candidates.reduce(0, { $0 + min($1.messageSize, Self.maximumBytes + 1) }) <= Self.maximumBytes else {
            throw StyleContentError.invalidInput
        }
    }
}

public struct StyleContentRead: Codable, Equatable, Sendable {
    public let candidate: StyleCandidate
    public let body: String?
    public let nativeCode: Int?
    public init(candidate: StyleCandidate, body: String? = nil, nativeCode: Int? = nil) {
        self.candidate = candidate; self.body = body; self.nativeCode = nativeCode
    }
}

public enum StyleContentError: String, LocalizedError, Sendable {
    case unsupported = "STYLE_CONTENT_UNSUPPORTED"
    case invalidInput = "STYLE_CONTENT_INPUT_INVALID"
    case invalidShape = "STYLE_CONTENT_SHAPE_INVALID"
    case limitExceeded = "STYLE_CONTENT_LIMIT_EXCEEDED"
    public var errorDescription: String? { rawValue }
}

public enum StyleContentLimits {
    public static func validate(cursor: MailIndexCursor, limit: Int) throws {
        guard !cursor.isLocal, cursor.role == .sent else { throw StyleContentError.invalidInput }
        do { try MailIndexLimits.validate(cursor: cursor, limit: limit) }
        catch { throw StyleContentError.invalidInput }
    }
    public static func validate(candidate: StyleCandidate) throws {
        guard (1...Int(Int32.max)).contains(candidate.position),
              candidate.sender.utf8.count <= 16_384,
              (0...Int(Int32.max)).contains(candidate.messageSize) else { throw StyleContentError.invalidInput }
    }
    public static func validate(page: StyleCandidatePage, limit: Int) throws {
        try validate(cursor: page.cursor, limit: limit)
        guard page.mailbox.accountID == page.cursor.accountID, page.mailbox.path == page.cursor.mailboxPath,
              page.mailbox.role == .sent, !page.mailbox.isLocal,
              (page.cursor.offset...Int(Int32.max)).contains(page.mailbox.messageCount),
              page.records.count == min(limit, page.mailbox.messageCount - page.cursor.offset),
              page.records.enumerated().allSatisfy({ $0.element.position == page.cursor.offset + $0.offset + 1 }) else {
            throw StyleContentError.invalidShape
        }
        try page.records.forEach(validate(candidate:))
        let offset = page.cursor.offset + page.records.count
        if let next = page.nextCursor {
            try validate(cursor: next, limit: limit)
            guard offset < page.mailbox.messageCount, next.offset == offset,
                  next.accountID == page.cursor.accountID, next.mailboxPath == page.cursor.mailboxPath,
                  next.scanID == page.cursor.scanID, next.expectedCount == page.mailbox.messageCount else {
                throw StyleContentError.invalidShape
            }
        } else if offset != page.mailbox.messageCount { throw StyleContentError.invalidShape }
    }
    public static func validate(reads: [StyleContentRead], for batch: StyleContentBatch) throws {
        try batch.validate()
        guard reads.map(\.candidate) == batch.candidates else { throw StyleContentError.invalidShape }
        for read in reads {
            if let body = read.body {
                guard read.nativeCode == nil else { throw StyleContentError.invalidShape }
                guard body.utf8.count <= StyleContentBatch.maximumBytes, body.unicodeScalars.count <= StyleContentBatch.maximumCharacters else {
                    throw StyleContentError.limitExceeded
                }
            } else if ![-1708, -1712].contains(read.nativeCode ?? 0) { throw StyleContentError.invalidShape }
        }
        guard reads.compactMap(\.body).reduce(0, { $0 + $1.utf8.count }) <= StyleContentBatch.maximumBytes else {
            throw StyleContentError.limitExceeded
        }
    }
}
