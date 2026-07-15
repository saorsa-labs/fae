import XCTest
@testable import Fae

final class SkillManagerStaticTests: XCTestCase {

    // MARK: - isSafeSkillName

    func testIsSafeSkillNameValid() {
        XCTAssertTrue(SkillManager.isSafeSkillName("my-skill"))
        XCTAssertTrue(SkillManager.isSafeSkillName("my_skill"))
        XCTAssertTrue(SkillManager.isSafeSkillName("MySkill123"))
    }

    func testIsSafeSkillNameInvalidPath() {
        XCTAssertFalse(SkillManager.isSafeSkillName("../evil"))
        XCTAssertFalse(SkillManager.isSafeSkillName("/etc/passwd"))
    }

    func testIsSafeSkillNameEmpty() {
        XCTAssertFalse(SkillManager.isSafeSkillName(""))
    }

    // MARK: - tierPriority

    func testTierPriorityBuiltIn() {
        let builtinP = SkillManager.tierPriority(.builtin)
        let personalP = SkillManager.tierPriority(.personal)
        XCTAssertLessThan(builtinP, personalP)
    }

    func testTierPriorityImported() {
        let communityP = SkillManager.tierPriority(.community)
        XCTAssertGreaterThanOrEqual(communityP, 0)
    }

    // MARK: - audioContextForSkill

    func testAudioContextForSkill() {
        let context = SkillManager.audioContextForSkill()
        XCTAssertFalse(context.isEmpty)
    }

    // MARK: - discoveryRoots

    func testDiscoveryRoots() {
        let roots = SkillManager.discoveryRoots()
        XCTAssertFalse(roots.isEmpty)
    }

    // MARK: - installedSkillNames

    func testInstalledSkillNames() {
        let names = SkillManager.installedSkillNames()
        // May be empty if no skills installed — just verify it doesn't crash
        _ = names
    }

    // MARK: - parseSkillMarkdown

    func testParseSkillMarkdownValid() throws {
        let content = """
        ---
        name: test-skill
        description: A test skill
        type: instruction
        ---
        This is the body.
        """
        let draft = try SkillManager.parseSkillMarkdown(content, fallbackName: "fallback")
        XCTAssertEqual(draft.name, "test-skill")
    }

    func testParseSkillMarkdownNoFrontmatter() {
        // parseSkillMarkdown enforces a strict contract: SKILL.md content
        // without YAML frontmatter is rejected, not silently repaired.
        let content = "Just plain text without frontmatter"
        XCTAssertThrowsError(
            try SkillManager.parseSkillMarkdown(content, fallbackName: "fallback-name")
        )
    }

    // MARK: - validateSkillName

    func testValidateSkillNameValid() throws {
        try SkillManager.validateSkillName("my-skill")
        // Should not throw
    }

    func testValidateSkillNameInvalidPath() {
        XCTAssertThrowsError(try SkillManager.validateSkillName("../evil"))
    }

    func testValidateSkillNameEmpty() {
        XCTAssertThrowsError(try SkillManager.validateSkillName(""))
    }

    // MARK: - validateScriptFileName

    func testValidateScriptFileNameValid() throws {
        try SkillManager.validateScriptFileName("script.py")
    }

    func testValidateScriptFileNameInvalid() {
        XCTAssertThrowsError(try SkillManager.validateScriptFileName("../evil.py"))
    }

    // MARK: - validateScriptContent

    func testValidateScriptContentValid() throws {
        try SkillManager.validateScriptContent("print('hello')")
    }

    // MARK: - isSafeEnvironmentVariableName

    func testIsSafeEnvVarValid() {
        XCTAssertTrue(SkillManager.isSafeEnvironmentVariableName("API_KEY"))
    }

    func testIsSafeEnvVarInvalid() {
        XCTAssertFalse(SkillManager.isSafeEnvironmentVariableName("api_key"))
    }

    // MARK: - isSensitiveKey

    func testIsSensitiveKeyToken() {
        XCTAssertTrue(SkillManager.isSensitiveKey("auth_token"))
    }

    func testIsSensitiveKeyPassword() {
        XCTAssertTrue(SkillManager.isSensitiveKey("password"))
    }

    func testIsSensitiveKeyNormal() {
        XCTAssertFalse(SkillManager.isSensitiveKey("filename"))
    }

    // MARK: - renderSkillMarkdown

