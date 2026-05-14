import XCTest
@testable import Fae

final class SkillImportViewTests: XCTestCase {

    // MARK: - normalizeGitHubURL

    func testNormalizeGitHubBlob() {
        let url = SkillImportView.normalizeGitHubURL("https://github.com/user/repo/blob/main/path/SKILL.md")
        XCTAssertTrue(url.contains("raw.githubusercontent.com"))
    }

    func testNormalizeGitHubRepo() {
        let url = SkillImportView.normalizeGitHubURL("https://github.com/user/repo")
        XCTAssertTrue(url.contains("/main/SKILL.md"))
    }

    func testNormalizeNonGitHub() {
        let url = SkillImportView.normalizeGitHubURL("https://example.com/path")
        XCTAssertEqual(url, "https://example.com/path")
    }

    // MARK: - extractFrontmatterName

    func testExtractFrontmatterName() {
        let content = "---\nname: my-skill\n---\nBody"
        let name = SkillImportView.extractFrontmatterName(from: content)
        XCTAssertEqual(name, "my-skill")
    }

    func testExtractFrontmatterNameNone() {
        let name = SkillImportView.extractFrontmatterName(from: "no frontmatter")
        XCTAssertNil(name)
    }
}
