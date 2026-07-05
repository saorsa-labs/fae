import XCTest
@testable import Fae

final class FaeConfigStaticTests: XCTestCase {

    // MARK: - [voice] (S18 push-to-talk)

    func testVoiceConfigDefaults() {
        // Push-to-talk is THE capture model (S18 kill-list 3/3); nil hotkey
        // means Right Option.
        let config = FaeConfig()
        XCTAssertNil(config.voice.pttHotkeyKeyCode)
    }

    func testVoiceConfigParsesFromTOML() throws {
        // The retired pushToTalkOnly key must be silently ignored, not fatal.
        let toml = """
        [voice]
        pushToTalkOnly = true
        pttHotkeyKeyCode = 96
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s18-voice-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = FaeConfig.load(from: url)
        XCTAssertEqual(config.voice.pttHotkeyKeyCode, 96)
    }

    // MARK: - migrateToolMode

    func testMigrateToolMode() {
        let migrated = FaeConfig.migrateToolMode("read_only")
        XCTAssertFalse(migrated.isEmpty)
    }

    // MARK: - recommendedMaxHistory

    func testRecommendedMaxHistoryLargeContext() {
        // Exact values under the P-H2 8K system budget.
        // 131072: (131072 - 8000 - 8192) / 400 = 287 → clamped to the 100 ceiling.
        XCTAssertEqual(
            FaeConfig.recommendedMaxHistory(contextSize: 131072, maxTokens: 8192), 100)
        // 32K (≥32GB tier): (32768 - 8000 - 4096) / 400 = 51 — real history headroom
        // (was 26 under the stale 18K budget).
        XCTAssertEqual(
            FaeConfig.recommendedMaxHistory(contextSize: 32768, maxTokens: 4096), 51)
    }

    func testRecommendedMaxHistoryMidContext() {
        // P-H2 regression: the 16GB tier (16K daemon context) previously clamped to
        // the 6-message floor because the 18K system budget exceeded the whole window.
        // With the corrected 8K budget a 16K machine gets meaningful history back.
        // (16384 - 8000 - 4096) / 400 = 10 with the production-default 4096 maxTokens.
        XCTAssertEqual(
            FaeConfig.recommendedMaxHistory(contextSize: 16384, maxTokens: 4096), 10)
        // (16384 - 8000 - 2048) / 400 = 15 with a leaner 2048 generation budget.
        XCTAssertEqual(
            FaeConfig.recommendedMaxHistory(contextSize: 16384, maxTokens: 2048), 15)
    }

    func testRecommendedMaxHistorySmallContext() {
        // 8K window still floors at 6: (8192 - 8000 - 4096) is negative → clamp to 6.
        XCTAssertEqual(
            FaeConfig.recommendedMaxHistory(contextSize: 8192, maxTokens: 4096), 6)
        // 4K window also floors at 6.
        XCTAssertEqual(
            FaeConfig.recommendedMaxHistory(contextSize: 4096, maxTokens: 2048), 6)
    }

    // MARK: - isMultimodalLLM

    func testIsMultimodalLLMQwen35() {
        XCTAssertTrue(FaeConfig.isMultimodalLLM(modelId: "Qwen3.5-35B-A3B"))
    }

    func testIsMultimodalLLMQwen3() {
        XCTAssertFalse(FaeConfig.isMultimodalLLM(modelId: "Qwen3-4B"))
    }

    func testIsMultimodalLLMMistral() {
        XCTAssertFalse(FaeConfig.isMultimodalLLM(modelId: "mistral-7b"))
    }

    // MARK: - recommendedPrefillStepSize

    func testRecommendedPrefillStepSize4B() {
        let size = FaeConfig.recommendedPrefillStepSize(modelId: "Qwen3-4B")
        XCTAssertEqual(size, 768)
    }

    func testRecommendedPrefillStepSizeSmall() {
        let size = FaeConfig.recommendedPrefillStepSize(modelId: "tiny-model")
        XCTAssertEqual(size, 1024)
    }

    // MARK: - canonicalVoiceModelPreset

    func testCanonicalVoiceModelPreset() {
        let preset = FaeConfig.canonicalVoiceModelPreset("auto")
        XCTAssertFalse(preset.isEmpty)
    }

    // MARK: - daemonModelId RAM tiering
    //
    // Why this matters: the daemon LLM lane is the default conversation path.
    // TEMPORARY (2026-06-15): the ≥32 GB → 12B tier is DEFERRED — `auto` resolves
    // to E4B on ALL machines. E4B is the verified-clean, fast model (the Gemma-4
    // Metal NaN fix, candle PR #3625, is confirmed on E4B); 12B's exact-payload
    // NaN verification + the prompt-budget trim are still pending (see
    // project_daemon_metal_nan_fix). Explicit `gemma_4_12b` still forces 12B.
    // Restore the ≥32 GB → 12B assertion when the tier is re-enabled.

    func testDaemonModelIdAutoUsesE4BEverywhereForNow() {
        // 12B tier deferred: `auto` must stay on E4B even at high RAM.
        let id = FaeConfig.daemonModelId(
            preset: "auto",
            totalMemoryBytes: 128 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(id, "google/gemma-4-E4B-it")
    }

    func testDaemonModelIdAutoStaysOnE4BBelow32GB() {
        let id = FaeConfig.daemonModelId(
            preset: "auto",
            totalMemoryBytes: 24 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(id, "google/gemma-4-E4B-it")
    }

    func testDaemonModelIdExplicit12BIgnoresRAM() {
        // Explicit selection must honour the user's choice regardless of RAM.
        let id = FaeConfig.daemonModelId(
            preset: "gemma_4_12b",
            totalMemoryBytes: 8 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(id, "google/gemma-4-12B-it")
    }

    // MARK: - recommendedTrainingTarget

    func testRecommendedTrainingTarget() {
        let target = FaeConfig.recommendedTrainingTarget()
        XCTAssertFalse(target.isEmpty)
    }

    // MARK: - trainingPresetParameters

    func testTrainingPresetParameters() {
        let params = FaeConfig.trainingPresetParameters("default")
        XCTAssertFalse(params.isEmpty)
    }

    // MARK: - recommendedVLMModel

    func testRecommendedVLMModelWithMemory() {
        // 64GB of RAM
        let result = FaeConfig.recommendedVLMModel(totalMemoryBytes: 64 * 1024 * 1024 * 1024, preset: "auto")
        XCTAssertNotNil(result)
    }

    func testRecommendedVLMModelLowMemory() {
        // 8GB of RAM — may return nil
        let result = FaeConfig.recommendedVLMModel(totalMemoryBytes: 8 * 1024 * 1024 * 1024, preset: "auto")
        // Could be nil or a small model depending on implementation
    }

    func testRecommendedVLMModelPreset() {
        let result = FaeConfig.recommendedVLMModel(
            totalMemoryBytes: 64 * 1024 * 1024 * 1024,
            preset: "qwen3_vl_4b_8bit"
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.modelId.contains("Qwen3-VL"))
    }

    // MARK: - recommendedFastVLMModel

    func testRecommendedFastVLMModel() {
        let result = FaeConfig.recommendedFastVLMModel(totalMemoryBytes: 64 * 1024 * 1024 * 1024)
        XCTAssertNotNil(result)
    }

    // recommendedSTTModel removed (S18 kill-list 3/3) — ASR happens inside
    // the LLM turn.

    // MARK: - recommendedTTSModel

    func testRecommendedTTSModel() {
        let result = FaeConfig.recommendedTTSModel(totalMemoryBytes: 32 * 1024 * 1024 * 1024)
        XCTAssertNotNil(result)
    }


}
