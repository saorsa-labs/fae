import XCTest
@testable import Fae

final class TurnHelpersTests: XCTestCase {

    // MARK: - Memory Recall

    func testShouldRecallMemoryDuringEnrollment() {
        XCTAssertFalse(TurnHelpers.shouldRecallMemoryForTurn(
            firstOwnerEnrollmentActive: true, userText: "who am i", availableToolNames: []
        ))
    }

    func testShouldRecallMemoryNormalTurn() {
        XCTAssertTrue(TurnHelpers.shouldRecallMemoryForTurn(
            firstOwnerEnrollmentActive: false, userText: "what do you know about me", availableToolNames: []
        ))
    }

    func testMemoryTurnGuidanceInterestTopic() {
        let guidance = TurnHelpers.memoryTurnGuidance(for: "I'm really interested in machine learning")
        XCTAssertNotNil(guidance)
        XCTAssertTrue(guidance!.contains("machine learning"))
    }

    func testMemoryTurnGuidanceRememberPrefix() {
        let guidance = TurnHelpers.memoryTurnGuidance(for: "remember my name is Alice")
        XCTAssertNotNil(guidance)
        XCTAssertTrue(guidance!.contains("durable personal context"))
    }

    func testMemoryTurnGuidancePersonalRecall() {
        let guidance = TurnHelpers.memoryTurnGuidance(for: "what's my name")
        XCTAssertNotNil(guidance)
        XCTAssertTrue(guidance!.contains("Answer directly from memory"))
    }

    func testMemoryTurnGuidanceNoMatch() {
        let guidance = TurnHelpers.memoryTurnGuidance(for: "hello how are you today")
        XCTAssertNil(guidance)
    }

    func testMemoryTurnGuidanceFaePrefix() {
        let guidance = TurnHelpers.memoryTurnGuidance(for: "fae, remember I work at Google")
        XCTAssertNotNil(guidance)
    }

    func testCleanInterestTopic() {
        XCTAssertEqual(TurnHelpers.cleanInterestTopic("  Rust programming  "), "Rust programming")
        XCTAssertEqual(TurnHelpers.cleanInterestTopic("Hello!"), "Hello")
        XCTAssertNil(TurnHelpers.cleanInterestTopic(""))
        XCTAssertNil(TurnHelpers.cleanInterestTopic("   "))
    }

    // MARK: - Tool Visibility

    func testVisibleToolsDuringEnrollment() {
        let tools = TurnHelpers.visibleToolNamesForTurn(
            firstOwnerEnrollmentActive: true, userText: "anything", availableToolNames: ["read", "bash"],
            proactiveAllowedTools: nil
        )
        XCTAssertEqual(tools, ["voice_identity"])
    }

    func testVisibleToolsConversationContinuation() {
        let tools = TurnHelpers.visibleToolNamesForTurn(
            firstOwnerEnrollmentActive: false, userText: "api key is abc", availableToolNames: ["input_request"],
            proactiveAllowedTools: nil, isConversationContinuation: true
        )
        XCTAssertNil(tools) // continuation with no allowlist = all tools visible
    }

    func testVisibleToolsWithProactiveAllowlist() {
        let tools = TurnHelpers.visibleToolNamesForTurn(
            firstOwnerEnrollmentActive: false, userText: "search web", availableToolNames: ["web_search", "read"],
            proactiveAllowedTools: ["web_search", "fetch_url"]
        )
        XCTAssertNotNil(tools)
    }

    func testExplicitlyMentionedToolNames() {
        let tools = TurnHelpers.explicitlyMentionedToolNames(
            in: "please use web_search to look this up",
            availableToolNames: ["web_search", "read", "bash"]
        )
        XCTAssertTrue(tools.contains("web_search"))
    }

    func testExplicitlyMentionedAmbiguousTool() {
        // "read" is in ambiguousToolNames — should NOT match
        let tools = TurnHelpers.explicitlyMentionedToolNames(
            in: "please read this",
            availableToolNames: ["read"]
        )
        XCTAssertTrue(tools.isEmpty)
    }

    func testInferredToolNamesWebSearch() {
        let tools = TurnHelpers.inferredToolNamesForTurn(
            in: "search the web for latest news",
            availableToolNames: ["web_search", "fetch_url", "read"]
        )
        XCTAssertTrue(tools.contains("web_search"))
    }

    func testInferredToolNamesCalendar() {
        let tools = TurnHelpers.inferredToolNamesForTurn(
            in: "what meetings do I have tomorrow",
            availableToolNames: ["calendar", "reminders"]
        )
        XCTAssertTrue(tools.contains("calendar"))
        // Cross-inference: calendar → reminders
        XCTAssertTrue(tools.contains("reminders"))
    }

    func testInferredToolNamesScreen() {
        let tools = TurnHelpers.inferredToolNamesForTurn(
            in: "what's on my screen",
            availableToolNames: ["screenshot", "read_screen"]
        )
        XCTAssertTrue(tools.contains("screenshot"))
    }

