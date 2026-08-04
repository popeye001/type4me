import Foundation

@main
enum ASRShadowCrossCheckSmoke {
    static func main() {
        let cases: [(name: String, primary: String, shadow: String, retry: Bool)] = [
            (
                "lost middle clause",
                "明白。那最最后，我给你提的比如说上传网盘啊，这些都有了嘛。",
                "明白，那最最后我给你提了三个需求，是不是都也做了呢？就是它我已经完整一条龙，比如说上传网盘啊，这些都有了嘛。",
                true
            ),
            (
                "repeated suffix",
                "我想知道经过优化会有什么好转，主要体现在哪些地方样的一些好的好转，主要体现在哪些地方？",
                "我想知道经过优化会有什么好转，主要体现在哪些地方？",
                true
            ),
            (
                "punctuation only",
                "现在这个效果已经很好了，速度也比较快。",
                "现在这个效果已经很好了 速度也比较快",
                false
            ),
            (
                "digit presentation",
                "我们重复一二三四五来测试。",
                "我们重复12345来测试",
                false
            ),
            (
                "short missing tail",
                "我录",
                "我录好了",
                true
            ),
            (
                "short decimal formatting",
                "你是豆包二点零吗",
                "你是豆包2.0吗",
                false
            ),
        ]

        var failures: [String] = []
        for item in cases {
            let decision = ASRShadowCrossCheck.evaluate(
                primary: item.primary,
                shadow: item.shadow
            )
            if decision.shouldRetryWithFullAudio != item.retry {
                failures.append(
                    "\(item.name): expected retry=\(item.retry), got " +
                    "\(decision.shouldRetryWithFullAudio) (\(decision.reason))"
                )
            }
        }
        if failures.isEmpty {
            print("PASS: \(cases.count) ASR shadow cross-check cases")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
