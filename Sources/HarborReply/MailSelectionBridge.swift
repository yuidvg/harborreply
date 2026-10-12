import HarborCore

@MainActor protocol MailSelectionBridge: MailClientBridge {
    func clearTracking()
    func canCaptureWithoutPrompt() async -> Bool
    func history(for target: MailTarget?, limit: Int) async throws -> MailHistoryWindow
    func hydrate(records: [MailHistoryItem]) async throws -> [MailHistoryMessage]
    func indexMailboxes(after cursor: MailMailboxCursor?, limit: Int) async throws -> MailMailboxPage
    func indexPage(cursor: MailIndexCursor, limit: Int) async throws -> MailIndexPage
    func hydrateIndexed(locators: [MailIndexLocator]) async throws -> [MailIndexReadResult]
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult]
    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int]) async throws -> [Bool]
    func bodyReadMetrics() async -> [MailBodyBatchMetrics]
    func styleCandidates(cursor: MailIndexCursor, limit: Int) async throws -> StyleCandidatePage
    func styleContents(batch: StyleContentBatch) async throws -> [StyleContentRead]
    func styleAccounts() async throws -> [MailAccountIdentity]
    func styleMailboxes(accountID: String) async throws -> [MailIndexMailbox]
}

extension MailSelectionBridge {
    func styleCandidates(cursor: MailIndexCursor, limit: Int) async throws -> StyleCandidatePage {
        throw StyleContentError.unsupported
    }
    func styleContents(batch: StyleContentBatch) async throws -> [StyleContentRead] {
        throw StyleContentError.unsupported
    }
    func hydrateIndexedBatch(_ batch: MailBodyBatch) async throws -> [MailIndexReadResult] {
        try batch.validate()
        return try await hydrateIndexed(locators: batch.locators)
    }
    func validateCachedIndexed(locators: [MailIndexLocator], attachmentCounts: [Int]) async throws -> [Bool] {
        guard locators.count == attachmentCounts.count else { throw MailIndexError.invalidLocator }
        return locators.map { _ in false }
    }
    func bodyReadMetrics() async -> [MailBodyBatchMetrics] { [] }
}

extension AppleMailBridge: MailSelectionBridge {}
