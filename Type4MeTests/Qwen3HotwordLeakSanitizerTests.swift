import XCTest
@testable import Type4Me

final class Qwen3HotwordLeakSanitizerTests: XCTestCase {
    func testStripsSingleChineseHotwordLeakWhenPreviewMatchesTail() {
        let text = Qwen3HotwordLeakSanitizer.sanitize(
            "一二三四三字",
            hotwords: ["一二三四"],
            fallbackText: "三字"
        )

        XCTAssertEqual(text, "三字")
    }

    func testKeepsFullHotwordUtterance() {
        let text = Qwen3HotwordLeakSanitizer.sanitize(
            "一二三四",
            hotwords: ["一二三四"],
            fallbackText: "一二三四"
        )

        XCTAssertEqual(text, "一二三四")
    }

    func testKeepsHotwordCorrectionWhenPreviewAlreadyStartsWithHotword() {
        let text = Qwen3HotwordLeakSanitizer.sanitize(
            "张三今天开会",
            hotwords: ["张三"],
            fallbackText: "张三今天开会"
        )

        XCTAssertEqual(text, "张三今天开会")
    }

    func testStripsLabeledHotwordDumpWithoutFallback() {
        let text = Qwen3HotwordLeakSanitizer.sanitize(
            "Vocabulary: OpenAI, Qwen, hello world",
            hotwords: ["OpenAI", "Qwen"]
        )

        XCTAssertEqual(text, "hello world")
    }

    func testFallsBackWhenDumpTailDoesNotMatchPreview() {
        let text = Qwen3HotwordLeakSanitizer.sanitize(
            "Claude, OpenAI, unrelated",
            hotwords: ["Claude", "OpenAI"],
            fallbackText: "真实内容"
        )

        XCTAssertEqual(text, "真实内容")
    }

    func testKeepsSingleHotwordPrefixWithoutFallback() {
        let text = Qwen3HotwordLeakSanitizer.sanitize(
            "一二三四三字",
            hotwords: ["一二三四"]
        )

        XCTAssertEqual(text, "一二三四三字")
    }
}
