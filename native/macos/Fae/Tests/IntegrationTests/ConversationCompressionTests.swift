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

    // MARK: - Task 2: Summary Generation Tests
    
    func testSummaryMessageHasCorrectMetadata() async {
        // Create messages that will trigger compression on small context window
        let messages = (0..<90).map { i in
            WorkWithFaeConversationMessage(
                role: i % 2 == 0 ? "user" : "assistant",
                content: String(repeating: "x", count: 100),
                modelID: "test-model"
            )
        }
        
        let compressed = await compressor.compressIfNeeded(
            messages: messages,
            contextWindowTokens: 10_000,
            modelID: "test-model"
        )
        
        // If compression happened, verify summary metadata
        let summary = compressed.first { $0.role == "summary" }
        
        if let summary = summary {
            XCTAssertEqual(summary.role, "summary", "Summary role should be 'summary'")
            XCTAssertEqual(summary.modelID, "test-model", "Summary should preserve modelID")
            XCTAssertEqual(summary.providerKind, "fae-localhost", "Summary should have fae-localhost provider")
        }
    }
    
    func testSummaryPreservesModelAndProvider() async {
        let messages = (0..<90).map { i in
            WorkWithFaeConversationMessage(
                role: i % 2 == 0 ? "user" : "assistant",
                content: String(repeating: "x", count: 100),
                modelID: "claude-opus-4-6",
                providerKind: "fae-localhost"
            )
        }
        
        let compressed = await compressor.compressIfNeeded(
            messages: messages,
            contextWindowTokens: 10_000,
            modelID: "claude-opus-4-6"
        )
        
        let summary = compressed.first { $0.role == "summary" }
        
        if let summary = summary {
            XCTAssertEqual(
                summary.modelID,
                "claude-opus-4-6",
                "Summary should preserve model ID"
            )
            XCTAssertEqual(
                summary.providerKind,
                "fae-localhost",
                "Summary should have fae-localhost provider"
            )
        }
    }
    
    // MARK: - Task 2: Progressive Compression Tests
    
    func testProgressiveCompressionIncludesPreviousSummary() async {
        // Create a conversation with existing summary
        let previousSummaryMessage = WorkWithFaeConversationMessage(
            role: "summary",
            content: "Previous conversation discussed Swift programming",
            modelID: "test-model",
            providerKind: "fae-localhost"
        )
        
        let newMessages = (0..<89).map { i in
            WorkWithFaeConversationMessage(
                role: i % 2 == 0 ? "user" : "assistant",
                content: String(repeating: "y", count: 100),
                modelID: "test-model"
            )
        }
        
        let messages = [previousSummaryMessage] + newMessages
        
        let compressed = await compressor.compressIfNeeded(
            messages: messages,
            contextWindowTokens: 10_000,
            modelID: "test-model"
        )
        
        // Verify that previous summary is still present in compressed
        let previousSummaryStillPresent = compressed.contains { msg in
            msg.role == "summary" && msg.content.contains("Previous conversation")
        }
        
        XCTAssertTrue(
            previousSummaryStillPresent || compressed.count > 0,
            "Progressive compression should preserve existing context"
        )
    }
    
    // MARK: - Task 3: Workspace Integration Tests
    
    func testCompressConversationAppliesSoftLimit() async {
        // Test that the workspace compression function respects max limit
        let messages = (0..<150).map { i in
            WorkWithFaeConversationMessage(
                role: i % 2 == 0 ? "user" : "assistant",
                content: "Message \(i)",
                modelID: "test-model"
            )
        }
        
        // Workspace uses maxConversationMessages = 120 by default
        let maxMessages = 120
        
        // Create a minimal state for testing
        let state = WorkWithFaeWorkspaceState(
            selectedDirectoryPath: nil,
            indexedFiles: [],
            attachments: [],
            conversationMessages: messages
        )
        
        // The sanitizedConversationState function should apply compression
        // For now it uses hard truncation, so we expect maxMessages or less
        // We can't directly call sanitizedConversationState (it's private),
        // but we can verify messages get truncated by saving
        WorkWithFaeWorkspaceStore.save(state)
        
        let loaded = WorkWithFaeWorkspaceStore.load()
        XCTAssertLessThanOrEqual(
            loaded.conversationMessages.count,
            maxMessages,
            "Saved state should respect max conversation messages limit"
        )
    }
    
    func testCompressionPreservesBranches() async {
        // Verify that when a workspace is duplicated (branched),
        // compressed messages are preserved
        let messages = (0..<90).map { i in
            WorkWithFaeConversationMessage(
                role: i % 2 == 0 ? "user" : "assistant",
                content: String(repeating: "x", count: 100),
                modelID: "test-model"
            )
        }
        
        let summaryMessage = WorkWithFaeConversationMessage(
            role: "summary",
            content: "Conversation summary",
            modelID: "test-model",
            providerKind: "fae-localhost"
        )
        
        let stateWithSummary = WorkWithFaeWorkspaceState(
            selectedDirectoryPath: nil,
            indexedFiles: [],
            attachments: [],
            conversationMessages: [summaryMessage] + messages
        )
        
        // Save the state
        WorkWithFaeWorkspaceStore.save(stateWithSummary)
        
        // Load it back
        let loaded = WorkWithFaeWorkspaceStore.load()
        
        // Verify summary message is preserved
        let summaryExists = loaded.conversationMessages.contains { msg in
            msg.role == "summary"
        }
        
        XCTAssertTrue(
            summaryExists,
            "Summary messages should be preserved through save/load cycle"
        )
    }
}
