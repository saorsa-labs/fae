import Foundation
import XCTest
@testable import Fae

final class RuntimeContractTests: XCTestCase {

    func testRuntimeProgressBackendEventRoutedToTypedNotification() {
        let router = BackendEventRouter()
        _ = router

        let exp = expectation(description: "runtime progress routed")
        var capturedStage: String?
        var capturedProgress: Double?

        let obs = NotificationCenter.default.addObserver(
            forName: .faeRuntimeProgress,
            object: nil,
            queue: .main
        ) { note in
            capturedStage = note.userInfo?["stage"] as? String
            capturedProgress = note.userInfo?["progress"] as? Double
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        NotificationCenter.default.post(
            name: .faeBackendEvent,
            object: nil,
            userInfo: [
                "event": "runtime.progress",
                "payload": ["stage": "verify_started", "progress": 0.98],
            ]
        )

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(capturedStage, "verify_started")
        XCTAssertEqual(capturedProgress ?? -1, 0.98, accuracy: 0.000_001)
    }

    func testPipelineDegradedModeEventRoutedToPipelineState() {
        let router = BackendEventRouter()
        _ = router

        let exp = expectation(description: "degraded mode routed")
        var capturedEvent: String?
        var capturedMode: String?

        let obs = NotificationCenter.default.addObserver(
            forName: .faePipelineState,
            object: nil,
            queue: .main
        ) { note in
            capturedEvent = note.userInfo?["event"] as? String
            let payload = note.userInfo?["payload"] as? [String: Any]
            capturedMode = payload?["mode"] as? String
            if capturedEvent == "pipeline.degraded_mode" {
                exp.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        NotificationCenter.default.post(
            name: .faeBackendEvent,
            object: nil,
            userInfo: [
                "event": "pipeline.degraded_mode",
                "payload": ["mode": "noTTS"],
            ]
        )

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(capturedEvent, "pipeline.degraded_mode")
        XCTAssertEqual(capturedMode, "noTTS")
    }

    @MainActor
    func testFaeCorePersistsConfigMutationsForOnboardingAndModelPreset() async throws {
        let url = FaeConfig.configFileURL
        let fm = FileManager.default
        let original = try? Data(contentsOf: url)

        defer {
            if let original {
                try? original.write(to: url, options: .atomic)
            } else {
                try? fm.removeItem(at: url)
            }
        }

        let core = FaeCore()

        core.sendCommand(name: "onboarding.set_user_name", payload: ["name": "Aileen"])
        try await Task.sleep(nanoseconds: 150_000_000)

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "llm.voice_model_preset", "value": "qwen3_8b"]
        )
        try await Task.sleep(nanoseconds: 150_000_000)

        core.sendCommand(name: "onboarding.complete", payload: [:])
        try await Task.sleep(nanoseconds: 200_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertEqual(reloaded.userName, "Aileen")
        XCTAssertEqual(reloaded.llm.voiceModelPreset, "qwen3_8b")
        XCTAssertTrue(reloaded.onboarded)
    }
}
