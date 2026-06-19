import Foundation

/// Manage persistent native-ACP sessions with external coding agents via the
/// daemon (`agent.session_start / prompt / cancel / close / session_list`,
/// gap A2). The daemon keeps each agent's ACP server alive across prompts and
/// republishes streamed output as `agent.output` / `agent.tool_call` events for
/// the orb. This replaces the macOS-only `ACPSessionManager` (acpx subprocess).
struct AgentSessionTool: Tool {
    let name = "agent_session"
    let description = "Manage persistent sessions with external AI coding agents (Claude Code, Codex, Pi, Gemini, etc.) via ACP. Actions: start (high risk), prompt (medium risk), status/cancel/close/list (low risk)."
    let parametersSchema = #"{"action":"string (required: start|prompt|status|cancel|close|list)","agent":"string (required for start — claude|codex|pi|gemini|copilot)","prompt":"string (required for start and prompt — task description or follow-up)","session_id":"string (required for prompt|status|cancel|close)","cwd":"string (optional — working directory, defaults to current)","approval_policy":"string (optional — approve_all|deny_all, default approve_all)","name":"string (optional — session name for identification)"}"#

    /// Tool protocol metadata is static, but this tool is conceptually dynamic:
    /// - start requires approval (spawns external process)
    /// - prompt is medium risk
    /// - status/cancel/close/list are low risk
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"agent_session","arguments":{"action":"start","agent":"claude","prompt":"Investigate failing unit tests and propose a fix.","cwd":"~/Projects/app","approval_policy":"approve_all","name":"test-fix"}}</tool_call>"#

    private static let maxOutputLength = 20_000
    private let runner: AgentRunner = DaemonAgentRunner()

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let rawAction = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch action {
        case "start":
            return await handleStart(input: input)
        case "prompt":
            return await handlePrompt(input: input)
        case "status":
            return await handleStatus(input: input)
        case "cancel":
            return await handleCancel(input: input)
        case "close":
            return await handleClose(input: input)
        case "list":
            return await handleList()
        default:
            return .error("Invalid action: \(rawAction). Use start, prompt, status, cancel, close, or list.")
        }
    }

    private func handleStart(input: [String: Any]) async -> ToolResult {
        guard let agent = nonEmptyString(input["agent"]) else {
            return .error("Missing required parameter for start: agent")
        }

        // Validate the agent identifier. Built-ins are the agents the daemon's
        // native ACP client knows how to launch.
        let allowedBuiltins: Set<String> = ["claude", "codex", "pi", "gemini", "copilot", "opencode"]
        guard allowedBuiltins.contains(agent.lowercased()) else {
            return .error("Invalid agent. Use claude, codex, pi, gemini, copilot, or opencode.")
        }

        guard let prompt = nonEmptyString(input["prompt"]) else {
            return .error("Missing required parameter for start: prompt")
        }

        let scan = SensitiveContentPolicy.scan(prompt)
        if scan.shouldBlockDelegation {
            return .error(
                "This prompt appears to include sensitive information. Delegation is blocked so sensitive content stays local to Fae."
            )
        }

        let cwd = resolveWorkingDirectory(from: input["cwd"])
        guard FileManager.default.fileExists(atPath: cwd.path) else {
            return .error("Working directory does not exist: \(cwd.path)")
        }
        let approvalPolicy = daemonApprovalPolicy(input["approval_policy"])

        do {
            let sessionId = try await runner.sessionStart(
                agent: agent.lowercased(), cwd: cwd.path, approvalPolicy: approvalPolicy)
            do {
                let outcome = try await runner.sessionPrompt(
                    sessionId: sessionId, prompt: prompt)
                let output = """
                    Started session \(sessionId)
                    Agent: \(agent)
                    CWD: \(cwd.path)
                    Stop reason: \(outcome.stopReason)

                    \(formatOutcome(outcome))
                    """
                return .success(truncate(output))
            } catch {
                try? await runner.sessionClose(sessionId: sessionId)
                return .error("Session started but initial prompt failed: \(error.localizedDescription)")
            }
        } catch {
            return .error("Failed to start session: \(error.localizedDescription)")
        }
    }

    private func handlePrompt(input: [String: Any]) async -> ToolResult {
        guard let sessionId = nonEmptyString(input["session_id"]) else {
            return .error("Missing required parameter for prompt: session_id")
        }
        guard let prompt = nonEmptyString(input["prompt"]) else {
            return .error("Missing required parameter for prompt: prompt")
        }

        let scan = SensitiveContentPolicy.scan(prompt)
        if scan.shouldBlockDelegation {
            return .error(
                "This prompt appears to include sensitive information. Delegation is blocked so sensitive content stays local to Fae."
            )
        }

        do {
            let outcome = try await runner.sessionPrompt(
                sessionId: sessionId, prompt: prompt)
            let output = """
                Session: \(sessionId)
                Stop reason: \(outcome.stopReason)

                \(formatOutcome(outcome))
                """
            return .success(truncate(output))
        } catch {
            return .error("Prompt failed for session \(sessionId): \(error.localizedDescription)")
        }
    }

    private func handleStatus(input: [String: Any]) async -> ToolResult {
        guard let sessionId = nonEmptyString(input["session_id"]) else {
            return .error("Missing required parameter for status: session_id")
        }
        do {
            let sessions = try await runner.sessionList()
            if let session = sessions.first(where: { $0.sessionId == sessionId }) {
                return .success("Session \(sessionId): active | agent=\(session.agent) | cwd=\(session.cwd)")
            }
            return .success("Session \(sessionId): not found (closed or never started).")
        } catch {
            return .error("Could not read session status: \(error.localizedDescription)")
        }
    }

    private func handleCancel(input: [String: Any]) async -> ToolResult {
        guard let sessionId = nonEmptyString(input["session_id"]) else {
            return .error("Missing required parameter for cancel: session_id")
        }
        do {
            try await runner.sessionCancel(sessionId: sessionId)
            return .success("Cancellation requested for session \(sessionId).")
        } catch {
            return .error("Cancel failed for session \(sessionId): \(error.localizedDescription)")
        }
    }

    private func handleClose(input: [String: Any]) async -> ToolResult {
        guard let sessionId = nonEmptyString(input["session_id"]) else {
            return .error("Missing required parameter for close: session_id")
        }
        do {
            try await runner.sessionClose(sessionId: sessionId)
            return .success("Closed session \(sessionId).")
        } catch {
            return .error("Close failed for session \(sessionId): \(error.localizedDescription)")
        }
    }

    private func handleList() async -> ToolResult {
        do {
            let sessions = try await runner.sessionList()
            guard !sessions.isEmpty else {
                return .success("No active ACP sessions.")
            }
            let lines = sessions.map { session in
                "- \(session.sessionId) | agent=\(session.agent) | cwd=\(session.cwd)"
            }
            let output = "Active ACP sessions (\(sessions.count)):\n" + lines.joined(separator: "\n")
            return .success(truncate(output))
        } catch {
            return .error("Could not list sessions: \(error.localizedDescription)")
        }
    }

    private func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolveWorkingDirectory(from raw: Any?) -> URL {
        if let cwd = nonEmptyString(raw) {
            let expanded = NSString(string: cwd).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardized.resolvingSymlinksInPath()
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .standardized
            .resolvingSymlinksInPath()
    }

    /// Map the tool's approval policy to the daemon's `approval_policy` value.
    /// The daemon distinguishes only deny-all from approve-all today; the finer
    /// `approve_reads` collapses to approve-all until per-call permission
    /// round-trips land (gap A3).
    private func daemonApprovalPolicy(_ raw: Any?) -> String {
        let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "deny_all" ? "deny_all" : "approve_all"
    }

    private func formatOutcome(_ outcome: DaemonAgentClient.Outcome) -> String {
        let trimmedText = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let textSection = trimmedText.isEmpty ? "[agent returned no text]" : trimmedText

        guard !outcome.toolCalls.isEmpty else {
            return textSection
        }
        let toolLines = outcome.toolCalls.map { "- \($0.title) (id: \($0.id))" }
        return textSection + "\n\nTool calls:\n" + toolLines.joined(separator: "\n")
    }

    private func truncate(_ text: String) -> String {
        if text.count <= Self.maxOutputLength { return text }
        return String(text.prefix(Self.maxOutputLength)) + "\n[truncated]"
    }
}
