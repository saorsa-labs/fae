import Foundation

struct AgentSessionTool: Tool {
    let name = "agent_session"
    let description = "Manage persistent sessions with external AI coding agents (Claude Code, Codex, Gemini, etc.) via ACP. Actions: start (high risk), prompt (medium risk), status/cancel/close/list (low risk)."
    let parametersSchema = #"{"action":"string (required: start|prompt|status|cancel|close|list)","agent":"string (required for start — claude|codex|gemini or custom command)","prompt":"string (required for start and prompt — task description or follow-up)","session_id":"string (required for prompt|status|cancel|close)","cwd":"string (optional — working directory, defaults to current)","approval_policy":"string (optional — approve_all|approve_reads|deny_all, default approve_reads)","name":"string (optional — session name for identification)"}"#

    /// Tool protocol metadata is static, but this tool is conceptually dynamic:
    /// - start requires approval (spawns external process)
    /// - prompt is medium risk
    /// - status/cancel/close/list are low risk
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"agent_session","arguments":{"action":"start","agent":"claude","prompt":"Investigate failing unit tests and propose a fix.","cwd":"~/Projects/app","approval_policy":"approve_reads","name":"test-fix"}}</tool_call>"#

    private static let sessionManager = ACPSessionManager()
    private static let maxOutputLength = 20_000

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

        // Validate agent identifier - must be alphanumeric/hyphens/underscores or a simple path.
        let allowedBuiltins: Set<String> = ["claude", "codex", "gemini", "copilot", "aider"]
        let isBuiltin = allowedBuiltins.contains(agent.lowercased())
        let isValidCustom = agent.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "/" || $0 == "." }
        guard isBuiltin || isValidCustom else {
            return .error("Invalid agent identifier. Use a built-in name (claude, codex, gemini, copilot, aider) or a simple command path.")
        }
        if !isBuiltin && (agent.contains("..") || agent.contains(";") || agent.contains("|") || agent.contains("&") || agent.contains("$") || agent.contains("`")) {
            return .error("Agent identifier contains disallowed characters.")
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

        let approvalPolicy: ACPSessionManager.ApprovalPolicy
        do {
            approvalPolicy = try parseApprovalPolicy(input["approval_policy"])
        } catch {
            return .error(error.localizedDescription)
        }

        let name = nonEmptyString(input["name"])

        do {
            let sessionId = try await Self.sessionManager.startSession(
                agent: agent,
                cwd: cwd.path,
                name: name,
                approvalPolicy: approvalPolicy
            )

            do {
                let response = try await Self.sessionManager.prompt(sessionId: sessionId, text: prompt)
                let output = """
                    Started session \(sessionId)
                    Agent: \(agent)
                    CWD: \(cwd.path)
                    Stop reason: \(response.stopReason)

                    \(formatResponse(response))
                    """
                return .success(truncate(output))
            } catch {
                await Self.sessionManager.close(sessionId: sessionId)
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
            let response = try await Self.sessionManager.prompt(sessionId: sessionId, text: prompt)
            let output = """
                Session: \(sessionId)
                Stop reason: \(response.stopReason)

                \(formatResponse(response))
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

        let status = await Self.sessionManager.status(sessionId: sessionId)
        let output = "Session \(sessionId): \(formatStatus(status))"
        return .success(output)
    }

    private func handleCancel(input: [String: Any]) async -> ToolResult {
        guard let sessionId = nonEmptyString(input["session_id"]) else {
            return .error("Missing required parameter for cancel: session_id")
        }

        await Self.sessionManager.cancel(sessionId: sessionId)
        return .success("Cancellation requested for session \(sessionId).")
    }

    private func handleClose(input: [String: Any]) async -> ToolResult {
        guard let sessionId = nonEmptyString(input["session_id"]) else {
            return .error("Missing required parameter for close: session_id")
        }

        await Self.sessionManager.close(sessionId: sessionId)
        return .success("Closed session \(sessionId).")
    }

    private func handleList() async -> ToolResult {
        let sessions = await Self.sessionManager.activeSessions()
        guard !sessions.isEmpty else {
            return .success("No active ACP sessions.")
        }

        let lines = sessions.map { session in
            let label: String
            if let sessionName = session.name, !sessionName.isEmpty {
                label = "\(sessionName) [\(session.id)]"
            } else {
                label = session.id
            }
            return "- \(label) | agent=\(session.agent) | cwd=\(session.cwd) | status=\(formatStatus(session.status)) | turns=\(session.turnCount)"
        }
        let output = "Active ACP sessions (\(sessions.count)):\n" + lines.joined(separator: "\n")
        return .success(truncate(output))
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

    private func parseApprovalPolicy(_ raw: Any?) throws -> ACPSessionManager.ApprovalPolicy {
        let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "approve_reads"

        switch value {
        case "approve_reads":
            return .approveReads
        case "approve_all":
            return .approveAll
        case "deny_all":
            return .denyAll
        default:
            throw NSError(
                domain: "AgentSessionTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid approval_policy: \(value). Use approve_reads, approve_all, or deny_all."]
            )
        }
    }

    private func formatResponse(_ response: ACPSessionManager.ACPResponse) -> String {
        let trimmedText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let textSection = trimmedText.isEmpty ? "[agent returned no text]" : trimmedText

        guard !response.toolCalls.isEmpty else {
            return textSection
        }

        let toolLines = response.toolCalls.map { call in
            var line = "- \(call.toolName) (id: \(call.toolCallId), complete: \(call.isComplete))"
            let output = call.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                line += "\n  output: \(singleLine(output, max: 280))"
            }
            return line
        }

        return textSection + "\n\nTool calls:\n" + toolLines.joined(separator: "\n")
    }

    private func formatStatus(_ status: ACPSessionManager.SessionStatus) -> String {
        switch status {
        case .idle:
            return "idle"
        case .prompting:
            return "prompting"
        case .streaming(let tokensReceived):
            return "streaming (tokens_received=\(tokensReceived))"
        case .awaitingApproval(let toolName, let description):
            return "awaiting approval for \(toolName): \(singleLine(description, max: 180))"
        case .completed(let stopReason):
            return "completed (stop_reason=\(stopReason))"
        case .failed(let error):
            return "failed: \(singleLine(error, max: 180))"
        case .closed:
            return "closed"
        }
    }

    private func singleLine(_ text: String, max: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= max { return oneLine }
        return String(oneLine.prefix(max)) + "…"
    }

    private func truncate(_ text: String) -> String {
        if text.count <= Self.maxOutputLength { return text }
        return String(text.prefix(Self.maxOutputLength)) + "\n[truncated]"
    }
}
