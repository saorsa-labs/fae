import XCTest
@testable import Fae

final class SkillParserTests: XCTestCase {

    // MARK: - splitFrontmatter

    func testSplitFrontmatterValid() {
        let content = """
        ---
        name: test-skill
        description: A test skill
        ---
        This is the body content.
        """
        let (metadata, body) = SkillParser.splitFrontmatter(content)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?["name"], "test-skill")
        XCTAssertNotNil(body)
        XCTAssertTrue(body!.contains("body content"))
    }

    func testSplitFrontmatterNoFrontmatter() {
        let content = "Just plain text without frontmatter"
        let (metadata, body) = SkillParser.splitFrontmatter(content)
        XCTAssertNil(metadata)
        XCTAssertEqual(body, content)
    }

    func testSplitFrontmatterEmpty() {
        // No frontmatter delimiter: the whole content (here empty) is the body.
        let (metadata, body) = SkillParser.splitFrontmatter("")
        XCTAssertNil(metadata)
        XCTAssertEqual(body, "")
    }

    func testSplitFrontmatterMinimal() {
        let content = """
        ---
        name: hello
        ---
        """
        let (metadata, body) = SkillParser.splitFrontmatter(content)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?["name"], "hello")
    }

    // MARK: - parseSimpleYAML

    func testParseSimpleYAML() {
        let lines = ["name: test", "version: 1.0"]
        let result = SkillParser.parseSimpleYAML(lines)
        XCTAssertEqual(result["name"], "test")
        XCTAssertEqual(result["version"], "1.0")
    }

    func testParseSimpleYAMLEmpty() {
        let result = SkillParser.parseSimpleYAML([])
        XCTAssertTrue(result.isEmpty)
    }


}
