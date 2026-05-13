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
}