    func testRenderSkillMarkdown() {
        let markdown = SkillManager.renderSkillMarkdown(name: "test", description: "A test skill", body: "# Content")
        XCTAssertTrue(markdown.contains("---"))
        XCTAssertTrue(markdown.contains("name: test"))
        XCTAssertTrue(markdown.contains("# Content"))
    }

    // MARK: - validateSkillMetadata

    func testValidateSkillMetadataValid() throws {
        try SkillManager.validateSkillMetadata(name: "test-skill", description: "A very good description here", body: "# This is a proper skill body with enough content")
    }

    func testValidateSkillMetadataShortDesc() {
        XCTAssertThrowsError(try SkillManager.validateSkillMetadata(name: "test", description: "short", body: "# This is a proper skill body with enough content"))
    }

    func testValidateSkillMetadataCredentialInBody() {
        XCTAssertThrowsError(try SkillManager.validateSkillMetadata(name: "test", description: "A very good description here", body: "# Body with api key in it and more text"))
    }

    // MARK: - sanitizeAny

    func testSanitizeAnyRedactsSensitiveKey() {
        let result = SkillManager.sanitizeAny(["token": "secret123"])
        if let dict = result as? [String: Any] {
            XCTAssertEqual(dict["token"] as? String, "[REDACTED_SECRET]")
        }
    }

    func testSanitizeAnyPreservesNormalKey() {
        let result = SkillManager.sanitizeAny(["filename": "test.txt"])
        if let dict = result as? [String: Any] {
            XCTAssertEqual(dict["filename"] as? String, "test.txt")
        }
    }

    // MARK: - sanitizeSkillInput

    func testSanitizeSkillInputRedactsSecrets() {
        let result = SkillManager.sanitizeSkillInput(["token": "secret", "name": "test"])
        XCTAssertEqual(result["token"] as? String, "[REDACTED_SECRET]")
        XCTAssertEqual(result["name"] as? String, "test")
    }

    func testSanitizeSkillInputEmpty() {
        let result = SkillManager.sanitizeSkillInput([:])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - firstDisallowedURL

    func testFirstDisallowedURLNotAllowed() {
        let url = SkillManager.firstDisallowedURL(in: "https://evil.com/path", allowedDomains: ["safe.com"])
        XCTAssertEqual(url, "https://evil.com/path")
    }

    func testFirstDisallowedURLAllowed() {
        let url = SkillManager.firstDisallowedURL(in: "https://safe.com/path", allowedDomains: ["safe.com"])
        XCTAssertNil(url)
    }

    // MARK: - firstBlockedURL

    func testFirstBlockedURLLocalhost() {
        let result = SkillManager.firstBlockedURL(in: "http://localhost/path")
        XCTAssertNotNil(result)
    }

    func testFirstBlockedURLPublic() {
        let result = SkillManager.firstBlockedURL(in: "https://example.com/path")
        XCTAssertNil(result)
    }

    // MARK: - activatedBodies LRU cap

    func testActivatedBodiesLRUCapEvictsOldest() async {
        let manager = SkillManager()
        // Activate 6 skills — cap is 5, so the first should be evicted.
        await manager.activateBodyDirectly(skillName: "s1", body: "body-1")
        await manager.activateBodyDirectly(skillName: "s2", body: "body-2")
        await manager.activateBodyDirectly(skillName: "s3", body: "body-3")
        await manager.activateBodyDirectly(skillName: "s4", body: "body-4")
        await manager.activateBodyDirectly(skillName: "s5", body: "body-5")
        await manager.activateBodyDirectly(skillName: "s6", body: "body-6")

        let keys = await manager.activatedBodyKeys()
        XCTAssertEqual(keys.count, 5, "LRU cap should keep exactly 5 activated skill bodies")
        XCTAssertFalse(keys.contains("s1"), "Oldest skill 's1' should have been evicted")
        XCTAssertTrue(keys.contains("s2"), "Second skill 's2' should be present")
        XCTAssertTrue(keys.contains("s6"), "Most recent skill 's6' should be present")
    }

    func testActivatedBodiesLRUCapUnderLimit() async {
        let manager = SkillManager()
        // Activating fewer than 5 should evict nothing.
        await manager.activateBodyDirectly(skillName: "a", body: "body-a")
        await manager.activateBodyDirectly(skillName: "b", body: "body-b")

        let keys = await manager.activatedBodyKeys()
        XCTAssertEqual(keys.count, 2, "No eviction should occur below the cap")
        XCTAssertTrue(keys.contains("a"))
        XCTAssertTrue(keys.contains("b"))
    }
}
