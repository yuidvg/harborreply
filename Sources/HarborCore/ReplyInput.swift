import Foundation

/// A reply uses one captured value of mail, scope, style and intent across suspension points.
public struct ReplyInput: Encodable, Sendable {
    public let current: CurrentMail
    public let caseID: String
    public let userIntent: String
    public let language: String
    public let tone: String
    public let styleProfile: String
    public let requestID: UUID
    public let contextRevision: Int

    public init(target: MailTarget, internalMail: Bool, caseID: String, userIntent: String,
                language: String, tone: String, styleProfile: String, requestID: UUID, revision: Int) {
        current = CurrentMail(target: target, internalMail: internalMail)
        self.caseID = caseID; self.userIntent = userIntent; self.language = language
        self.tone = tone; self.styleProfile = styleProfile; self.requestID = requestID
        contextRevision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case current, language, tone
        case caseID = "case_id", userIntent = "user_intent", styleProfile = "style_profile"
        case requestID = "request_id", contextRevision = "context_revision"
    }

    public struct CurrentMail: Encodable, Sendable {
        public let target: MailTarget
        public let internalMail: Bool
        public init(target: MailTarget, internalMail: Bool) {
            self.target = target; self.internalMail = internalMail
        }
        private enum CodingKeys: String, CodingKey { case internalMail = "internal" }
        public func encode(to encoder: Encoder) throws {
            try target.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(internalMail, forKey: .internalMail)
        }
    }
}

/// Observed formatting traits and an explicitly requested local description.
/// Source phrases are exact neutral allowlisted lines from authored mail.
public struct StyleSummary: Decodable, Equatable, Sendable {
    public let version: String
    public let exampleCount: Int
    public let paragraphCharactersMedian: Int
    public let sentenceCharactersMedian: Int
    public let paragraphsPerMessageMedian: Int
    public let usesBullets: Bool
    public let politeRequestRatio: Double
    public let language: String
    public let extractionStatus: String
    public let explanation: String
    public let extractedAt: String?
    public let sourcePhrases: [String]
    public let sampleInfo: SampleInfo?
    public let sourceAddress: String?
    public let sourceAccountID: String?

    public struct SampleInfo: Decodable, Equatable, Sendable {
        public let selectedMessages: Int
        public let tokenEstimate: Int
        public let tokenBudget: Int
        public let tokenEstimateIsExact: Bool
        public let candidatesChecked: Int
        private enum CodingKeys: String, CodingKey {
            case selectedMessages = "selected_messages", tokenEstimate = "token_estimate"
            case tokenBudget = "token_budget", tokenEstimateIsExact = "token_estimate_is_exact"
            case candidatesChecked = "candidates_checked"
        }
    }

    public var isExtracted: Bool { extractionStatus == "ready" && !explanation.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case version, language
        case exampleCount = "example_count"
        case paragraphCharactersMedian = "paragraph_characters_median"
        case sentenceCharactersMedian = "sentence_characters_median"
        case paragraphsPerMessageMedian = "paragraphs_per_message_median"
        case usesBullets = "uses_bullets"
        case politeRequestRatio = "polite_request_ratio"
        case extractionStatus = "extraction_status", explanation = "description"
        case descriptionOrigin = "description_origin", extractedAt = "extracted_at"
        case sourcePhrases = "source_phrases"
        case sampleInfo = "sample_info"
        case sourceAddress = "source_address", sourceAccountID = "source_account_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        sourceAddress = try container.decodeIfPresent(String.self, forKey: .sourceAddress)
        sourceAccountID = try container.decodeIfPresent(String.self, forKey: .sourceAccountID)
        exampleCount = try container.decode(Int.self, forKey: .exampleCount)
        paragraphCharactersMedian = try container.decode(Int.self, forKey: .paragraphCharactersMedian)
        sentenceCharactersMedian = try container.decode(Int.self, forKey: .sentenceCharactersMedian)
        paragraphsPerMessageMedian = try container.decode(Int.self, forKey: .paragraphsPerMessageMedian)
        usesBullets = try container.decode(Bool.self, forKey: .usesBullets)
        politeRequestRatio = try container.decode(Double.self, forKey: .politeRequestRatio)
        language = try container.decode(String.self, forKey: .language)
        extractionStatus = try container.decodeIfPresent(String.self, forKey: .extractionStatus) ?? "not_extracted"
        let descriptionOrigin = try container.decodeIfPresent(String.self, forKey: .descriptionOrigin)
        explanation = ["observed_format_traits", "llm_sent_text"].contains(descriptionOrigin ?? "")
            ? try container.decodeIfPresent(String.self, forKey: .explanation) ?? ""
            : ""
        extractedAt = try container.decodeIfPresent(String.self, forKey: .extractedAt)
        sourcePhrases = try container.decodeIfPresent([String].self, forKey: .sourcePhrases) ?? []
        sampleInfo = try container.decodeIfPresent(SampleInfo.self, forKey: .sampleInfo)
    }
}
