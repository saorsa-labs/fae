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
        // Voice-identity teardown: enrollment exposes no tools at all.
        let tools = TurnHelpers.visibleToolNamesForTurn(
            firstOwnerEnrollmentActive: true, userText: "anything", availableToolNames: ["read", "bash"],
            proactiveAllowedTools: nil
        )
        XCTAssertEqual(tools, [])
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

    func testFullSchemaToolsGenericTurnUsesCoreWorkingSet() {
        let available = [
            "read", "write", "edit", "bash", "self_config", "web_search", "fetch_url",
            "calendar", "camera", "mail", "scheduler_create", "input_request",
        ]
        let tools = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "hello there",
            availableToolNames: available,
            proactiveAllowedTools: nil
        )
        XCTAssertTrue(tools.contains("read"))
        XCTAssertTrue(tools.contains("bash"))
        XCTAssertTrue(tools.contains("input_request"))
        XCTAssertFalse(tools.contains("calendar"))
        XCTAssertFalse(tools.contains("camera"))
        XCTAssertLessThan(tools.count, available.count)
    }

    func testFullSchemaToolsIncludeInferredLongTailTool() {
        let tools = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "can you see me",
            availableToolNames: ["read", "bash", "camera", "calendar"],
            proactiveAllowedTools: nil
        )
        XCTAssertTrue(tools.contains("read"))
        XCTAssertTrue(tools.contains("camera"))
        XCTAssertFalse(tools.contains("calendar"))
    }

    func testFullSchemaToolsProactiveAllowlistStaysNarrow() {
        let tools = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "look around",
            availableToolNames: ["read", "bash", "camera", "calendar"],
            proactiveAllowedTools: ["camera"]
        )
        XCTAssertEqual(tools, ["camera"])
    }

    func testFullSchemaToolsProactiveAllowlistDoesNotNarrowIndexAndSchemasApart() {
        let tools = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "check the calendar",
            availableToolNames: ["calendar", "mail", "reminders"],
            proactiveAllowedTools: ["calendar", "mail", "reminders"]
        )
        XCTAssertEqual(tools, ["calendar", "mail", "reminders"])
    }

    func testFullSchemaToolsContinuationStaysConservativeWithoutRecentTools() {
        // Prompt-budget: an ambiguous follow-up with no recently-used tools must
        // NOT inflate to the full surface (the old `return available` behaviour
        // paid the whole 36-tool schema tax on every continuation). It stays on
        // the conservative working set, so niche tools remain index-only.
        let available = ["read", "bash", "calendar", "mail", "input_request"]
        let tools = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "yes, use that",
            availableToolNames: available,
            proactiveAllowedTools: nil,
            isConversationContinuation: true
        )
        XCTAssertTrue(tools.contains("read"))
        XCTAssertTrue(tools.contains("bash"))
        XCTAssertFalse(tools.contains("calendar"), "ambiguous follow-up must not pull in calendar")
        XCTAssertFalse(tools.contains("mail"), "ambiguous follow-up must not pull in mail")
        XCTAssertLessThan(tools.count, available.count)
    }

    func testFullSchemaToolsContinuationKeepsRecentlyUsedToolsSticky() {
        // The reason the old "all schemas" behaviour existed: a bare follow-up
        // ("yes, do that") may need the tool the PRIOR turn used but can't infer
        // from the text. The sticky set preserves exactly those tools — and only
        // those — so the follow-up stays callable without the full-surface tax.
        let available = ["read", "bash", "calendar", "mail", "input_request"]
        let tools = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "yes, do that",
            availableToolNames: available,
            proactiveAllowedTools: nil,
            isConversationContinuation: true,
            recentlyUsedTools: ["calendar"]
        )
        XCTAssertTrue(tools.contains("calendar"), "the tool used last turn must stay full-schema")
        XCTAssertTrue(tools.contains("read"))
        XCTAssertFalse(tools.contains("mail"), "tools never used must not become sticky")
    }

    func testFullSchemaToolsRecentToolsIgnoredOutsideContinuation() {
        // Sticky tools only apply inside the continuation window; a fresh,
        // non-continuation turn ignores them entirely.
        let available = ["read", "bash", "calendar", "mail"]
        let tools = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "hello there",
            availableToolNames: available,
            proactiveAllowedTools: nil,
            isConversationContinuation: false,
            recentlyUsedTools: ["calendar", "mail"]
        )
        XCTAssertFalse(tools.contains("calendar"))
        XCTAssertFalse(tools.contains("mail"))
    }

    func testFullSchemaToolsDuringEnrollmentAreEmpty() {
        let tools = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: true,
            userText: "search web",
            availableToolNames: ["read", "web_search"],
            proactiveAllowedTools: nil
        )
        XCTAssertTrue(tools.isEmpty)
    }

    func testToolRegistryStrictLocalFiltersFullSchemaWorkingSet() {
        let registry = ToolRegistry(tools: [ReadTool(), WebSearchTool(), FetchURLTool(), BashTool()])
        let workingSet = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "search the web",
            availableToolNames: registry.toolNames,
            proactiveAllowedTools: nil
        )
        let allowed = registry.allowedToolNames(
            for: "full",
            privacyMode: "strict_local",
            limitedTo: workingSet
        )
        XCTAssertTrue(allowed.contains("read"))
        XCTAssertTrue(allowed.contains("bash"))
        XCTAssertFalse(allowed.contains("web_search"))
        XCTAssertFalse(allowed.contains("fetch_url"))
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

    // MARK: - Progressive Tool Disclosure: no-regression gate (Task #11)
    //
    // Lever 1 sends full native schemas only for a per-turn working set; the
    // rest of the tool surface stays index-only. The risk: a high-frequency
    // voice command whose tool falls out of the working set becomes
    // effectively un-callable (native tool calling can't emit a call for a tool
    // with no schema). This battery is the deterministic gate the prompt-budget
    // plan required — it asserts the common spoken intents keep their full
    // schema on a COLD turn (no continuation, no allowlist), against the real
    // default registry, so a future inference change that strands one fails CI.

    func testProgressiveDisclosureKeepsHighFrequencyCommandTools() {
        let registry = ToolRegistry.buildDefault()
        let available = registry.toolNames
        // (spoken phrasing, the tool the user expects Fae to be able to call)
        let battery: [(String, String)] = [
            ("what's on my calendar today", "calendar"),
            ("am I free tomorrow afternoon", "calendar"),
            ("remind me to call mum at six", "reminders"),
            ("send an email to john about the meeting", "mail"),
            ("look up tonight's weather", "web_search"),
            ("search the web for the train times", "web_search"),
            ("take a screenshot", "screenshot"),
            ("can you see me", "camera"),
            ("read ~/notes/today.md", "read"),
            ("run git status in the terminal", "bash"),
            ("what did we decide about the budget earlier", "session_search"),
        ]
        for (phrase, expected) in battery {
            guard available.contains(expected) else { continue }
            let workingSet = TurnHelpers.fullSchemaToolNamesForTurn(
                firstOwnerEnrollmentActive: false,
                userText: phrase,
                availableToolNames: available,
                proactiveAllowedTools: nil
            )
            XCTAssertTrue(
                workingSet.contains(expected),
                "REGRESSION: \"\(phrase)\" must keep a full \(expected) schema, "
                    + "otherwise the model cannot call it on a cold turn")
        }
    }

    // The flip side: niche tools intentionally stay index-only on a cold,
    // generic turn (and on an ambiguous continuation — they only regain a full
    // schema when inferred from the turn, or when they were used in a recent
    // turn via the sticky set). Documents the deliberate trade so an accidental
    // demotion of a high-frequency tool above — or promotion here — is caught.
    func testProgressiveDisclosureKeepsNicheToolsIndexOnlyOnColdTurn() {
        let registry = ToolRegistry.buildDefault()
        let available = registry.toolNames
        let workingSet = TurnHelpers.fullSchemaToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "hello fae, how are you",
            availableToolNames: available,
            proactiveAllowedTools: nil
        )
        for niche in ["roleplay", "delegate_agent", "agent_session", "plugin_manage"]
        where available.contains(niche) {
            XCTAssertFalse(
                workingSet.contains(niche),
                "\(niche) is not expected in the cold-turn working set")
        }
    }
}
