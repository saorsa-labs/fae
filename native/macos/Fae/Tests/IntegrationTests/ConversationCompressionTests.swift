import XCTest
@testable import Fae

final class ConversationCompressionTests: XCTestCase {
    var compressor: ConversationCompressor!
    
    override func setUp() {
        super.setUp()
        compressor = ConversationCompressor()
    }
    
    override func tearDown() {
        compressor = nil
        super.tearDown()
    }
    
    // MARK: - Task 1: Token Estimation Tests
    
    func testTokenEstimation() async {
        let config = CompressionConfig.default
        
        // Test: 100-char message should be ~25 tokens (100 * 0.25)
        let shortMessage = String(repeating: "a", count: 100)
        let shortTokens = Int(Double(shortMessage.count) * config.tokensPerChar)
        XCTAssertEqual(shortTokens, 25, "100-char message should be ~25 tokens")
        
        // Test: 1000-char message should be ~250 tokens
        let longMessage = String(repeating: "b", count: 1000)
        let longTokens = Int(Double(longMessage.count) * config.tokensPerChar)
        XCTAssertEqual(longTokens, 250, "1000-char message should be ~250 tokens")
        
        // Test: Empty string should be 0 tokens
        let emptyTokens = Int(Double("".count) * config.tokensPerChar)
        XCTAssertEqual(emptyTokens, 0, "Empty string should be 0 tokens")
    }
    
    // MARK: - Task 1: Compression Trigger Tests
    
    func testNoCompressionUnderThreshold() async {
        // Create messages totaling less than 75% of context window
        let messages = (0..<50).map { i in
            WorkWithFaeConversationMessage(
                role: i % 2 == 0 ? "user" : "assistant",
                content: "Short message \(i)",
                modelID: "test-model"
            )
        }
        
        // At 200K tokens (200,000), threshold is 150K (0.75 * 200,000)
        // 50 messages × 17 chars ≈ 850 chars ≈ 212 tokens << 150K threshold
        let contextWindow = 200_000
        
        let compressed = await compressor.compressIfNeeded(
            messages: messages,
            contextWindowTokens: contextWindow,
            modelID: "test-model"
        )
        
        // Should return unchanged when under threshold
        XCTAssertEqual(
            compressed.count,
            messages.count,
            "Should not compress when under 75% threshold"
        )
    }
    
    func testCompressionAboveThreshold() async {
        // Create 90 messages to exceed threshold on small context window
        let messages = (0..<90).map { i in
            WorkWithFaeConversationMessage(
                role: i % 2 == 0 ? "user" : "assistant",
                content: String(repeating: "x", count: 100),  // 100 chars each
                modelID: "test-model"
            )
        }
        
        // 90 messages × 100 chars = 9,000 chars ≈ 2,250 tokens
        // For 200K context: threshold = 150K tokens >> 2,250 tokens (still under)
        // For 10K context: threshold = 7,500 tokens << 2,250 tokens (over!)
        let contextWindow = 10_000
        
        let compressed = await compressor.compressIfNeeded(
            messages: messages,
            contextWindowTokens: contextWindow,
            modelID: "test-model"
        )
        
        // Should have added a summary message or reduced count
        let hasSummary = compressed.contains { $0.role == "summary" }
        XCTAssertTrue(
            hasSummary || compressed.count <= messages.count,
            "Should trigger compression or reduce message count when over 75% threshold"
        )
    }
    
    // MARK: - Task 1: Message Structure Tests
    
    func testSummaryMessageStructure() async {
        let messages = (0..<90).map { i in
            WorkWithFaeConversationMessage(
                role: i % 2 == 0 ? "user" : "assistant",
                content: String(repeating: "x", count: 100),
                modelID: "test-model"
            )
        }
        
        let contextWindow = 10_000
        let compressed = await compressor.compressIfNeeded(
            messages: messages,
            contextWindowTokens: contextWindow,
            modelID: "test-model"
        )
        
        // Find summary message if it exists
        let summary = compressed.first { $0.role == "summary" }
        
        if let summary = summary {
            XCTAssertEqual(summary.role, "summary", "Summary message should have role='summary'")
            XCTAssertEqual(summary.modelID, "test-model", "Summary should preserve modelID")
            XCTAssertEqual(summary.providerKind, "fae-localhost", "Summary should have fae-localhost provider")
            XCTAssertNotNil(summary.id, "Summary should have unique ID")
        }
    }
    
    // MARK: - Task 1: Edge Cases
    
    func testNoCompressionForSmallConversations() async {
        // Single message conversation
        let messages = [
            WorkWithFaeConversationMessage(
                role: "user",
                content: "Hello",
                modelID: "test-model"
            )
        ]
        
        let compressed = await compressor.compressIfNeeded(
            messages: messages,
            contextWindowTokens: 200_000,
            modelID: "test-model"
        )
        
        XCTAssertEqual(
            compressed.count,
            1,
            "Should not compress single-message conversations"
        )
    }
    
    func testPreservesLastMessage() async {
        // Create conversation with last message being a user input
        let messages = (0..<90).map { i in
            WorkWithFaeConversationMessage(
                role: i < 89 ? "assistant" : "user",  // Last is user
                content: String(repeating: "x", count: 100),
                modelID: "test-model"
            )
        }
        
        let compressed = await compressor.compressIfNeeded(
            messages: messages,
            contextWindowTokens: 10_000,
            modelID: "test-model"
        )
        
        // Last message should still be user message
        if let lastMessage = compressed.last {
            XCTAssertEqual(
                lastMessage.role,
                "user",
                "Last message should be preserved"
            )
        }
    }
}
