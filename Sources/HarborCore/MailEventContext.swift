import Foundation

/// Fixed identifiers only: no mailbox, address, subject or Apple's error text.
public enum MailEventOperation: String, Codable, Sendable {
    case capture, history, hydrate, create, snapshot, insert
    case indexMailboxes = "index_mailboxes"
    case indexPage = "index_page"
    case indexHydrate = "index_hydrate"
    case indexHydrateBatch = "index_hydrate_batch"
    case indexCacheValidate = "index_cache_validate"
    case styleCandidates = "style_candidates"
    case styleContents = "style_contents"
    case styleAccounts = "style_accounts"
    case styleMailboxes = "style_mailboxes"
    case unknown
}

public enum MailEventStage: String, Codable, Sendable {
    case request, input, preflight, response
    case scriptResource = "script_resource"
    case scriptExecution = "script_execution"
    case selection
    case messageSize = "message_size"
    case account, metadata, body, headers
    case accountIdentity = "account_identity"
    case sentMailbox = "sent_mailbox"
    case mailbox
    case metadataNativeID = "metadata_native_id"
    case metadataMessageID = "metadata_message_id"
    case metadataSubject = "metadata_subject"
    case metadataSender = "metadata_sender"
    case metadataDateSent = "metadata_date_sent"
    case metadataDateReceived = "metadata_date_received"
    case metadataSize = "metadata_size"
    case metadataNativeIDScalar = "metadata_native_id_scalar"
    case metadataMessageIDScalar = "metadata_message_id_scalar"
    case metadataSubjectScalar = "metadata_subject_scalar"
    case metadataSenderScalar = "metadata_sender_scalar"
    case metadataDateSentScalar = "metadata_date_sent_scalar"
    case metadataDateReceivedScalar = "metadata_date_received_scalar"
    case metadataSizeScalar = "metadata_size_scalar"
    case mailboxRole = "mailbox_role"
    case attachments
    case messageCount = "message_count"
    case accountCount = "account_count"
    case mailboxCount = "mailbox_count"
    case accountID = "account_id"
    case accountEnabled = "account_enabled"
    case accountName = "account_name"
    case accountAddresses = "account_addresses"
    case mailboxName = "mailbox_name"
    case messageLookup = "message_lookup"
    case mailboxContainer = "mailbox_container"
    case draftSnapshot = "draft_snapshot"
    case draftCreate = "draft_create"
    case draftInsert = "draft_insert"
    case metadataRow = "metadata_row"
    case rangeCapability = "range_capability"
    case rangeCapabilityUpdate = "range_capability_update"

    public static func scriptStage(_ number: Int) -> Self? {
        switch number {
        case 9160: return .selection
        case 9161: return .messageSize
        case 9162: return .account
        case 9163, 9169: return .metadata
        case 9164, 9170: return .body
        case 9165: return .headers
        case 9166: return .accountIdentity
        case 9167: return .sentMailbox
        case 9168: return .mailbox
        case 9171: return .metadataNativeID
        case 9172: return .metadataMessageID
        case 9173: return .metadataSubject
        case 9174: return .metadataSender
        case 9175: return .metadataDateSent
        case 9176: return .metadataDateReceived
        case 9177: return .metadataSize
        case 9178: return .mailboxRole
        case 9179: return .attachments
        case 9180: return .messageCount
        case 9181: return .accountCount
        case 9182: return .mailboxCount
        case 9183: return .accountID
        case 9184: return .accountEnabled
        case 9185: return .accountName
        case 9186: return .accountAddresses
        case 9187: return .mailboxName
        case 9188: return .messageLookup
        case 9189: return .mailboxContainer
        case 9190: return .draftSnapshot
        case 9191: return .draftCreate
        case 9192: return .draftInsert
        case 9193: return .metadataRow
        case 9194: return .rangeCapability
        case 9195: return .rangeCapabilityUpdate
        case 9301: return .metadataNativeIDScalar
        case 9302: return .metadataMessageIDScalar
        case 9303: return .metadataSubjectScalar
        case 9304: return .metadataSenderScalar
        case 9305: return .metadataDateSentScalar
        case 9306: return .metadataDateReceivedScalar
        case 9307: return .metadataSizeScalar
        default: return nil
        }
    }
}

public struct MailEventContext: Codable, Equatable, Sendable {
    public let operation: MailEventOperation
    public let stage: MailEventStage
    /// Original numeric Apple event error, or the script's explicit validation
    /// number. Native -1700 is reconstructed from separate 926x/940x ranges.
    public let nativeCode: Int?
    public let semanticCode: String?
    public let isShapeFailure: Bool

