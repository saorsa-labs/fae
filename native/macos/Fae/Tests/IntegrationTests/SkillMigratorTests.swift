import XCTest
@testable import Fae

final class SkillMigratorTests: XCTestCase {

    // MARK: - normalizeSkillMarkdown

    func testNormalizeSkillMarkdown() {
        let content = """
        ---
        name: test-skill
        description: A test skill
        type: instruction
        ---
        This is the body.
        """
        let normalized = SkillMigrator.normalizeSkillMarkdown(name: "test", content: content)
        XCTAssertFalse(normalized.isEmpty)
    }

    func testNormalizeSkillMarkdownEmpty() {
        let normalized = SkillMigrator.normalizeSkillMarkdown(name: "test", content: "")
        XCTAssertTrue(normalized.isEmpty || !normalized.contains("---"))
    }

    // MARK: - inferredSkillName

    func testInferredSkillNameWithFrontmatter() {
        let content = "---\nname: my-skill\ntype: instruction\n---\nBody"
        let name = SkillMigrator.inferredSkillName(from: content)
        XCTAssertEqual(name, "my-skill")
    }

    func testInferredSkillNameNoFrontmatter() {
        let name = SkillMigrator.inferredSkillName(from: "Just plain text")
        XCTAssertNil(name)
    }

    func testInferredSkillNameQuotedName() {
        let content = "---\nname: \"quoted-skill\"\n---\nBody"
        let name = SkillMigrator.inferredSkillName(from: content)
        XCTAssertEqual(name, "quoted-skill")
    }
}
