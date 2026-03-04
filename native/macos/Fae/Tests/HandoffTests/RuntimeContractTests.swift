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

    @MainActor
    func testFaeCorePersistsMemoryPatchKeys() async throws {
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

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "memory.enabled", "value": false]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "memory.max_recall_results", "value": 12]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertFalse(reloaded.memory.enabled)
        XCTAssertEqual(reloaded.memory.maxRecallResults, 12)
    }

    @MainActor
    func testFaeCoreStoresChannelSecretsInKeychainWithConfigCompatibility() async throws {
        let url = FaeConfig.configFileURL
        let fm = FileManager.default
        let originalConfig = try? Data(contentsOf: url)

        let secretKey = "channels.discord.bot_token"
        let originalSecret = CredentialManager.retrieve(key: secretKey)

        defer {
            if let originalConfig {
                try? originalConfig.write(to: url, options: .atomic)
            } else {
                try? fm.removeItem(at: url)
            }

            if let originalSecret {
                try? CredentialManager.store(key: secretKey, value: originalSecret)
            } else {
                CredentialManager.delete(key: secretKey)
            }
        }

        let core = FaeCore()
        let newSecret = "discord-test-token-123"

        core.sendCommand(
            name: "config.patch",
            payload: ["key": secretKey, "value": newSecret]
        )
        try await Task.sleep(nanoseconds: 150_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertNil(reloaded.channels.discord.botToken)
        XCTAssertEqual(CredentialManager.retrieve(key: secretKey), newSecret)
    }

    @MainActor
    func testFaeCorePersistsVisionPatchKeysAndSupportsVisionConfigGet() async throws {
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

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "vision.enabled", "value": true]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "vision.model_preset", "value": "qwen3_vl_4b_4bit"]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertTrue(reloaded.vision.enabled)
        XCTAssertEqual(reloaded.vision.modelPreset, "qwen3_vl_4b_4bit")

        let response = await core.queryCommand(name: "config.get", payload: ["key": "vision"])
        let payload = response?["payload"] as? [String: Any]
        let vision = payload?["vision"] as? [String: Any]
        XCTAssertEqual(vision?["enabled"] as? Bool, true)
        XCTAssertEqual(vision?["model_preset"] as? String, "qwen3_vl_4b_4bit")
    }

    @MainActor
    func testFaeCorePersistsAwarenessPatchKeys() async throws {
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

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "awareness.enabled", "value": true]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "awareness.camera_enabled", "value": true]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "awareness.pause_on_battery", "value": false]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "awareness.pause_on_thermal_pressure", "value": false]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertTrue(reloaded.awareness.enabled)
        XCTAssertTrue(reloaded.awareness.cameraEnabled)
        XCTAssertFalse(reloaded.awareness.pauseOnBattery)
        XCTAssertFalse(reloaded.awareness.pauseOnThermalPressure)
        XCTAssertNotNil(reloaded.awareness.consentGrantedAt)
    }

    @MainActor
    func testFaeCorePersistsVoiceIdentityLockAndExposesTTSRuntimeFields() async throws {
        let url = FaeConfig.configFileURL
        let fm = FileManager.default
        let original = try? Data(contentsOf: url)

        let defaults = UserDefaults.standard
        let originalRuntimeSource = defaults.object(forKey: "fae.tts.runtime_voice_source")
        let originalRuntimeLockApplied = defaults.object(forKey: "fae.tts.runtime_voice_lock_applied")

        defer {
            if let original {
                try? original.write(to: url, options: .atomic)
            } else {
                try? fm.removeItem(at: url)
            }
            defaults.set(originalRuntimeSource, forKey: "fae.tts.runtime_voice_source")
            defaults.set(originalRuntimeLockApplied, forKey: "fae.tts.runtime_voice_lock_applied")
        }

        defaults.set("locked_bundled_fae_wav", forKey: "fae.tts.runtime_voice_source")
        defaults.set(true, forKey: "fae.tts.runtime_voice_lock_applied")

        let core = FaeCore()
        core.sendCommand(
            name: "config.patch",
            payload: ["key": "tts.voice_identity_lock", "value": false]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertFalse(reloaded.tts.voiceIdentityLock)

        let response = await core.queryCommand(name: "config.get", payload: ["key": "tts"])
        let payload = response?["payload"] as? [String: Any]
        let tts = payload?["tts"] as? [String: Any]
        XCTAssertEqual(tts?["voice_identity_lock"] as? Bool, false)
        XCTAssertEqual(tts?["runtime_voice_source"] as? String, "locked_bundled_fae_wav")
        XCTAssertEqual(tts?["runtime_voice_lock_applied"] as? Bool, true)
    }
}
