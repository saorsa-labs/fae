import XCTest
@testable import Fae

@MainActor
final class PipelineAuxBridgeControllerTests: XCTestCase {

    func testVoiceAttentionEventUpdatesDiagnosticsSnapshot() async throws {
        let controller = PipelineAuxBridgeController()

        NotificationCenter.default.post(
            name: .faePipelineState,
            object: nil,
            userInfo: [
                "event": "pipeline.voice_attention",
                "payload": [
                    "stage": "attention",
                    "decision": "wake",
                    "reason": "acoustic_wake",
                    "transcript": "what time is it",
                    "speaker_role": "owner",
                    "wake_source": "acoustic",
                    "wake_score": 0.91,
                    "semantic_state": "merged",
                    "rms": 0.12,
                ] as [String: Any],
            ]
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.voiceAttention.lastStage, "attention")
        XCTAssertEqual(controller.voiceAttention.lastDecision, "wake")
        XCTAssertEqual(controller.voiceAttention.lastReason, "acoustic_wake")
        XCTAssertEqual(controller.voiceAttention.lastTranscript, "what time is it")
        XCTAssertEqual(controller.voiceAttention.lastSpeakerRole, "owner")
        XCTAssertEqual(controller.voiceAttention.lastWakeSource, "acoustic")
        XCTAssertEqual(controller.voiceAttention.lastWakeScore ?? 0, 0.91, accuracy: 0.0001)
        XCTAssertEqual(controller.voiceAttention.lastSemanticState, "merged")
        XCTAssertEqual(controller.voiceAttention.recentEvents.count, 1)
    }

    func testStartupCanvasClearsWhenEnrollmentIsActive() async throws {
        let controller = PipelineAuxBridgeController()
        let canvas = CanvasController()
        let windows = AuxiliaryWindowManager()
        controller.canvasController = canvas
        controller.auxiliaryWindows = windows
        windows.canvasController = canvas

        NotificationCenter.default.post(
            name: .faeRuntimeProgress,
            object: nil,
            userInfo: ["stage": "stt"]
        )
        NotificationCenter.default.post(
            name: .faePipelineState,
            object: nil,
            userInfo: [
                "event": "pipeline.enrollment_started",
                "payload": [:] as [String: Any],
            ]
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        controller.finishStartupCanvasTransition()

        XCTAssertFalse(canvas.isActivityMode)
        XCTAssertEqual(canvas.htmlContent, "")
        XCTAssertFalse(canvas.isVisible)
    }

    func testStartupProgressDoesNotAutoOpenCanvasWindow() async throws {
        let controller = PipelineAuxBridgeController()
        let canvas = CanvasController()
        let windows = AuxiliaryWindowManager()
        controller.canvasController = canvas
        controller.auxiliaryWindows = windows
        windows.canvasController = canvas

        NotificationCenter.default.post(
            name: .faeRuntimeProgress,
            object: nil,
            userInfo: ["stage": "stt"]
        )

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(canvas.htmlContent, "")
        XCTAssertFalse(canvas.isVisible)
        XCTAssertFalse(windows.isCanvasVisible)
    }

    func testReadyProgressStageDoesNotMarkPipelineReady() async throws {
        let controller = PipelineAuxBridgeController()

        NotificationCenter.default.post(
            name: .faeRuntimeProgress,
            object: nil,
            userInfo: ["stage": "ready"]
        )
        try await flushNotifications()

        XCTAssertFalse(controller.isPipelineReady)
        XCTAssertEqual(controller.status, "Warming up Fae…")
    }

    func testThreeLoadCompleteEventsDoNotAutoReadyPipeline() async throws {
        let controller = PipelineAuxBridgeController()

        for model in ["stt", "llm", "tts"] {
            NotificationCenter.default.post(
                name: .faeRuntimeProgress,
                object: nil,
                userInfo: [
                    "stage": "load_complete",
                    "model_name": model,
                ]
            )
        }
        try await flushNotifications()

        XCTAssertFalse(controller.isPipelineReady)
        XCTAssertEqual(controller.status, "All core models loaded — verifying startup…")
    }

    func testMicStatusDoesNotAutoReadyPipeline() async throws {
        let controller = PipelineAuxBridgeController()

        NotificationCenter.default.post(
            name: .faePipelineState,
            object: nil,
            userInfo: [
                "event": "pipeline.mic_status",
                "payload": ["active": true] as [String: Any],
            ]
        )
        try await flushNotifications()

        XCTAssertFalse(controller.isPipelineReady)
        XCTAssertEqual(controller.status, "Mic: active")
    }

    func testRuntimeStartedMarksPipelineReady() async throws {
        let controller = PipelineAuxBridgeController()
        let subtitles = SubtitleStateController()
        controller.subtitleState = subtitles

        NotificationCenter.default.post(
            name: .faeRuntimeState,
            object: nil,
            userInfo: ["event": "runtime.started"]
        )
        try await flushNotifications()

        XCTAssertTrue(controller.isPipelineReady)
        XCTAssertEqual(controller.status, "Running")
    }

    private func flushNotifications() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}
