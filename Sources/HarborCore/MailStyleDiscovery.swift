import Foundation

public enum MailStyleDiscoveryError: String, LocalizedError, Sendable {
    case unavailable = "MAIL_STYLE_DISCOVERY_UNAVAILABLE"
    case limitExceeded = "MAIL_STYLE_DISCOVERY_LIMIT_EXCEEDED"
    case accountChanged = "MAIL_STYLE_ACCOUNT_CHANGED"
    case invalidIdentity = "MAIL_STYLE_IDENTITY_INVALID"
    case sentUnavailable = "MAIL_STYLE_SENT_MAILBOX_UNAVAILABLE"
    case invalidSentMailbox = "MAIL_STYLE_SENT_MAILBOX_INVALID"
    public var errorDescription: String? { rawValue }
}

/// Discovery supplies choices, not proof that an address belongs to the user.
/// The coordinator must require the user's separate personal-author declaration.
public enum MailStyleDiscovery {
    public static let accounts = 32
    public static let addressesPerAccount = 32

    public static func validate(accountID: String) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 16_384,
              accountID != MailIndexLimits.localAccountID else { throw MailStyleDiscoveryError.invalidIdentity }
    }
    public static func validate(identities: [MailAccountIdentity]) throws {
        guard identities.count <= accounts else { throw MailStyleDiscoveryError.limitExceeded }
        guard Set(identities.map(\.id)).count == identities.count else { throw MailStyleDiscoveryError.invalidIdentity }
        for identity in identities {
            try validate(accountID: identity.id)
            guard identity.name.utf8.count <= 16_384, identity.addresses.count <= addressesPerAccount,
                  identity.addresses.allSatisfy({ $0.utf8.count <= 16_384 }) else { throw MailStyleDiscoveryError.invalidIdentity }
        }
    }
    public static func validate(mailboxes: [MailIndexMailbox], accountID: String) throws {
        try validate(accountID: accountID)
        guard mailboxes.count <= 1 else { throw MailStyleDiscoveryError.invalidSentMailbox }
        for box in mailboxes {
            try MailIndexLimits.validate(path: box.path, accountID: box.accountID, isLocal: box.isLocal)
            guard box.accountID == accountID, !box.isLocal, box.role == .sent, !box.path.isEmpty,
                  box.path.last == box.name, box.messageCount >= 0 else { throw MailStyleDiscoveryError.invalidSentMailbox }
        }
    }
}

/// Script stages contain no message/account data. Apple's private error text
/// never enters this mapping or a diagnostic output.
public enum MailReadCoercion {
    public static func code(for number: Int) -> String? {
        switch number {
        case 9160: return "MAIL_CAPTURE_SELECTION_COERCION"
        case 9161: return "MAIL_CAPTURE_SIZE_COERCION"
        case 9162: return "MAIL_CAPTURE_ACCOUNT_COERCION"
        case 9163: return "MAIL_CAPTURE_METADATA_COERCION"
        case 9164: return "MAIL_CAPTURE_BODY_COERCION"
        case 9165: return "MAIL_CAPTURE_HEADERS_COERCION"
        case 9166: return "MAIL_STYLE_ACCOUNTS_COERCION"
        case 9167: return "MAIL_STYLE_SENT_COERCION"
        case 9168: return "MAIL_INDEX_MAILBOX_COERCION"
        case 9169: return "MAIL_INDEX_METADATA_COERCION"
        case 9170: return "MAIL_INDEX_BODY_COERCION"
        default: return nil
        }
    }
}