    public init(operation: MailEventOperation, stage: MailEventStage, nativeCode: Int?,
                semanticCode: String? = nil, isShapeFailure: Bool = false) {
        self.operation = operation; self.stage = stage; self.nativeCode = nativeCode
        // Callers supply only known app codes. This also prevents accidental
        // private strings from entering the otherwise numeric diagnostic value.
        self.semanticCode = semanticCode.flatMap {
            !$0.isEmpty && $0.utf8.count <= 128 && $0.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil ? $0 : nil
        }
        self.isShapeFailure = isShapeFailure
    }

    private enum CodingKeys: String, CodingKey { case operation, stage, nativeCode, semanticCode, isShapeFailure }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(operation: try values.decode(MailEventOperation.self, forKey: .operation),
                  stage: try values.decode(MailEventStage.self, forKey: .stage),
                  nativeCode: try values.decodeIfPresent(Int.self, forKey: .nativeCode),
                  semanticCode: try values.decodeIfPresent(String.self, forKey: .semanticCode),
                  isShapeFailure: try values.decodeIfPresent(Bool.self, forKey: .isShapeFailure) ?? false)
    }

    public var code: String {
        let prefix = "MAIL_\(operation.rawValue.uppercased())_\(stage.rawValue.uppercased())"
        if let nativeCode { return "\(prefix)_\(isShapeFailure ? "SHAPE" : "EVENT")_\(nativeCode)" }
        return "\(prefix)_FAILED"
    }

    public var captureError: MailCaptureError? {
        guard operation == .capture, let semanticCode else { return nil }
        return MailCaptureError(rawValue: semanticCode)
    }

    public static func fromScript(operation: MailEventOperation, number: Int?, stageNumber: Int = 0) -> Self {
        if let number, ((9260...9295).contains(number) || (9401...9407).contains(number)),
           let stage = MailEventStage.scriptStage(number - 100) {
            return .init(operation: operation, stage: stage, nativeCode: -1700)
        }
        let shapeStage = number.flatMap(MailEventStage.scriptStage)
        return .init(operation: operation, stage: shapeStage ?? MailEventStage.scriptStage(stageNumber) ?? .request,
                     nativeCode: number, semanticCode: semanticCode(operation: operation, number: number),
                     isShapeFailure: shapeStage != nil)
    }

    private static func semanticCode(operation: MailEventOperation, number: Int?) -> String? {
        guard let number else { return nil }
        switch operation {
        case .capture:
            switch number {
            case 9101: return MailCaptureError.selectionRequired.rawValue
            case 9102: return MailCaptureError.messageTooLarge.rawValue
            default: return nil
            }
        case .styleAccounts, .styleMailboxes:
            switch number {
            case 9140, 9112: return MailStyleDiscoveryError.limitExceeded.rawValue
            case 9141: return MailStyleDiscoveryError.accountChanged.rawValue
            case 9142: return MailStyleDiscoveryError.invalidIdentity.rawValue
            case 9143, 9113: return MailStyleDiscoveryError.sentUnavailable.rawValue
            case 9144: return MailStyleDiscoveryError.invalidSentMailbox.rawValue
            case 9136: return MailStyleDiscoveryError.unavailable.rawValue
            default: return nil
            }
        case .history, .hydrate:
            switch number {
            case 9111: return MailHistoryError.accountSelectionRequired.rawValue
            case 9116, 9120: return MailHistoryError.staleWindow.rawValue
            case 9117, 9122: return MailHistoryError.changedMessage.rawValue
            case 9115, 9121: return MailHistoryError.limitExceeded.rawValue
            case 9123: return MailHistoryError.messageTooLarge.rawValue
            case 9112, 9113, 9118: return MailHistoryError.unavailable.rawValue
            case 9114, 9119: return MailHistoryError.invalidMetadata.rawValue
            default: return nil
            }
        case .indexMailboxes, .indexPage, .indexHydrate, .indexHydrateBatch, .indexCacheValidate:
            switch number {
            case 9130: return MailIndexError.cursorInvalidated.rawValue
            case 9131: return MailIndexError.limitExceeded.rawValue
            case 9132: return MailIndexFailure.changed.rawValue
            case 9133: return MailIndexError.invalidLocator.rawValue
            case 9134: return MailIndexError.invalidMetadata.rawValue
            case 9135: return MailIndexFailure.tooLarge.rawValue
            case 9136: return MailIndexError.unavailable.rawValue
            default: return nil
            }
        default: return nil
        }
    }
}
