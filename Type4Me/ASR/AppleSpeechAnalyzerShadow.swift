import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech

/// A non-authoritative SpeechAnalyzer session fed with the same PCM stream as
/// the primary recognizer. Its result is diagnostic only: it never reaches the
/// input field and therefore cannot change current user-visible behavior.
final class AppleSpeechAnalyzerShadowSession: @unchecked Sendable {
    struct Output: Sendable {
        let text: String
        let status: String
        let errorDescription: String?
        let elapsedSeconds: Double
    }

    private let inputContinuation: AsyncStream<Data>.Continuation
    private let task: Task<Output, Never>

    init(locale: Locale = Locale(identifier: "zh_CN")) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .unbounded
        )
        inputContinuation = continuation
        task = Task.detached(priority: .utility) {
            guard #available(macOS 26.0, *) else {
                return Output(
                    text: "",
                    status: "unsupported_os",
                    errorDescription: nil,
                    elapsedSeconds: 0
                )
            }
            return await Self.runModern(input: stream, locale: locale)
        }
    }

    func append(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        inputContinuation.yield(pcm16)
    }

    func finish() async -> Output {
        inputContinuation.finish()
        return await task.value
    }

    func cancel() {
        inputContinuation.finish()
        task.cancel()
    }

    @available(macOS 26.0, *)
    private static func runModern(
        input: AsyncStream<Data>,
        locale requestedLocale: Locale
    ) async -> Output {
        let startedAt = ContinuousClock.now
        guard SpeechTranscriber.isAvailable else {
            return output(status: "unavailable", startedAt: startedAt)
        }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            return output(status: "locale_unsupported", startedAt: startedAt)
        }
        let installedLocales = await SpeechTranscriber.installedLocales
        guard installedLocales.contains(where: { installed in
            installed.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else {
            return output(status: "asset_missing", startedAt: startedAt)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: AudioCaptureEngine.targetFormat
        ) else {
            return output(status: "format_unavailable", startedAt: startedAt)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (analyzerInput, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .unbounded
        )

        let resultTask = Task { () -> (final: String, volatile: String) in
            var finalized = ""
            var volatile = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                }
            } catch {
                DebugFileLogger.log("Apple shadow result stream failed: \(error)")
            }
            return (finalized, volatile)
        }

        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try await analyzer.start(inputSequence: analyzerInput)
            let converter = try ShadowAudioConverter(outputFormat: analyzerFormat)

            for await data in input {
                if Task.isCancelled { break }
                guard let pcmBuffer = AudioCaptureEngine.makePCMBuffer(from: data) else {
                    continue
                }
                if let converted = try converter.convert(pcmBuffer) {
                    analyzerContinuation.yield(AnalyzerInput(buffer: converted))
                }
            }

            analyzerContinuation.finish()
            if Task.isCancelled {
                await analyzer.cancelAndFinishNow()
                resultTask.cancel()
                return output(status: "cancelled", startedAt: startedAt)
            }

            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let result = await resultTask.value
            let text = (result.final.isEmpty ? result.volatile : result.final)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output(
                text: text,
                status: text.isEmpty ? "empty" : "completed",
                startedAt: startedAt
            )
        } catch {
            analyzerContinuation.finish()
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            DebugFileLogger.log("Apple shadow failed: \(error)")
            return output(
                status: "failed",
                errorDescription: String(describing: error),
                startedAt: startedAt
            )
        }
    }

    private static func output(
        text: String = "",
        status: String,
        errorDescription: String? = nil,
        startedAt: ContinuousClock.Instant
    ) -> Output {
        let duration = startedAt.duration(to: .now).components
        let elapsed = Double(duration.seconds)
            + Double(duration.attoseconds) / 1_000_000_000_000_000_000
        return Output(
            text: text,
            status: status,
            errorDescription: errorDescription,
            elapsedSeconds: max(0, elapsed)
        )
    }
}

@available(macOS 26.0, *)
private final class ShadowAudioConverter {
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) throws {
        self.outputFormat = outputFormat
        if Self.formatsMatch(AudioCaptureEngine.targetFormat, outputFormat) {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(
                from: AudioCaptureEngine.targetFormat,
                to: outputFormat
            ) else {
                throw AppleASRError.recognizerUnavailable
            }
            self.converter = converter
        }
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard let converter else { return input }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }

        var conversionError: NSError?
        nonisolated(unsafe) var hasData = true
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return input
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        if let conversionError { throw conversionError }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }
}
