import XCTest
@testable import Type4Me

final class LLMProviderModelOptionsTests: XCTestCase {

    func testProviderModelListsExposeCurrentDefaults() {
        XCTAssertEqual(LLMProvider.doubao.optionValues.first, "doubao-seed-2-1-turbo-260628")
        XCTAssertTrue(LLMProvider.doubao.optionValues.contains("doubao-seed-2-1-pro-260628"))
        XCTAssertTrue(LLMProvider.doubao.optionValues.contains("doubao-seed-2-0-mini-260428"))

        XCTAssertEqual(LLMProvider.minimaxCN.optionValues.first, "MiniMax-M3")
        XCTAssertEqual(LLMProvider.minimaxCN.optionValues, LLMProvider.minimaxIntl.optionValues)

        XCTAssertEqual(LLMProvider.bailian.optionValues.first, "qwen3.7-plus")
        XCTAssertTrue(LLMProvider.bailian.optionValues.contains("qwen3.7-max"))
        XCTAssertTrue(LLMProvider.bailian.optionValues.contains("qwen3.6-flash"))

        XCTAssertEqual(LLMProvider.kimi.optionValues.first, "kimi-k2.6")
        XCTAssertTrue(LLMProvider.kimi.optionValues.contains("kimi-k2.7-code"))
        XCTAssertTrue(LLMProvider.kimi.optionValues.contains("kimi-k2.7-code-highspeed"))
        XCTAssertFalse(LLMProvider.kimi.optionValues.contains("kimi-k2-turbo-preview"))

        XCTAssertEqual(LLMProvider.openai.optionValues.first, "gpt-5.4-mini")
        XCTAssertTrue(LLMProvider.openai.optionValues.contains("gpt-5.5"))
        XCTAssertTrue(LLMProvider.openai.optionValues.contains("gpt-5.4-nano"))
        XCTAssertFalse(LLMProvider.openai.optionValues.contains("o4-mini"))

        XCTAssertEqual(LLMProvider.gemini.optionValues.first, "gemini-3.5-flash")
        XCTAssertTrue(LLMProvider.gemini.optionValues.contains("gemini-3.1-flash-lite"))
        XCTAssertTrue(LLMProvider.gemini.optionValues.contains("gemini-3.1-pro-preview"))
        XCTAssertFalse(LLMProvider.gemini.optionValues.contains("gemini-3.1-flash-lite-preview"))

        XCTAssertEqual(LLMProvider.deepseek.optionValues.first, "deepseek-v4-flash")
        XCTAssertTrue(LLMProvider.deepseek.optionValues.contains("deepseek-v4-pro"))

        XCTAssertEqual(LLMProvider.zhipu.optionValues.first, "glm-5.2")
        XCTAssertTrue(LLMProvider.zhipu.optionValues.contains("glm-4.7-flashx"))
        XCTAssertTrue(LLMProvider.zhipu.optionValues.contains("glm-4.7-flash"))

        XCTAssertEqual(LLMProvider.claude.optionValues.first, "claude-sonnet-5")
        XCTAssertTrue(LLMProvider.claude.optionValues.contains("claude-fable-5"))
        XCTAssertTrue(LLMProvider.claude.optionValues.contains("claude-opus-4-8"))
    }

    func testProviderModelOptionsHaveNoDuplicates() {
        for provider in LLMProvider.allCases {
            let values = provider.optionValues
            XCTAssertEqual(
                Set(values).count,
                values.count,
                "\(provider.rawValue) has duplicate model options"
            )
        }
    }

    func testThinkingDisableStrategyIsModelAware() {
        XCTAssertNil(LLMProvider.kimi.thinkingDisableField(for: "kimi-k2.7-code"))
        XCTAssertNil(LLMProvider.kimi.thinkingDisableField(for: "kimi-k2.7-code-highspeed"))
        XCTAssertEqual(LLMProvider.kimi.thinkingDisableField(for: "kimi-k2.6"), .thinking)
        XCTAssertEqual(LLMProvider.deepseek.thinkingDisableField(for: "deepseek-v4-flash"), .thinking)
        XCTAssertEqual(LLMProvider.zhipu.thinkingDisableField(for: "glm-5.2"), .thinking)
    }
}

private extension LLMProvider {
    var optionValues: [String] {
        modelOptions.map(\.value)
    }
}
