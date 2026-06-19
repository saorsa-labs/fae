// End-to-end smoke test exercising the production ACPSessionManager code path
// against locally-installed coding agents (codex, pi, etc.) via acpx.
//
// Gated by RUN_ACP_SMOKE=1 because it:
//   - launches real `acpx` subprocesses (~10-30 seconds per agent)
//   - depends on network (the agents call OpenAI/Google/Anthropic backends)
//   - requires agents to be authenticated (claude is intentionally skipped —
//     it needs interactive /login first; see scripts/smoke-acp.sh)
//
// Run via:  just smoke-acp-swift
//      or:  RUN_ACP_SMOKE=1 swift test --filter IntegrationTests.ACPSmokeTests
//
// Both layers (scripts/smoke-acp.sh and this XCTest) drive the same underlying
// `acpx <agent> exec <prompt>` form per turn — the shell harness invokes it
// directly, while this test goes through ACPSessionManager which composes the
// args and parses the NDJSON output. The original "persistent-session daemon"
// design ACPSessionManager once attempted (writing JSON-RPC to acpx's stdin)
// did not work — see the ACPSessionManager class-level doc for the full story.

import XCTest
@testable import Fae

final class ACPSmokeTests: XCTestCase {

    private static var smokeEnabled: Bool {
        ProcessInfo.processInfo.environment["RUN_ACP_SMOKE"] == "1"
    }

    override func setUpWithError() throws {
        guard Self.smokeEnabled else {
            throw XCTSkip("RUN_ACP_SMOKE=1 not set — skipping live ACP smoke (sets up subprocess + network).")
        }
    }

    // MARK: - agent_session (ACPSessionManager — multi-turn via acpx)

    func testCodexRoundTrip() async throws {
        try await runSmoke(agent: "codex", expectInResponse: "pong")
    }

    func testPiRoundTrip() async throws {
        try await runSmoke(agent: "pi", expectInResponse: "pong")
    }

    // MARK: - delegate_agent (AgentDelegateTool — one-shot, direct CLI)

    func testDelegateCodex() async throws {
        try await runDelegateSmoke(provider: "codex", expectInResponse: "pong")
    }

    func testDelegatePi() async throws {
        try await runDelegateSmoke(provider: "pi", expectInResponse: "pong")
    }

    // MARK: - Helpers

    /// Drives the daemon's native ACP session lifecycle (gap A2) — the same path
    /// Fae's AgentSessionTool uses: `agent.session_start → agent.prompt →
    /// agent.close`. Requires a running daemon (endpoints resolved from the
    /// default run dir). Asserts a non-empty response containing the expected
    /// substring and a non-error stop reason.
    private func runSmoke(
        agent: String,
        prompt: String = "Reply with the single word 'pong' and nothing else.",
        expectInResponse: String,
        timeout: TimeInterval = 90
    ) async throws {
        // Publish the live daemon endpoints so DaemonAgentClient can connect
        // (mirrors what FaeCore does at runtime).
        let runDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/fae/run", isDirectory: true)
        await DaemonEndpointStore.shared.set((
            socketPath: runDir.appendingPathComponent("fae-daemon.sock").path,
            tokenPath: runDir.appendingPathComponent("bootstrap.token").path))

        // Run from /tmp so agents that scan their cwd (e.g. pi) don't go off
        // exploring the Fae project tree and pad the response with markdown.
        let sessionId: String
        do {
            sessionId = try await DaemonAgentClient.sessionStart(
                agent: agent, cwd: "/tmp", approvalPolicy: "approve_all")
        } catch {
            XCTFail("sessionStart(\(agent)) threw: \(error)")
            return
        }
        addTeardownBlock { try? await DaemonAgentClient.sessionClose(sessionId: sessionId) }

        let outcome: DaemonAgentClient.Outcome
        do {
            outcome = try await withTimeout(seconds: timeout) {
                try await DaemonAgentClient.sessionPrompt(sessionId: sessionId, prompt: prompt)
            }
        } catch {
            XCTFail("prompt(\(agent)) threw: \(error)")
            return
        }

        XCTAssertFalse(outcome.text.isEmpty, "\(agent) returned empty text")
        XCTAssertTrue(
            outcome.text.lowercased().contains(expectInResponse.lowercased()),
            "\(agent) response missing expected substring '\(expectInResponse)'. Got: \(outcome.text.prefix(200))"
        )
        XCTAssertNotEqual(
            outcome.stopReason.lowercased(),
            "error",
            "\(agent) stop_reason=error: \(outcome.text.prefix(200))"
        )

        print("  [\(agent)] stopReason=\(outcome.stopReason) bytes=\(outcome.text.count) excerpt=\"\(outcome.text.prefix(80))\"")
    }

    /// One-shot delegation via AgentDelegateTool. Bypasses acpx — directly invokes
    /// `<provider> exec/-p/--print` per the provider's case in ExternalAgentDelegate.
    private func runDelegateSmoke(
        provider: String,
        prompt: String = "Reply with the single word 'pong' and nothing else.",
        expectInResponse: String,
        timeout: TimeInterval = 90
    ) async throws {
        let tool = AgentDelegateTool()
        let cwd = "/tmp"
        let input: [String: Any] = [
            "provider": provider,
            "mode": "read_only",
            "workdir": cwd,
            "prompt": prompt,
        ]

        let result: ToolResult
        do {
            result = try await withTimeout(seconds: timeout) {
                try await tool.execute(input: input)
            }
        } catch {
            XCTFail("delegate(\(provider)) threw: \(error)")
            return
        }

        if result.isError {
            XCTFail("delegate(\(provider)) returned error: \(result.output.prefix(300))")
            return
        }
        XCTAssertFalse(result.output.isEmpty, "delegate(\(provider)) returned empty text")
        XCTAssertTrue(
            result.output.lowercased().contains(expectInResponse.lowercased()),
            "delegate(\(provider)) response missing '\(expectInResponse)'. Got: \(result.output.prefix(200))"
        )
        print("  [delegate/\(provider)] bytes=\(result.output.count) excerpt=\"\(result.output.prefix(80))\"")
    }

    /// Wrap an async throwing call in a wall-clock deadline so a hung subprocess
    /// (e.g. unauthenticated claude) fails fast instead of stalling CI.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ACPSmokeTimeoutError.expired(seconds)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private enum ACPSmokeTimeoutError: Error, LocalizedError {
    case expired(TimeInterval)
    var errorDescription: String? {
        switch self {
        case .expired(let s): return "ACP smoke timed out after \(Int(s))s"
        }
    }
}
