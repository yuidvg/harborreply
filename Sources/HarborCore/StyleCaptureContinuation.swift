import Foundation

/// Private continuation metadata, never bodies or output diagnostics. A page
/// fingerprint must match a freshly read page before its saved offset is used.
public struct StyleCaptureContinuation: Codable, Sendable {
    public let version: Int
    public let folderIndex: Int
    public let mailboxPlanHash: String
    public let pageCursor: MailIndexCursor
    public let pageHash: String
    public let pageLimit: Int
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

    public init(folderIndex: Int, mailboxPlanHash: String, pageCursor: MailIndexCursor, pageHash: String,
                pageLimit: Int, nextBodyOffset: Int, pageCompleted: Bool, headersChecked: Int,
                metadataExcluded: Int, bodyAttempts: Int, bodyReadsCompleted: Int, bodyCaptured: Int,
                cachedBodies: Int, budgetAttempts: Int, capturedBytes: Int, folderCount: Int, sentCount: Int) {
        version = 1; self.folderIndex = folderIndex; self.mailboxPlanHash = mailboxPlanHash
        self.pageCursor = pageCursor; self.pageHash = pageHash; self.pageLimit = pageLimit
        self.nextBodyOffset = nextBodyOffset; self.pageCompleted = pageCompleted; self.headersChecked = headersChecked
        self.metadataExcluded = metadataExcluded; self.bodyAttempts = bodyAttempts
        self.bodyReadsCompleted = bodyReadsCompleted; self.bodyCaptured = bodyCaptured; self.cachedBodies = cachedBodies
        self.budgetAttempts = budgetAttempts; self.capturedBytes = capturedBytes
        self.folderCount = folderCount; self.sentCount = sentCount
    }

    public func validate(accountID: String, captureID: String) throws {
        let isHash: (String) -> Bool = { value in
            value.utf8.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
        }
        guard version == 1, (1...MailIndexLimits.folders).contains(folderCount),
              (0..<folderCount).contains(folderIndex), (0...Int(Int32.max)).contains(sentCount),
              (1...MailIndexLimits.metadata).contains(pageLimit), (0...MailIndexLimits.metadata).contains(nextBodyOffset),
              (0...4_096).contains(headersChecked), (0...headersChecked).contains(metadataExcluded),
              (0...1_024).contains(bodyAttempts), (0...1_024).contains(bodyReadsCompleted),
              (0...bodyReadsCompleted).contains(bodyCaptured), (0...1_024).contains(cachedBodies),
              bodyAttempts <= budgetAttempts, isHash(mailboxPlanHash), isHash(pageHash),
              pageCursor.accountID == accountID, pageCursor.scanID == captureID,
              pageCursor.role == .sent, !pageCursor.isLocal else { throw MailIndexError.invalidMetadata }
        try MailIndexLimits.validate(cursor: pageCursor, limit: pageLimit)
        _ = try SentStyleReadBudget(resumingBodyAttempts: budgetAttempts, capturedBytes: capturedBytes)
    }
}
