import Foundation

public struct DecodedMailHistoryWindow: Sendable {
    public let window: MailHistoryWindow
    /// Zero-based metadata positions retain matching native references in the
    /// engine, without putting native descriptors in a Sendable value.
    public let sourceIndices: [String: Int]
}

/// Read-only decoding at the native boundary. Descriptors remain confined to the
/// bridge's queue; only immutable Mail values leave it. These functions execute
/// no Apple events, coerce no lists to scalars and never include input in errors.
public enum MailMetadataDecoder {
    private static let listType: UInt32 = 0x6C697374
    private static let integerType: UInt32 = 0x6C6F6E67
    private static let booleanTypes: Set<UInt32> = [0x626F6F6C, 0x74727565, 0x66616C73]
    private static let missingType: UInt32 = 0x6D736E67

    private static func fields(_ value: NSAppleEventDescriptor, count: Int) throws -> [NSAppleEventDescriptor] {
        guard value.descriptorType == listType, value.numberOfItems == count else { throw MailIndexError.invalidMetadata }
        return try children(value, limit: count)
    }

    private static func children(_ value: NSAppleEventDescriptor, limit: Int) throws -> [NSAppleEventDescriptor] {
        guard value.descriptorType == listType, value.numberOfItems <= limit else { throw MailIndexError.invalidMetadata }
        return try (0..<value.numberOfItems).map { index in
            guard let child = value.atIndex(index + 1) else { throw MailIndexError.invalidMetadata }
            return child
        }
    }

    private static func text(_ value: NSAppleEventDescriptor, limit: Int = 16_384) throws -> String {
        guard value.descriptorType != listType, let text = value.stringValue,
              text.utf8.count <= limit else { throw MailIndexError.invalidMetadata }
        return text
    }

    private static func texts(_ value: NSAppleEventDescriptor, limit: Int) throws -> [String] {
        try children(value, limit: limit).map { try text($0) }
    }

    private static func integer(_ value: NSAppleEventDescriptor) throws -> Int {
        guard value.descriptorType == integerType else { throw MailIndexError.invalidMetadata }
        return Int(value.int32Value)
    }

    private static func boolean(_ value: NSAppleEventDescriptor) throws -> Bool {
        guard booleanTypes.contains(value.descriptorType) else { throw MailIndexError.invalidMetadata }
        return value.booleanValue
    }

    private static func date(_ value: NSAppleEventDescriptor) throws -> Date? {
        if value.descriptorType == 0x74797065, value.typeCodeValue == missingType { return nil }
        guard value.descriptorType == 0x6C647420, let date = value.dateValue else { throw MailIndexError.invalidMetadata }
        return date
    }

    private static func direction(_ value: NSAppleEventDescriptor) throws -> MailHistoryDirection {
        guard let direction = MailHistoryDirection(rawValue: try text(value)) else { throw MailIndexError.invalidMetadata }
        return direction
    }

    public static func account(_ value: NSAppleEventDescriptor) throws -> MailAccountIdentity {
        let row = try fields(value, count: 3)
        return .init(id: try text(row[0]), name: try text(row[1]),
                     addresses: try texts(row[2], limit: MailStyleDiscovery.addressesPerAccount))
    }

    public static func styleAccounts(_ value: NSAppleEventDescriptor) throws -> [MailAccountIdentity] {
        guard value.descriptorType == listType else { throw MailStyleDiscoveryError.invalidIdentity }
        guard value.numberOfItems <= MailStyleDiscovery.accounts else { throw MailStyleDiscoveryError.limitExceeded }
        let accounts = try children(value, limit: MailStyleDiscovery.accounts).map(account)
        try MailStyleDiscovery.validate(identities: accounts)
        return accounts
    }

