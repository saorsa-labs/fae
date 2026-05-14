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

    func testParseSkillMarkdownNoFrontmatter() throws {
        let content = "Just plain text without frontmatter"
        let draft = try SkillManager.parseSkillMarkdown(content, fallbackName: "fallback-name")
        XCTAssertEqual(draft.name, "fallback-name")
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
}
