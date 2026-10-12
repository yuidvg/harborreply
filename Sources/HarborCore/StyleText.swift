import Foundation

/// Concatenates all returned bodies, including quotes and duplicates, in order.
/// The final body is cut at a Swift Character boundary to fill the exact limit.
public struct StyleText: Equatable, Sendable {
    public let limit: Int
    public private(set) var text = ""
    public private(set) var characters = 0
    public private(set) var messages = 0
    public var isFull: Bool { characters >= limit }
    public init(limit: Int = 32_768) { self.limit = max(1, min(limit, 131_072)) }
    public mutating func append(_ body: String) {
        guard !isFull, !body.isEmpty else { return }
        let separator = text.isEmpty ? "" : "\n\n"
        let fragment = String((separator + body).prefix(limit - characters))
        text += fragment; characters += fragment.count; messages += 1
    }
}

public struct StyleTextProgress: Equatable, Sendable {
    public enum Phase: String, Sendable { case discovering, collecting, analyzing, completed }
    public let phase: Phase
    public let messages: Int
    public let characters: Int
    public let limit: Int
    public let unavailable: Int
    public init(phase: Phase, messages: Int = 0, characters: Int = 0, limit: Int, unavailable: Int = 0) {
        self.phase = phase; self.messages = messages; self.characters = characters
        self.limit = limit; self.unavailable = unavailable
    }
}