    public static func mailbox(_ value: NSAppleEventDescriptor) throws -> MailIndexMailbox {
        let row = try fields(value, count: 6)
        guard let count = Int(try text(row[3])), count >= 0 else { throw MailIndexError.invalidMetadata }
        let mailbox = MailIndexMailbox(accountID: try text(row[0]), path: try texts(row[1], limit: MailIndexLimits.depth),
                                       name: try text(row[2]), messageCount: count, role: try direction(row[4]), isLocal: try boolean(row[5]))
        try MailIndexLimits.validate(path: mailbox.path, accountID: mailbox.accountID, isLocal: mailbox.isLocal)
        guard !mailbox.path.isEmpty, mailbox.path.last == mailbox.name else { throw MailIndexError.invalidMetadata }
        return mailbox
    }

    public static func styleMailboxes(_ value: NSAppleEventDescriptor, accountID: String) throws -> [MailIndexMailbox] {
        guard value.descriptorType == listType, value.numberOfItems <= 1 else { throw MailStyleDiscoveryError.invalidSentMailbox }
        let mailboxes = try children(value, limit: 1).map(mailbox)
        try MailStyleDiscovery.validate(mailboxes: mailboxes, accountID: accountID)
        return mailboxes
    }

    public static func validate(discovery cursor: MailMailboxCursor) throws {
        guard !cursor.scanID.isEmpty, cursor.scanID.utf8.count <= 128,
              cursor.accountOffset >= 0, cursor.accountOffset <= Int(Int32.max),
              cursor.stack.count <= MailIndexLimits.depth,
              cursor.expectedAccountCount.map({ $0 >= cursor.accountOffset && $0 <= Int(Int32.max) }) ?? true else { throw MailIndexError.invalidLocator }
        try cursor.stack.forEach { frame in
            try MailIndexLimits.validate(path: frame.parentPath, accountID: frame.accountID, isLocal: frame.isLocal)
            guard frame.nextChild >= 0, frame.nextChild <= Int(Int32.max),
                  frame.expectedChildCount.map({ $0 >= frame.nextChild && $0 <= Int(Int32.max) }) ?? true else { throw MailIndexError.invalidLocator }
        }
    }

    public static func discoveryCursor(_ value: NSAppleEventDescriptor) throws -> MailMailboxCursor? {
        if try children(value, limit: 5).isEmpty { return nil }
        let row = try fields(value, count: 5)
        let frames = try children(row[4], limit: MailIndexLimits.depth).map { value in
            let frame = try fields(value, count: 5)
            let expected = try integer(frame[3])
            return MailIndexFolderCursor(accountID: try text(frame[0]), parentPath: try texts(frame[1], limit: MailIndexLimits.depth),
                                         nextChild: try integer(frame[2]), expectedChildCount: expected < 0 ? nil : expected,
                                         isLocal: try boolean(frame[4]))
        }
        let expected = try integer(row[2])
        let cursor = MailMailboxCursor(scanID: try text(row[0]), accountOffset: try integer(row[1]),
                                       expectedAccountCount: expected < 0 ? nil : expected,
                                       localPhase: try boolean(row[3]), stack: frames)
        try validate(discovery: cursor)
        return cursor
    }

    public static func discoveryPage(_ value: NSAppleEventDescriptor, for cursor: MailMailboxCursor, limit: Int) throws -> MailMailboxPage {
        guard (1...MailIndexLimits.folders).contains(limit) else { throw MailIndexError.limitExceeded }
        try validate(discovery: cursor)
        let row = try fields(value, count: 4)
        guard try text(row[0]) == cursor.scanID else { throw MailIndexError.invalidMetadata }
        let boxes = try children(row[1], limit: limit).map(mailbox)
        let accounts = try children(row[2], limit: MailIndexLimits.folders).map(account)
        let next = try discoveryCursor(row[3])
        guard next.map({ $0.scanID == cursor.scanID }) ?? true else { throw MailIndexError.invalidMetadata }
        return .init(scanID: cursor.scanID, mailboxes: boxes, accounts: accounts, nextCursor: next)
    }

