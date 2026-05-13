import XCTest
@testable import Fae

final class WorkWithFaeWorkspaceTests: XCTestCase {

    // MARK: - kindForFile

    func testKindForFileFolder() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test"), isDirectory: true), "folder")
    }

    func testKindForFileSwift() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test.swift"), isDirectory: false), "text")
    }

    func testKindForFileImage() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test.png"), isDirectory: false), "image")
    }

    func testKindForFilePDF() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test.pdf"), isDirectory: false), "document")
    }

    func testKindForFileUnknownExt() {
        XCTAssertEqual(WorkWithFaeFileEntry.kindForFile(url: URL(fileURLWithPath: "/test.xyz"), isDirectory: false), "xyz")
    }

    // MARK: - duplicatedWorkspaceName

    func testDuplicatedWorkspaceNameSimple() {
        let name = WorkWithFaeWorkspaceStore.duplicatedWorkspaceName(from: "My Workspace", existingNames: [])
        XCTAssertEqual(name, "My Workspace Fork")
    }

    func testDuplicatedWorkspaceNameConflict() {
        let name = WorkWithFaeWorkspaceStore.duplicatedWorkspaceName(from: "My Workspace", existingNames: ["my workspace fork"])
        XCTAssertEqual(name, "My Workspace Fork 2")
    }

    func testDuplicatedWorkspaceNameMultipleConflicts() {
        let name = WorkWithFaeWorkspaceStore.duplicatedWorkspaceName(from: "My Workspace", existingNames: ["my workspace fork", "my workspace fork 2"])
        XCTAssertEqual(name, "My Workspace Fork 3")
    }
}
