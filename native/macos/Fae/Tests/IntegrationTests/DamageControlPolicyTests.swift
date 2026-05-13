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
}
