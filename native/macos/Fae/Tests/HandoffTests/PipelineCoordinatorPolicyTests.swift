import XCTest
@testable import Fae

final class PipelineCoordinatorPolicyTests: XCTestCase {
    func testToolModeUpgradePopupShownOnlyForActionableReasons() {
        XCTAssertTrue(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "owner_enrollment_required"))
        XCTAssertTrue(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "tool_not_called"))
        XCTAssertTrue(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "non-owner"))

        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "toolMode=off"))
        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "quick_voice_fast_path"))
        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "proactive_turn"))
        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "unknown"))
    }

    func testExplicitlyMentionedToolNamesMatchesUnderscoredAndFriendlyAliases() {
        let matches = PipelineCoordinator.explicitlyMentionedToolNames(
            in: "Fae, use the read tool and then run self config to show your settings.",
            availableToolNames: ["read", "self_config", "web_search"]
        )

        XCTAssertEqual(matches, ["read", "self_config"])
    }

    func testVisibleToolNamesForTurnNarrowsToExplicitToolMention() {
        let visible = PipelineCoordinator.visibleToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "Fae, call the read tool to open /etc/hosts.",
            availableToolNames: ["read", "write", "web_search"],
            proactiveAllowedTools: nil
        )

        XCTAssertEqual(visible, ["read"])
    }

    func testVisibleToolNamesForTurnPreservesProactiveAllowanceWhenNoExplicitMention() {
        let visible = PipelineCoordinator.visibleToolNamesForTurn(
            firstOwnerEnrollmentActive: false,
            userText: "What maintenance jobs are pending?",
            availableToolNames: ["scheduler_list", "web_search"],
            proactiveAllowedTools: ["scheduler_list"]
        )

        XCTAssertEqual(visible, ["scheduler_list"])
    }

    func testPrefersLegacyInlineToolPromptForQwenModels() {
        // Qwen models use native MLX tool calling — no legacy inline prompt needed.
        XCTAssertFalse(
            PipelineCoordinator.prefersLegacyInlineToolPrompt(
                modelId: "mlx-community/Qwen3.5-2B-4bit"
            )
        )
        XCTAssertFalse(
            PipelineCoordinator.prefersLegacyInlineToolPrompt(
                modelId: "mlx-community/Qwen3-8B-4bit"
            )
        )
        // The Claude-distilled variant requires the legacy inline format.
        XCTAssertTrue(
            PipelineCoordinator.prefersLegacyInlineToolPrompt(
                modelId: "mlx-community/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"
            )
        )
    }

    func testShouldSuppressEpisodeRecallForToolSensitiveTurn() {
        XCTAssertTrue(
            PipelineCoordinator.shouldSuppressEpisodeRecallForToolSensitiveTurn(
                userText: "Fae, write 'hello' to /tmp/a.txt",
                availableToolNames: ["write", "read"]
            )
        )
        XCTAssertTrue(
            PipelineCoordinator.shouldSuppressEpisodeRecallForToolSensitiveTurn(
                userText: "Fae, use the web_search tool to search for Swift news",
                availableToolNames: ["web_search", "read"]
            )
        )
        XCTAssertFalse(
            PipelineCoordinator.shouldSuppressEpisodeRecallForToolSensitiveTurn(
                userText: "Tell me a joke about Edinburgh",
                availableToolNames: ["write", "web_search"]
            )
        )
    }

    func testShouldSuppressEpisodeRecallForArithmeticQuery() {
        XCTAssertTrue(
            PipelineCoordinator.shouldSuppressEpisodeRecallForToolSensitiveTurn(
                userText: "What is seven times eight?",
                availableToolNames: ["read", "web_search"]
            )
        )
        XCTAssertTrue(
            PipelineCoordinator.shouldSuppressEpisodeRecallForToolSensitiveTurn(
                userText: "What's 7 * 8?",
                availableToolNames: ["read", "web_search"]
            )
        )
    }

    func testDeterministicEasyTurnActionAnswersArithmeticWordProblems() {
        let action = PipelineCoordinator.deterministicEasyTurnAction(
            for: "Fae, what is seven times eight?",
            rememberedUserName: nil
        )

        XCTAssertEqual(action, .arithmetic(reply: "56."))
    }

    func testDeterministicEasyTurnActionAnswersArithmeticDigitProblems() {
        let action = PipelineCoordinator.deterministicEasyTurnAction(
            for: "what is 12 + 30?",
            rememberedUserName: nil
        )

        XCTAssertEqual(action, .arithmetic(reply: "42."))
    }

    func testDeterministicEasyTurnActionRemembersStandaloneNameDeclaration() {
        let action = PipelineCoordinator.deterministicEasyTurnAction(
            for: "my name is Jarvis",
            rememberedUserName: nil
        )

        XCTAssertEqual(
            action,
            .rememberUserName(name: "Jarvis", reply: "Got it. I'll remember that your name is Jarvis.")
        )
    }

    func testDeterministicEasyTurnActionRecallsRememberedName() {
        let action = PipelineCoordinator.deterministicEasyTurnAction(
            for: "what is my name?",
            rememberedUserName: "Jarvis"
        )

        XCTAssertEqual(action, .recallUserName(reply: "Your name is Jarvis."))
    }

    func testDeterministicEasyTurnActionPromptsForNameWhenUnknown() {
        let action = PipelineCoordinator.deterministicEasyTurnAction(
            for: "who am i?",
            rememberedUserName: nil
        )

        XCTAssertEqual(
            action,
            .recallUserName(reply: "I don't know your name yet. Tell me your name and I'll remember it.")
        )
    }

    func testMemoryTurnGuidanceFlagsCaptureTurns() {
        let guidance = PipelineCoordinator.memoryTurnGuidance(for: "Fae, I'm called TestUser")

        XCTAssertEqual(
            guidance,
            "Memory capture guidance: The user is giving durable personal context. Acknowledge the exact fact, person, or name briefly and plainly."
        )
    }

    func testMemoryTurnGuidanceIgnoresGenericImStatusTurns() {
        let guidance = PipelineCoordinator.memoryTurnGuidance(for: "Fae, I'm exhausted")

        XCTAssertNil(guidance)
    }

    func testMemoryTurnGuidanceFlagsGroundedRecallTurns() {
        let guidance = PipelineCoordinator.memoryTurnGuidance(
            for: "Fae, what have you learned recently from my imported notes?"
        )

        XCTAssertEqual(
            guidance,
            "Memory reply guidance: Answer directly from memory context. If the fact is missing, say that plainly. Do not improvise or switch topics."
        )
    }

    func testMemoryTurnGuidanceIncludesExplicitInterestTopic() {
        let guidance = PipelineCoordinator.memoryTurnGuidance(
            for: "Fae, I love learning about quantum computing"
        )

        XCTAssertEqual(
            guidance,
            "Memory capture guidance: The user is giving durable personal context about an interest in quantum computing. Acknowledge quantum computing explicitly and briefly."
        )
    }

    func testPersonQueryDetectorHandlesAnyoneWhoWorksAtVariant() {
        let match = PersonQueryDetector.detectPersonQuery(
            in: "tell me about people who work at Google"
        )

        XCTAssertEqual(match?.targetOrganisation, "Google")
        XCTAssertTrue(match?.isExplicitQuery == true)
    }

    func testBatchedTTSSegmentsKeepsShortRepliesIntact() {
        let segments = PipelineCoordinator.batchedTTSSegments(
            from: "Local AI keeps your private data on your own machine."
        )

        XCTAssertEqual(
            segments,
            ["Local AI keeps your private data on your own machine."]
        )
    }

    func testBatchedTTSSegmentsSplitsLongRepliesAtSentenceBoundaries() {
        let text = """
        Local AI privacy matters because your personal data stays on-device instead of being sent to a third-party service. \
        That reduces exposure for sensitive conversations, business plans, and health information. \
        It also makes trust easier to reason about because the authority boundary is local. \
        Finally, it gives users stronger guarantees about what can and cannot leave the machine.
        """

        let segments = PipelineCoordinator.batchedTTSSegments(from: text, maxCharacters: 120)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.count <= 120 })
        XCTAssertTrue(segments[0].hasSuffix("."))
    }

    func testRepairedToolCallForSkippedWriteTurnExtractsPathAndContent() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, write 'hello fae test' to /tmp/fae-test-write.txt"
        ) else {
            return XCTFail("Expected write repair call")
        }

        XCTAssertEqual(call.name, "write")
        XCTAssertEqual(call.arguments["path"] as? String, "/tmp/fae-test-write.txt")
        XCTAssertEqual(call.arguments["content"] as? String, "hello fae test")
    }

    func testRepairedToolCallForCreateFilePhraseExtractsWriteIntent() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, create a file at /tmp/perm-test.txt with content 'test'"
        ) else {
            return XCTFail("Expected create-file repair call")
        }

        XCTAssertEqual(call.name, "write")
        XCTAssertEqual(call.arguments["path"] as? String, "/tmp/perm-test.txt")
        XCTAssertEqual(call.arguments["content"] as? String, "test")
    }

    func testRepairedToolCallForSkippedFetchTurnExtractsURL() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, fetch https://example.com"
        ) else {
            return XCTFail("Expected fetch repair call")
        }

        XCTAssertEqual(call.name, "fetch_url")
        XCTAssertEqual(call.arguments["url"] as? String, "https://example.com")
    }

    func testRepairedToolCallForSkippedSearchTurnExtractsQuery() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, search for Rust programming"
        ) else {
            return XCTFail("Expected web search repair call")
        }

        XCTAssertEqual(call.name, "web_search")
        XCTAssertEqual(call.arguments["query"] as? String, "Rust programming")
    }

    func testRepairedToolCallForCalendarLookupDefaultsToToday() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, check my calendar"
        ) else {
            return XCTFail("Expected calendar repair call")
        }

        XCTAssertEqual(call.name, "calendar")
        XCTAssertEqual(call.arguments["action"] as? String, "list_today")
    }

    func testRepairedToolCallForCalendarWeekLookupUsesListWeek() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, what is on my calendar this week?"
        ) else {
            return XCTFail("Expected calendar week repair call")
        }

        XCTAssertEqual(call.name, "calendar")
        XCTAssertEqual(call.arguments["action"] as? String, "list_week")
    }

    func testRepairedToolCallForCalendarSearchUsesSearchAction() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, search my calendar for dentist"
        ) else {
            return XCTFail("Expected calendar search repair call")
        }

        XCTAssertEqual(call.name, "calendar")
        XCTAssertEqual(call.arguments["action"] as? String, "search")
        XCTAssertEqual(call.arguments["query"] as? String, "dentist")
    }

    func testRepairedToolCallForSchedulerCreateExtractsNameAndInterval() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, create a task called fae-test-task that runs every 5 minutes"
        ) else {
            return XCTFail("Expected scheduler_create repair call")
        }

        XCTAssertEqual(call.name, "scheduler_create")
        XCTAssertEqual(call.arguments["name"] as? String, "fae-test-task")
        XCTAssertEqual(call.arguments["schedule_type"] as? String, "interval")
        let params = call.arguments["schedule_params"] as? [String: String]
        XCTAssertEqual(params?["minutes"], "5")
    }

    func testRepairedToolCallForSchedulerUpdateUsesSchedulerListBootstrap() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, use scheduler_list to find fae-update-test, then use scheduler_update to change its interval to every 10 minutes"
        ) else {
            return XCTFail("Expected scheduler_list repair call")
        }

        XCTAssertEqual(call.name, "scheduler_list")
    }

    func testRepairedToolCallForUnquotedEditTurnExtractsReplacementPair() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, edit /tmp/fae-test-edit.txt and replace FAETEST_ORIGINAL with FAETEST_MODIFIED"
        ) else {
            return XCTFail("Expected edit repair call")
        }

        XCTAssertEqual(call.name, "edit")
        XCTAssertEqual(call.arguments["path"] as? String, "/tmp/fae-test-edit.txt")
        XCTAssertEqual(call.arguments["old_string"] as? String, "FAETEST_ORIGINAL")
        XCTAssertEqual(call.arguments["new_string"] as? String, "FAETEST_MODIFIED")
    }

    func testRepairedToolCallForInputRequestUsesSecurePrompt() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, use the input_request tool to ask me for a password"
        ) else {
            return XCTFail("Expected input_request repair call")
        }

        XCTAssertEqual(call.name, "input_request")
        XCTAssertEqual(call.arguments["title"] as? String, "Password Required")
        XCTAssertEqual(call.arguments["prompt"] as? String, "Please enter the password.")
        XCTAssertEqual(call.arguments["secure"] as? Bool, true)
        XCTAssertEqual(call.arguments["return_to_model"] as? Bool, false)
    }

    func testRepairedToolCallForActivateSkillExtractsSkillName() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, activate the voice-identity skill"
        ) else {
            return XCTFail("Expected activate_skill repair call")
        }

        XCTAssertEqual(call.name, "activate_skill")
        XCTAssertEqual(call.arguments["name"] as? String, "voice-identity")
    }

    func testRepairedToolCallForRunSkillExtractsSkillName() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, run the fae-test-skill"
        ) else {
            return XCTFail("Expected run_skill repair call")
        }

        XCTAssertEqual(call.name, "run_skill")
        XCTAssertEqual(call.arguments["name"] as? String, "fae-test-skill")
    }

    func testRepairedToolCallForScreenshotRequestUsesScreenshotTool() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, capture my screen"
        ) else {
            return XCTFail("Expected screenshot repair call")
        }

        XCTAssertEqual(call.name, "screenshot")
        XCTAssertNotNil(call.arguments["prompt"] as? String)
    }

    func testRepairedToolCallForScreenshotMentionUsesScreenshotTool() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, use the screenshot tool and tell me what is on my screen right now."
        ) else {
            return XCTFail("Expected screenshot repair call")
        }

        XCTAssertEqual(call.name, "screenshot")
    }

    func testRepairedToolCallForSafariScreenshotCarriesAppTarget() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, take a screenshot and tell me the exact headline text in the Safari window."
        ) else {
            return XCTFail("Expected screenshot repair call")
        }

        XCTAssertEqual(call.name, "screenshot")
        XCTAssertEqual(call.arguments["app"] as? String, "Safari")
    }

    func testRepairedToolCallForCameraRequestUsesCameraTool() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, capture from the webcam"
        ) else {
            return XCTFail("Expected camera repair call")
        }

        XCTAssertEqual(call.name, "camera")
    }

    func testRepairedToolCallForVoiceIdentityStatusUsesVoiceIdentityTool() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, use the voice_identity tool to check current status"
        ) else {
            return XCTFail("Expected voice_identity repair call")
        }

        XCTAssertEqual(call.name, "voice_identity")
        XCTAssertEqual(call.arguments["action"] as? String, "check_status")
    }

    func testRepairedToolCallForReadScreenRequestUsesReadScreenTool() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, describe what you see on my screen"
        ) else {
            return XCTFail("Expected read_screen repair call")
        }

        XCTAssertEqual(call.name, "read_screen")
    }

    func testRepairedToolCallForWhatsOnMyScreenUsesReadScreenTool() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, what is on my screen right now?"
        ) else {
            return XCTFail("Expected read_screen repair call")
        }

        XCTAssertEqual(call.name, "read_screen")
    }

    func testRepairedToolCallForSafariReadScreenCarriesAppTarget() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, read what is on the Safari window."
        ) else {
            return XCTFail("Expected read_screen repair call")
        }

        XCTAssertEqual(call.name, "read_screen")
        XCTAssertEqual(call.arguments["app"] as? String, "Safari")
    }

    func testShouldSuppressThinkingInFastModeForToolFollowUps() {
        // Tool follow-up turns always keep thinking enabled so the model can
        // reason over tool results, even when the global level is .fast.
        XCTAssertFalse(
            PipelineCoordinator.shouldSuppressThinking(
                forceSuppressThinking: false,
                thinkingLevel: .fast,
                isToolFollowUp: true
            )
        )
    }

    func testShouldKeepThinkingInBalancedModeWhenNotForced() {
        XCTAssertFalse(
            PipelineCoordinator.shouldSuppressThinking(
                forceSuppressThinking: false,
                thinkingLevel: .balanced,
                isToolFollowUp: true
            )
        )
    }

    func testToolTimeoutSecondsExtendsVisionToolBudget() {
        XCTAssertEqual(PipelineCoordinator.toolTimeoutSeconds(for: "screenshot"), 180)
        XCTAssertEqual(PipelineCoordinator.toolTimeoutSeconds(for: "camera"), 180)
        XCTAssertEqual(PipelineCoordinator.toolTimeoutSeconds(for: "read_screen"), 180)
    }

    func testToolTimeoutSecondsKeepsDefaultBudgetForNonVisionTools() {
        XCTAssertEqual(PipelineCoordinator.toolTimeoutSeconds(for: "calendar"), 30)
        XCTAssertEqual(PipelineCoordinator.toolTimeoutSeconds(for: "bash"), 30)
    }

    func testRepairedToolCallForClickRequestExtractsElementIndex() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, click on element 1"
        ) else {
            return XCTFail("Expected click repair call")
        }

        XCTAssertEqual(call.name, "click")
        XCTAssertEqual(call.arguments["element_index"] as? Int, 1)
    }

    func testRepairedToolCallForTypeTextRequestExtractsText() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, type 'hello world' in the current text box"
        ) else {
            return XCTFail("Expected type_text repair call")
        }

        XCTAssertEqual(call.name, "type_text")
        XCTAssertEqual(call.arguments["text"] as? String, "hello world")
    }

    func testRepairedToolCallForScrollRequestUsesScrollTool() {
        guard let call = PipelineCoordinator.repairedToolCallForSkippedTurn(
            "Fae, scroll the page down"
        ) else {
            return XCTFail("Expected scroll repair call")
        }

        XCTAssertEqual(call.name, "scroll")
        XCTAssertEqual(call.arguments["direction"] as? String, "down")
    }

    func testRepairedToolCallRespectsToolModePreflight() {
        let registry = ToolRegistry.buildDefault()
        let call = PipelineCoordinator.ToolCall(
            name: "write",
            arguments: ["path": "/tmp/test.txt", "content": "test"]
        )

        XCTAssertFalse(
            PipelineCoordinator.shouldAttemptRepairToolCall(
                call,
                registry: registry,
                toolMode: "read_only",
                privacyMode: "local_preferred"
            )
        )
    }

    func testPreflightToolDenialBlocksSystemPathWriteBeforeFiller() {
        let denial = PipelineCoordinator.preflightToolDenial(
            for: [PipelineCoordinator.ToolCall(name: "write", arguments: ["path": "/etc/test-fae", "content": "test"])],
            registry: ToolRegistry.buildDefault(),
            toolMode: "full_no_approval",
            privacyMode: "local_preferred"
        )

        XCTAssertEqual(denial, "Cannot write to system path: /etc")
    }

    func testVoiceApprovalResponsesAreIgnoredWhileAssistantIsSpeaking() {
        XCTAssertFalse(
            PipelineCoordinator.shouldAcceptVoiceApprovalResponse(
                awaitingApproval: true,
                manualOnlyApprovalPending: false,
                assistantSpeaking: true
            )
        )
        XCTAssertTrue(
            PipelineCoordinator.shouldAcceptVoiceApprovalResponse(
                awaitingApproval: true,
                manualOnlyApprovalPending: false,
                assistantSpeaking: false
            )
        )
    }

    func testDirectToolReplyTextUsesGroundedCalendarOutputVerbatim() {
        let call = PipelineCoordinator.ToolCall(
            name: "calendar",
            arguments: ["action": "list_today"]
        )
        let result = ToolResult.success(
            """
            2 events:
            - All day: Food Waste Caddy
            - 12/03/2026, 17:00: Peader
            """
        )

        XCTAssertEqual(
            PipelineCoordinator.directToolReplyText(for: call, result: result),
            """
            2 events:
            - All day: Food Waste Caddy
            - 12/03/2026, 17:00: Peader
            """
        )
    }

    func testDirectToolReplyTextStripsScreenshotEnvelope() {
        let call = PipelineCoordinator.ToolCall(name: "screenshot", arguments: [:])
        let result = ToolResult.success("Screenshot (1920x1080):\nFAE Vision Test 7321")

        XCTAssertEqual(
            PipelineCoordinator.directToolReplyText(for: call, result: result),
            "FAE Vision Test 7321"
        )
    }

    func testDirectToolReplyTextLeavesReadScreenForFollowUpReasoning() {
        let call = PipelineCoordinator.ToolCall(name: "read_screen", arguments: [:])
        let result = ToolResult.success("Interactive elements:\n[0] AXButton: OK")

        XCTAssertNil(PipelineCoordinator.directToolReplyText(for: call, result: result))
    }

    func testShouldPreferInlineToolExecutionForCalendarLookup() {
        let call = PipelineCoordinator.ToolCall(name: "calendar", arguments: ["action": "list_today"])

        XCTAssertTrue(
            PipelineCoordinator.shouldPreferInlineToolExecution(
                userText: "Fae, use the calendar tool right now and list my events for today.",
                toolCalls: [call]
            )
        )
    }

    func testShouldPreferInlineToolExecutionKeepsWebSearchDeferredEligible() {
        let call = PipelineCoordinator.ToolCall(name: "web_search", arguments: ["query": "swift news"])

        XCTAssertFalse(
            PipelineCoordinator.shouldPreferInlineToolExecution(
                userText: "Fae, search for Swift news.",
                toolCalls: [call]
            )
        )
    }
}
