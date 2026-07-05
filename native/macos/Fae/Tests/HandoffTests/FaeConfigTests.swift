import Foundation
import XCTest
@testable import Fae

final class FaeConfigTests: XCTestCase {

    func testLoadFromMissingFileReturnsDefaults() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let config = FaeConfig.load(from: fileURL)

        XCTAssertNil(config.userName)
        XCTAssertEqual(config.audio.inputSampleRate, 16_000)
        XCTAssertFalse(config.startupIntroSeen)
        XCTAssertFalse(config.startupIntroSeenConfigured)
        XCTAssertEqual(config.llm.voiceModelPreset, "auto")
        XCTAssertEqual(config.llm.remoteProviderPreset, "openrouter")
        XCTAssertEqual(config.llm.remoteBaseURL, "https://openrouter.ai/api")
        XCTAssertEqual(config.llm.remoteModel, "openai/gpt-4.1-mini")
        XCTAssertEqual(config.llm.resolvedThinkingLevel, .fast)
        XCTAssertTrue(config.memory.enabled)
        XCTAssertTrue(config.memory.autoIngestInbox)
        XCTAssertTrue(config.memory.generateDigests)
        XCTAssertTrue(config.vision.enabled)
        XCTAssertTrue(config.awareness.enabled)
        XCTAssertNil(config.awareness.consentGrantedAt)
        XCTAssertEqual(config.privacy.mode, "local_preferred")
    }

    func testConversationDefaultsRequireWakeAfterIdle() {
        let config = FaeConfig()

        XCTAssertTrue(config.conversation.requireDirectAddress)
        XCTAssertEqual(config.conversation.idleTimeoutS, 45)
        XCTAssertEqual(config.conversation.directAddressFollowupS, 30)
    }

    func testLoadFromInvalidContentReturnsDefaultsWithoutThrowing() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let invalid = """
        userName = "ok"
        onboarded = maybe
        [audio
        inputSampleRate == nope
        [llm]
        temperature = not-a-float
        """
        try invalid.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)

        XCTAssertNil(config.userName)
        XCTAssertEqual(config.audio.inputSampleRate, 16_000)
        XCTAssertEqual(config.llm.temperature, 0.7, accuracy: 0.0001)
        XCTAssertEqual(config.conversation.sleepPhrases.count, 9)
    }

    func testSaveLoadRoundTripWithNestedOverrides() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        var original = FaeConfig()
        original.userName = "Ada"
        original.startupIntroSeen = true
        original.startupIntroSeenConfigured = true

        original.audio.inputSampleRate = 22_050
        original.audio.bufferSize = 256

        original.vad.threshold = 0.0125
        original.vad.maxSpeechDurationMs = 12_000

        original.llm.maxTokens = 1024
        original.llm.enableVision = true
        original.llm.voiceModelPreset = "qwen3_4b"
        original.llm.remoteProviderPreset = "openrouter"
        original.llm.remoteBaseURL = "https://openrouter.ai/api"
        original.llm.remoteModel = "anthropic/claude-sonnet-4"
        original.llm.thinkingLevel = FaeThinkingLevel.deep.rawValue
        original.llm.thinkingEnabled = true

        original.tts.voice = "custom"
        original.tts.speed = 0.95
        original.tts.referenceText = "hello world"

        original.conversation.wakeWord = "hey fae"
        original.conversation.requireDirectAddress = true
        original.conversation.sleepPhrases = ["sleep now", "good night"]

        original.bargeIn.minRms = 0.12

        original.memory.maxRecallResults = 11
        original.memory.autoIngestInbox = false
        original.memory.generateDigests = false
        original.privacy.mode = "strict_local"

        try original.save(to: fileURL)

        let loaded = FaeConfig.load(from: fileURL)

        XCTAssertEqual(loaded.userName, "Ada")
        XCTAssertTrue(loaded.startupIntroSeen)
        XCTAssertTrue(loaded.startupIntroSeenConfigured)

        XCTAssertEqual(loaded.audio.inputSampleRate, 22_050)
        XCTAssertEqual(loaded.audio.bufferSize, 256)

        XCTAssertEqual(loaded.vad.threshold, 0.0125, accuracy: 0.0001)
        XCTAssertEqual(loaded.vad.maxSpeechDurationMs, 12_000)

        XCTAssertEqual(loaded.llm.maxTokens, 1024)
        XCTAssertTrue(loaded.llm.enableVision)
        XCTAssertEqual(loaded.llm.voiceModelPreset, "qwen3_4b")
        XCTAssertEqual(loaded.llm.remoteProviderPreset, "openrouter")
        XCTAssertEqual(loaded.llm.remoteBaseURL, "https://openrouter.ai/api")
        XCTAssertEqual(loaded.llm.remoteModel, "anthropic/claude-sonnet-4")
        XCTAssertEqual(loaded.llm.resolvedThinkingLevel, .deep)

        XCTAssertEqual(loaded.tts.voice, "custom")
        XCTAssertEqual(loaded.tts.speed, 0.95, accuracy: 0.0001)
        XCTAssertEqual(loaded.tts.referenceText, "hello world")

        XCTAssertEqual(loaded.conversation.wakeWord, "hey fae")
        XCTAssertTrue(loaded.conversation.requireDirectAddress)
        XCTAssertEqual(loaded.conversation.sleepPhrases, ["sleep now", "good night"])

        XCTAssertEqual(loaded.bargeIn.minRms, 0.12, accuracy: 0.0001)

        XCTAssertEqual(loaded.memory.maxRecallResults, 11)
        XCTAssertFalse(loaded.memory.autoIngestInbox)
        XCTAssertFalse(loaded.memory.generateDigests)
        XCTAssertEqual(loaded.privacy.mode, "strict_local")
    }

    func testRecommendedVLMModelAcceptsCurrentPresetNames() {
        let preset4bit = FaeConfig.recommendedVLMModel(
            totalMemoryBytes: UInt64(24) * 1024 * 1024 * 1024,
            preset: "qwen3_vl_4b_4bit"
        )
        XCTAssertEqual(preset4bit?.modelId, "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit")

        let preset8bit = FaeConfig.recommendedVLMModel(
            totalMemoryBytes: UInt64(48) * 1024 * 1024 * 1024,
            preset: "qwen3_vl_4b_8bit"
        )
        XCTAssertEqual(preset8bit?.modelId, "mlx-community/Qwen3-VL-4B-Instruct-8bit")
    }

    func testLegacyModelPresetAliasesResolveToSaorsaWeights() {
        // Unknown legacy presets now fall back to auto mode
        let legacy27b = FaeConfig.recommendedModel(
            totalMemoryBytes: UInt64(64) * 1024 * 1024 * 1024,
            preset: "qwen3_5_27b"
        )
        // Falls back to auto → 9B Unsloth on 64 GB
        XCTAssertEqual(legacy27b.modelId, "Brooooooklyn/Qwen3.5-9B-unsloth-mlx")

        let legacyTiny = FaeConfig.recommendedModel(
            totalMemoryBytes: UInt64(8) * 1024 * 1024 * 1024,
            preset: "qwen3_5_0_8b"
        )
        // Falls back to auto → 4B uniform on 8 GB
        XCTAssertEqual(legacyTiny.modelId, "mlx-community/Qwen3.5-4B-4bit")

    }

    func testRecommendedEmbeddingTierPrefersLowerResidentMemory() {
        XCTAssertEqual(
            EmbeddingModelTier.recommendedTier(ramGB: 96, prefersLowResidentMemory: false),
            .medium
        )
        XCTAssertEqual(
            EmbeddingModelTier.recommendedTier(ramGB: 96, prefersLowResidentMemory: true),
            .small
        )
        XCTAssertEqual(
            EmbeddingModelTier.recommendedTier(ramGB: 8, prefersLowResidentMemory: true),
            .hash
        )
    }

    func testVisionModelPresetParsesSnakeCaseKey() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [vision]
        enabled = true
        model_preset = "qwen3_vl_4b_4bit"
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertTrue(config.vision.enabled)
        XCTAssertEqual(config.vision.modelPreset, "qwen3_vl_4b_4bit")
    }

    func testTTSVoiceIdentityLockParsesSnakeCaseKey() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [tts]
        voice_identity_lock = false
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertFalse(config.tts.voiceIdentityLock)
    }

    func testThinkingLevelFallsBackFromLegacyThinkingEnabledFlag() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [llm]
        thinkingEnabled = true
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertEqual(config.llm.resolvedThinkingLevel, .balanced)
        XCTAssertTrue(config.llm.thinkingEnabled)
    }

    func testExplicitThinkingLevelOverridesLegacyBooleanMirror() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [llm]
        thinkingEnabled = true
        thinkingLevel = "fast"
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertEqual(config.llm.resolvedThinkingLevel, .fast)
        XCTAssertFalse(config.llm.thinkingEnabled)
    }

    func testInvalidExplicitThinkingLevelFallsBackToLegacyBooleanAndNormalizes() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [llm]
        thinkingEnabled = true
        thinkingLevel = "turbo"
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertEqual(config.llm.resolvedThinkingLevel, .balanced)
        XCTAssertEqual(config.llm.thinkingLevel, FaeThinkingLevel.balanced.rawValue)
        XCTAssertTrue(config.llm.thinkingEnabled)
    }

    // MARK: - TTS Streaming Mode (Phase 1.1/1.2/1.3)

    func testTTSPreferFinalOnlyDefaultIsFalse() {
        // Sentence-streaming mode must be enabled by default.
        // Regression guard: do not accidentally flip back to batched-only.
        let config = FaeConfig()
        XCTAssertFalse(config.tts.preferFinalOnly,
                       "Streaming TTS must be ON by default (preferFinalOnly = false)")
    }

    func testTTSPreferFinalOnlyCanBeEnabledViaConfig() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [tts]
        prefer_final_only = true
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertTrue(config.tts.preferFinalOnly,
                      "Batched TTS must be configurable via prefer_final_only = true")
    }

    func testTTSPreferFinalOnlyFalseIsExplicitlyConfigurable() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [tts]
        prefer_final_only = false
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertFalse(config.tts.preferFinalOnly,
                       "Streaming TTS must remain on when explicitly set to false")
    }

    func testStartupIntroSeenParsesFromConfig() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        licenseAccepted = true
        startupIntroSeen = false
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertTrue(config.licenseAccepted)
        XCTAssertFalse(config.startupIntroSeen)
        XCTAssertTrue(config.startupIntroSeenConfigured)
    }

    // MARK: - UiConfig round-trip (W5 advanced menus)

    func testUiAdvancedMenusDefaultIsFalse() {
        let config = FaeConfig()
        XCTAssertFalse(config.ui.advancedMenus,
                       "advancedMenus must default false — non-experts must not see engineering menus")
    }

    func testUiAdvancedMenusRoundTripTrue() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [ui]
        advancedMenus = true
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertTrue(config.ui.advancedMenus,
                      "advancedMenus = true must parse and round-trip correctly")
    }

    func testUiAdvancedMenusSerializesAndReloads() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        var original = FaeConfig()
        original.ui.advancedMenus = true
        try original.save(to: fileURL)

        let reloaded = FaeConfig.load(from: fileURL)
        XCTAssertTrue(reloaded.ui.advancedMenus,
                      "ui.advancedMenus must survive a serialize → reload cycle")
    }

    // MARK: - Voice mute (tts.speakReplies)

    func testTTSSpeakRepliesDefaultIsTrue() {
        // Voice ON by default — muting is an opt-in, text-first preference.
        let config = FaeConfig()
        XCTAssertTrue(config.tts.speakReplies,
                      "speakReplies must default true so Fae speaks out of the box")
    }

    func testTTSSpeakRepliesParsesSnakeAndCamelCase() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let snakeURL = tempRoot.appendingPathComponent("snake.toml")
        try "[tts]\nspeak_replies = false\n".write(to: snakeURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(FaeConfig.load(from: snakeURL).tts.speakReplies,
                       "speak_replies = false (snake_case) must mute the voice")

        let camelURL = tempRoot.appendingPathComponent("camel.toml")
        try "[tts]\nspeakReplies = false\n".write(to: camelURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(FaeConfig.load(from: camelURL).tts.speakReplies,
                       "speakReplies = false (camelCase) must mute the voice")
    }

    func testTTSSpeakRepliesSerializesAndReloads() throws {
        // Round-trip the muted state: a text-first user's preference must
        // survive a serialize → reload cycle (like tts.speed / ui.advancedMenus).
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        var original = FaeConfig()
        original.tts.speakReplies = false
        try original.save(to: fileURL)

        let reloaded = FaeConfig.load(from: fileURL)
        XCTAssertFalse(reloaded.tts.speakReplies,
                       "tts.speakReplies must survive a serialize → reload cycle")
    }
}