    public static func indexCursor(_ value: NSAppleEventDescriptor) throws -> MailIndexCursor? {
        if try children(value, limit: 7).isEmpty { return nil }
        let row = try fields(value, count: 7)
        let expected = try integer(row[3])
        let cursor = MailIndexCursor(accountID: try text(row[0]), mailboxPath: try texts(row[1], limit: MailIndexLimits.depth),
                                    offset: try integer(row[2]), expectedCount: expected < 0 ? nil : expected,
                                    scanID: try text(row[4]), isLocal: try boolean(row[5]), role: try direction(row[6]))
        try MailIndexLimits.validate(cursor: cursor, limit: MailIndexLimits.metadata)
        return cursor
    }

    public static func locator(_ value: NSAppleEventDescriptor) throws -> MailIndexLocator {
        let row = try fields(value, count: 12)
        guard let size = Int(try text(row[8])) else { throw MailIndexError.invalidMetadata }
        let locator = MailIndexLocator(accountID: try text(row[0]), mailboxPath: try texts(row[1], limit: MailIndexLimits.depth),
                                       nativeID: try text(row[2]), messageID: try text(row[3]), subject: try text(row[4]), sender: try text(row[5]),
                                       dateSent: try date(row[6]), dateReceived: try date(row[7]), messageSize: size,
                                       role: try direction(row[9]), isLocal: try boolean(row[10]), scanID: try text(row[11]))
        try MailIndexLimits.validate(locator: locator)
        return locator
    }

    public static func indexPage(_ value: NSAppleEventDescriptor, for cursor: MailIndexCursor, limit: Int) throws -> MailIndexPage {
        try MailIndexLimits.validate(cursor: cursor, limit: limit)
        let row = try fields(value, count: 4)
        guard try text(row[3]) == cursor.scanID else { throw MailIndexError.invalidMetadata }
        let page = MailIndexPage(mailbox: try mailbox(row[0]), records: try children(row[1], limit: limit).map(locator),
                                 nextCursor: try indexCursor(row[2]), scanID: cursor.scanID)
        try MailIndexLimits.validate(page: page, for: cursor, limit: limit)
        return page
    }

    public static func historyItem(_ value: NSAppleEventDescriptor, windowID: String) throws -> MailHistoryItem {
        do {
            let row = try fields(value, count: 11)
            let metadata = try row.prefix(7).map { try text($0) }
            let attachments = try integer(row[10])
            guard !metadata[0].isEmpty, !metadata[1].isEmpty, let size = Int(try text(row[9])), size >= 0,
                  attachments >= 0 else { throw MailHistoryError.invalidMetadata }
            return .init(id: metadata[0], windowID: windowID, accountID: metadata[1], mailbox: metadata[2],
                         messageID: metadata[3], subject: metadata[4], sender: metadata[5], direction: try direction(row[6]),
                         dateSent: try date(row[7]), dateReceived: try date(row[8]), messageSize: size, attachmentCount: attachments)
        } catch { throw MailHistoryError.invalidMetadata }
    }

    public static func historyWindow(_ value: NSAppleEventDescriptor, windowID: String, limit: Int,
                                     capturedAt: Date) throws -> DecodedMailHistoryWindow {
        try MailHistoryLimits.validate(limit: limit)
        do {
            let row = try fields(value, count: 4)
            guard try text(row[3]) == windowID else { throw MailHistoryError.invalidMetadata }
            let identity = try account(row[0])
            guard !identity.id.isEmpty else { throw MailHistoryError.invalidMetadata }
            let metadata = try children(row[1], limit: MailHistoryLimits.metadata)
            let mailboxNames = try texts(row[2], limit: 3)
            let unique = try metadata.enumerated().reduce(into: [String: (item: MailHistoryItem, index: Int)]()) { result, entry in
                let item = try historyItem(entry.element, windowID: windowID)
                guard item.accountID == identity.id else { throw MailHistoryError.invalidMetadata }
                // A genuine Sent/Inbox role takes precedence over a selected
                // mailbox's unknown role for the same native message.
                if let previous = result[item.id], previous.item.direction != .unknown, item.direction == .unknown { return }
                result[item.id] = (item: item, index: entry.offset)
            }
            let items = unique.values.map(\.item).sorted {
                let left = $0.dateReceived ?? $0.dateSent ?? .distantPast
                let right = $1.dateReceived ?? $1.dateSent ?? .distantPast
                return left == right ? $0.id < $1.id : left > right
            }
            return .init(window: .init(account: identity, items: items, sampledMailboxes: Array(Set(mailboxNames)).sorted(),
                                      perMailboxLimit: limit, capturedAt: capturedAt), sourceIndices: unique.mapValues(\.index))
        } catch { throw MailHistoryError.invalidMetadata }
    }

