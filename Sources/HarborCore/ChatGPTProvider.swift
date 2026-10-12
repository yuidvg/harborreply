import Foundation

public struct ChatGPTModel: Identifiable, Sendable, Equatable {
    public let id: String, name: String
}

public enum ChatGPTHTTP {
    public static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    /// All credential-bearing destinations are fixed; user input cannot replace them.
    public static func request(_ url: String, fields: [String: String]? = nil, bearer: String? = nil) async throws -> Data {
        guard [ChatGPTOAuth.issuer + "/api/accounts/oauth/token", ChatGPTOAuth.issuer + "/.well-known/openid-configuration",
               ChatGPTOAuth.issuer + "/.well-known/jwks.json", ChatGPTOAuth.issuer + "/api/accounts/oauth/revoke", ChatGPTOAuth.resource + "/models"].contains(url) else { throw ChatGPTError.invalidResponse }
        var request = URLRequest(url: URL(string: url)!)
        if let fields { request.httpMethod = "POST"; request.httpBody = ChatGPTOAuth.form(fields); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let session = session(); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 2_000_000, let http = response as? HTTPURLResponse else { throw ChatGPTError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data) }
        return data
    }
    public static func failure(status: Int, data: Data) -> ChatGPTError {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (root?["error"] as? [String: Any])?["code"] as? String ?? root?["error"] as? String ?? ""
        if ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused", "subscription_sharing_invalid_user"].contains(code) { return .signInRequired }
        if code == "subscription_sharing_usage_limit_exceeded" || status == 429 { return .usageLimit }
        if code == "subscription_sharing_user_not_eligible" || status == 403 { return .ineligible }
        if status == 401 { return .signInRequired }; return .unavailable
    }
    public static func models(_ data: Data) throws -> [ChatGPTModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let models = root["models"] as? [[String: Any]] else { throw ChatGPTError.invalidResponse }
        var seen = Set<String>()
        return models.compactMap { value in
            guard value["visibility"] as? String == "list", let slug = value["slug"] as? String, !slug.isEmpty,
                  let name = value["display_name"] as? String, seen.insert(slug).inserted else { return nil }
            return .init(id: slug, name: name)
        }
    }
}

/// Fixed protocol diagnostics; never includes server messages or response text.
public enum ChatGPTResponseError: String, Error, LocalizedError, Sendable {
    case streamFailed = "CHATGPT_STREAM_FAILED"
    case invalidEvent = "CHATGPT_STREAM_INVALID_EVENT"
    case notCompleted = "CHATGPT_STREAM_NOT_COMPLETED"
    case contentType = "CHATGPT_RESPONSE_CONTENT_TYPE"
    case missingContentType = "CHATGPT_RESPONSE_CONTENT_TYPE_MISSING"
    case plainContentType = "CHATGPT_RESPONSE_CONTENT_TYPE_TEXT_PLAIN"
    case htmlContentType = "CHATGPT_RESPONSE_CONTENT_TYPE_HTML"
    case binaryContentType = "CHATGPT_RESPONSE_CONTENT_TYPE_BINARY"
    case completion = "CHATGPT_STREAM_INVALID_COMPLETION"
    case size = "CHATGPT_STREAM_SIZE_LIMIT"
    case schema = "CHATGPT_RESPONSE_SCHEMA_REJECTED"
    case parameter = "CHATGPT_RESPONSE_PARAMETER_REJECTED"
    public var errorDescription: String? { rawValue }
}