    func testInferredToolNamesLongText() {
        let longText = String.init(repeating: "a", count: 250)
        let tools = TurnHelpers.inferredToolNamesForTurn(
            in: longText, availableToolNames: ["web_search"]
        )
        XCTAssertTrue(tools.isEmpty) // >200 chars → skip inference
    }

    func testInferredToolNamesInputRequest() {
        let tools = TurnHelpers.inferredToolNamesForTurn(
            in: "let me paste a link for you",
            availableToolNames: ["input_request"]
        )
        XCTAssertTrue(tools.contains("input_request"))
    }

    func testInferredToolNamesCamera() {
        let tools = TurnHelpers.inferredToolNamesForTurn(
            in: "can you see me",
            availableToolNames: ["camera"]
        )
        XCTAssertTrue(tools.contains("camera"))
    }

    func testInferredToolNamesScheduler() {
        let tools = TurnHelpers.inferredToolNamesForTurn(
            in: "schedule a job every day",
            availableToolNames: ["scheduler_create", "scheduler_list"]
        )
        XCTAssertTrue(tools.contains("scheduler_create"))
    }

    // MARK: - Episode Recall Suppression

    func testSuppressRecallForToolMention() {
        XCTAssertTrue(TurnHelpers.shouldSuppressEpisodeRecallForToolSensitiveTurn(
            userText: "use bash to run ls", availableToolNames: ["bash"]
        ))
    }

    func testNoSuppressForMemoryQuery() {
        XCTAssertFalse(TurnHelpers.shouldSuppressEpisodeRecallForToolSensitiveTurn(
            userText: "what do you know about me", availableToolNames: ["bash"]
        ))
    }

    func testSuppressForArithmetic() {
        XCTAssertTrue(TurnHelpers.shouldSuppressEpisodeRecallForToolSensitiveTurn(
            userText: "what's 2 plus 2", availableToolNames: []
        ))
    }

    func testSuppressForURL() {
        XCTAssertTrue(TurnHelpers.shouldSuppressEpisodeRecallForToolSensitiveTurn(
            userText: "check https://example.com", availableToolNames: []
        ))
    }

    func testSuppressForFilePath() {
        XCTAssertTrue(TurnHelpers.shouldSuppressEpisodeRecallForToolSensitiveTurn(
            userText: "read /tmp/file.txt", availableToolNames: []
        ))
    }

    // MARK: - Deterministic Easy Turns

