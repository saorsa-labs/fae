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
        XCTAssertEqual(config.llm.voiceModelPreset, "auto")
        XCTAssertTrue(config.memory.enabled)
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

        original.audio.inputSampleRate = 22_050
        original.audio.bufferSize = 256

        original.vad.threshold = 0.0125
        original.vad.maxSpeechDurationMs = 12_000

        original.llm.maxTokens = 1024
        original.llm.enableVision = true
        original.llm.voiceModelPreset = "qwen3_4b"

        original.tts.voice = "custom"
        original.tts.speed = 0.95
        original.tts.referenceText = "hello world"

        original.stt.modelId = "mlx-community/Qwen3-ASR-0.6B-4bit"

        original.conversation.wakeWord = "hey fae"
        original.conversation.requireDirectAddress = true
        original.conversation.sleepPhrases = ["sleep now", "good night"]

        original.bargeIn.enabled = false
        original.bargeIn.minRms = 0.12

        original.memory.maxRecallResults = 11

        try original.save(to: fileURL)

        let loaded = FaeConfig.load(from: fileURL)

        XCTAssertEqual(loaded.userName, "Ada")

        XCTAssertEqual(loaded.audio.inputSampleRate, 22_050)
        XCTAssertEqual(loaded.audio.bufferSize, 256)

        XCTAssertEqual(loaded.vad.threshold, 0.0125, accuracy: 0.0001)
        XCTAssertEqual(loaded.vad.maxSpeechDurationMs, 12_000)

        XCTAssertEqual(loaded.llm.maxTokens, 1024)
        XCTAssertTrue(loaded.llm.enableVision)
        XCTAssertEqual(loaded.llm.voiceModelPreset, "qwen3_4b")

        XCTAssertEqual(loaded.tts.voice, "custom")
        XCTAssertEqual(loaded.tts.speed, 0.95, accuracy: 0.0001)
        XCTAssertEqual(loaded.tts.referenceText, "hello world")

        XCTAssertEqual(loaded.stt.modelId, "mlx-community/Qwen3-ASR-0.6B-4bit")

        XCTAssertEqual(loaded.conversation.wakeWord, "hey fae")
        XCTAssertTrue(loaded.conversation.requireDirectAddress)
        XCTAssertEqual(loaded.conversation.sleepPhrases, ["sleep now", "good night"])

        XCTAssertFalse(loaded.bargeIn.enabled)
        XCTAssertEqual(loaded.bargeIn.minRms, 0.12, accuracy: 0.0001)

        XCTAssertEqual(loaded.memory.maxRecallResults, 11)
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
}
