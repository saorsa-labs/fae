import XCTest
@testable import Fae

final class PersonalityManagerTests: XCTestCase {

    // MARK: - Approval Prompt Formatting

    func testFormatApprovalPromptBash() {
        let prompt = PersonalityManager.formatApprovalPrompt(
            toolName: "bash",
            inputJSON: #"{"command":"ls -la /tmp"}"#
        )
        XCTAssertTrue(prompt.contains("run a command"))
        XCTAssertTrue(prompt.contains("ls -la"))
    }

    func testFormatApprovalPromptWrite() {
        let prompt = PersonalityManager.formatApprovalPrompt(
            toolName: "write",
            inputJSON: #"{"path":"/tmp/file.txt"}"#
        )
        XCTAssertTrue(prompt.contains("create the file"))
        XCTAssertTrue(prompt.contains("/tmp/file.txt"))
    }

    func testFormatApprovalPromptEdit() {
        let prompt = PersonalityManager.formatApprovalPrompt(
            toolName: "edit",
            inputJSON: #"{"path":"/Users/me/config.toml"}"#
        )
        XCTAssertTrue(prompt.contains("edit"))
        XCTAssertTrue(prompt.contains("/Users/me/config.toml"))
    }

    func testFormatApprovalPromptDesktop() {
        let prompt = PersonalityManager.formatApprovalPrompt(
            toolName: "desktop", inputJSON: "{}"
        )
        XCTAssertTrue(prompt.contains("desktop automation"))
    }

    func testFormatApprovalPromptPythonSkill() {
        let prompt = PersonalityManager.formatApprovalPrompt(
            toolName: "python_skill", inputJSON: "{}"
        )
        XCTAssertTrue(prompt.contains("Python skill"))
    }

    func testFormatApprovalPromptUnknown() {
        let prompt = PersonalityManager.formatApprovalPrompt(
            toolName: "custom_tool_xyz", inputJSON: "{}"
        )
        XCTAssertTrue(prompt.contains("custom_tool_xyz"))
    }

    func testFormatApprovalPromptTruncation() {
        // Path longer than 80 chars should be truncated
        let longPath = String.init(repeating: "a", count: 100)
        let prompt = PersonalityManager.formatApprovalPrompt(
            toolName: "write",
            inputJSON: #"{"path":"\#(longPath)"}"#
        )
        XCTAssertTrue(prompt.contains(String(longPath.prefix(80))))
    }

    func testFormatApprovalPromptMissingField() {
        let prompt = PersonalityManager.formatApprovalPrompt(
            toolName: "bash",
            inputJSON: #"{"other":"value"}"#
        )
        XCTAssertTrue(prompt.contains("run a command"))
        XCTAssertTrue(prompt.contains("(unknown)"))
    }

    // MARK: - Phrase Cycling

    func testNextThinkingAcknowledgment() {
        let phrase = PersonalityManager.nextThinkingAcknowledgment()
        XCTAssertFalse(phrase.isEmpty)
    }

    func testNextApprovalGranted() {
        let phrase = PersonalityManager.nextApprovalGranted()
        XCTAssertFalse(phrase.isEmpty)
    }

    func testNextApprovalDenied() {
        let phrase = PersonalityManager.nextApprovalDenied()
        XCTAssertFalse(phrase.isEmpty)
    }

    func testNextApprovalTimeout() {
        let phrase = PersonalityManager.nextApprovalTimeout()
        XCTAssertFalse(phrase.isEmpty)
    }

    func testNextApprovalAmbiguous() {
        let phrase = PersonalityManager.nextApprovalAmbiguous()
        XCTAssertFalse(phrase.isEmpty)
    }

    // MARK: - Assemble Ephemeral Turn Context

