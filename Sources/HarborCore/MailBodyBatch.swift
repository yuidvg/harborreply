import Foundation

/// Original, contiguous Mail collection positions; never inferred from native IDs.
public struct MailBodyBatch: Equatable, Sendable {
    public static let maximumMessages = 4
    public static let maximumBytes = 2_097_152
    public let locators: [MailIndexLocator]
    public let firstIndex: Int?
    public let expectedMailboxCount: Int?

    public init(locators: [MailIndexLocator], firstIndex: Int? = nil, expectedMailboxCount: Int? = nil) {
        self.locators = locators; self.firstIndex = firstIndex; self.expectedMailboxCount = expectedMailboxCount
    }

    public func validate() throws {
        guard !locators.isEmpty, locators.count <= Self.maximumMessages else { throw MailIndexError.limitExceeded }
        try locators.forEach { try MailIndexLimits.validate(locator: $0) }
        guard let first = locators.first, Set(locators.map(\.nativeID)).count == locators.count,
              locators.allSatisfy({ $0.accountID == first.accountID && $0.mailboxPath == first.mailboxPath &&
                  $0.isLocal == first.isLocal && $0.role == first.role && $0.scanID == first.scanID }),
              locators.reduce(0, { $0 + min($1.messageSize, Self.maximumBytes + 1) }) <= Self.maximumBytes else {
            throw MailIndexError.invalidLocator
        }
        switch (firstIndex, expectedMailboxCount) {
        case (nil, nil): break
        case let (.some(index), .some(count)):
            guard index >= 1, count <= Int(Int32.max), count >= index,
                  locators.count <= count - index + 1 else { throw MailIndexError.invalidLocator }
        default: throw MailIndexError.invalidLocator
        }
    }
}

public enum MailBodyReadMode: String, Codable, Sendable {
    case styleContentsFailure = "style_contents_failure"
    case styleCandidates = "style_candidates", styleContents = "style_contents", styleContentsFallback = "style_contents_fallback"
    case scalar, bulk, scalarFallback = "scalar_fallback", cacheValidation = "cache_validation"
}

/// Numeric aggregates only. Getter counts are actual explicit request sites,
/// including failures, not the opaque Mail process's internal work.
public struct MailBodyBatchMetrics: Codable, Equatable, Sendable {
    public let mode: MailBodyReadMode
    public let count: Int
    public let beforeMilliseconds: Int
    public let contentMilliseconds: Int
    public let headersMilliseconds: Int
    public let afterMilliseconds: Int
    public let beforeGets: Int
    public let contentGets: Int
    public let headersGets: Int
    public let afterGets: Int
    public init(mode: MailBodyReadMode, count: Int, beforeMilliseconds: Int, contentMilliseconds: Int,
                headersMilliseconds: Int, afterMilliseconds: Int, beforeGets: Int, contentGets: Int,
                headersGets: Int, afterGets: Int) {
        self.mode = mode; self.count = count; self.beforeMilliseconds = beforeMilliseconds
        self.contentMilliseconds = contentMilliseconds; self.headersMilliseconds = headersMilliseconds
        self.afterMilliseconds = afterMilliseconds; self.beforeGets = beforeGets
        self.contentGets = contentGets; self.headersGets = headersGets; self.afterGets = afterGets
    }
}
