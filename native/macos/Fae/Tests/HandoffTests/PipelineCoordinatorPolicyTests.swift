import XCTest
@testable import Fae

final class PipelineCoordinatorPolicyTests: XCTestCase {
    func testToolModeUpgradePopupShownOnlyForActionableReasons() {
        XCTAssertTrue(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "owner_enrollment_required"))
        XCTAssertTrue(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "tool_not_called"))
        XCTAssertTrue(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "non-owner"))

        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "toolMode=off"))
        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "quick_voice_fast_path"))
        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "concierge_route"))
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
        XCTAssertTrue(
            PipelineCoordinator.prefersLegacyInlineToolPrompt(
                modelId: "mlx-community/Qwen3.5-2B-4bit"
            )
        )
        XCTAssertTrue(
            PipelineCoordinator.prefersLegacyInlineToolPrompt(
                modelId: "mlx-community/Qwen3-8B-4bit"
            )
        )
        XCTAssertFalse(
            PipelineCoordinator.prefersLegacyInlineToolPrompt(
                modelId: "LiquidAI/LFM2-24B-A2B-MLX-4bit"
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
}
