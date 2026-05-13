import XCTest
@testable import Fae

@MainActor
final class ConversationBridgeTests: XCTestCase {

    // MARK: - extractLLMLabel

    func testExtractLLMLabelStandard() {
        let label = ConversationBridgeController.extractLLMLabel(
            from: "LLM (unsloth/Qwen3-8B-GGUF / Qwen3-8B-Q4_K_M.gguf)"
        )
        XCTAssertEqual(label, "Qwen3 8B · Q4_K_M")
    }

    func testExtractLLMLabelShortFormat() {
        let label = ConversationBridgeController.extractLLMLabel(
            from: "LLM (model/Qwen3-4B-Q4.gguf)"
        )
        XCTAssertEqual(label, "Qwen3 4B · Q4")
    }

    func testExtractLLMLabelNotLLM() {
        let label = ConversationBridgeController.extractLLMLabel(from: "not an LLM string")
        XCTAssertNil(label)
    }

    func testExtractLLMLabelTwoParts() {
        let label = ConversationBridgeController.extractLLMLabel(
            from: "LLM (model/Qwen3-4B.gguf)"
        )
        // Only 2 parts → returns basename as-is
        XCTAssertNotNil(label)
    }

    // MARK: - friendlyModelLabel

    func testFriendlyModelLabelMLX() {
        let label = ConversationBridgeController.friendlyModelLabel(from: "mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(label, "Qwen3 4B · 4bit")
    }

    func testFriendlyModelLabelSimple() {
        let label = ConversationBridgeController.friendlyModelLabel(from: "some-model")
        XCTAssertEqual(label, "some-model")
    }

    func testFriendlyModelLabelLongParts() {
        let label = ConversationBridgeController.friendlyModelLabel(from: "org/Qwen3-8B-GGUF-Q4_K_M")
        XCTAssertEqual(label, "Qwen3 8B · GGUF-Q4_K_M")
    }

    // MARK: - friendlyLoadingLabel

    func testFriendlyLoadingLabelSTT() {
        let (label, _) = ConversationBridgeController.friendlyLoadingLabel(model: "parakeet-stt")
        XCTAssertTrue(label.contains("ears"))
        XCTAssertTrue(label.contains("listen"))
    }

    func testFriendlyLoadingLabelLLM() {
        let (label, _) = ConversationBridgeController.friendlyLoadingLabel(model: "qwen3-4b")
        XCTAssertTrue(label.contains("brain"))
        XCTAssertTrue(label.contains("think"))
    }

    func testFriendlyLoadingLabelTTS() {
        let (label, _) = ConversationBridgeController.friendlyLoadingLabel(model: "kokoro-tts")
        XCTAssertTrue(label.contains("voice"))
        XCTAssertTrue(label.contains("speak"))
    }

    func testFriendlyLoadingLabelUnknown() {
        let (label, _) = ConversationBridgeController.friendlyLoadingLabel(model: "custom-model")
        XCTAssertTrue(label.contains("custom-model"))
    }

    // MARK: - friendlyLoadCompleteLabel

    func testFriendlyLoadCompleteSTT() {
        let label = ConversationBridgeController.friendlyLoadCompleteLabel(model: "parakeet")
        XCTAssertTrue(label.contains("Ears ready"))
    }

    func testFriendlyLoadCompleteLLM() {
        let label = ConversationBridgeController.friendlyLoadCompleteLabel(model: "qwen3-4b")
        XCTAssertTrue(label.contains("Brain ready"))
    }

    func testFriendlyLoadCompleteTTS() {
        let label = ConversationBridgeController.friendlyLoadCompleteLabel(model: "kokoro")
        XCTAssertTrue(label.contains("Voice ready"))
    }

    func testFriendlyLoadCompleteUnknown() {
        let label = ConversationBridgeController.friendlyLoadCompleteLabel(model: "custom-model")
        XCTAssertTrue(label.contains("Loaded custom-model"))
    }

    // MARK: - friendlyDownloadLabel

    func testFriendlyDownloadLabelSTT() {
        let label = ConversationBridgeController.friendlyDownloadLabel(repoId: "org/parakeet-stt")
        XCTAssertTrue(label.contains("speech recognition"))
    }

    func testFriendlyDownloadLabelLLM() {
        let label = ConversationBridgeController.friendlyDownloadLabel(repoId: "unsloth/Qwen3-8B")
        XCTAssertTrue(label.contains("brain"))
    }

    func testFriendlyDownloadLabelTTS() {
        let label = ConversationBridgeController.friendlyDownloadLabel(repoId: "org/kokoro-tts")
        XCTAssertTrue(label.contains("voice"))
    }

    func testFriendlyDownloadLabelUnknown() {
        let label = ConversationBridgeController.friendlyDownloadLabel(repoId: "org/some-model")
        XCTAssertTrue(label.contains("some-model"))
    }
}