/// Bounded SSE framing. Only a completed Responses object may produce a draft.
public struct ChatGPTStream: Sendable {
    private var line = Data(), eventLines: [String] = []
    private var total = 0
    private var finishedItems: [Int: Data] = [:]
    public private(set) var completed: Data?
    public init() {}
    public mutating func feed(_ byte: UInt8) throws {
        total += 1; guard total <= 12_000_000, line.count <= 2_000_000 else { throw ChatGPTResponseError.size }
        if byte == 10 {
            if line.last == 13 { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8) else { throw ChatGPTResponseError.invalidEvent }; line.removeAll(keepingCapacity: true)
            if text.isEmpty { try dispatch() }
            else if text.hasPrefix("data:") { eventLines.append(String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        } else { line.append(byte) }
    }
    private mutating func dispatch() throws {
        guard !eventLines.isEmpty else { return }
        let text = eventLines.joined(separator: "\n"); eventLines = []
        if text == "[DONE]" { return }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let type = root["type"] as? String else { throw ChatGPTResponseError.invalidEvent }
        if type == "error" || type == "response.failed" {
            let response = root["response"] as? [String: Any]
            let failure = (response?["error"] as? [String: Any]) ?? (root["error"] as? [String: Any]) ?? root
            switch failure["code"] as? String {
            case "invalid_json_schema": throw ChatGPTResponseError.schema
            case "unsupported_parameter", "invalid_parameter", "unknown_parameter": throw ChatGPTResponseError.parameter
            case "subscription_sharing_usage_limit_exceeded", "rate_limit_exceeded": throw ChatGPTError.usageLimit
            default: throw ChatGPTResponseError.streamFailed
            }
        }
        if type == "response.incomplete" { throw ProviderError.incomplete }
        if type == "response.refusal.delta" || type == "response.refusal.done" { throw ProviderError.refused }
        if type == "response.output_item.done" {
            guard let index = root["output_index"] as? Int, (0..<1024).contains(index),
                  finishedItems[index] == nil, let item = root["item"] as? [String: Any] else { throw ChatGPTResponseError.invalidEvent }
            finishedItems[index] = try JSONSerialization.data(withJSONObject: item)
        }
        if type == "response.completed" {
            guard completed == nil, var response = root["response"] as? [String: Any], response["status"] as? String == "completed" else { throw ChatGPTResponseError.completion }
            if (response["output"] as? [Any])?.isEmpty != false, !finishedItems.isEmpty {
                response["output"] = try finishedItems.sorted { $0.key < $1.key }.map { try JSONSerialization.jsonObject(with: $0.value) }
            }
            completed = try JSONSerialization.data(withJSONObject: response)
        }
    }
    public func finish() throws -> Data { guard let completed else { throw ChatGPTResponseError.notCompleted }; return completed }
}

public struct ChatGPTProvider: LLMProvider {
    private let token: String, model: String
    private let transport: URLSession?
    public init(accessToken: String, model: String, session: URLSession? = nil) {
        token = accessToken; self.model = model; transport = session
    }
    public static func requestBody(context: Data, schema: Data, instructions: String, model: String) throws -> Data {
        guard !model.isEmpty else { throw ProviderError.configuration }
        return try JSONSerialization.data(withJSONObject: ["model": model, "store": false, "stream": true, "instructions": instructions,
            "input": [["role": "user", "content": String(decoding: context, as: UTF8.self)]],
            "text": ["format": ["type": "json_schema", "name": "harbor_reply", "strict": true, "schema": try JSONSerialization.jsonObject(with: schema)]]])
    }
    public func generate(context: Data, schema: Data, instructions: String) async throws -> GenerationResult {
        guard !token.isEmpty else { throw ChatGPTError.signInRequired }
        var request = URLRequest(url: URL(string: ChatGPTOAuth.resource + "/responses")!)
        request.httpMethod = "POST"; request.httpBody = try Self.requestBody(context: context, schema: schema, instructions: instructions, model: model)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let session = transport ?? ChatGPTHTTP.session(); defer { if transport == nil { session.invalidateAndCancel() } }
        let start = Date(); let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data(); for try await byte in bytes { data.append(byte); if data.count >= 32_768 { break } }
            throw ChatGPTHTTP.failure(status: http.statusCode, data: data)
        }
        let mediaType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let data: Data
        switch mediaType {
        case "application/json":
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < 2_000_000 else { throw ChatGPTResponseError.size }
                body.append(byte)
            }
            data = body
        case "text/event-stream":
            var parser = ChatGPTStream()
            for try await byte in bytes {
                try Task.checkCancellation(); try parser.feed(byte)
                if parser.completed != nil { break }
            }
            data = try parser.finish()
        case nil:
            // Some plan responses omit Content-Type. The body still has to
            // satisfy the same completed JSON/SSE contract, never plain text.
            var parser = ChatGPTStream()
            var body = Data()
            var isJSON: Bool?
            for try await byte in bytes {
                try Task.checkCancellation()
                if isJSON == nil, ![9, 10, 13, 32].contains(byte) { isJSON = byte == 123 }
                if isJSON == true {
                    guard body.count < 2_000_000 else { throw ChatGPTResponseError.size }
                    body.append(byte)
                } else {
                    try parser.feed(byte)
                    if parser.completed != nil { break }
                }
            }
            data = isJSON == true ? body : try parser.finish()
        case "text/plain": throw ChatGPTResponseError.plainContentType
        case "text/html": throw ChatGPTResponseError.htmlContentType
        case "application/octet-stream": throw ChatGPTResponseError.binaryContentType
        default: throw ChatGPTResponseError.contentType
        }
        let output = try ResponsesProvider.parseResponse(data)
        let usage = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["usage"] as? [String: Any]
        return .init(output: output, elapsed: Date().timeIntervalSince(start), inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int)
    }
}
