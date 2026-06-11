import XCTest
@testable import Fae

final class ToolExecutorStaticTests: XCTestCase {

    // MARK: - toolTimeoutSeconds

    func testToolTimeoutScreenshot() {
        // Vision tools get the extended 180s budget — VLM analysis is slow.
        let timeout = ToolExecutor.toolTimeoutSeconds(for: "screenshot")
        XCTAssertEqual(timeout, 180) // extendedVisionToolTimeoutSeconds
    }

    func testToolTimeoutCamera() {
        let timeout = ToolExecutor.toolTimeoutSeconds(for: "camera")
        XCTAssertEqual(timeout, 180)
    }

    func testToolTimeoutReadScreen() {
        let timeout = ToolExecutor.toolTimeoutSeconds(for: "read_screen")
        XCTAssertEqual(timeout, 180)
    }

    func testToolTimeoutDefault() {
        let timeout = ToolExecutor.toolTimeoutSeconds(for: "web_search")
        XCTAssertEqual(timeout, 30) // defaultToolTimeoutSeconds
    }

    // MARK: - isSelfConfigReadAction

    func testIsSelfConfigReadGetSettings() {
        XCTAssertTrue(ToolExecutor.isSelfConfigReadAction(arguments: ["action": "get_settings"]))
    }

    func testIsSelfConfigReadGetDirective() {
        XCTAssertTrue(ToolExecutor.isSelfConfigReadAction(arguments: ["action": "get_directive"]))
    }

    func testIsSelfConfigReadSetSetting() {
        XCTAssertFalse(ToolExecutor.isSelfConfigReadAction(arguments: ["action": "adjust_setting"]))
    }

    func testIsSelfConfigReadNoAction() {
        XCTAssertFalse(ToolExecutor.isSelfConfigReadAction(arguments: [:]))
    }

    // MARK: - toolRequiresApproval

    func testToolRequiresApprovalSelfConfigRead() {
        XCTAssertFalse(ToolExecutor.toolRequiresApproval(
            toolName: "self_config",
            arguments: ["action": "get_settings"],
            defaultRequiresApproval: true
        ))
    }

    func testToolRequiresApprovalSelfConfigWrite() {
        XCTAssertTrue(ToolExecutor.toolRequiresApproval(
            toolName: "self_config",
            arguments: ["action": "adjust_setting"],
            defaultRequiresApproval: false
        ))
    }

    func testToolRequiresApprovalCalendarCreate() {
        XCTAssertTrue(ToolExecutor.toolRequiresApproval(
            toolName: "calendar",
            arguments: ["action": "create"],
            defaultRequiresApproval: false
        ))
    }

    func testToolRequiresApprovalCalendarRead() {
        XCTAssertFalse(ToolExecutor.toolRequiresApproval(
            toolName: "calendar",
            arguments: ["action": "list_today"],
            defaultRequiresApproval: false
        ))
    }

    func testToolRequiresApprovalRemindersCreate() {
        XCTAssertTrue(ToolExecutor.toolRequiresApproval(
            toolName: "reminders",
            arguments: ["action": "create"],
            defaultRequiresApproval: false
        ))
    }

    // MARK: - buildApprovalDescription

    func testBuildApprovalDescriptionBash() {
        let desc = ToolExecutor.buildApprovalDescription(
            toolName: "bash", reason: "test", arguments: ["command": "ls -la"]
        )
        XCTAssertTrue(desc.contains("ls -la"))
        XCTAssertTrue(desc.contains("yes or no"))
    }

    func testBuildApprovalDescriptionBashLong() {
        let longCmd = String.init(repeating: "a", count: 200)
        let desc = ToolExecutor.buildApprovalDescription(
            toolName: "bash", reason: "test", arguments: ["command": longCmd]
        )
        XCTAssertTrue(desc.contains("..."))
    }

    func testBuildApprovalDescriptionWrite() {
        let desc = ToolExecutor.buildApprovalDescription(
            toolName: "write", reason: "test", arguments: ["path": "/tmp/file.txt"]
        )
        XCTAssertTrue(desc.contains("/tmp/file.txt"))
    }

    func testBuildApprovalDescriptionEdit() {
        let desc = ToolExecutor.buildApprovalDescription(
            toolName: "edit", reason: "test", arguments: ["path": "/tmp/config.toml"]
        )
        XCTAssertTrue(desc.contains("edit"))
    }

    func testBuildApprovalDescriptionSelfConfig() {
        let desc = ToolExecutor.buildApprovalDescription(
            toolName: "self_config", reason: "test", arguments: ["action": "adjust_setting", "key": "speed"]
        )
        XCTAssertTrue(desc.contains("speed"))
    }

    func testBuildApprovalDescriptionScheduler() {
        let desc = ToolExecutor.buildApprovalDescription(
            toolName: "scheduler_create", reason: "test", arguments: [:]
        )
        XCTAssertTrue(desc.contains("scheduled task"))
    }

