import Foundation
import os

enum VolcASRError: Error, LocalizedError {
    case unsupportedProvider
    case serverRejected(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider: return "VolcASRClient requires VolcanoASRConfig"
        case .serverRejected(let code, let message):
            return message ?? "HTTP \(code)"
        }
    }

    static func isWebSocketUpgradeProbeMessage(_ message: String?) -> Bool {
        guard let message = message?.lowercased(), !message.isEmpty else {
            return false
        }
        return message.contains("cannot upgrade to websocket")
            || message.contains("client is not using the websocket protocol")
            || message.contains("upgrade token not found")
            || message.contains("'upgrade' token not found")
    }
}

actor VolcASRClient: SpeechRecognizer {

    private static let endpoint =
        URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!

    private let logger = Logger(
        subsystem: "com.type4me.asr",
        category: "VolcASRClient"
    )

    // MARK: - State

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var ownsSession = false
    private var receiveTask: Task<Void, Never>?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream
        return stream
    }

    // MARK: - Connect

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions = ASRRequestOptions()) async throws {
        guard let volcConfig = config as? VolcanoASRConfig else {
            throw VolcASRError.unsupportedProvider
        }

        // Ensure fresh event stream
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        self.eventContinuation = continuation
        self._events = stream

        let connectId = UUID().uuidString
        let isCloudProxy = options.cloudProxyURL != nil
        let targetURL: URL
        if let proxyURLString = options.cloudProxyURL, let proxyURL = URL(string: proxyURLString) {
            targetURL = proxyURL
        } else {
            targetURL = Self.endpoint
        }

        var request = URLRequest(url: targetURL)
        if !isCloudProxy {
            // Direct connection: inject vendor credentials
            request.setValue(volcConfig.appKey, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(volcConfig.accessKey, forHTTPHeaderField: "X-Api-Access-Key")
            request.setValue(volcConfig.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(connectId, forHTTPHeaderField: "X-Api-Connect-Id")
        }

        // Send full_client_request (no compression, plain JSON)
        let payload = VolcProtocol.buildClientRequest(uid: volcConfig.uid, options: options)

        let header = VolcHeader(
            messageType: .fullClientRequest,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: payload)

        let initialSession = options.resolvedSession
        var activeSession = initialSession
        var activeTask = initialSession.webSocketTask(with: request)
        var activeOwnsSession = options.bypassProxy
        activeTask.resume()

        lastTranscript = .empty
        audioPacketCount = 0
        totalAudioBytes = 0
        didRequestEnd = false
        sessionStartTime = ContinuousClock.now
        lastTranscriptTime = nil
        localConfirmedSegments = []
        lastPartialText = ""
        lastServerConfirmedCount = 0
        NSLog("[ASR] Sending full_client_request (%d bytes), connectId=%@", message.count, connectId)
        do {
            try await activeTask.send(.data(message))
        } catch {
            // Long-idle shared URLSession sockets can fail on the first write.
            // Retry once with a fresh session before showing a user-visible error.
            NSLog("[ASR] WebSocket send failed: %@, retrying with fresh session...", String(describing: error))
            activeTask.cancel(with: .goingAway, reason: nil)

            let retrySession = URLSession(configuration: options.urlSessionConfiguration)
            let retryTask = retrySession.webSocketTask(with: request)
            retryTask.resume()
            do {
                try await retryTask.send(.data(message))
                activeSession = retrySession
                activeTask = retryTask
                activeOwnsSession = true
                NSLog("[ASR] WebSocket retry sent full_client_request OK")
            } catch {
                retryTask.cancel(with: .goingAway, reason: nil)
                retrySession.invalidateAndCancel()
                // WebSocket handshake failed — probe with HTTP to get real auth/vendor errors.
                NSLog("[ASR] WebSocket retry failed: %@, probing for server error...", String(describing: error))
                if let serverError = await Self.probeServerError(request: request) {
                    throw serverError
                }
                throw error
            }
        }

        self.session = activeSession
        self.ownsSession = activeOwnsSession
        self.webSocketTask = activeTask

        NSLog("[ASR] full_client_request sent OK")

        // Start receive loop
        startReceiveLoop()
    }

    /// When WebSocket handshake is rejected, make a plain HTTPS request to get the actual error body.
    private static func probeServerError(request: URLRequest) async -> VolcASRError? {
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        guard let httpsURL = components.url else { return nil }

        var httpRequest = URLRequest(url: httpsURL, timeoutInterval: 5)
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            httpRequest.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: httpRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode != 200 else { return nil }

            // Try to parse JSON error body (e.g. {"code": 1001, "message": "..."})
            var message: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = json["message"] as? String ?? json["msg"] as? String
                if let code = json["code"] as? Int, let msg = message {
                    message = "\(msg) (\(code))"
                }
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                message = String(text.prefix(200))
            }

            if VolcASRError.isWebSocketUpgradeProbeMessage(message) {
                NSLog("[ASR] Ignoring misleading WebSocket upgrade probe response: %@", message ?? "")
                return nil
            }

            NSLog("[ASR] HTTP probe got %d: %@", httpResponse.statusCode, message ?? "(no body)")
            return .serverRejected(statusCode: httpResponse.statusCode, message: message)
        } catch {
            NSLog("[ASR] HTTP probe failed: %@", String(describing: error))
            return nil
        }
    }

    // MARK: - Send Audio

    private var audioPacketCount = 0
    private var totalAudioBytes = 0
    private var didRequestEnd = false
    private var lastTranscript: RecognitionTranscript = .empty
    private var lastTranscriptTime: ContinuousClock.Instant?
    private var sessionStartTime: ContinuousClock.Instant?

    /// Locally promoted confirmed segments from dropped partials.
    /// When the server starts a new utterance without confirming the previous partial,
    /// we preserve the old partial here to prevent UI flicker.
    private var localConfirmedSegments: [String] = []
    /// Previous partial text for drop detection.
    private var lastPartialText: String = ""
    /// Previous server confirmed count, to detect genuine new confirmations vs stale state.
    private var lastServerConfirmedCount: Int = 0

    func sendAudio(_ data: Data) async throws {
        guard let task = webSocketTask else { return }
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: data,
            isLast: false
        )
        try await task.send(.data(packet))
        audioPacketCount += 1
        totalAudioBytes += data.count
    }

    // MARK: - End Audio

    func endAudio() async throws {
        guard let task = webSocketTask else { return }
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: Data(),
            isLast: true
        )
        didRequestEnd = true
        try await task.send(.data(packet))
        NSLog("[ASR] Sent last audio packet (empty, isLast=true)")
    }

    // MARK: - Disconnect

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        if ownsSession {
            session?.invalidateAndCancel()
        }
        ownsSession = false
        // Don't invalidate shared session — just release our reference
        session = nil
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
        NSLog("[ASR] Disconnected")
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.webSocketTask else { break }
                    let message = try await task.receive()
                    await self.handleMessage(message)
                } catch {
                    NSLog("[ASR] Receive loop error: %@", String(describing: error))
                    if !Task.isCancelled {
                        if await self.didRequestEnd {
                            // We already sent end-of-stream — socket close is normal.
                            NSLog("[ASR] Treating as normal session end (sent %d packets)", await self.audioPacketCount)
                        } else if await self.audioPacketCount == 0 {
                            // No audio sent yet — real connection/auth error.
                            await self.emitEvent(.error(error))
                        } else {
                            // Audio was flowing but we never sent end-of-stream — network failure.
                            NSLog("[ASR] Unexpected close during audio (sent %d packets)", await self.audioPacketCount)
                            await self.emitEvent(.error(error))
                        }
                        await self.emitEvent(.completed)
                    }
                    break
                }
            }
            NSLog("[ASR] Receive loop ended")
            // Finish the event stream so consumers (eventConsumptionTask) can complete.
            await self.eventContinuation?.finish()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            let headerByte1 = data.count > 1 ? data[1] : 0
            let msgType = (headerByte1 >> 4) & 0x0F

            // Server error (0xF): could be a real error or just
            // bigmodel_async's "session complete" signal.
            if msgType == 0x0F {
                if audioPacketCount == 0 {
                    // No audio was sent yet — this is a real setup/auth error.
                    do {
                        _ = try VolcProtocol.decodeServerResponse(data)
                    } catch {
                        NSLog("[ASR] Server error: %@", String(describing: error))
                        emitEvent(.error(error))
                    }
                } else {
                    NSLog("[ASR] Session ended by server after %d audio packets", audioPacketCount)
                }
                emitEvent(.completed)
                webSocketTask?.cancel(with: .normalClosure, reason: nil)
                webSocketTask = nil
                return
            }

            do {
                let response = try VolcProtocol.decodeServerResponse(data)
                let transcript = makeTranscript(
                    from: response.result,
                    isFinal: response.header.flags == .asyncFinal
                )
                guard transcript != lastTranscript else { return }
                lastTranscript = transcript

                let now = ContinuousClock.now
                let sinceStart = sessionStartTime.map { now - $0 } ?? .zero
                let sinceLastUpdate = lastTranscriptTime.map { now - $0 } ?? .zero
                lastTranscriptTime = now

                let gapMs = Int(sinceLastUpdate.components.seconds * 1000 + sinceLastUpdate.components.attoseconds / 1_000_000_000_000_000)
                DebugFileLogger.log("ASR transcript +\(sinceStart) gap=\(gapMs)ms confirmed=\(transcript.confirmedSegments.count) partial=\(transcript.partialText.count) final=\(transcript.isFinal)")

                NSLog(
                    "[ASR] Transcript update +%@ gap=%dms confirmed=%d partial=%d final=%@",
                    String(describing: sinceStart),
                    gapMs,
                    transcript.confirmedSegments.count,
                    transcript.partialText.count,
                    transcript.isFinal ? "yes" : "no"
                )
                emitEvent(.transcript(transcript))

                if transcript.isFinal, !transcript.authoritativeText.isEmpty {
                    NSLog("[ASR] Final transcript received (%d chars)", transcript.authoritativeText.count)
                }
            } catch {
                NSLog("[ASR] Decode error: %@", String(describing: error))
                emitEvent(.error(error))
            }

        case .string(let text):
            NSLog("[ASR] Unexpected text message: %@", text)

        @unknown default:
            break
        }
    }

    private func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }

    private func makeTranscript(from result: VolcASRResult, isFinal: Bool) -> RecognitionTranscript {
        let serverConfirmed = result.utterances
            .filter(\.definite)
            .map(\.text)
            .filter { !$0.isEmpty }
        let partialText = result.utterances.last(where: { !$0.definite && !$0.text.isEmpty })?.text ?? ""

        let prevServerConfirmedCount = lastServerConfirmedCount
        lastServerConfirmedCount = serverConfirmed.count

        // When the server confirms new segments, sync local state
        if serverConfirmed.count > localConfirmedSegments.count {
            localConfirmedSegments = serverConfirmed
        }

        // Detect dropped partial: server started a new utterance without confirming the old one.
        // Conditions: (1) server confirmed count didn't increase since last response,
        // (2) old partial was substantial.
        // Two sub-cases:
        //   a) new partial is non-empty but shares <50% prefix with old → replaced
        //   b) new partial is empty → server cleared it (e.g. during finalization)
        if !isFinal,
           serverConfirmed.count <= prevServerConfirmedCount,
           lastPartialText.count >= 4
        {
            if partialText.isEmpty {
                NSLog("[ASR] Partial cleared without confirmation: \"%@\", promoting to local confirmed",
                      lastPartialText)
                localConfirmedSegments.append(lastPartialText)
            } else {
                let lcp = longestCommonPrefixLength(lastPartialText, partialText)
                let ratio = Double(lcp) / Double(lastPartialText.count)
                if ratio < 0.5 {
                    NSLog("[ASR] Dropped partial detected: \"%@\" → \"%@\" (LCP=%d ratio=%.2f), promoting to local confirmed",
                          lastPartialText, partialText, lcp, ratio)
                    localConfirmedSegments.append(lastPartialText)
                }
            }
        }

        lastPartialText = partialText

        // Guard against false promotion: if the new partial overlaps significantly
        // with the last promoted segment, the server merely re-analyzed — undo.
        if !partialText.isEmpty && localConfirmedSegments.count > serverConfirmed.count {
            let lastPromoted = localConfirmedSegments.last!
            let lcp = longestCommonPrefixLength(lastPromoted, partialText)
            let ratio = Double(lcp) / Double(lastPromoted.count)
            if ratio >= 0.5 {
                NSLog("[ASR] Un-promoting \"%@\" — partial \"%@\" reclaims it (LCP ratio=%.2f)",
                      lastPromoted, partialText, ratio)
                localConfirmedSegments.removeLast()
            }
        }

        // Use local confirmed segments (which may include promoted partials)
        let effectiveConfirmed = localConfirmedSegments.count > serverConfirmed.count
            ? localConfirmedSegments : serverConfirmed

        let composedText = (effectiveConfirmed + (partialText.isEmpty ? [] : [partialText])).joined()
        let authoritativeText = result.text.isEmpty ? composedText : result.text
        return RecognitionTranscript(
            confirmedSegments: effectiveConfirmed,
            partialText: partialText,
            authoritativeText: authoritativeText,
            isFinal: isFinal
        )
    }

    private func longestCommonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        var ai = a.startIndex, bi = b.startIndex
        while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
            count += 1
            ai = a.index(after: ai)
            bi = b.index(after: bi)
        }
        return count
    }
}
