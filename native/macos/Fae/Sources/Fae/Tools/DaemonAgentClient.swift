import Foundation

/// Live endpoints of the running `fae-daemon`, published by `FaeCore` once the
/// daemon LLM lane is ACTIVE so stateless tools (built in `ToolRegistry`
/// without a daemon reference) can open their own authenticated connections.
///
/// This mirrors how `DaemonTTSEngine` and the pipeline's event subscriber are
/// handed `DaemonLLMEngine.endpoints`: the daemon serializes long LLM turns on
/// one connection, so every sibling lane opens a SECOND connection to the same
/// process. `agent.run` turns can run for minutes — they must not queue behind
/// the LLM connection.
actor DaemonEndpointStore {
    static let shared = DaemonEndpointStore()

    private var endpoints: (socketPath: String, tokenPath: String)?

    /// Publish (or clear, with nil) the live daemon endpoints. Called by
    /// `FaeCore` when the daemon LLM lane goes ACTIVE and on fallback/shutdown.
    func set(_ endpoints: (socketPath: String, tokenPath: String)?) {
        self.endpoints = endpoints
    }

    func current() -> (socketPath: String, tokenPath: String)? {
        endpoints
    }
}

/// Errors specific to the native ACP delegation lane (daemon `agent.run`).
enum DaemonAgentClientError: LocalizedError {
    case daemonUnavailable

    var errorDescription: String? {
        switch self {
        case .daemonUnavailable:
            return "fae-daemon is not running — the native ACP lane is unavailable"
        }
    }
}

/// Thin Swift client for the daemon's native ACP delegation surface
/// (`agent.run`, gap A1). Opens a dedicated authenticated socket connection to
/// the already-running daemon (it never launches it), drives one delegation
/// turn, and returns the collected outcome.
///
/// The daemon spawns the external agent (codex/claude/gemini/pi/copilot) as an
/// ACP server subprocess under its own process registry; this replaces the
/// macOS-only `acpx`/`Process()` route in `AgentDelegateTool`.
enum DaemonAgentClient {
    /// Result of one daemon `agent.run` turn.
    struct Outcome {
        var text: String
        var stopReason: String
        var toolCalls: [(id: String, title: String)]
    }

    /// Run one delegation turn through the daemon. Throws
    /// `DaemonAgentClientError.daemonUnavailable` when no daemon endpoints are
    /// published (caller falls back to the legacy subprocess path), and
    /// `DaemonLLMEngineError.daemonError` for an `ok=false` response.
    ///
    /// - Parameters:
    ///   - agent: provider name (codex|claude|gemini|pi|copilot).
    ///   - prompt: the fully-built delegation prompt (mode/system guidance
    ///     already folded in by `AgentDelegateTool.buildPrompt`).
    ///   - cwd: absolute working directory for the spawned agent.
    static func run(agent: String, prompt: String, cwd: String) async throws -> Outcome {
        // Stage 1 (A1): non-streaming one-shot. The owner already approved the
        // delegation at the Fae tool layer, so the daemon approves the agent's
        // own tool calls (ApproveAll). Per-call permission round-trips are A3.
        let response = try await call(
            command: "agent.run",
            payload: [
                "agent": agent,
                "prompt": prompt,
                "cwd": cwd,
            ])
        return parseOutcome(response)
    }

    // MARK: - Persistent sessions (gap A2)

    /// One live native-ACP session as reported by `agent.session_list`.
    struct SessionInfo {
        var sessionId: String
        var agent: String
        var cwd: String
    }

    /// Start a persistent session (`agent.session_start`), returning its daemon
    /// handle. The agent's ACP server stays alive across prompts.
    static func sessionStart(
        agent: String, cwd: String, approvalPolicy: String
    ) async throws -> String {
        let response = try await call(
            command: "agent.session_start",
            payload: [
                "agent": agent,
                "cwd": cwd,
                "approval_policy": approvalPolicy,
            ])
        guard let sessionId = (response["result"] as? [String: Any])?["session_id"] as? String
        else {
            throw DaemonLLMEngineError.daemonError("agent.session_start returned no session_id")
        }
        return sessionId
    }