    func testBuildApprovalDescriptionUnknown() {
        let desc = ToolExecutor.buildApprovalDescription(
            toolName: "custom_tool", reason: "test", arguments: [:]
        )
        XCTAssertTrue(desc.contains("custom_tool"))
    }

    // MARK: - isSafeSkillName

    func testIsSafeSkillNameValid() {
        XCTAssertTrue(ToolExecutor.isSafeSkillName("my-skill"))
        XCTAssertTrue(ToolExecutor.isSafeSkillName("my_skill"))
        XCTAssertTrue(ToolExecutor.isSafeSkillName("MySkill123"))
    }

    func testIsSafeSkillNameInvalidPath() {
        XCTAssertFalse(ToolExecutor.isSafeSkillName("../evil"))
        XCTAssertFalse(ToolExecutor.isSafeSkillName("/etc/passwd"))
        XCTAssertFalse(ToolExecutor.isSafeSkillName("back\\slash"))
        XCTAssertFalse(ToolExecutor.isSafeSkillName("~/secret"))
    }

    func testIsSafeSkillNameEmpty() {
        XCTAssertFalse(ToolExecutor.isSafeSkillName(""))
        XCTAssertFalse(ToolExecutor.isSafeSkillName("   "))
    }

    // MARK: - buildNarrationText

    func testBuildNarrationWrite() {
        let narration = ToolExecutor.buildNarrationText(
            toolName: "write", arguments: ["path": "/tmp/file.txt"]
        )
        XCTAssertNotNil(narration)
        XCTAssertTrue(narration!.contains("file.txt"))
    }

    func testBuildNarrationEdit() {
        let narration = ToolExecutor.buildNarrationText(
            toolName: "edit", arguments: ["path": "/tmp/config.toml"]
        )
        XCTAssertNotNil(narration)
        XCTAssertTrue(narration!.contains("config.toml"))
    }

    func testBuildNarrationBashMkdir() {
        let narration = ToolExecutor.buildNarrationText(
            toolName: "bash", arguments: ["command": "mkdir /tmp/newdir"]
        )
        XCTAssertNotNil(narration)
        XCTAssertTrue(narration!.contains("folder"))
    }

    func testBuildNarrationCalendarCreate() {
        let narration = ToolExecutor.buildNarrationText(
            toolName: "calendar", arguments: ["action": "create"]
        )
        XCTAssertNotNil(narration)
        XCTAssertTrue(narration!.contains("calendar"))
    }

    func testBuildNarrationRemindersComplete() {
        let narration = ToolExecutor.buildNarrationText(
            toolName: "reminders", arguments: ["action": "complete"]
        )
        XCTAssertNotNil(narration)
        XCTAssertTrue(narration!.contains("done"))
    }

    func testBuildNarrationSchedulerCreate() {
        let narration = ToolExecutor.buildNarrationText(
            toolName: "scheduler_create", arguments: [:]
        )
        XCTAssertEqual(narration, "I've scheduled that task.")
    }

    func testBuildNarrationUnknownTool() {
        let narration = ToolExecutor.buildNarrationText(
            toolName: "unknown_tool", arguments: [:]
        )
        XCTAssertNil(narration)
    }

    // MARK: - requiresCountdown

    func testRequiresCountdownMailSend() {
        XCTAssertTrue(ToolExecutor.requiresCountdown(
            toolName: "mail", arguments: ["action": "send"]
        ))
    }

    func testRequiresCountdownMailRead() {
        XCTAssertFalse(ToolExecutor.requiresCountdown(
            toolName: "mail", arguments: ["action": "check_inbox"]
        ))
    }

    func testRequiresCountdownDelegateAgent() {
        XCTAssertTrue(ToolExecutor.requiresCountdown(
            toolName: "delegate_agent", arguments: [:]
        ))
    }

    func testRequiresCountdownNormalTool() {
        XCTAssertFalse(ToolExecutor.requiresCountdown(
            toolName: "web_search", arguments: [:]
        ))
    }

    // MARK: - buildCountdownText

    func testBuildCountdownMailSend() {
        let text = ToolExecutor.buildCountdownText(
            toolName: "mail", arguments: ["action": "send"]
        )
        XCTAssertTrue(text.contains("5 seconds"))
        XCTAssertTrue(text.contains("stop to cancel"))
    }

    func testBuildCountdownMailReply() {
        let text = ToolExecutor.buildCountdownText(
            toolName: "mail", arguments: ["action": "reply"]
        )
        XCTAssertTrue(text.contains("reply"))
    }

    func testBuildCountdownDelegateAgent() {
        let text = ToolExecutor.buildCountdownText(
            toolName: "delegate_agent", arguments: [:]
        )
        XCTAssertFalse(text.isEmpty)
    }
}
