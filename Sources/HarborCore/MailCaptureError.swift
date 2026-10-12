import Foundation

/// Application checks made by the static capture script. These are distinct
/// from native Apple event failures and never contain selected-mail values.
public enum MailCaptureError: String, LocalizedError, Sendable {
    case selectionRequired = "MAIL_CAPTURE_SELECTION_REQUIRED"
    case messageTooLarge = "MAIL_CAPTURE_MESSAGE_TOO_LARGE"

    public var errorDescription: String? { rawValue }
    public var userMessage: String {
        switch self {
        case .selectionRequired:
            return "Apple Mailの一覧で対象メールを1通だけ選び、もう一度読み込んでください。"
        case .messageTooLarge:
            return "対象メールが読み込み上限（2MB）を超えています。本文の短いメールを選んでください。"
        }
    }

    public var diagnosticFailure: DiagnosticFailureCode {
        switch self {
        case .selectionRequired: return .selectionRequired
        case .messageTooLarge: return .inputLimit
        }
    }
}
