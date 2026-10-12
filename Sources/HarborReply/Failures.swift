import Foundation
import HarborCore

/// Display codes come from fixed application/worker contracts. Apple error text
/// is deliberately absent: it can contain the selected message or its address.
struct AppFailure: LocalizedError, Sendable {
    let code: String
    let baseCode: String
    let mailContext: MailEventContext?
    let location: DiagnosticLocation?
    let writeUncertain: Bool
    var errorDescription: String? { code }
    var userMessage: String { mailContext?.captureError?.userMessage ?? code }

    init(_ code: String, mailContext: MailEventContext? = nil, location: DiagnosticLocation? = nil,
         baseCode: String? = nil, writeUncertain: Bool = false) {
        self.code = code; self.mailContext = mailContext
        self.location = location ?? mailContext.map { context in
            switch context.operation {
            case .capture: return .mailCapture
            case .indexMailboxes: return .mailIndexDiscovery
            case .indexPage: return .mailIndexMetadata
            case .indexHydrate, .indexHydrateBatch, .indexCacheValidate, .hydrate: return .mailIndexBody
            case .styleAccounts: return .styleAccounts
            case .styleMailboxes: return .styleSent
            case .styleCandidates, .styleContents: return .styleCapture
            case .history: return .relatedSource
            case .create: return .mailDraftCreate
            case .snapshot: return .mailDraftSnapshot
            case .insert: return .mailDraftInsert
            case .unknown: return .workerResponse
            }
        }
        self.baseCode = baseCode ?? mailContext?.semanticCode ?? code
        self.writeUncertain = writeUncertain
    }

    static func located(_ error: Error, at location: DiagnosticLocation) -> Error {
        if error is CancellationError { return error }
        let prior = error as? AppFailure
        if prior?.location == location { return error }
        let serviceCause = (error as? ChatGPTError)?.errorDescription ?? (error as? ProviderError)?.errorDescription
        let protocolCause = (error as? ChatGPTResponseError)?.rawValue
        let networkCause = (error as? URLError).map { "NETWORK_\($0.errorCode)" }
        let cause = prior?.code ?? (error as? MailIndexError)?.rawValue ??
            (error as? MailHistoryError)?.rawValue ?? (error as? MailStyleDiscoveryError)?.rawValue ??
            (error as? StyleContentError)?.rawValue ?? serviceCause ?? protocolCause ?? networkCause ?? "INVALID_RESPONSE"
        let prefix = location.rawValue.replacingOccurrences(of: ".", with: "_").uppercased() + "__"
        return AppFailure(cause.hasPrefix(prefix) ? cause : prefix + cause,
                          mailContext: prior?.mailContext, location: location, baseCode: prior?.baseCode ?? cause,
                          writeUncertain: prior?.writeUncertain ?? false)
    }

    var diagnosticFailure: DiagnosticFailureCode {
        if let context = mailContext {
            if let captureError = context.captureError { return captureError.diagnosticFailure }
            if context.isShapeFailure { return .invalidResponse }
            return context.nativeCode == -1700 ? .coercion : context.nativeCode != nil ? .appleEvent : .unknown
        }
        if code.contains("TIMEOUT") { return .timeout }
        if code.contains("INPUT_LIMIT") || code.contains("INPUT_SIZE_LIMIT") { return .inputLimit }
        if code.contains("OUTPUT_LIMIT") { return .outputLimit }
        if code.contains("SOURCE_CHANGED") || code.contains("ACCOUNT_CHANGED") { return .sourceChanged }
        if code.contains("CHECKPOINT_CHANGED") || code.contains("SCAN_CHANGED") { return .checkpointChanged }
        if code.contains("BUDGET") || code.contains("NARROW_REQUIRED") { return .searchBudget }
        if code.contains("INVALID") || code.contains("RESPONSE") { return .invalidResponse }
        return .workerFailure
    }
}
