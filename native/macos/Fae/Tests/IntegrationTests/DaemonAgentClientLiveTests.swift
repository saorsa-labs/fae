import XCTest
@testable import Fae

/// Live proof for gap A1: exercises the real `DaemonAgentClient` Swift code
/// against a running `fae-daemon`. Gated behind `FAE_ACP_LIVE=1` so it never
/// runs in CI or a normal `swift test` (it needs a live daemon + an installed,
/// authenticated external agent CLI).
///
/// Run:
///   1. Launch a daemon (lazy sidecar serves the socket immediately):
///      `cd crates && env -u RUSTFLAGS FAE_DEV=1 FAE_MODELS_LOCK=off \
///         FAE_LLAMACPP_RUNTIME_DIR=<…/Resources/LlamaCpp> \
///         ./target/debug/fae-daemon`
///   2. `FAE_ACP_LIVE=1 swift test --filter DaemonAgentClientLiveTests`
final class DaemonAgentClientLiveTests: XCTestCase {

    func testDelegateToGeminiViaDaemon() async throws {
        guard ProcessInfo.processInfo.environment["FAE_ACP_LIVE"] == "1" else {
            throw XCTSkip("set FAE_ACP_LIVE=1 with a running daemon to run this live test")
        }

        // Mirror what FaeCore does: publish the live daemon endpoints so the
        // stateless tool/client can open its own authenticated connection.
        let runDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/fae/run", isDirectory: true)
        let socketPath = runDir.appendingPathComponent("fae-daemon.sock").path
        let tokenPath = runDir.appendingPathComponent("bootstrap.token").path
        await DaemonEndpointStore.shared.set((socketPath: socketPath, tokenPath: tokenPath))
        defer { Task { await DaemonEndpointStore.shared.set(nil) } }

        let agent = ProcessInfo.processInfo.environment["FAE_ACP_LIVE_AGENT"] ?? "gemini"
        let outcome = try await DaemonAgentClient.run(
            agent: agent,
            prompt: "Reply with exactly the single word: pong",
            cwd: "/tmp"
        )

        // The agent's own model phrasing varies; assert the daemon round-trip
        // produced a real turn (non-empty text + a stop reason), which proves
        // the Swift socket → auth → agent.run → parse path end to end.
        XCTAssertFalse(
            outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "expected non-empty delegate text, got: \(outcome.text)")
        XCTAssertFalse(outcome.stopReason.isEmpty)
    }
}