    func testArithmeticReply() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "what's 2 plus 3", rememberedUserName: nil)
        switch action {
        case .arithmetic(let reply):
            XCTAssertTrue(reply.contains("5"))
        default:
            XCTFail("Expected arithmetic")
        }
    }

    func testArithmeticSubtraction() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "10 minus 3", rememberedUserName: nil)
        switch action {
        case .arithmetic(let reply):
            XCTAssertTrue(reply.contains("7"))
        default:
            XCTFail("Expected arithmetic")
        }
    }

    func testArithmeticDivisionByZero() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "5 divided by 0", rememberedUserName: nil)
        switch action {
        case .arithmetic(let reply):
            XCTAssertTrue(reply.contains("zero"))
        default:
            XCTFail("Expected arithmetic")
        }
    }

    func testArithmeticWithWords() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "two plus three", rememberedUserName: nil)
        switch action {
        case .arithmetic(let reply):
            XCTAssertTrue(reply.contains("5"))
        default:
            XCTFail("Expected arithmetic, got \(String(describing: action))")
        }
    }

    func testArithmeticHeyFaePrefix() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "hey fae, what's 4 times 5", rememberedUserName: nil)
        switch action {
        case .arithmetic(let reply):
            XCTAssertTrue(reply.contains("20"))
        default:
            XCTFail("Expected arithmetic")
        }
    }

    func testUserNameDeclaration() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "my name is Alice", rememberedUserName: nil)
        switch action {
        case .rememberUserName(let name, let reply):
            XCTAssertEqual(name, "Alice")
            XCTAssertTrue(reply.contains("Alice"))
        default:
            XCTFail("Expected rememberUserName")
        }
    }

    func testUserNameDeclarationCallMe() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "call me Bob", rememberedUserName: nil)
        switch action {
        case .rememberUserName(let name, _):
            XCTAssertEqual(name, "Bob")
        default:
            XCTFail("Expected rememberUserName")
        }
    }

    func testUserNameRecallWithKnownName() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "what's my name", rememberedUserName: "Alice")
        switch action {
        case .recallUserName(let reply):
            XCTAssertTrue(reply.contains("Alice"))
        default:
            XCTFail("Expected recallUserName")
        }
    }

    func testUserNameRecallWithoutKnownName() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "what's my name", rememberedUserName: nil)
        switch action {
        case .recallUserName(let reply):
            XCTAssertTrue(reply.contains("don't know"))
        default:
            XCTFail("Expected recallUserName")
        }
    }

    func testNoActionForComplexQuery() {
        let action = TurnHelpers.deterministicEasyTurnAction(for: "search the web for weather", rememberedUserName: nil)
        XCTAssertNil(action)
    }

    // MARK: - TTS Batching

    func testBatchedTTSShortText() {
        let segments = TurnHelpers.batchedTTSSegments(from: "Hello world")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0], "Hello world")
    }

    func testBatchedTTSLongText() {
        let longText = String.init(repeating: "word ", count: 200) + "end"
        let segments = TurnHelpers.batchedTTSSegments(from: longText, maxCharacters: 100)
        XCTAssertGreaterThan(segments.count, 1)
    }

    func testBatchedTTSEmpty() {
        let segments = TurnHelpers.batchedTTSSegments(from: "")
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - Voice Approval

    func testShouldAcceptVoiceApprovalWhenAllClear() {
        XCTAssertTrue(TurnHelpers.shouldAcceptVoiceApprovalResponse(
            awaitingApproval: true, manualOnlyApprovalPending: false, assistantSpeaking: false
        ))
    }

    func testShouldRejectVoiceApprovalNotAwaiting() {
        XCTAssertFalse(TurnHelpers.shouldAcceptVoiceApprovalResponse(
            awaitingApproval: false, manualOnlyApprovalPending: false, assistantSpeaking: false
        ))
    }

    func testShouldRejectVoiceApprovalManualOnly() {
        XCTAssertFalse(TurnHelpers.shouldAcceptVoiceApprovalResponse(
            awaitingApproval: true, manualOnlyApprovalPending: true, assistantSpeaking: false
        ))
    }

    func testShouldRejectVoiceApprovalWhileSpeaking() {
        XCTAssertFalse(TurnHelpers.shouldAcceptVoiceApprovalResponse(
            awaitingApproval: true, manualOnlyApprovalPending: false, assistantSpeaking: true
        ))
    }

    // MARK: - Tool Aliases

    func testToolAliasBasic() {
        let aliases = TurnHelpers.toolNameAliases("web_search")
        XCTAssertTrue(aliases.contains("web_search"))
        XCTAssertTrue(aliases.contains("web search"))
        XCTAssertTrue(aliases.contains("websearch"))
    }

    func testToolAliasSelfConfig() {
        let aliases = TurnHelpers.toolNameAliases("self_config")
        XCTAssertTrue(aliases.contains("settings tool"))
        XCTAssertTrue(aliases.contains("config tool"))
    }

    func testToolAliasSessionSearch() {
        let aliases = TurnHelpers.toolNameAliases("session_search")
        XCTAssertTrue(aliases.contains("transcript search"))
        XCTAssertTrue(aliases.contains("search our chat"))
    }

    func testToolAliasVoiceIdentity() {
        let aliases = TurnHelpers.toolNameAliases("voice_identity")
        XCTAssertTrue(aliases.contains("speaker profile"))
    }

    func testToolAliasSchedulerCreate() {
        let aliases = TurnHelpers.toolNameAliases("scheduler_create")
        XCTAssertTrue(aliases.contains("create schedule"))
    }

    func testToolAliasUnknown() {
        let aliases = TurnHelpers.toolNameAliases("unknown_tool")
        XCTAssertEqual(aliases.count, 3) // name, spaced, no-underscore
    }

    // MARK: - Failure Messages

    func testLLMFailureFallbackProactive() {
        let msg = TurnHelpers.llmFailureFallbackMessage(
            firstOwnerEnrollmentActive: false, proactiveContextPresent: true
        )
        XCTAssertNil(msg)
    }

    func testLLMFailureFallbackEnrollment() {
        let msg = TurnHelpers.llmFailureFallbackMessage(
            firstOwnerEnrollmentActive: true, proactiveContextPresent: false
        )
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("get to know you"))
    }

    func testLLMFailureFallbackNormal() {
        let msg = TurnHelpers.llmFailureFallbackMessage(
            firstOwnerEnrollmentActive: false, proactiveContextPresent: false
        )
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("try that once more"))
    }

    // MARK: - Legacy Inline Tool Prompt

    func testPrefersLegacyInlineToolPromptClaude() {
        XCTAssertTrue(TurnHelpers.prefersLegacyInlineToolPrompt(
            modelId: "anthropic/claude-4.6-opus-distilled"
        ))
    }

    func testPrefersLegacyInlineToolPromptOther() {
        XCTAssertFalse(TurnHelpers.prefersLegacyInlineToolPrompt(modelId: "qwen3-4b"))
    }

    func testPrefersLegacyInlineToolPromptNil() {
        XCTAssertFalse(TurnHelpers.prefersLegacyInlineToolPrompt(modelId: nil))
    }
}
