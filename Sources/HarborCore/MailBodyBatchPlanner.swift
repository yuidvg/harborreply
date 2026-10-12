import Foundation

/// Collection positions come from the original page, never from native IDs.
/// Excluded neighbours must never be included in a bulk GET.
public enum MailBodyBatchPlanner {
    public static func plan(page: [MailIndexLocator], selected: [MailIndexLocator], offset: Int,
                            expectedCount: Int) throws -> [MailBodyBatch] {
        guard page.count <= MailIndexLimits.metadata, selected.count <= MailHistoryLimits.hydratedMessages,
              (0...Int(Int32.max)).contains(expectedCount), (0...expectedCount).contains(offset),
              Set(page.map(\.nativeID)).count == page.count else { throw MailIndexError.invalidMetadata }
        try selected.forEach { try MailIndexLimits.validate(locator: $0) }
        let positions = Dictionary(uniqueKeysWithValues: page.enumerated().map { ($0.element.nativeID, $0.offset) })
        let indices = try selected.map { row -> Int in
            guard let index = positions[row.nativeID], page[index] == row else { throw MailIndexError.invalidLocator }
            return index
        }
        guard indices == indices.sorted(), Set(indices).count == indices.count else { throw MailIndexError.invalidLocator }
        let groups = indices.reduce(into: [[Int]]()) { groups, index in
            let bytes = groups.last?.reduce(0, { $0 + page[$1].messageSize }) ?? 0
            if let last = groups.last, last.last == index - 1, last.count < MailBodyBatch.maximumMessages,
               page[index].messageSize <= MailBodyBatch.maximumBytes - bytes {
                groups[groups.count - 1].append(index)
            } else { groups.append([index]) }
        }
        return try groups.map { group in
            let batch = MailBodyBatch(locators: group.map { page[$0] }, firstIndex: offset + group[0] + 1,
                                      expectedMailboxCount: expectedCount)
            try batch.validate()
            return batch
        }
    }
}
