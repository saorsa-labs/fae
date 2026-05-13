import XCTest
@testable import Fae

final class ToolAugmentationManagerTests: XCTestCase {

    // MARK: - availableToolsSummary

    func testAvailableToolsSummaryEmpty() {
        let summary = ToolAugmentationManager.availableToolsSummary(installed: [:])
        XCTAssertTrue(summary.contains("No augmented CLI tools"))
    }

    func testAvailableToolsSummaryWithTools() {
        let summary = ToolAugmentationManager.availableToolsSummary(
            installed: ["fd": "/usr/local/bin/fd"]
        )
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("CLI tools available"))
    }

    // MARK: - promptFragment

    func testPromptFragmentEmpty() {
        let fragment = ToolAugmentationManager.promptFragment(installed: [:])
        XCTAssertNil(fragment)
    }

    func testPromptFragmentWithTools() {
        let fragment = ToolAugmentationManager.promptFragment(
            installed: ["fd": "/usr/local/bin/fd", "rg": "/usr/local/bin/rg"]
        )
        XCTAssertNotNil(fragment)
        XCTAssertTrue(fragment!.contains("fd"))
        XCTAssertTrue(fragment!.contains("rg"))
    }

    func testPromptFragmentWithJQ() {
        let fragment = ToolAugmentationManager.promptFragment(
            installed: ["jq": "/usr/local/bin/jq"]
        )
        XCTAssertNotNil(fragment)
        XCTAssertTrue(fragment!.contains("jq"))
    }

    // MARK: - formatProjectsForMemory

    func testFormatProjectsForMemoryEmpty() {
        let text = ToolAugmentationManager.formatProjectsForMemory([])
        XCTAssertTrue(text.isEmpty || text.contains("No projects"))
    }

    func testFormatProjectsForMemoryWithProjects() {
        let project = ToolAugmentationManager.DiscoveredProject(
            name: "test-project",
            path: "/tmp/test-project",
            projectType: "rust",
            gitRemote: "https://github.com/test/test-project"
        )
        let text = ToolAugmentationManager.formatProjectsForMemory([project])
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.contains("test-project"))
    }

    // MARK: - checkInstalled

    func testCheckInstalled() {
        let installed = ToolAugmentationManager.checkInstalled()
        // Just verify it returns a dictionary (may be empty)
        XCTAssertFalse(installed is NSNull)
    }

    // MARK: - invalidateCache

    func testInvalidateCache() {
        ToolAugmentationManager.invalidateCache()
        // Should not crash
    }

    // MARK: - packageManagerBinary

    func testPackageManagerBinary() {
        let binary = ToolAugmentationManager.packageManagerBinary()
        // May be nil if no package manager installed
        if let binary {
            XCTAssertFalse(binary.isEmpty)
        }
    }
}
