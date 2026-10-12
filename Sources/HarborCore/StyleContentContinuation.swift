import Foundation

/// A private collection cursor and already observed candidates. Positions are
/// Mail collection offsets, not stable message identities or freshness proofs.
public struct StyleContentContinuation: Codable, Sendable {
    public let version: Int
    public let collectionMode: String
    public let folderIndex: Int
    public let pageCursor: MailIndexCursor
    public let nextCursor: MailIndexCursor?
    public let candidates: [StyleCandidate]
    public let nextBodyOffset: Int
    public let pageCompleted: Bool
    public let headersChecked: Int
    public let metadataExcluded: Int
    public let bodyAttempts: Int
    public let bodyReadsCompleted: Int
    public let bodyCaptured: Int
    public let cachedBodies: Int
    public let budgetAttempts: Int
    public let capturedBytes: Int
    public let folderCount: Int
    public let sentCount: Int

    enum CodingKeys: String, CodingKey {
        case version, folderIndex, pageCursor, nextCursor, candidates, nextBodyOffset, pageCompleted
        case headersChecked, metadataExcluded, bodyAttempts, bodyReadsCompleted, bodyCaptured, cachedBodies
        case budgetAttempts, capturedBytes, folderCount, sentCount
        case collectionMode = "collection_mode"
    }

    public init(folderIndex: Int, pageCursor: MailIndexCursor, nextCursor: MailIndexCursor?,
                candidates: [StyleCandidate], nextBodyOffset: Int, pageCompleted: Bool,
                headersChecked: Int, metadataExcluded: Int, bodyAttempts: Int, bodyReadsCompleted: Int,
                bodyCaptured: Int, cachedBodies: Int, budgetAttempts: Int, capturedBytes: Int,
                folderCount: Int, sentCount: Int) {
        version = 2; collectionMode = "sent_contents"
        self.folderIndex = folderIndex; self.pageCursor = pageCursor; self.nextCursor = nextCursor
        self.candidates = candidates; self.nextBodyOffset = nextBodyOffset; self.pageCompleted = pageCompleted
        self.headersChecked = headersChecked; self.metadataExcluded = metadataExcluded
        self.bodyAttempts = bodyAttempts; self.bodyReadsCompleted = bodyReadsCompleted
        self.bodyCaptured = bodyCaptured; self.cachedBodies = cachedBodies
        self.budgetAttempts = budgetAttempts; self.capturedBytes = capturedBytes
        self.folderCount = folderCount; self.sentCount = sentCount
    }

    public func validate(accountID: String, captureID: String) throws {
        guard version == 2, collectionMode == "sent_contents",
              (1...MailIndexLimits.folders).contains(folderCount), (0..<folderCount).contains(folderIndex),
              sentCount >= 0, candidates.count <= MailIndexLimits.metadata,
              (0...candidates.count).contains(nextBodyOffset),
              pageCompleted == (nextBodyOffset == candidates.count),
              (0...4_096).contains(headersChecked), (0...headersChecked).contains(metadataExcluded),
              (0...1_024).contains(bodyAttempts), (0...1_024).contains(bodyReadsCompleted),
              (0...bodyReadsCompleted).contains(bodyCaptured), cachedBodies == 0,
              bodyAttempts <= budgetAttempts, pageCursor.accountID == accountID,
              pageCursor.scanID == captureID, pageCursor.role == .sent, !pageCursor.isLocal,
              Set(candidates.map(\.position)).count == candidates.count,
              candidates.map(\.position) == candidates.map(\.position).sorted(),
              candidates.allSatisfy({ $0.position > pageCursor.offset &&
                  $0.sender.utf8.count <= 320 && SentStyleSelection.address($0.sender) == $0.sender }) else {
            throw MailIndexError.invalidMetadata
        }
        try MailIndexLimits.validate(cursor: pageCursor, limit: MailIndexLimits.metadata)
        try candidates.forEach { try $0.validate() }
        if let nextCursor {
            try MailIndexLimits.validate(cursor: nextCursor, limit: MailIndexLimits.metadata)
            guard nextCursor.offset > pageCursor.offset, nextCursor.accountID == accountID,
                  nextCursor.scanID == captureID, nextCursor.mailboxPath == pageCursor.mailboxPath,
                  nextCursor.role == .sent, !nextCursor.isLocal else { throw MailIndexError.invalidMetadata }
        }
        _ = try SentStyleReadBudget(resumingBodyAttempts: budgetAttempts, capturedBytes: capturedBytes)
    }
}
