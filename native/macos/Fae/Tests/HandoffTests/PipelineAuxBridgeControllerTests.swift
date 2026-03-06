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
}
