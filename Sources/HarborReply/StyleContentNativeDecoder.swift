import Foundation
import HarborCore

struct DecodedStyleCandidates {
    let page: StyleCandidatePage
    let metrics: [MailBodyBatchMetrics]
}
struct DecodedStyleContents {
    let reads: [StyleContentRead]
    let metrics: [MailBodyBatchMetrics]
}

/// Pure validation of bounded descriptors. There are deliberately no Mail
/// identities, header/attachment witnesses or additional native requests here.
enum StyleContentNativeDecoder {
    private static func children(_ value: NSAppleEventDescriptor, count: Int) throws -> [NSAppleEventDescriptor] {
        guard value.descriptorType == 0x6C697374, value.numberOfItems == count else { throw StyleContentError.invalidShape }
        return try (1...max(1, count)).prefix(count).map { index in
            guard let child = value.atIndex(index) else { throw StyleContentError.invalidShape }
            return child
        }
    }
    private static func integer(_ value: NSAppleEventDescriptor, range: ClosedRange<Int>) throws -> Int {
        guard value.descriptorType == 0x6C6F6E67 else { throw StyleContentError.invalidShape }
        let number = Int(value.int32Value)
        guard range.contains(number) else { throw StyleContentError.invalidShape }
        return number
    }
    private static func text(_ value: NSAppleEventDescriptor) throws -> String {
        guard [UInt32(0x75747874), 0x54455854, 0x75746638].contains(value.descriptorType), let string = value.stringValue else {
            throw StyleContentError.invalidShape
        }
        return string
    }
    private static func metrics(_ value: NSAppleEventDescriptor, count: Int, allowed: [MailBodyReadMode]) throws -> [MailBodyBatchMetrics] {
        let fields = try children(value, count: 4)
        guard let mode = MailBodyReadMode(rawValue: try text(fields[0])), allowed.contains(mode),
              try integer(fields[1], range: 0...128) == count else { throw StyleContentError.invalidShape }
        let elapsed = try children(fields[2], count: 4).map { try integer($0, range: 0...86_400_000) }
        let gets = try children(fields[3], count: 4).map { try integer($0, range: 0...16_384) }
        guard elapsed[2] == 0, elapsed[3] == 0, gets[2] == 0, gets[3] == 0 else { throw StyleContentError.invalidShape }
        return [.init(mode: mode, count: count, beforeMilliseconds: elapsed[0], contentMilliseconds: elapsed[1],
                      headersMilliseconds: 0, afterMilliseconds: 0, beforeGets: gets[0], contentGets: gets[1], headersGets: 0, afterGets: 0)]
    }
    static func failure(_ value: NSAppleEventDescriptor) throws -> (MailEventContext, [MailBodyBatchMetrics]) {
        let fields = try children(value, count: 3)
        guard try text(fields[0]) == "HARBOR_STYLE_CONTENT_FAILURE_V1" else { throw StyleContentError.invalidShape }
        let envelope = try children(fields[1], count: 3)
        guard try text(envelope[0]) == "HARBOR_MAIL_FAILURE_V1" else { throw StyleContentError.invalidShape }
        let number = try integer(envelope[1], range: Int(Int32.min)...Int(Int32.max))
        let stage = try integer(envelope[2], range: 0...10_000)
        let metricFields = try children(fields[2], count: 4)
        let count = try integer(metricFields[1], range: 1...StyleContentBatch.maximumMessages)
        return (.fromScript(operation: .styleContents, number: number, stageNumber: stage),
                try metrics(fields[2], count: count, allowed: [.styleContentsFailure]))
    }
    static func candidates(_ value: NSAppleEventDescriptor, cursor: MailIndexCursor, limit: Int) throws -> DecodedStyleCandidates {
        try StyleContentLimits.validate(cursor: cursor, limit: limit)
        let fields = try children(value, count: 4)
        guard try text(fields[0]) == "HARBOR_STYLE_CANDIDATES_V1" else { throw StyleContentError.invalidShape }
        let total = try integer(fields[1], range: cursor.offset...Int(Int32.max))
        let count = min(limit, total - cursor.offset)
        let records = try children(fields[2], count: count).map { row in
            let columns = try children(row, count: 3)
            return StyleCandidate(position: try integer(columns[0], range: 1...Int(Int32.max)),
                                  sender: try text(columns[1]), messageSize: try integer(columns[2], range: 0...Int(Int32.max)))
        }
        let offset = cursor.offset + count
        let next: MailIndexCursor? = offset < total ? .init(accountID: cursor.accountID, mailboxPath: cursor.mailboxPath,
            offset: offset, expectedCount: total, scanID: cursor.scanID, isLocal: false, role: .sent) : nil
        let page = StyleCandidatePage(cursor: cursor, records: records, nextCursor: next,
            mailbox: .init(accountID: cursor.accountID, path: cursor.mailboxPath, name: cursor.mailboxPath.last ?? "",
                           messageCount: total, role: .sent, isLocal: false))
        try StyleContentLimits.validate(page: page, limit: limit)
        let measured = try metrics(fields[3], count: count, allowed: [.styleCandidates])
        guard measured.allSatisfy({ $0.contentGets == 0 }) else { throw StyleContentError.invalidShape }
        return .init(page: page, metrics: measured)
    }
    static func contents(_ value: NSAppleEventDescriptor, batch: StyleContentBatch) throws -> DecodedStyleContents {
        try batch.validate()
        let fields = try children(value, count: 3)
        guard try text(fields[0]) == "HARBOR_STYLE_CONTENTS_V1" else { throw StyleContentError.invalidShape }
        let rows = try children(fields[1], count: batch.candidates.count)
        let reads = try zip(rows, batch.candidates).map { row, candidate in
            let columns = try children(row, count: 3)
            guard try integer(columns[0], range: 1...Int(Int32.max)) == candidate.position else { throw StyleContentError.invalidShape }
            let body = try text(columns[1])
            let code = try integer(columns[2], range: -1712...0)
            guard code == 0 || ([-1708, -1712].contains(code) && body.isEmpty) else { throw StyleContentError.invalidShape }
            return StyleContentRead(candidate: candidate, body: code == 0 ? body : nil, nativeCode: code == 0 ? nil : code)
        }
        try StyleContentLimits.validate(reads: reads, for: batch)
        return .init(reads: reads, metrics: try metrics(fields[2], count: reads.count, allowed: [.styleContents, .styleContentsFallback]))
    }
}
