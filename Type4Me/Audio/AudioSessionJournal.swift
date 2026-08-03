import Foundation

/// Incrementally persists the microphone stream before it is handed to ASR.
///
/// The journal intentionally sits outside the recognition transport. A decoder,
/// WebSocket, or UI failure therefore cannot destroy the source audio needed to
/// reproduce or recover a session.
final class AudioSessionJournal: @unchecked Sendable {
    struct Metadata: Codable, Sendable {
        let sessionID: String
        let createdAt: Date
        var updatedAt: Date
        let sampleRate: Int
        let channels: Int
        let bitsPerSample: Int
        let asrProvider: String
        let asrModel: String?
        var pcmBytes: Int
        var chunkCount: Int
        var status: String
        var shadowStatus: String?
        var shadowText: String?
        var shadowError: String?
        var shadowElapsedSeconds: Double?
    }

    enum JournalError: Error {
        case unableToCreateFile
    }

    let sessionID: String
    let audioURL: URL
    let metadataURL: URL

    private let lock = NSLock()
    private var metadata: Metadata
    private var fileHandle: FileHandle?
    private var finalized = false

    init(
        sessionID: String,
        createdAt: Date,
        asrProvider: String,
        asrModel: String?,
        directory: URL = AudioSessionJournal.defaultDirectory
    ) throws {
        Self.recoverInterruptedSessions(in: directory)
        self.sessionID = sessionID
        audioURL = directory.appendingPathComponent("\(sessionID).wav")
        metadataURL = directory.appendingPathComponent("\(sessionID).json")
        metadata = Metadata(
            sessionID: sessionID,
            createdAt: createdAt,
            updatedAt: createdAt,
            sampleRate: 16_000,
            channels: 1,
            bitsPerSample: 16,
            asrProvider: asrProvider,
            asrModel: asrModel,
            pcmBytes: 0,
            chunkCount: 0,
            status: "recording",
            shadowStatus: nil,
            shadowText: nil,
            shadowError: nil,
            shadowElapsedSeconds: nil
        )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(
            atPath: audioURL.path,
            contents: Self.wavHeader(pcmBytes: 0)
        ) else {
            throw JournalError.unableToCreateFile
        }
        fileHandle = try FileHandle(forUpdating: audioURL)
        try fileHandle?.seekToEnd()
        try persistMetadataLocked()
    }

    deinit {
        finalize(status: "interrupted")
    }

    /// Called directly from the audio callback. File writes are serialized and
    /// kept deliberately small so chunk ordering is identical to capture order.
    func append(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finalized, let fileHandle else { return }

        do {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: pcm16)
            metadata.pcmBytes += pcm16.count
            metadata.chunkCount += 1
            metadata.updatedAt = Date()

            // Refresh the WAV length and sidecar about once per second. If the
            // app is killed, the file remains playable up to the last checkpoint.
            if metadata.chunkCount.isMultiple(of: 5) {
                try rewriteHeaderLocked()
                try fileHandle.synchronize()
                try persistMetadataLocked()
            }
        } catch {
            DebugFileLogger.log("audio journal append failed session=\(sessionID): \(error)")
        }
    }

    /// Closes the audio file after capture stops. Repeated calls are harmless.
    func finalize(status: String) {
        lock.lock()
        defer { lock.unlock() }

        if finalized {
            return
        }
        finalized = true
        metadata.status = status
        metadata.updatedAt = Date()
        do {
            try rewriteHeaderLocked()
            try fileHandle?.synchronize()
            try fileHandle?.close()
            fileHandle = nil
            try persistMetadataLocked()
        } catch {
            DebugFileLogger.log("audio journal finalize failed session=\(sessionID): \(error)")
        }
    }

    /// Updates the recognition outcome without reopening the WAV file.
    func markOutcome(_ status: String) {
        lock.lock()
        defer { lock.unlock() }
        updateStatusLocked(status)
    }

    func markShadowResult(_ output: AppleSpeechAnalyzerShadowSession.Output) {
        lock.lock()
        defer { lock.unlock() }
        metadata.shadowStatus = output.status
        metadata.shadowText = output.text.isEmpty ? nil : output.text
        metadata.shadowError = output.errorDescription
        metadata.shadowElapsedSeconds = output.elapsedSeconds
        metadata.updatedAt = Date()
        do {
            try persistMetadataLocked()
        } catch {
            DebugFileLogger.log("audio journal shadow metadata failed session=\(sessionID): \(error)")
        }
    }

    private func updateStatusLocked(_ status: String) {
        metadata.status = status
        metadata.updatedAt = Date()
        do {
            try persistMetadataLocked()
        } catch {
            DebugFileLogger.log("audio journal metadata failed session=\(sessionID): \(error)")
        }
    }

    private func rewriteHeaderLocked() throws {
        guard let fileHandle else { return }
        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: Self.wavHeader(pcmBytes: metadata.pcmBytes))
        try fileHandle.seekToEnd()
    }

    private func persistMetadataLocked() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Type4Me", isDirectory: true)
            .appendingPathComponent("AudioHistory", isDirectory: true)
    }

    static func wavHeader(pcmBytes: Int) -> Data {
        let safePCMBytes = UInt32(clamping: pcmBytes)
        let byteRate: UInt32 = 16_000 * 1 * 16 / 8
        let blockAlign: UInt16 = 1 * 16 / 8
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.appendLittleEndian(UInt32(36) &+ safePCMBytes)
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(16_000))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(UInt16(16))
        data.append("data".data(using: .ascii)!)
        data.appendLittleEndian(safePCMBytes)
        return data
    }

    /// Repairs sessions left open by a crash or forced process termination.
    /// The PCM bytes were already durable; this restores the WAV length fields
    /// and marks the sidecar so diagnostics can distinguish an interrupted run.
    static func recoverInterruptedSessions(in directory: URL = defaultDirectory) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for audioURL in files where audioURL.pathExtension == "wav" {
            let metadataURL = audioURL.deletingPathExtension().appendingPathExtension("json")
            guard let metadataData = try? Data(contentsOf: metadataURL),
                  var metadata = try? decoder.decode(Metadata.self, from: metadataData),
                  metadata.status == "recording"
            else { continue }

            do {
                let values = try audioURL.resourceValues(forKeys: [.fileSizeKey])
                let pcmBytes = max(0, (values.fileSize ?? 44) - 44)
                let handle = try FileHandle(forUpdating: audioURL)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: wavHeader(pcmBytes: pcmBytes))
                try handle.synchronize()
                try handle.close()

                metadata.pcmBytes = pcmBytes
                metadata.updatedAt = Date()
                metadata.status = "interrupted"
                try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
                DebugFileLogger.log("audio journal recovered session=\(metadata.sessionID) bytes=\(pcmBytes)")
            } catch {
                DebugFileLogger.log("audio journal recovery failed path=\(audioURL.path): \(error)")
            }
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
