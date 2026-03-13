import XCTest
@testable import Fae

final class PersonalityContractTests: XCTestCase {
    private var tempDirectory: URL!
    private var originalSoulOverride: URL?
    private var originalHeartbeatOverride: URL?

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-personality-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        originalSoulOverride = SoulManager.userSoulURLOverride
        originalHeartbeatOverride = HeartbeatManager.userHeartbeatURLOverride
        SoulManager.userSoulURLOverride = tempDirectory.appendingPathComponent("soul.md")
        HeartbeatManager.userHeartbeatURLOverride = tempDirectory.appendingPathComponent("heartbeat.md")
    }

    override func tearDownWithError() throws {
        SoulManager.userSoulURLOverride = originalSoulOverride
        HeartbeatManager.userHeartbeatURLOverride = originalHeartbeatOverride
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testSoulManagerSupportsSaveLoadResetAndModifiedState() throws {
        XCTAssertFalse(SoulManager.isModified)

        let custom = "# SOUL\nBe warm and steady."
        try SoulManager.saveSoul(custom)

        XCTAssertEqual(SoulManager.loadSoul(), custom)
        XCTAssertTrue(SoulManager.isModified)
        XCTAssertEqual(SoulManager.lineCount, custom.components(separatedBy: .newlines).count)

        try SoulManager.resetToDefault()

        XCTAssertEqual(SoulManager.loadSoul(), SoulManager.defaultSoul())
        XCTAssertFalse(SoulManager.isModified)
    }

    func testHeartbeatManagerSupportsEnsureCopySaveLoadResetAndModifiedState() throws {
        let heartbeatURL = try XCTUnwrap(HeartbeatManager.userHeartbeatURLOverride)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heartbeatURL.path))

        HeartbeatManager.ensureUserCopy()
        XCTAssertTrue(FileManager.default.fileExists(atPath: heartbeatURL.path))
        XCTAssertFalse(HeartbeatManager.isModified)

        let custom = "# HEARTBEAT\nStay quiet until the moment matters."
        try HeartbeatManager.saveHeartbeat(custom)

        XCTAssertEqual(HeartbeatManager.loadHeartbeat(), custom)
        XCTAssertTrue(HeartbeatManager.isModified)
        XCTAssertEqual(HeartbeatManager.lineCount, custom.components(separatedBy: .newlines).count)

        try HeartbeatManager.resetToDefault()

        XCTAssertEqual(HeartbeatManager.loadHeartbeat(), HeartbeatManager.defaultHeartbeat())
        XCTAssertFalse(HeartbeatManager.isModified)
    }

    func testAssemblePromptIncludesSoulAndHeartbeatContracts() {
        let prompt = PersonalityManager.assemblePrompt(
            voiceOptimized: true,
            soulContract: "SOUL CONTRACT",
            heartbeatContract: "HEARTBEAT CONTRACT",
            nativeToolsAvailable: false,
            includeEphemeralContext: false
        )

        XCTAssertTrue(prompt.contains("SOUL CONTRACT"))
        XCTAssertTrue(prompt.contains("HEARTBEAT CONTRACT"))
    }

    func testWorkWithFaeGuideMakesRemoteTrustBoundaryExplicit() throws {
        let guide = try loadRepositoryText(relativePath: "docs/guides/work-with-fae.md")

        XCTAssertTrue(guide.contains("remote models do **not** get direct access to local tools"))
        XCTAssertTrue(guide.contains("remote models do **not** get your files, apps, or approvals directly"))
        XCTAssertTrue(guide.contains("only Fae Local owns tool execution, approval prompts, local grounding, and memory writes"))
    }

    func testReadmeKeepsRemoteProviderClaimsHonest() throws {
        let readme = try loadRepositoryText(relativePath: "README.md")

        XCTAssertTrue(readme.contains("Work with Fae can optionally connect selected remote providers"))
        XCTAssertTrue(readme.contains("remote models never get direct local tool access"))
        XCTAssertFalse(readme.contains("No cloud. No API keys. No data ever leaves your Mac."))
    }

    func testSystemPromptKeepsSensitiveScopeLocalOnlyPolicy() throws {
        let systemPrompt = try loadRepositoryText(relativePath: "Prompts/system_prompt.md")

        XCTAssertTrue(systemPrompt.contains("For any task that touches sensitive scope, use only Fae local brain and Fae internal local tools."))
        XCTAssertTrue(systemPrompt.contains("Never send sensitive scope to third-party models or services."))
        XCTAssertTrue(systemPrompt.contains("Do not delegate sensitive tasks to `codex` or `claude`"))
    }

    func testHeartbeatContractPreservesQuietProgressiveUsefulnessRules() throws {
        let heartbeat = try loadRepositoryText(relativePath: "HEARTBEAT.md")

        XCTAssertTrue(heartbeat.contains("## Quiet by Default"))
        XCTAssertTrue(heartbeat.contains("Interrupt only for urgent, high-signal reasons."))
        XCTAssertTrue(heartbeat.contains("Batch non-urgent updates into briefings, summaries, or the next natural opening."))
        XCTAssertTrue(heartbeat.contains("## Progressive Disclosure"))
        XCTAssertTrue(heartbeat.contains("Show the lightest useful surface first."))
        XCTAssertTrue(heartbeat.contains("Skills start as name + description only; load full skill instructions only after `activate_skill`."))
        XCTAssertTrue(heartbeat.contains("Channel setup should ask for one missing field at a time"))
        XCTAssertTrue(heartbeat.contains("## Progressive Permissions"))
        XCTAssertTrue(heartbeat.contains("Prefer that popup over sending people into Settings for ordinary approval decisions."))
        XCTAssertTrue(heartbeat.contains("Morning briefings should be short, warm, and action-oriented."))
        XCTAssertTrue(heartbeat.contains("Follow-ups should attach to the originating thread of intent"))
        XCTAssertTrue(heartbeat.contains("Setup should feel conversational, not like a control panel."))
    }

    func testSoulContractPreservesQuietRespectfulAndAntiNagPresence() throws {
        let soul = try loadRepositoryText(relativePath: "SOUL.md")

        XCTAssertTrue(soul.contains("Fae is there when you need her and quiet when you don't."))
        XCTAssertTrue(soul.contains("If she's not sure she's being addressed, she stays quiet."))
        XCTAssertTrue(soul.contains("She does not interject into third-party conversations"))
        XCTAssertTrue(soul.contains("Morning briefings only, no mid-conversation interrupts unless something's actually urgent."))
        XCTAssertTrue(soul.contains("One mention. No nagging."))
        XCTAssertTrue(soul.contains("She earns more presence over time. Trust builds slowly"))
        XCTAssertTrue(soul.contains("Briefings feel like a friend catching you up over coffee"))
    }

    func testSoulDocumentReferencesTruthSources() throws {
        let soul = try loadRepositoryText(relativePath: "SOUL.md")

        XCTAssertTrue(soul.contains("## Truth Sources"))
        XCTAssertTrue(soul.contains("Prompts/system_prompt.md"))
        XCTAssertTrue(soul.contains("docs/guides/Memory.md"))
    }

    func testAssembledPromptPreservesSkillConfirmationAndSecretSafeSetupRules() {
        let prompt = PersonalityManager.assemblePrompt(
            voiceOptimized: false,
            soulContract: "SOUL CONTRACT",
            heartbeatContract: "HEARTBEAT CONTRACT",
            nativeToolsAvailable: true,
            includeEphemeralContext: false
        )

        XCTAssertTrue(prompt.contains("Before creating a new skill, ask the user for confirmation."))
        XCTAssertTrue(prompt.contains("Use manage_skill update to modify existing personal skill behavior."))
        XCTAssertTrue(prompt.contains("Use manage_skill patch for surgical body edits"))
        XCTAssertTrue(prompt.contains("Use manage_skill list_drafts / show_draft"))
        XCTAssertTrue(prompt.contains("collect them with input_request + store_key"))
        XCTAssertTrue(prompt.contains("secrets stay out of chat history"))
    }

    func testVisibleSkillAndApprovalCopyPreservesProgressiveDisclosure() throws {
        let skillsTab = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/SettingsSkillsTab.swift")
        let approvalOverlay = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/ApprovalOverlayView.swift")

        XCTAssertTrue(skillsTab.contains("Personal skills are first-class here: create, edit, import, and remove them directly."))
        XCTAssertTrue(skillsTab.contains("Built-in and Apple integrations are still available, but tucked away so the screen stays focused."))
        XCTAssertTrue(approvalOverlay.contains("Use the popup to confirm. Settings are for review and revocation."))
    }

    private func loadRepositoryText(relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
