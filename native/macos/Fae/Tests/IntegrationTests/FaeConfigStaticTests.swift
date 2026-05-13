import XCTest
@testable import Fae

final class FaeConfigStaticTests: XCTestCase {

    // MARK: - migrateToolMode

    func testMigrateToolMode() {
        let migrated = FaeConfig.migrateToolMode("read_only")
        XCTAssertFalse(migrated.isEmpty)
    }

    // MARK: - recommendedMaxHistory

    func testRecommendedMaxHistoryLargeContext() {
        let maxHist = FaeConfig.recommendedMaxHistory(contextSize: 131072, maxTokens: 8192)
        XCTAssertGreaterThanOrEqual(maxHist, 6)
        XCTAssertLessThanOrEqual(maxHist, 100)
    }

    func testRecommendedMaxHistorySmallContext() {
        let maxHist = FaeConfig.recommendedMaxHistory(contextSize: 4096, maxTokens: 2048)
        XCTAssertEqual(maxHist, 6) // minimum
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

    // MARK: - recommendedSTTModel

    func testRecommendedSTTModel() {
        let result = FaeConfig.recommendedSTTModel(totalMemoryBytes: 32 * 1024 * 1024 * 1024, llmPreset: "auto")
        XCTAssertNotNil(result)
    }

    // MARK: - recommendedTTSModel

    func testRecommendedTTSModel() {
        let result = FaeConfig.recommendedTTSModel(totalMemoryBytes: 32 * 1024 * 1024 * 1024)
        XCTAssertNotNil(result)
    }


}
