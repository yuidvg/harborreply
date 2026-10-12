import Foundation

public enum ProviderError: Error, LocalizedError {
    case disabled, configuration, http(Int), incomplete, refused, invalidOutput, missingText, nonJSONText, fencedJSONText, nonObjectJSON
    public var errorDescription: String? {
        switch self {
        case .disabled: "API_DISABLED"
        case .configuration: "API_CONFIGURATION_REQUIRED"
        case .http(let status): "API_HTTP_\(status)"
        case .incomplete: "API_INCOMPLETE"
        case .refused: "API_REFUSED"
        case .invalidOutput: "API_INVALID_OUTPUT"
        case .missingText: "API_OUTPUT_TEXT_MISSING"
        case .nonJSONText: "API_OUTPUT_NOT_JSON"
        case .fencedJSONText: "API_OUTPUT_FENCED_JSON"
        case .nonObjectJSON: "API_OUTPUT_NOT_OBJECT"
        }
    }
}

public struct ProviderConfiguration: Sendable {
    public let enabled: Bool
    public let endpoint: String
    public let model: String
    public init(enabled: Bool, endpoint: String, model: String) { self.enabled = enabled; self.endpoint = endpoint; self.model = model }
    public func checkedURL() throws -> URL {
        guard enabled else { throw ProviderError.disabled }
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.configuration }
        return url
    }
}

public struct GenerationResult: Sendable {
    public let output: Data
    public let elapsed: Double
    public let inputTokens: Int?
    public let outputTokens: Int?
}

public protocol LLMProvider: Sendable {
    func generate(context: Data, schema: Data, instructions: String) async throws -> GenerationResult
}

/// URLSession delegate intentionally refuses every redirect, including same-host redirects.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct ResponsesProvider: LLMProvider {
    public let configuration: ProviderConfiguration
    private let key: String
    public init(configuration: ProviderConfiguration, key: String) { self.configuration = configuration; self.key = key }
    public func generate(context: Data, schema: Data, instructions: String) async throws -> GenerationResult {
        let url = try configuration.checkedURL()
        guard !key.isEmpty else { throw ProviderError.configuration }
        let format: [String: Any] = ["type": "json_schema", "name": "harbor_reply", "strict": true,
                                     "schema": try JSONSerialization.jsonObject(with: schema)]
        let body: [String: Any] = ["model": configuration.model, "store": false, "instructions": instructions,
                                  "input": String(decoding: context, as: UTF8.self), "text": ["format": format], "max_output_tokens": 5000]
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 100
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let started = Date()
        for attempt in 0...1 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidOutput }
            if http.statusCode == 429 && attempt == 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000); continue
            }
            guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
            guard data.count <= 2_000_000 else { throw ProviderError.invalidOutput }
            let output = try Self.parseResponse(data)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let usage = root?["usage"] as? [String: Any]
            return .init(output: output, elapsed: Date().timeIntervalSince(started), inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int)
        }
        throw ProviderError.http(429)
    }
    public static func parseResponse(_ data: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "completed" else { throw ProviderError.incomplete }
        let messages = root["output"] as? [[String: Any]] ?? []
        let content = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        if content.contains(where: { $0["type"] as? String == "refusal" }) { throw ProviderError.refused }
        let text = content.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
        guard let result = text.data(using: .utf8), !result.isEmpty else { throw ProviderError.missingText }
        guard let parsed = try? JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed]) else {
            throw text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") ? ProviderError.fencedJSONText : ProviderError.nonJSONText
        }
        guard parsed is [String: Any] else { throw ProviderError.nonObjectJSON }
        return result
    }
}
