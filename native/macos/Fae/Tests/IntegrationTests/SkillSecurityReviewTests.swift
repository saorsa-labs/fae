import XCTest
@testable import Fae

final class SkillSecurityReviewTests: XCTestCase {

    // MARK: - normalizeSkillURL

    func testNormalizeGitHubBlob() {
        let url = URL(string: "https://github.com/user/repo/blob/main/file.py")!
        let normalized = SkillImportService.normalizeSkillURL(url)
        XCTAssertTrue(normalized.host == "raw.githubusercontent.com")
    }

    func testNormalizeNonGitHub() {
        let url = URL(string: "https://example.com/path/file.py")!
        let normalized = SkillImportService.normalizeSkillURL(url)
        XCTAssertEqual(normalized, url)
    }
}
