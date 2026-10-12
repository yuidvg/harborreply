import Foundation
import HarborCore

struct DecodedMailBodyBatch {
    let messages: [MailIndexReadResult]
    let metrics: [MailBodyBatchMetrics]
}
struct DecodedMailCacheValidation {
    let valid: [Bool]
    let metrics: [MailBodyBatchMetrics]
}

/// Pure descriptor decoding; no Mail events, coercing lists, or private errors.
enum MailBodyNativeDecoder {
    private static func children(_ value: NSAppleEventDescriptor, count: Int) throws -> [NSAppleEventDescriptor] {
        guard value.descriptorType == 0x6C697374, value.numberOfItems == count else { throw MailIndexError.invalidMetadata }
        return try (1...max(1, count)).prefix(count).map { index in
            guard let child = value.atIndex(index) else { throw MailIndexError.invalidMetadata }
            return child
        }
    }
    private static func integer(_ value: NSAppleEventDescriptor, limit: Int) throws -> Int {
        guard value.descriptorType == 0x6C6F6E67 else { throw MailIndexError.invalidMetadata }
        let number = Int(value.int32Value)
        guard (0...limit).contains(number) else { throw MailIndexError.invalidMetadata }
        return number
    }
    private static func metrics(_ descriptor: NSAppleEventDescriptor, count: Int) throws -> [MailBodyBatchMetrics] {
        guard descriptor.descriptorType == 0x6C697374, (1...2).contains(descriptor.numberOfItems) else {
            throw MailIndexError.invalidMetadata
        }
        return try children(descriptor, count: descriptor.numberOfItems).map { value in
            let fields = try children(value, count: 4)
            guard fields[0].descriptorType != 0x6C697374, let raw = fields[0].stringValue,
                  let mode = MailBodyReadMode(rawValue: raw), try integer(fields[1], limit: 4) == count else {
                throw MailIndexError.invalidMetadata
            }
            let elapsed = try children(fields[2], count: 4).map { try integer($0, limit: 86_400_000) }
            let gets = try children(fields[3], count: 4).map { try integer($0, limit: 16_384) }
            return .init(mode: mode, count: count, beforeMilliseconds: elapsed[0], contentMilliseconds: elapsed[1],
                headersMilliseconds: elapsed[2], afterMilliseconds: elapsed[3], beforeGets: gets[0], contentGets: gets[1],
                headersGets: gets[2], afterGets: gets[3])
        }
    }
    static func messages(_ value: NSAppleEventDescriptor, expected: [MailIndexLocator]) throws -> DecodedMailBodyBatch {
        guard !expected.isEmpty, expected.count <= MailBodyBatch.maximumMessages else { throw MailIndexError.limitExceeded }
        let fields = try children(value, count: 3)
        guard fields[0].stringValue == "HARBOR_MAIL_BODY_V1" else { throw MailIndexError.invalidMetadata }
        let measured = try metrics(fields[2], count: expected.count)
        guard measured.allSatisfy({ [.scalar, .bulk, .scalarFallback].contains($0.mode) }) else {
            throw MailIndexError.invalidMetadata
        }
        let rows = try children(fields[1], count: expected.count)
        let messages = try zip(rows, expected).map { row, locator -> MailIndexReadResult in
            let wrapper = NSAppleEventDescriptor.list(); wrapper.insert(row, at: 1)
            let message = try MailMetadataDecoder.indexedMessage(wrapper, expected: locator)
            if measured.last?.mode == .bulk {
                guard message.failure == nil, let content = message.message else { throw MailIndexError.invalidMetadata }
                // Bind the returned header column to its ordered native witness.
                // Missing header IDs make this extra witness unavailable; Mail's
                // strict native-ID/count/metadata checkpoints remain mandatory.
                if !locator.messageID.isEmpty {
                    guard headerMessageID(content.target.headers) == normalizedID(locator.messageID) else {
                        throw MailIndexError.invalidMetadata
                    }
                }
            }
            return message
        }
        let bytes = messages.compactMap(\.message).reduce(0) { $0 + $1.target.body.utf8.count + $1.target.headers.utf8.count }
        guard bytes <= MailBodyBatch.maximumBytes else { throw MailIndexError.limitExceeded }
        return .init(messages: messages, metrics: measured)
    }
    static func cached(_ value: NSAppleEventDescriptor, count: Int) throws -> DecodedMailCacheValidation {
        guard (1...MailBodyBatch.maximumMessages).contains(count) else { throw MailIndexError.limitExceeded }
        let fields = try children(value, count: 3)
        guard fields[0].stringValue == "HARBOR_MAIL_CACHE_V1" else { throw MailIndexError.invalidMetadata }
        let measured = try metrics(fields[2], count: count)
        guard measured.count == 1, measured[0].mode == .cacheValidation,
              measured[0].contentGets == 0, measured[0].headersGets == 0 else { throw MailIndexError.invalidMetadata }
        let flags = try children(fields[1], count: count).map { descriptor in
            guard [UInt32(0x626F6F6C), 0x74727565, 0x66616C73].contains(descriptor.descriptorType) else {
                throw MailIndexError.invalidMetadata
            }
            return descriptor.booleanValue
        }
        return .init(valid: flags, metrics: measured)
    }
    private static func normalizedID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<") && trimmed.hasSuffix(">") ? String(trimmed.dropFirst().dropLast()) : trimmed
    }
    private static func headerMessageID(_ headers: String) -> String? {
        let lines = headers.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let unfolded = lines.reduce(into: [String]()) { result, line in
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !result.isEmpty {
                result[result.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else { result.append(line) }
        }
        let values = unfolded.compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "message-id" else { return nil }
            return normalizedID(String(line[line.index(after: colon)...]))
        }
        return values.count == 1 ? values.first : nil
    }
}
