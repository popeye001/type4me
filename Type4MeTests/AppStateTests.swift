import XCTest
@testable import Type4Me

@MainActor
final class AppStateTests: XCTestCase {

    func testStartRecordingTransitionsToPreparing() {
        let appState = AppState()
        appState.startRecording()

        XCTAssertEqual(appState.barPhase, .preparing)
    }

    func testStopRecordingIgnoredWhenNotRecording() {
        let appState = AppState()
        appState.currentMode = .smartDirect
        appState.cancel()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingCancelsWhenPreparing() {
        let appState = AppState()
        appState.startRecording()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingTransitionsToProcessingWhenRecording() {
        let appState = AppState()
        appState.currentMode = .smartDirect
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testStopRecordingTransitionsDirectModeToProcessing() {
        let appState = AppState()
        appState.currentMode = .direct
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testHiddenRecordingVisualDoesNotShowPanelUntilProcessing() {
        let previousStyle = UserDefaults.standard.string(forKey: RecordingVisualStyle.storageKey)
        UserDefaults.standard.set(RecordingVisualStyle.hidden.rawValue, forKey: RecordingVisualStyle.storageKey)
        defer {
            if let previousStyle {
                UserDefaults.standard.set(previousStyle, forKey: RecordingVisualStyle.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RecordingVisualStyle.storageKey)
            }
        }

        let appState = AppState()
        var showCount = 0
        var hideCount = 0
        appState.onShowPanel = { showCount += 1 }
        appState.onHidePanel = { hideCount += 1 }

        appState.startRecording()
        appState.markRecordingReady()

        XCTAssertEqual(appState.barPhase, .recording)
        XCTAssertEqual(showCount, 0)
        XCTAssertEqual(hideCount, 1)

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
        XCTAssertEqual(showCount, 1)
    }

    func testSetLiveTranscriptReplacesExistingConfirmedSegments() {
        let appState = AppState()
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖"],
                partialText: "",
                authoritativeText: "我想买咖",
                isFinal: false
            )
        )
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖啡"],
                partialText: "",
                authoritativeText: "我想买咖啡",
                isFinal: false
            )
        )

        XCTAssertEqual(appState.segments.map(\.text), ["我想", "买咖啡"])
        XCTAssertEqual(appState.transcriptionText, "我想买咖啡")
    }

    func testSetLiveTranscriptUsesAuthoritativeFinalTextWhenDifferent() {
        let appState = AppState()
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["deep seek"],
                partialText: "",
                authoritativeText: "DeepSeek",
                isFinal: true
            )
        )

        XCTAssertEqual(appState.segments.count, 1)
        XCTAssertEqual(appState.segments.first?.text, "DeepSeek")
        XCTAssertTrue(appState.segments.first?.isConfirmed == true)
    }

    func testSetLiveTranscriptDropsStalePartialUpdates() {
        let appState = AppState()
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["new"],
                partialText: "",
                authoritativeText: "new",
                isFinal: false
            )
        )

        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["old"],
                partialText: "",
                authoritativeText: "old",
                isFinal: false,
                emitTime: ContinuousClock.now - .seconds(1)
            )
        )

        XCTAssertEqual(appState.transcriptionText, "new")
    }

    func testFinalizeShowsClipboardFallbackMessage() {
        let appState = AppState()
        appState.barPhase = .processing

        appState.finalize(text: "测试文本", outcome: .copiedToClipboard)

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.feedbackMessage, InjectionOutcome.copiedToClipboard.completionMessage)
        XCTAssertEqual(appState.transcriptionText, "测试文本")
    }

    func testShowErrorDisplaysErrorPhaseAndMessage() {
        let appState = AppState()

        appState.showError("找不到麦克风")

        XCTAssertEqual(appState.barPhase, .error)
        XCTAssertEqual(appState.feedbackMessage, "找不到麦克风")
    }

    func testReconcileCurrentModeKeepsSupportedCustomModeForQuickOnlyProvider() {
        let appState = AppState()
        let customMode = ProcessingMode(
            id: UUID(),
            name: "结构化",
            prompt: "Rewrite {text}",
            isBuiltin: false
        )
        appState.availableModes.append(customMode)
        appState.currentMode = customMode

        appState.reconcileCurrentMode(for: .bailian)

        XCTAssertEqual(appState.currentMode.id, customMode.id)
    }
}
