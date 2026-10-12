import XCTest
@testable import HarborCore

final class StyleTextTests: XCTestCase {
    func testQuotesDuplicatesAndWhitespaceAreNotFiltered() {
        var text = StyleText(limit: 100)
        text.append("> quoted\nSame"); text.append("> quoted\nSame")
        XCTAssertEqual(text.text, "> quoted\nSame\n\n> quoted\nSame")
        XCTAssertEqual(text.messages, 2)
    }
    func testExactCharacterLimitIncludingUnicodeAndSeparator() {
        var text = StyleText(limit: 8)
        text.append("あ👨‍👩‍👧‍👦い"); text.append("うえおかき")
        XCTAssertEqual(text.text, "あ👨‍👩‍👧‍👦い\n\nうえお")
        XCTAssertEqual(text.characters, 8)
        text.append("ignored")
        XCTAssertEqual(text.characters, 8)
    }
    func testLongBodyContributesItsPrefixInsteadOfBeingRejected() {
        var text = StyleText(limit: 10)
        text.append(String(repeating: "a", count: 1000))
        XCTAssertEqual(text.text, "aaaaaaaaaa")
        XCTAssertTrue(text.isFull)
    }
}
