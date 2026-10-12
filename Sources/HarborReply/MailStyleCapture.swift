import Foundation
import HarborCore

/// One bounded text, no scoring, deduplication, sample selection or token budget.
@MainActor final class MailStyleCapture {
    private let mail: any MailSelectionBridge
    init(mail: any MailSelectionBridge) { self.mail = mail }

    func collect(account: MailAccountIdentity, address: String, shared: [String], characterLimit: Int,
                 progress: (StyleTextProgress) -> Void) async throws -> StyleText {
        guard let sender = SentStyleSelection.address(address),
              account.addresses.compactMap(SentStyleSelection.address).contains(sender),
              !shared.compactMap(SentStyleSelection.address).contains(sender) else {
            throw AppFailure("STYLE_PERSONAL_ADDRESS_REQUIRED")
        }
        var text = StyleText(limit: characterLimit), unavailable = 0
        func report(_ phase: StyleTextProgress.Phase) {
            progress(.init(phase: phase, messages: text.messages, characters: text.characters,
                           limit: text.limit, unavailable: unavailable))
        }
        try Task.checkCancellation(); report(.discovering)
        let boxes = try await mail.styleMailboxes(accountID: account.id)
        let captureID = UUID().uuidString
        for box in boxes {
            guard box.accountID == account.id, box.role == .sent, !box.isLocal else {
                throw AppFailure("STYLE_SENT_MAILBOX_INVALID")
            }
            var cursor: MailIndexCursor? = .init(accountID: account.id, mailboxPath: box.path,
                expectedCount: box.messageCount, scanID: captureID, role: .sent)
            while let current = cursor, !text.isFull {
                try Task.checkCancellation(); report(.collecting)
                let page = try await mail.styleCandidates(cursor: current, limit: MailIndexLimits.metadata)
                try Task.checkCancellation(); try page.validate(for: current, limit: MailIndexLimits.metadata)
                let candidates = page.records.filter { SentStyleSelection.address($0.sender) == sender }
                var offset = 0
                while offset < candidates.count, !text.isFull {
                    try Task.checkCancellation()
                    // Native IPC has a fixed response cap; report unreadable large
                    // messages rather than claiming their body was collected.
                    if candidates[offset].messageSize > MailBodyBatch.maximumBytes {
                        unavailable += 1; offset += 1; report(.collecting); continue
                    }
                    var size = 0
                    let slice = candidates.dropFirst(offset).prefix(4).prefix { candidate in
                        guard size + candidate.messageSize <= MailBodyBatch.maximumBytes else { return false }
                        size += candidate.messageSize; return true
                    }
                    let batch = StyleContentBatch(cursor: current, candidates: Array(slice))
                    let reads = try await mail.styleContents(batch: batch)
                    try Task.checkCancellation(); try StyleContentLimits.validate(reads: reads, for: batch)
                    for read in reads where !text.isFull {
                        if let body = read.body { text.append(body) } else { unavailable += 1 }
                    }
                    offset += batch.candidates.count; report(.collecting)
                }
                cursor = page.nextCursor
            }
            if text.isFull { break }
        }
        try Task.checkCancellation()
        guard !text.text.isEmpty else { throw AppFailure("STYLE_INDEXED_SENT_EXAMPLES_REQUIRED") }
        return text
    }
}
