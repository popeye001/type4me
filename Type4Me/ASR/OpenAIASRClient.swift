import Foundation
import os

enum OpenAIASRError: Error, LocalizedError {
    case invalidConfig
    case emptyAudio
    case requestFailed(Int)
    case invalidResponse
    case invalidStreamingEndpoint
    case streamingHandshakeFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfig:     return "OpenAI ASR requires OpenAIASRConfig"
        case .emptyAudio:        return "No audio data recorded"
        case .requestFailed(let code): return "OpenAI API returned HTTP \(code)"
        case .invalidResponse:   return "Failed to parse OpenAI transcription response"
        case .invalidStreamingEndpoint: return "Invalid LocalVoice streaming endpoint"
        case .streamingHandshakeFailed: return "LocalVoice streaming handshake failed"
        }
    }
}

/// OpenAI-compatible ASR client.
///
/// Qwen3-ASR on the user's LocalVoice server uses a WebSocket session so audio
/// is decoded while recording. Other OpenAI-compatible endpoints retain the
/// original whole-file REST fallback.
actor OpenAIASRClient: SpeechRecognizer {

    private let logger = Logger(subsystem: "com.type4me.asr", category: "OpenAIASRClient")

    private var config: OpenAIASRConfig?
    /// Capture request options at connect time so batch providers can pass
    /// user-specific vocabulary to the transcription request.
    private var requestOptions = ASRRequestOptions()
    private var audioBuffer = Data()
    private var usesLocalVoiceStreaming = false
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var didRequestFinish = false
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        guard let openAIConfig = config as? OpenAIASRConfig else {
            throw OpenAIASRError.invalidConfig
        }
        self.config = openAIConfig
        self.requestOptions = options
        audioBuffer = Data()
        didRequestFinish = false

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream

        usesLocalVoiceStreaming = Self.shouldUseLocalVoiceStreaming(openAIConfig)
        if usesLocalVoiceStreaming {
            try await connectLocalVoice(config: openAIConfig, options: options)
            continuation.yield(.ready)
            startReceiveLoop()
        } else {
            continuation.yield(.ready)

            // Batch fallback: show a recording placeholder while accumulating audio.
            let placeholder = RecognitionTranscript(
                confirmedSegments: [],
                partialText: L("录音中…", "Recording…"),
                authoritativeText: "",
                isFinal: false
            )
            continuation.yield(.transcript(placeholder))
        }
    }

    func sendAudio(_ data: Data) async throws {
        if usesLocalVoiceStreaming {
            try await webSocketTask?.send(.data(data))
        } else {
            audioBuffer.append(data)
        }
    }

    func endAudio() async throws {
        guard let config else { return }

        if usesLocalVoiceStreaming {
            didRequestFinish = true
            let command = try JSONSerialization.data(withJSONObject: ["type": "finish"])
            guard let text = String(data: command, encoding: .utf8) else {
                throw OpenAIASRError.invalidResponse
            }
            try await webSocketTask?.send(.string(text))
            return
        }

        // 0.5s at 16kHz, 16-bit PCM = 16000 bytes
        let minBytes = Int(0.5 * 16000) * 2
        guard audioBuffer.count >= minBytes else {
            // Too short for Whisper — skip API call to avoid hallucination
            let transcript = RecognitionTranscript(
                confirmedSegments: [],
                partialText: "",
                authoritativeText: "",
                isFinal: true
            )
            eventContinuation?.yield(.transcript(transcript))
            eventContinuation?.yield(.completed)
            eventContinuation?.finish()
            return
        }

        let wavData = Self.wavFromPCM(audioBuffer)
        logger.info("Sending \(wavData.count) bytes WAV to OpenAI transcription")

        let text = try await transcribe(wavData: wavData, config: config)

        if !text.isEmpty {
            let transcript = RecognitionTranscript(
                confirmedSegments: [text],
                partialText: "",
                authoritativeText: text,
                isFinal: true
            )
            eventContinuation?.yield(.transcript(transcript))
        }

        eventContinuation?.yield(.completed)
        eventContinuation?.finish()
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        audioBuffer = Data()
        config = nil
        requestOptions = ASRRequestOptions()
        usesLocalVoiceStreaming = false
        didRequestFinish = false
    }

    // MARK: - LocalVoice streaming

    private static func shouldUseLocalVoiceStreaming(_ config: OpenAIASRConfig) -> Bool {
        config.model.lowercased().contains("qwen3-asr")
    }

    private static func streamingURL(from baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, "audio/transcriptions/stream"]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func connectLocalVoice(config: OpenAIASRConfig, options: ASRRequestOptions) async throws {
        guard let url = Self.streamingURL(from: config.baseURL) else {
            throw OpenAIASRError.invalidStreamingEndpoint
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let context = options.hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let start: [String: Any] = [
            "type": "start",
            "context": context,
            "chunk_size_sec": 4.0,
            // Bound decoder context so minute-long dictation does not become
            // progressively slower or stall while retaining the accumulated text.
            "max_context_sec": 30.0,
            // Finish on the fast incremental path first. If the decoder sees
            // the tail audio but produces no new text, accuracy mode retries
            // only the final few seconds. The server pins that retry to the
            // already-downloaded local model, so it never waits on the cloud.
            "finalization_mode": "accuracy",
            // Fixed chunks avoid an energy-endpoint tail decode occasionally
            // taking tens of seconds on long recordings.
            "endpointing_mode": "fixed",
        ]
        let startData = try JSONSerialization.data(withJSONObject: start)
        guard let startText = String(data: startData, encoding: .utf8) else {
            throw OpenAIASRError.invalidResponse
        }

        // macOS can transiently report `.notConnectedToInternet` for the
        // first LAN WebSocket after a long idle or app launch, even when the
        // local server is reachable a moment later. Audio is buffered while
        // connecting, so one short transparent retry is preferable to making
        // the user press the shortcut a second time.
        var lastError: Error?
        for attempt in 0..<2 {
            let task = options.resolvedSession.webSocketTask(with: request)
            webSocketTask = task
            task.resume()

            do {
                try await task.send(.string(startText))
                let reply = try await task.receive()
                guard let payload = Self.messageData(reply),
                      let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      object["type"] as? String == "ready"
                else {
                    throw OpenAIASRError.streamingHandshakeFailed
                }
                logger.info("LocalVoice streaming connected: \(url.absoluteString, privacy: .private(mask: .hash))")
                return
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                webSocketTask = nil
                lastError = error
                guard attempt == 0, Self.isTransientLANConnectError(error) else { throw error }
                DebugFileLogger.log("LocalVoice first connect failed; retrying once: \(error)")
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
        throw lastError ?? OpenAIASRError.streamingHandshakeFailed
    }

    private static func isTransientLANConnectError(_ error: Error) -> Bool {
        let urlError = error as? URLError
        switch urlError?.code {
        case .notConnectedToInternet, .timedOut, .cannotConnectToHost, .networkConnectionLost:
            return true
        default:
            return false
        }
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    let isComplete = await self.handleStreamingMessage(message)
                    if isComplete { break }
                } catch {
                    if Task.isCancelled { break }
                    let expectedClose = await self.didRequestFinish
                    if !expectedClose {
                        await self.emitEvent(.error(error))
                        await self.emitEvent(.completed)
                    }
                    break
                }
            }
            await self.finishEventStream()
        }
    }

    private func handleStreamingMessage(_ message: URLSessionWebSocketTask.Message) -> Bool {
        guard let data = Self.messageData(message),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return false }

        switch type {
        case "partial", "final":
            let rawText = (object["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = Qwen3HotwordLeakSanitizer.sanitize(
                rawText,
                hotwords: requestOptions.hotwords
            )
            if text != rawText {
                DebugFileLogger.log("LocalVoice hotword leak sanitized \(rawText.count)->\(text.count) chars")
            }
            let isFinal = type == "final"
            let chunkID = object["chunk_id"] as? Int ?? 0
            let processingMS = object["processing_ms"] as? Int ?? 0
            let audioSeconds = object["audio_seconds"] as? Double ?? 0
            DebugFileLogger.log(
                "LocalVoice \(type) chunk=\(chunkID) audio=\(String(format: "%.1f", audioSeconds))s " +
                "server=\(processingMS)ms chars=\(text.count)"
            )
            let transcript = RecognitionTranscript(
                confirmedSegments: isFinal && !text.isEmpty ? [text] : [],
                partialText: isFinal ? "" : text,
                authoritativeText: text,
                isFinal: isFinal,
                processedAudioSeconds: audioSeconds
            )
            eventContinuation?.yield(.transcript(transcript))
            if isFinal {
                logger.info("LocalVoice final result: \(text.count) chars")
                eventContinuation?.yield(.completed)
                return true
            }
        case "error":
            let message = object["message"] as? String ?? "LocalVoice streaming failed"
            let error = NSError(
                domain: "LocalVoiceASR",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            eventContinuation?.yield(.error(error))
            eventContinuation?.yield(.completed)
            return true
        default:
            break
        }
        return false
    }

    private static func messageData(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: return nil
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }

    private func finishEventStream() {
        eventContinuation?.finish()
    }

    // MARK: - Transcription API

    /// Force one whole-file REST transcription even when this model normally
    /// uses LocalVoice WebSocket streaming. Recovery must use a fresh decoder
    /// pass over the complete recording; opening another streaming session can
    /// reproduce the same dropped-middle failure it is meant to repair.
    func transcribeFullAudio(
        pcmData: Data,
        config: OpenAIASRConfig,
        options: ASRRequestOptions
    ) async throws -> String {
        guard !pcmData.isEmpty else { throw OpenAIASRError.emptyAudio }
        requestOptions = options
        return try await transcribe(wavData: Self.wavFromPCM(pcmData), config: config)
    }

    private func transcribe(wavData: Data, config: OpenAIASRConfig) async throws -> String {
        guard let url = URL(string: "\(config.baseURL)/audio/transcriptions") else {
            throw OpenAIASRError.invalidConfig
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120  // Whisper may need >60s for long recordings

        // Build multipart form data
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: "audio.wav", mimeType: "audio/wav", data: wavData)
        body.appendMultipart(boundary: boundary, name: "model", value: config.model)
        body.appendMultipart(boundary: boundary, name: "response_format", value: "json")
        // Qwen3-ASR's OpenAI-compatible server accepts `prompt` as context.
        // Reuse Type4Me's hotword list for names, products, and projects.
        let prompt = requestOptions.hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !prompt.isEmpty {
            body.appendMultipart(boundary: boundary, name: "prompt", value: prompt)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await requestOptions.resolvedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIASRError.requestFailed(0)
        }

        guard http.statusCode == 200 else {
            if let raw = String(data: data.prefix(500), encoding: .utf8) {
                logger.error("OpenAI ASR HTTP \(http.statusCode): \(raw)")
            }
            throw OpenAIASRError.requestFailed(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else {
            if let raw = String(data: data.prefix(500), encoding: .utf8) {
                logger.error("OpenAI ASR unexpected response: \(raw)")
            }
            throw OpenAIASRError.invalidResponse
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("OpenAI ASR result: \(trimmed.count) chars")
        return trimmed
    }

    // MARK: - WAV Encoding

    private static func wavFromPCM(_ pcmData: Data) -> Data {
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize

        var wav = Data(capacity: 44 + pcmData.count)

        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
        appendUInt32(&wav, fileSize)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"

        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
        appendUInt32(&wav, 16)
        appendUInt16(&wav, 1)        // PCM format
        appendUInt16(&wav, 1)        // mono
        appendUInt32(&wav, 16000)    // sample rate
        appendUInt32(&wav, 32000)    // byte rate
        appendUInt16(&wav, 2)        // block align
        appendUInt16(&wav, 16)       // bits per sample

        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
        appendUInt32(&wav, dataSize)
        wav.append(pcmData)

        return wav
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 2))
    }
}

// MARK: - Multipart Helpers

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
