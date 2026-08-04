import XCTest
@testable import Type4Me

final class ASRShadowCrossCheckTests: XCTestCase {
    func testRetriesWhenStreamingLostMiddleClause() {
        let decision = ASRShadowCrossCheck.evaluate(
            primary: "明白。那最最后，我给你提的比如说上传网盘啊，这些都有了嘛。",
            shadow: "明白，那最最后我给你提了三个需求，是不是都也做了呢？就是它我已经完整一条龙，比如说上传网盘啊，这些都有了嘛。"
        )

        XCTAssertTrue(decision.shouldRetryWithFullAudio)
        XCTAssertEqual(decision.reason, "primary_missing_content")
    }

    func testRetriesWhenStreamingRepeatedSuffix() {
        let decision = ASRShadowCrossCheck.evaluate(
            primary: "我想知道经过优化会有什么好转，主要体现在哪些地方样的一些好的好转，主要体现在哪些地方？",
            shadow: "我想知道经过优化会有什么好转，主要体现在哪些地方？"
        )

        XCTAssertTrue(decision.shouldRetryWithFullAudio)
        XCTAssertEqual(decision.reason, "primary_repeated_content")
    }

    func testAcceptsPunctuationAndSmallWordingDifferences() {
        let decision = ASRShadowCrossCheck.evaluate(
            primary: "现在这个效果已经很好了，速度也比较快。",
            shadow: "现在这个效果已经很好了 速度也比较快"
        )

        XCTAssertFalse(decision.shouldRetryWithFullAudio)
        XCTAssertEqual(decision.reason, "consistent")
    }

    func testNormalizesArabicAndChineseDigitsBeforeComparison() {
        let decision = ASRShadowCrossCheck.evaluate(
            primary: "我们重复一二三四五来测试。",
            shadow: "我们重复12345来测试"
        )

        XCTAssertFalse(decision.shouldRetryWithFullAudio)
    }

    func testRetriesShortUtteranceWithMissingTail() {
        let decision = ASRShadowCrossCheck.evaluate(
            primary: "我录",
            shadow: "我录好了"
        )

        XCTAssertTrue(decision.shouldRetryWithFullAudio)
        XCTAssertEqual(decision.reason, "primary_missing_content")
    }

    func testAcceptsShortDecimalFormattingDifference() {
        let decision = ASRShadowCrossCheck.evaluate(
            primary: "你是豆包二点零吗",
            shadow: "你是豆包2.0吗"
        )

        XCTAssertFalse(decision.shouldRetryWithFullAudio)
        XCTAssertEqual(decision.reason, "consistent")
    }
}
