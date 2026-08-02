import XCTest
@testable import Type4Me

final class HistoryStoreTests: XCTestCase {

    private var store: HistoryStore!
    private var testPath: String!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-test-\(UUID().uuidString).db").path
        store = HistoryStore(path: testPath)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: testPath)
    }

    func testInsertAndFetchAll() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 3.5,
            rawText: "测试文本", processingMode: nil, processedText: nil,
            finalText: "测试文本", status: "completed", characterCount: 4, asrProvider: nil,
            audioSessionID: "audio-session", audioPath: "/tmp/audio-session.wav"
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.rawText, "测试文本")
        XCTAssertEqual(all.first?.durationSeconds ?? 0, 3.5, accuracy: 0.01)
        XCTAssertEqual(all.first?.characterCount, 4)
        XCTAssertEqual(all.first?.audioSessionID, "audio-session")
        XCTAssertEqual(all.first?.audioPath, "/tmp/audio-session.wav")
    }

    func testInsertWithProcessedText() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 2.0,
            rawText: "原始文本", processingMode: "润色",
            processedText: "润色后的文本", finalText: "润色后的文本", status: "completed",
            characterCount: 6, asrProvider: nil
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.processingMode, "润色")
        XCTAssertEqual(all.first?.processedText, "润色后的文本")
        XCTAssertEqual(all.first?.characterCount, 6)
    }

    func testInterruptedCheckpointKeepsLatestStreamingText() async {
        let id = "stream-recovery"
        let createdAt = Date()
        await store.upsertInterrupted(HistoryRecord(
            id: id, createdAt: createdAt, durationSeconds: 4,
            rawText: "前四秒", processingMode: nil, processedText: nil,
            finalText: "前四秒", status: "interrupted", characterCount: 3,
            asrProvider: "OpenAI", asrModel: "Qwen3-ASR-0.6B"
        ))
        await store.upsertInterrupted(HistoryRecord(
            id: id, createdAt: createdAt, durationSeconds: 8,
            rawText: "前八秒已经识别", processingMode: nil, processedText: nil,
            finalText: "前八秒已经识别", status: "interrupted", characterCount: 7,
            asrProvider: "OpenAI", asrModel: "Qwen3-ASR-0.6B"
        ))

        let recovered = await store.fetchAll().first
        XCTAssertEqual(recovered?.id, id)
        XCTAssertEqual(recovered?.status, "interrupted")
        XCTAssertEqual(recovered?.rawText, "前八秒已经识别")
        XCTAssertEqual(recovered?.durationSeconds ?? 0, 8, accuracy: 0.01)
    }

    func testLateCheckpointCannotOverwriteCompletedHistory() async {
        let id = "completed-stream"
        let createdAt = Date()
        let partial = HistoryRecord(
            id: id, createdAt: createdAt, durationSeconds: 4,
            rawText: "部分", processingMode: nil, processedText: nil,
            finalText: "部分", status: "interrupted", characterCount: 2,
            asrProvider: "OpenAI"
        )
        await store.upsertInterrupted(partial)
        await store.insert(HistoryRecord(
            id: id, createdAt: createdAt, durationSeconds: 6,
            rawText: "完整结果", processingMode: nil, processedText: nil,
            finalText: "完整结果", status: "completed", characterCount: 4,
            asrProvider: "OpenAI"
        ))
        await store.upsertInterrupted(partial)

        let record = await store.fetchAll().first
        XCTAssertEqual(record?.status, "completed")
        XCTAssertEqual(record?.finalText, "完整结果")
    }

    func testDelete() async {
        let id = UUID().uuidString
        let record = HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 1.0,
            rawText: "to delete", processingMode: nil, processedText: nil,
            finalText: "to delete", status: "completed", characterCount: 9, asrProvider: nil
        )
        await store.insert(record)
        await store.delete(id: id)
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testFetchAllOrderedByDate() async {
        let old = HistoryRecord(
            id: "1", createdAt: Date(timeIntervalSinceNow: -100), durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old", status: "completed", characterCount: 3, asrProvider: nil
        )
        let recent = HistoryRecord(
            id: "2", createdAt: Date(), durationSeconds: 1,
            rawText: "recent", processingMode: nil, processedText: nil,
            finalText: "recent", status: "completed", characterCount: 6, asrProvider: nil
        )
        await store.insert(old)
        await store.insert(recent)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.rawText, "recent")
        XCTAssertEqual(all.last?.rawText, "old")
    }

    func testDeleteAll() async {
        for i in 0..<3 {
            await store.insert(HistoryRecord(
                id: "\(i)", createdAt: Date(), durationSeconds: 1,
                rawText: "text\(i)", processingMode: nil, processedText: nil,
                finalText: "text\(i)", status: "completed", characterCount: 5 + i, asrProvider: nil
            ))
        }
        await store.deleteAll()
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testDeleteBatchEmptyDoesNothing() async {
        let id = "only-one"
        await store.insert(HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 1,
            rawText: "x", processingMode: nil, processedText: nil,
            finalText: "x", status: "completed", characterCount: 1, asrProvider: nil
        ))
        await store.delete(ids: [])
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, id)
    }

    func testDeleteBatch() async {
        for i in 0..<5 {
            await store.insert(HistoryRecord(
                id: "batch-\(i)", createdAt: Date(), durationSeconds: 1,
                rawText: "t\(i)", processingMode: nil, processedText: nil,
                finalText: "t\(i)", status: "completed", characterCount: 2, asrProvider: nil
            ))
        }
        await store.delete(ids: ["batch-0", "batch-2", "batch-4"])
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 2)
        let ids = Set(all.map(\.id))
        XCTAssertEqual(ids, Set(["batch-1", "batch-3"]))
    }

    func testDeleteBatchPostsSingleNotification() async {
        await store.insert(HistoryRecord(
            id: "a", createdAt: Date(), durationSeconds: 1,
            rawText: "a", processingMode: nil, processedText: nil,
            finalText: "a", status: "completed", characterCount: 1, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "b", createdAt: Date(), durationSeconds: 1,
            rawText: "b", processingMode: nil, processedText: nil,
            finalText: "b", status: "completed", characterCount: 1, asrProvider: nil
        ))

        let batchNote = expectation(forNotification: .historyStoreDidChange, object: nil)
        await store.delete(ids: ["a", "b"])
        await fulfillment(of: [batchNote], timeout: 1.0)

        let remaining = await store.fetchAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testInsertPostsHistoryDidChangeNotification() async {
        let notification = expectation(forNotification: .historyStoreDidChange, object: nil)
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 1.2,
            rawText: "notify", processingMode: "智能模式", processedText: "notify",
            finalText: "notify", status: "completed", characterCount: 6, asrProvider: nil
        )

        await store.insert(record)

        await fulfillment(of: [notification], timeout: 1.0)
    }

    func testUsageBreakdownGroupsByProviderAndPeriods() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records: [HistoryRecord] = [
            HistoryRecord(
                id: "soniox-now", createdAt: now.addingTimeInterval(-60), durationSeconds: 30,
                rawText: "a", processingMode: nil, processedText: nil,
                finalText: "a", status: "completed", characterCount: 1, asrProvider: "Soniox",
                asrModel: "Soniox · stt-rt-v5"
            ),
            HistoryRecord(
                id: "soniox-week", createdAt: now.addingTimeInterval(-3 * 24 * 60 * 60), durationSeconds: 90,
                rawText: "b", processingMode: nil, processedText: nil,
                finalText: "b", status: "completed", characterCount: 1, asrProvider: "Soniox",
                asrModel: "Soniox · stt-rt-v5"
            ),
            HistoryRecord(
                id: "openai-month", createdAt: now.addingTimeInterval(-10 * 24 * 60 * 60), durationSeconds: 120,
                rawText: "c", processingMode: nil, processedText: nil,
                finalText: "c", status: "completed", characterCount: 1, asrProvider: "OpenAI"
            ),
            HistoryRecord(
                id: "old", createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60), durationSeconds: 300,
                rawText: "d", processingMode: nil, processedText: nil,
                finalText: "d", status: "completed", characterCount: 1, asrProvider: "Old"
            )
        ]

        for record in records {
            await store.insert(record)
        }

        let rows = await store.getUsageBreakdown(now: now)
        let byModel = Dictionary(uniqueKeysWithValues: rows.map { ($0.modelName, $0) })

        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.lastDayDuration ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.last7DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.last30DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.lastDayDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.last7DaysDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.last30DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Old"]?.last30DaysDuration ?? 0, 0, accuracy: 0.01)
    }
}
