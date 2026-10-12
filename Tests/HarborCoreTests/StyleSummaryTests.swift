import Foundation
import XCTest
@testable import HarborCore

final class StyleSummaryTests: XCTestCase {
    private var traits: [String: Any] {
        ["version": "local-style-2-authored", "example_count": 2,
         "paragraph_characters_median": 48, "sentence_characters_median": 32,
         "paragraphs_per_message_median": 3, "uses_bullets": false,
         "polite_request_ratio": 0.5, "language": "Japanese"]
    }

    private func decode(_ value: [String: Any]) throws -> StyleSummary {
        try JSONDecoder().decode(StyleSummary.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testExistingNumericProfileWithoutCorpusInfoKeepsItsUnextractedState() throws {
        let summary = try decode(traits)
        XCTAssertEqual(summary.exampleCount, 2)
        XCTAssertNil(summary.sampleInfo)
        XCTAssertEqual(summary.extractionStatus, "not_extracted")
        XCTAssertFalse(summary.isExtracted)
        XCTAssertEqual(summary.explanation, "")
    }

    func testCorpusProfileDecodesManySamplesAndConservativeTokenCounts() throws {
        let value = traits.merging([
            "example_count": 256, "extraction_status": "ready",
            "description": "短い段落の文体です。",
            "description_origin": "observed_format_traits",
            "source_phrases": ["ご確認をお願いいたします。"],
            "corpus_version": "local-style-corpus-1",
            "sample_info": ["selected_messages": 256, "token_estimate": 31_000,
                            "token_budget": 32_768, "token_estimate_is_exact": false,
                            "token_unit": "utf8_bytes_upper_bound", "candidates_checked": 280,
                            "candidates_fetched": 320, "sample_limit": 512,
                            "coverage": ["snapshot_only": true]],
        ], uniquingKeysWith: { _, new in new })
        let summary = try decode(value)
        let sample = try XCTUnwrap(summary.sampleInfo)
        XCTAssertTrue(summary.isExtracted)
        XCTAssertEqual(summary.explanation, "短い段落の文体です。")
        XCTAssertEqual(summary.sourcePhrases, ["ご確認をお願いいたします。"])
        XCTAssertEqual(summary.exampleCount, 256)
        XCTAssertEqual(sample.selectedMessages, 256)
        XCTAssertEqual(sample.tokenEstimate, 31_000)
        XCTAssertEqual(sample.tokenBudget, 32_768)
        XCTAssertFalse(sample.tokenEstimateIsExact)
        XCTAssertEqual(sample.candidatesChecked, 280)
    }

    func testLegacyFabricatedExamplesAndDescriptionsAreNeverDisplayed() throws {
        let value = traits.merging([
            "extraction_status": "ready",
            "description": "以下は構成を示す合成例です。",
            "examples": ["[今回の用件]をご確認ください。"],
            "example_origin": "synthetic_template_not_source_quote",
            "source_phrases": ["ご確認をお願いいたします。"],
        ], uniquingKeysWith: { _, new in new })
        let summary = try decode(value)
        XCTAssertEqual(summary.explanation, "")
        XCTAssertFalse(summary.isExtracted)
        XCTAssertEqual(summary.exampleCount, 2)
    }

    func testMalformedTokenCountsCannotBeDisplayedAsAnExtractedProfile() {
        let value = traits.merging([
            "extraction_status": "ready", "description": "架空の文体説明。",
            "sample_info": ["selected_messages": 8, "token_estimate": "unknown",
                            "token_budget": 32_768, "token_estimate_is_exact": false,
                            "candidates_checked": 8],
        ], uniquingKeysWith: { _, new in new })
        XCTAssertThrowsError(try decode(value))
    }

    func testSenderLabelComesFromExtractedProfileAndOldProfilesHaveNoInventedScope() throws {
        XCTAssertNil(try decode(traits).sourceAddress)
        let value = traits.merging(["source_address": "author@fixture.invalid", "source_account_id": "fixture-personal"],
                                  uniquingKeysWith: { _, new in new })
        let summary = try decode(value)
        XCTAssertEqual(summary.sourceAddress, "author@fixture.invalid")
        XCTAssertEqual(summary.sourceAccountID, "fixture-personal")
    }
}
