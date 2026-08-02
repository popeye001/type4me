import Foundation
import XCTest
@testable import Type4Me

final class AudioSessionJournalTests: XCTestCase {
    func testJournalProducesRecoverableWAVAndMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-audio-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let journal = try AudioSessionJournal(
            sessionID: "session-1",
            createdAt: Date(),
            asrProvider: "LocalVoice",
            asrModel: "Qwen3-ASR-0.6B",
            directory: directory
        )
        journal.append(Data(repeating: 0x11, count: 6_400))
        journal.append(Data(repeating: 0x22, count: 3_200))
        journal.finalize(status: "completed")

        let wav = try Data(contentsOf: journal.audioURL)
        XCTAssertEqual(wav.count, 44 + 9_600)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(littleEndianUInt32(wav, at: 40), 9_600)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            AudioSessionJournal.Metadata.self,
            from: Data(contentsOf: journal.metadataURL)
        )
        XCTAssertEqual(metadata.pcmBytes, 9_600)
        XCTAssertEqual(metadata.chunkCount, 2)
        XCTAssertEqual(metadata.status, "completed")
        XCTAssertNil(metadata.shadowText)
    }

    func testRecoveryRepairsInterruptedHeader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-audio-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let journal = try AudioSessionJournal(
            sessionID: "interrupted-session",
            createdAt: Date(),
            asrProvider: "LocalVoice",
            asrModel: nil,
            directory: directory
        )
        journal.append(Data(repeating: 0x33, count: 3_200))

        // Simulate a stale header/sidecar from process termination. The open
        // handle is safe here because recovery uses a separate updating handle.
        try AudioSessionJournal.wavHeader(pcmBytes: 0).write(to: journal.audioURL)
        let pcmHandle = try FileHandle(forWritingTo: journal.audioURL)
        try pcmHandle.seekToEnd()
        try pcmHandle.write(contentsOf: Data(repeating: 0x33, count: 3_200))
        try pcmHandle.close()

        AudioSessionJournal.recoverInterruptedSessions(in: directory)

        let wav = try Data(contentsOf: journal.audioURL)
        XCTAssertEqual(littleEndianUInt32(wav, at: 40), 3_200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            AudioSessionJournal.Metadata.self,
            from: Data(contentsOf: journal.metadataURL)
        )
        XCTAssertEqual(metadata.status, "interrupted")
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(0) { value, item in
            value | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    }
}
