import Foundation

/// The native-ACP delegation surface, abstracted behind a protocol (gap A4
/// conductor seam). The delegation tools depend on this capability rather than
/// the concrete daemon client, so the future cross-machine conductor — which
/// treats a local ACP agent as one `Runner` among others (x0x peers, etc.) — can
/// inject its own runner, and tests can inject a fake.
///
/// `DaemonAgentRunner` is the production conformer; it forwards to
/// `DaemonAgentClient` (daemon `agent.*` over the bootstrap socket).
protocol AgentRunner: Sendable {
    /// One-shot delegation (`agent.run`).
    func run(agent: String, prompt: String, cwd: String) async throws -> DaemonAgentClient.Outcome
    /// Start a persistent session (`agent.session_start`), returning its handle.
    func sessionStart(agent: String, cwd: String, approvalPolicy: String) async throws -> String
    /// Prompt a live session (`agent.prompt`); permission/fs requests surface to
    /// Fae mid-turn.
    func sessionPrompt(sessionId: String, prompt: String) async throws -> DaemonAgentClient.Outcome
    /// Cancel a session's in-flight turn (`agent.cancel`).
    func sessionCancel(sessionId: String) async throws
    /// Tear a session down (`agent.close`).
    func sessionClose(sessionId: String) async throws
    /// List live sessions (`agent.session_list`).
    func sessionList() async throws -> [DaemonAgentClient.SessionInfo]
}

/// Production `AgentRunner` — forwards to the daemon's native ACP client.
struct DaemonAgentRunner: AgentRunner {
    func run(agent: String, prompt: String, cwd: String) async throws -> DaemonAgentClient.Outcome {
        try await DaemonAgentClient.run(agent: agent, prompt: prompt, cwd: cwd)
    }

    func sessionStart(agent: String, cwd: String, approvalPolicy: String) async throws -> String {
        try await DaemonAgentClient.sessionStart(
            agent: agent, cwd: cwd, approvalPolicy: approvalPolicy)
    }

    func sessionPrompt(sessionId: String, prompt: String) async throws -> DaemonAgentClient.Outcome
    {
        try await DaemonAgentClient.sessionPrompt(sessionId: sessionId, prompt: prompt)
    }

    func sessionCancel(sessionId: String) async throws {
        try await DaemonAgentClient.sessionCancel(sessionId: sessionId)
    }

    func sessionClose(sessionId: String) async throws {
        try await DaemonAgentClient.sessionClose(sessionId: sessionId)
    }

    func sessionList() async throws -> [DaemonAgentClient.SessionInfo] {
        try await DaemonAgentClient.sessionList()
    }
}
