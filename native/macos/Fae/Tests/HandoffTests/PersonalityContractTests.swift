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

    func testSoulDocumentReferencesTruthSources() throws {
        let soul = try loadRepositoryText(relativePath: "SOUL.md")

        XCTAssertTrue(soul.contains("## Truth Sources"))
        XCTAssertTrue(soul.contains("Prompts/system_prompt.md"))
        XCTAssertTrue(soul.contains("docs/guides/Memory.md"))
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