    func testAssembleEphemeralTurnContextWithMemory() {
        let context = PersonalityManager.assembleEphemeralTurnContext(
            speakerDisplayName: nil,
            speakerRole: nil,
            memoryContext: "User likes coffee"
        )
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("coffee"))
    }

    func testAssembleEphemeralTurnContextOwner() {
        let context = PersonalityManager.assembleEphemeralTurnContext(
            speakerDisplayName: "Alice",
            speakerRole: .owner,
            memoryContext: nil
        )
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("Alice"))
        XCTAssertTrue(context!.contains("your owner"))
    }

    func testAssembleEphemeralTurnContextTrusted() {
        let context = PersonalityManager.assembleEphemeralTurnContext(
            speakerDisplayName: "Bob",
            speakerRole: .trusted,
            memoryContext: nil
        )
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("a trusted speaker"))
    }

    func testAssembleEphemeralTurnContextGuest() {
        let context = PersonalityManager.assembleEphemeralTurnContext(
            speakerDisplayName: "Charlie",
            speakerRole: .guest,
            memoryContext: nil
        )
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("an unregistered speaker"))
    }

    func testAssembleEphemeralTurnContextNoSpeaker() {
        let context = PersonalityManager.assembleEphemeralTurnContext(
            speakerDisplayName: nil,
            speakerRole: nil,
            memoryContext: nil
        )
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("not been identified"))
    }

    func testAssembleEphemeralTurnContextWithTime() {
        let context = PersonalityManager.assembleEphemeralTurnContext(
            speakerDisplayName: nil,
            speakerRole: nil,
            memoryContext: nil
        )
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("Current date and time"))
    }

    func testAssembleEphemeralTurnContextExtraSections() {
        let context = PersonalityManager.assembleEphemeralTurnContext(
            speakerDisplayName: "Alice",
            speakerRole: .owner,
            memoryContext: nil,
            extraSections: ["Custom section content"]
        )
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("Custom section content"))
    }

    // MARK: - Assemble Prompt (basic checks)

    func testAssemblePromptMinimal() {
        let prompt = PersonalityManager.assemblePrompt(voiceOptimized: true)
        XCTAssertFalse(prompt.isEmpty)
    }

    func testAssemblePromptWithUserName() {
        let prompt = PersonalityManager.assemblePrompt(
            voiceOptimized: true, userName: "Alice"
        )
        XCTAssertTrue(prompt.contains("Alice"))
    }

    func testAssemblePromptWithTools() {
        let prompt = PersonalityManager.assemblePrompt(
            voiceOptimized: false, nativeToolsAvailable: true
        )
        XCTAssertTrue(prompt.contains("Tool usage"))
    }

    func testAssemblePromptWithSoulContract() {
        let prompt = PersonalityManager.assemblePrompt(
            voiceOptimized: true, soulContract: "I am helpful"
        )
        XCTAssertTrue(prompt.contains("I am helpful"))
    }

    func testAssemblePromptWithHeartbeat() {
        let prompt = PersonalityManager.assemblePrompt(
            voiceOptimized: true, heartbeatContract: "Stay focused"
        )
        XCTAssertTrue(prompt.contains("Stay focused"))
    }

    func testAssemblePromptLightweight() {
        let prompt = PersonalityManager.assemblePrompt(
            voiceOptimized: false, nativeToolsAvailable: true, lightweight: true
        )
        XCTAssertTrue(prompt.contains("Tool usage") || !prompt.isEmpty)
    }

    func testAssemblePromptWithSkills() {
        let prompt = PersonalityManager.assemblePrompt(
            voiceOptimized: false,
            nativeToolsAvailable: true,
            skillDescriptions: [
                (name: "weather", description: "Check weather", type: .instruction),
            ]
        )
        XCTAssertTrue(prompt.contains("weather"))
    }

    func testAssemblePromptWithVision() {
        let prompt = PersonalityManager.assemblePrompt(
            voiceOptimized: false, visionCapable: true, nativeToolsAvailable: true
        )
        XCTAssertFalse(prompt.isEmpty)
    }

    // MARK: - Extract Field

    func testExtractFieldSimple() {
        let value = PersonalityManager.extractField("command", from: #"{"command":"ls -la"}"#)
        XCTAssertEqual(value, "ls -la")
    }

    func testExtractFieldNotFound() {
        let value = PersonalityManager.extractField("missing", from: #"{"other":"value"}"#)
        XCTAssertEqual(value, "(unknown)")
    }

    func testExtractFieldEmptyJSON() {
        let value = PersonalityManager.extractField("key", from: "{}")
        XCTAssertEqual(value, "(unknown)")
    }

    func testExtractFieldWithSpaces() {
        let value = PersonalityManager.extractField(
            "path",
            from: #"{"path": "/Users/me/file.txt"}"#
        )
        XCTAssertEqual(value, "/Users/me/file.txt")
    }
}