    public static func hydratedMessage(_ value: NSAppleEventDescriptor, expected: MailHistoryItem) throws -> MailHistoryMessage {
        let row: [NSAppleEventDescriptor]
        do { row = try fields(value, count: 4) } catch { throw MailHistoryError.changedMessage }
        guard try historyItem(row[0], windowID: expected.windowID) == expected else { throw MailHistoryError.changedMessage }
        let attachments: Int
        let body: String
        let headers: String
        do {
            attachments = try integer(row[3]); body = try text(row[1], limit: Int.max)
            headers = try text(row[2], limit: Int.max)
        } catch { throw MailHistoryError.changedMessage }
        guard attachments >= 0 else { throw MailHistoryError.changedMessage }
        let target = MailTarget(id: expected.id, account: expected.accountID + ":" + expected.mailbox,
                                messageID: expected.messageID, subject: expected.subject, sender: expected.sender, body: body, headers: headers)
        try MailHistoryLimits.validate(content: target, for: expected)
        return .init(item: expected.withAttachmentCount(attachments), target: target)
    }

    public static func indexedMessage(_ value: NSAppleEventDescriptor, expected: MailIndexLocator) throws -> MailIndexReadResult {
        let result = try fields(value, count: 1)
        let row = try fields(result[0], count: 7)
        guard try locator(row[0]) == expected else {
            return .init(locator: expected, failure: .changed, mailContext:
                .init(operation: .indexHydrate, stage: .response, nativeCode: nil, semanticCode: MailIndexFailure.changed.rawValue))
        }
        let failureCode = try text(row[4])
        if !failureCode.isEmpty {
            let context = MailEventContext.fromScript(operation: .indexHydrate, number: try integer(row[5]), stageNumber: try integer(row[6]))
            return .init(locator: expected, failure: MailIndexFailure(rawValue: failureCode) ?? .unavailable, mailContext: context)
        }
        let attachments = try integer(row[3])
        guard attachments >= 0 else { throw MailIndexError.invalidMetadata }
        let item = MailHistoryItem(id: expected.nativeID, windowID: expected.scanID, accountID: expected.accountID,
                                   mailbox: expected.mailboxPath.joined(separator: "/"), messageID: expected.messageID,
                                   subject: expected.subject, sender: expected.sender, direction: expected.role,
                                   dateSent: expected.dateSent, dateReceived: expected.dateReceived, messageSize: expected.messageSize, attachmentCount: attachments)
        let target = MailTarget(id: item.id, account: item.accountID + ":" + item.mailbox, messageID: item.messageID,
                                subject: item.subject, sender: item.sender,
                                body: try text(row[1], limit: Int.max), headers: try text(row[2], limit: Int.max))
        do { try MailHistoryLimits.validate(content: target, for: item) }
        catch {
            return .init(locator: expected, failure: .tooLarge, mailContext:
                .init(operation: .indexHydrate, stage: .response, nativeCode: nil, semanticCode: MailIndexFailure.tooLarge.rawValue))
        }
        return .init(locator: expected, message: .init(item: item, target: target))
    }
}
