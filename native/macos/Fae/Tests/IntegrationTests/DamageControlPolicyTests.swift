import XCTest
@testable import Fae

final class DamageControlPolicyTests: XCTestCase {

    // MARK: - isDestructiveShellCommand

    func testIsDestructiveRm() {
        XCTAssertTrue(DamageControlPolicy.isDestructiveShellCommand("rm -rf /tmp/test"))
    }

    func testIsDestructiveMv() {
        XCTAssertTrue(DamageControlPolicy.isDestructiveShellCommand("mv file1 file2"))
    }

    func testIsDestructiveNormal() {
        XCTAssertFalse(DamageControlPolicy.isDestructiveShellCommand("ls -la /tmp"))
    }

    func testIsDestructiveRemoveFile() {
        XCTAssertFalse(DamageControlPolicy.isDestructiveShellCommand("remove_file.sh"))
    }

    // MARK: - matches

    func testMatchesSimple() {
        XCTAssertTrue(DamageControlPolicy.matches(pattern: "\\d+", in: "hello 123 world"))
    }

    func testMatchesNoMatch() {
        XCTAssertFalse(DamageControlPolicy.matches(pattern: "\\d+", in: "no numbers here"))
    }

    func testMatchesInvalidPattern() {
        XCTAssertFalse(DamageControlPolicy.matches(pattern: "[invalid", in: "test"))
    }

    // MARK: - expandPath

    func testExpandPathTilde() {
        let expanded = DamageControlPolicy.expandPath("~/Documents")
        XCTAssertTrue(expanded.hasPrefix("/Users/"))
    }

    func testExpandPathNoTilde() {
        let expanded = DamageControlPolicy.expandPath("/tmp/test")
        XCTAssertEqual(expanded, "/tmp/test")
    }

    // MARK: - extractPath

    func testExtractPathRead() {
        let path = DamageControlPolicy.extractPath(toolName: "read", arguments: ["path": "/tmp/file.txt"])
        XCTAssertEqual(path, "/tmp/file.txt")
    }

    func testExtractPathWrite() {
        let path = DamageControlPolicy.extractPath(toolName: "write", arguments: ["file_path": "/tmp/out.txt"])
        XCTAssertEqual(path, "/tmp/out.txt")
    }

    func testExtractPathBash() {
        let path = DamageControlPolicy.extractPath(toolName: "bash", arguments: ["command": "ls"])
        XCTAssertNil(path)
    }

    // MARK: - commandTargetsPath

    func testCommandTargetsPathMatch() {
        XCTAssertTrue(DamageControlPolicy.commandTargetsPath(command: "cat /tmp/file.txt", expandedPath: "/tmp/file.txt"))
    }

    func testCommandTargetsPathNoMatch() {
        XCTAssertFalse(DamageControlPolicy.commandTargetsPath(command: "cat /other/file.txt", expandedPath: "/tmp/file.txt"))
    }
}