    /// Submit a prompt to a live session (`agent.prompt`). The agent's streamed
    /// output is republished by the daemon as `agent.output` / `agent.tool_call`
    /// events for the orb; this call returns the final assembled turn.
    static func sessionPrompt(sessionId: String, prompt: String) async throws -> Outcome {
        let response = try await call(
            command: "agent.prompt",
            payload: ["session_id": sessionId, "prompt": prompt])
        return parseOutcome(response)
    }

    /// Cancel a session's in-flight turn (`agent.cancel`).
    static func sessionCancel(sessionId: String) async throws {
        _ = try await call(command: "agent.cancel", payload: ["session_id": sessionId])
    }

    /// Tear a session down (`agent.close`).
    static func sessionClose(sessionId: String) async throws {
        _ = try await call(command: "agent.close", payload: ["session_id": sessionId])
    }

    /// List live sessions (`agent.session_list`).
    static func sessionList() async throws -> [SessionInfo] {
        let response = try await call(command: "agent.session_list", payload: [:])
        let raw = (response["result"] as? [String: Any])?["sessions"] as? [[String: Any]] ?? []
        return raw.map {
            SessionInfo(
                sessionId: ($0["session_id"] as? String) ?? "",
                agent: ($0["agent"] as? String) ?? "",
                cwd: ($0["cwd"] as? String) ?? "")
        }
    }

    /// Parse the `{text, stop_reason, tool_calls}` result shared by `agent.run`
    /// and `agent.prompt`.
    private static func parseOutcome(_ response: [String: Any]) -> Outcome {
        let result = (response["result"] as? [String: Any]) ?? [:]
        let text = (result["text"] as? String) ?? ""
        let stopReason = (result["stop_reason"] as? String) ?? "end_turn"
        var toolCalls: [(id: String, title: String)] = []
        for raw in (result["tool_calls"] as? [[String: Any]]) ?? [] {
            toolCalls.append((
                id: (raw["id"] as? String) ?? "",
                title: (raw["title"] as? String) ?? ""))
        }
        return Outcome(text: text, stopReason: stopReason, toolCalls: toolCalls)
    }

    /// Open an authenticated connection, send one command frame, and return the
    /// validated response. Throws `DaemonAgentClientError.daemonUnavailable`
    /// when no daemon endpoints are published.
    private static func call(
        command: String, payload: [String: Any]
    ) async throws -> [String: Any] {
        guard let endpoints = await DaemonEndpointStore.shared.current() else {
            throw DaemonAgentClientError.daemonUnavailable
        }
        let connection = DaemonSocketConnection(queueLabel: "fae.daemon-agent.socket")
        try connection.connect(to: endpoints.socketPath)
        defer { connection.close() }
        try await authenticate(connection: connection, tokenPath: endpoints.tokenPath)
        let requestID = "a1"
        let frame = try DaemonWire.encodeFrame(
            requestID: requestID, command: command, payload: payload)
        let raw = try await connection.roundTrip(frame: frame, expectRequestID: requestID)
        return try DaemonWire.unwrapResponse(raw)
    }

    /// Authenticate the connection with the bootstrap token (first frame on the
    /// connection, protocol v2) — the same handshake `DaemonLLMEngine` and
    /// `DaemonTTSEngine` use. The token is hash-verified per connection, so a
    /// third authenticated session alongside the LLM + TTS connections is fine.
    private static func authenticate(
        connection: DaemonSocketConnection, tokenPath: String
    ) async throws {
        let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw DaemonLLMEngineError.tokenUnreadable(tokenPath)
        }
        let authFrame = try DaemonWire.encodeFrame(
            requestID: "a0",
            command: "session.authenticate",
            payload: [
                "client_id": "swift-frontend-bootstrap",
                "token": token,
            ])
        let raw = try await connection.roundTrip(frame: authFrame, expectRequestID: "a0")
        _ = try DaemonWire.unwrapResponse(raw)
    }
}
