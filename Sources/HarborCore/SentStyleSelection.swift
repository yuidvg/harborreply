import Foundation

/// Mail's Sent classification and an explicit personal-account declaration are
/// independent requirements. A matching From address alone proves neither.
public enum SentStyleSelection {
    public static func address(_ sender: String) -> String? {
        let value = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("\n"), !value.contains("\r") else { return nil }
        let candidate: String
        if let start = value.lastIndex(of: "<"), value.hasSuffix(">") {
            let end = value.index(before: value.endIndex)
            guard !value[..<start].contains("<"), !value[..<start].contains(">"), !value[..<start].contains("@") else { return nil }
            candidate = String(value[value.index(after: start)..<end])
        } else { candidate = value }
        guard candidate.range(of: "^[^\\s<>,;@]+@[^\\s<>,;@]+$", options: .regularExpression) != nil else { return nil }
        return candidate.lowercased()
    }

    public static func candidates(in window: MailHistoryWindow, personalAccountIDs: Set<String>, excluding sharedAddresses: Set<String>) -> [MailHistoryItem] {
        guard personalAccountIDs.contains(window.account.id) else { return [] }
        let own = Set(window.account.addresses.compactMap(address)).subtracting(sharedAddresses)
        guard !own.isEmpty else { return [] }
        let eligible = window.items.filter { item in
            item.direction == .sent && item.accountID == window.account.id &&
            (0...2_097_152).contains(item.messageSize) && address(item.sender).map(own.contains) == true
        }.sorted {
            let left = $0.dateSent ?? $0.dateReceived ?? .distantPast
            let right = $1.dateSent ?? $1.dateReceived ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
        var ids = Set<String>()
        // Eager deduplication: a lazy Collection can evaluate its predicate
        // again while computing indices; a stateful predicate would be invalid.
        let distinct = eligible.filter { ids.insert($0.id).inserted }
        return Array(distinct.prefix(3))
    }
}
