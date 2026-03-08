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

    func testCredentialManagerListsKeysByPrefix() throws {
        let key = "tests.runtime.\(UUID().uuidString)"
        let original = CredentialManager.retrieve(key: key)

        defer {
            if let original {
                try? CredentialManager.store(key: key, value: original)
            } else {
                CredentialManager.delete(key: key)
            }
        }

        try CredentialManager.store(key: key, value: "temporary-secret")

        let keys = CredentialManager.listKeys(prefix: "tests.runtime.")
        XCTAssertTrue(keys.contains(key))
    }

    @MainActor
    func testFaeCorePersistsRemoteProviderDefaults() async throws {
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
            payload: ["key": "llm.remote_provider_preset", "value": "openrouter"]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "llm.remote_base_url", "value": "https://openrouter.ai/api"]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        core.sendCommand(
            name: "config.patch",
            payload: ["key": "llm.remote_model", "value": "anthropic/claude-sonnet-4"]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertEqual(reloaded.llm.remoteProviderPreset, "openrouter")
        XCTAssertEqual(reloaded.llm.remoteBaseURL, "https://openrouter.ai/api")
        XCTAssertEqual(reloaded.llm.remoteModel, "anthropic/claude-sonnet-4")
    }

    @MainActor
    func testFaeCorePersistsThinkingLevelPatchAndConfigGet() async throws {
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
            payload: ["key": "llm.thinking_level", "value": "deep"]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertEqual(reloaded.llm.resolvedThinkingLevel, .deep)
        XCTAssertTrue(reloaded.llm.thinkingEnabled)

        let response = await core.queryCommand(name: "config.get", payload: ["key": "llm"])
        let payload = response?["payload"] as? [String: Any]
        let llm = payload?["llm"] as? [String: Any]
        XCTAssertEqual(llm?["thinking_level"] as? String, "deep")
        XCTAssertEqual(llm?["thinking_enabled"] as? Bool, true)
    }

    @MainActor
    func testFaeCoreSetThinkingMethodsKeepPublishedStateAndConfigInSync() async throws {
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

        core.setThinkingLevel(.deep)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(core.thinkingLevel, .deep)
        XCTAssertTrue(core.thinkingEnabled)

        core.setThinkingEnabled(false)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(core.thinkingLevel, .fast)
        XCTAssertFalse(core.thinkingEnabled)

        core.cycleThinkingLevel()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(core.thinkingLevel, .balanced)
        XCTAssertTrue(core.thinkingEnabled)

        let reloaded = FaeConfig.load()
        XCTAssertEqual(reloaded.llm.resolvedThinkingLevel, .balanced)
        XCTAssertTrue(reloaded.llm.thinkingEnabled)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "thinkingLevel"), FaeThinkingLevel.balanced.rawValue)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "thinkingEnabled") as? Bool, true)
    }

    @MainActor
    func testFaeCorePersistsPrivacyModePatch() async throws {
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
            payload: ["key": "privacy.mode", "value": "strict_local"]
        )
        try await Task.sleep(nanoseconds: 120_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertEqual(reloaded.privacy.mode, "strict_local")

        let response = await core.queryCommand(name: "config.get", payload: ["key": "privacy"])
        let payload = response?["payload"] as? [String: Any]
        let privacy = payload?["privacy"] as? [String: Any]
        XCTAssertEqual(privacy?["mode"] as? String, "strict_local")
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
            payload: ["key": "awareness.consent_granted", "value": true]
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

    func testThinkingLevelControlsRemainWiredAcrossMainAndCoworkSurfaces() throws {
        let settingsModels = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/SettingsModelsTab.swift")
        let settingsPerformance = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/SettingsModelsPerformanceTab.swift")
        let inputBar = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/InputBarView.swift")
        let coworkView = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceView.swift")

        XCTAssertTrue(settingsModels.contains("Picker(\"Thinking level\""))
        XCTAssertTrue(settingsModels.contains("payload: [\"key\": \"llm.thinking_level\""))
        XCTAssertTrue(settingsPerformance.contains("Picker(\"Thinking level\""))
        XCTAssertTrue(settingsPerformance.contains("patchConfig(\"llm.thinking_level\""))
        XCTAssertTrue(inputBar.contains("faeCore.setThinkingLevel(level)"))
        XCTAssertTrue(inputBar.contains("Text(faeCore.thinkingLevel.displayName)"))
        XCTAssertTrue(coworkView.contains("controller.setThinkingLevel(level)"))
        XCTAssertTrue(coworkView.contains("conversationControlPill(icon: faeCore.thinkingLevel.systemImage, title: faeCore.thinkingLevel.displayName)"))
    }

    func testMainInputKeepsTypingAvailableWhileListening() throws {
        let inputBar = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/InputBarView.swift")
        let coworkGuide = try loadRepositoryText(relativePath: "docs/guides/work-with-fae.md")

        XCTAssertTrue(inputBar.contains("let shouldRestoreFocus = isTextFieldFocused || !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
        XCTAssertTrue(inputBar.contains("isTextFieldFocused = true"))
        XCTAssertTrue(inputBar.contains("Voice capture and typing can stay active at the same time."))
        XCTAssertTrue(inputBar.contains("Type a message for Fae while listening stays on"))
        XCTAssertTrue(coworkGuide.contains("voice capture should not turn typing into a separate mode"))
    }

    func testOnboardingBannerUsesNativeEnrollmentFlow() throws {
        let contentView = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/ContentView.swift")

        XCTAssertTrue(contentView.contains("SpeakerEnrollmentView("))
        XCTAssertTrue(contentView.contains("beginNativeEnrollment()"))
        XCTAssertTrue(contentView.contains("restoreConversationAfterNativeEnrollment()"))
        XCTAssertTrue(contentView.contains("onboarding.isComplete = true"))
        XCTAssertTrue(contentView.contains("onboarding.isComplete || faeCore.hasOwnerSetUp"))
        XCTAssertFalse(contentView.contains("faeCore.injectText(\"Hi Fae, I'm ready to introduce myself.\")"))
    }

    @MainActor
    func testFaeCoreCompleteNativeOwnerEnrollmentPersistsUserName() async throws {
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
        core.completeNativeOwnerEnrollment(displayName: "David")
        try await Task.sleep(nanoseconds: 150_000_000)

        let reloaded = FaeConfig.load()
        XCTAssertEqual(reloaded.userName, "David")
    }

    @MainActor
    func testPipelineAuxBridgeTracksLocalModelStackDiagnostics() {
        let controller = PipelineAuxBridgeController()

        controller.localStack = .init()
        NotificationCenter.default.post(
            name: .faePipelineState,
            object: nil,
            userInfo: [
                "event": "pipeline.local_stack_status",
                "payload": [
                    "operator_loaded": true,
                    "concierge_loaded": false,
                    "dual_model_active": false,
                    "current_route": "operator",
                    "fallback_reason": "concierge_load_failed",
                    "operator_runtime": "worker_process",
                    "concierge_runtime": "worker_process",
                ] as [String: Any],
            ]
        )

        let expectation = expectation(description: "pipeline aux update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(controller.localStack.operatorLoaded)
        XCTAssertFalse(controller.localStack.conciergeLoaded)
        XCTAssertEqual(controller.localStack.currentRoute, "operator")
        XCTAssertEqual(controller.localStack.fallbackReason, "concierge_load_failed")
        XCTAssertEqual(controller.localStack.operatorRuntime, "worker_process")
    }

    private func loadRepositoryText(relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
