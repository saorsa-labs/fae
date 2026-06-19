import XCTest
@testable import Fae

@MainActor
final class ConversationBridgeTests: XCTestCase {

    // MARK: - extractLLMLabel

    func testExtractLLMLabelStandard() {
        let label = ConversationEventBridgeController.extractLLMLabel(
            from: "LLM (unsloth/Qwen3-8B-GGUF / Qwen3-8B-Q4_K_M.gguf)"
        )
        XCTAssertEqual(label, "Qwen3 8B · Q4_K_M")
    }

    func testExtractLLMLabelShortFormat() {
        let label = ConversationEventBridgeController.extractLLMLabel(
            from: "LLM (model/Qwen3-4B-Q4.gguf)"
        )
        XCTAssertEqual(label, "Qwen3 4B · Q4")
    }

    func testExtractLLMLabelNotLLM() {
        let label = ConversationEventBridgeController.extractLLMLabel(from: "not an LLM string")
        XCTAssertNil(label)
    }

    func testExtractLLMLabelTwoParts() {
        let label = ConversationEventBridgeController.extractLLMLabel(
            from: "LLM (model/Qwen3-4B.gguf)"
        )
        // Only 2 parts → returns basename as-is
        XCTAssertNotNil(label)
    }

    // MARK: - friendlyModelLabel

    func testFriendlyModelLabelMLX() {
        let label = ConversationEventBridgeController.friendlyModelLabel(from: "mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(label, "Qwen3 4B · 4bit")
    }

    func testFriendlyModelLabelSimple() {
        let label = ConversationEventBridgeController.friendlyModelLabel(from: "some-model")
        XCTAssertEqual(label, "some-model")
    }

    func testFriendlyModelLabelLongParts() {
        let label = ConversationEventBridgeController.friendlyModelLabel(from: "org/Qwen3-8B-GGUF-Q4_K_M")
        XCTAssertEqual(label, "Qwen3 8B · GGUF-Q4_K_M")
    }

    // MARK: - friendlyLoadingLabel

    func testFriendlyLoadingLabelSTT() {
        let (label, _) = ConversationEventBridgeController.friendlyLoadingLabel(model: "parakeet-stt")
        XCTAssertTrue(label.contains("ears"))
        XCTAssertTrue(label.contains("listen"))
    }

    func testFriendlyLoadingLabelLLM() {
        let (label, _) = ConversationEventBridgeController.friendlyLoadingLabel(model: "qwen3-4b")
        XCTAssertTrue(label.contains("brain"))
        XCTAssertTrue(label.contains("think"))
    }

    func testFriendlyLoadingLabelTTS() {
        let (label, _) = ConversationEventBridgeController.friendlyLoadingLabel(model: "kokoro-tts")
        XCTAssertTrue(label.contains("voice"))
        XCTAssertTrue(label.contains("speak"))
    }

    func testFriendlyLoadingLabelUnknown() {
        let (label, _) = ConversationEventBridgeController.friendlyLoadingLabel(model: "custom-model")
        XCTAssertTrue(label.contains("custom-model"))
    }

    // MARK: - friendlyLoadCompleteLabel

    func testFriendlyLoadCompleteSTT() {
        let label = ConversationEventBridgeController.friendlyLoadCompleteLabel(model: "parakeet")
        XCTAssertTrue(label.contains("Ears ready"))
    }

    func testFriendlyLoadCompleteLLM() {
        let label = ConversationEventBridgeController.friendlyLoadCompleteLabel(model: "qwen3-4b")
        XCTAssertTrue(label.contains("Brain ready"))
    }

    func testFriendlyLoadCompleteTTS() {
        let label = ConversationEventBridgeController.friendlyLoadCompleteLabel(model: "kokoro")
        XCTAssertTrue(label.contains("Voice ready"))
    }

    func testFriendlyLoadCompleteUnknown() {
        let label = ConversationEventBridgeController.friendlyLoadCompleteLabel(model: "custom-model")
        XCTAssertTrue(label.contains("Loaded custom-model"))
    }

    // MARK: - friendlyDownloadLabel

    func testFriendlyDownloadLabelSTT() {
        let label = ConversationEventBridgeController.friendlyDownloadLabel(repoId: "org/parakeet-stt")
        XCTAssertTrue(label.contains("speech recognition"))
    }

    func testFriendlyDownloadLabelLLM() {
        let label = ConversationEventBridgeController.friendlyDownloadLabel(repoId: "unsloth/Qwen3-8B")
        XCTAssertTrue(label.contains("brain"))
    }

    func testFriendlyDownloadLabelTTS() {
        let label = ConversationEventBridgeController.friendlyDownloadLabel(repoId: "org/kokoro-tts")
        XCTAssertTrue(label.contains("voice"))
    }

    func testFriendlyDownloadLabelUnknown() {
        let label = ConversationEventBridgeController.friendlyDownloadLabel(repoId: "org/some-model")
        XCTAssertTrue(label.contains("some-model"))
    }
}
