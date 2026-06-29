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
    /// A classified delegation failure (gap A4): `message` is already
    /// user-facing (auth / rate-limit / network / generic).
    case agentFailed(String)

    var errorDescription: String? {
        switch self {
        case .daemonUnavailable:
            return "fae-daemon is not running — the native ACP lane is unavailable"
        case .agentFailed(let message):
            return message
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
    ///
    /// Mid-turn, the agent may ask the daemon for permission, which the daemon
    /// forwards here as a `permission.request` server-request (gap A3). Each is
    /// surfaced on Fae's approval card; the user's decision flows back into the
    /// agent's turn on this same connection.
    static func sessionPrompt(sessionId: String, prompt: String) async throws -> Outcome {
        let response = try await callHandlingServerRequests(
            command: "agent.prompt",
            payload: ["session_id": sessionId, "prompt": prompt],
            onServerRequest: { _, method, params in
                await handleServerRequest(method: method, params: params)
            })
        return parseOutcome(response)
    }

    /// Answer a daemon server-request: `permission.request` (gap A3a, approval
    /// card) and `fs.read` / `fs.write` (gap A3b, mediated by PathPolicy).
    static func handleServerRequest(
        method: String, params: [String: Any]
    ) async -> [String: Any] {
        switch method {
        case "permission.request":
            let title = (params["title"] as? String) ?? "Agent action"
            let options = (params["options"] as? [[String: Any]]) ?? []
            let approved = await requestApproval(
                title: "Agent permission",
                message: permissionMessage(title: title, options: options))
            if approved, let optionID = firstAllowOption(options) {
                return ["option_id": optionID]
            }
            return ["cancelled": true]
        case "fs.read":
            return readFile(params: params)
        case "fs.write":
            return writeFile(params: params)
        case "tool.confirm":
            // A3-Swift: the governed daemon ToolHost asks the owner to approve a
            // dangerous tool before it runs in the per-session sandbox. The
            // reply must be EXACTLY {approved, call_id} (the daemon's parser is
            // strict deny_unknown_fields; any extra field denies).
            return await handleToolConfirm(params: params)
        case "workspace.confirm_root":
            // B-Swift: the daemon asks the owner to approve a DURABLE workspace
            // root (a real project dir). DISTINCT from tool.confirm — this
            // authorizes a PLACE once per session, not a tool per call. The
            // reply is the strict {approved, call_id} shape (call_id is REQUIRED
            // in B-Rust; a missing/blank call_id denies fail-closed).
            return await handleWorkspaceConfirmRoot(params: params)
        default:
            return ["error": "unsupported server request: \(method)"]
        }
    }

    /// `fs/read_text_file` mediation (gap A3b). Gated by `PathPolicy.validateReadPath`:
    /// the requester is an autonomous delegate (NOT the owner), so it must not be
    /// able to read credentials or Fae's identity (`~/.ssh`, `speakers.json`,
    /// `~/.fae-vault`, …) through Fae. General project/system reads are allowed.
    static func readFile(params: [String: Any]) -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            return ["error": "fs.read missing path"]
        }
        switch PathPolicy.validateReadPath(path) {
        case .blocked(let reason):
            NSLog("DaemonAgentClient: fs.read blocked by PathPolicy: %@", reason)
            return ["error": "fs.read blocked: \(reason)"]
        case .allowed(let canonicalPath):
            do {
                let content = try String(contentsOfFile: canonicalPath, encoding: .utf8)
                return ["content": content]
            } catch {
                return ["error": "could not read \(path): \(error.localizedDescription)"]
            }
        }
    }

    /// `fs/write_text_file` mediation (gap A3b) — gated by `PathPolicy`, which
    /// blocks system paths, sensitive dotfiles, and Fae's own data files.
    static func writeFile(params: [String: Any]) -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            return ["error": "fs.write missing path"]
        }
        guard let content = params["content"] as? String else {
            return ["error": "fs.write missing content"]
        }
        switch PathPolicy.validateWritePath(path) {
        case .blocked(let reason):
            NSLog("DaemonAgentClient: fs.write blocked by PathPolicy: %@", reason)
            return ["error": reason]
        case .allowed(let canonicalPath):
            do {
                try content.write(toFile: canonicalPath, atomically: true, encoding: .utf8)
                return ["ok": true]
            } catch {
                return ["error": "could not write \(path): \(error.localizedDescription)"]
            }
        }
    }

    // MARK: - ToolHost execution (A3-Swift)

    /// Execute a portable/native tool in the governed daemon ToolHost. Uses the
    /// SERVER-REQUEST-AWARE round-trip (BLOCKER-1): a dangerous tool emits a
    /// `tool.confirm` server-request that the plain `roundTrip` would SKIP (the
    /// daemon would park forever awaiting the reply → deadlock). `handleServerRequest`
    /// answers `tool.confirm` on this same connection.
    ///
    /// `handleServerRequest` is shared with the agent-delegation lane, so a
    /// `tool.confirm` and a `permission.request`/`fs.*` can both be answered on
    /// one connection.
    static func toolhostExecute(tool: String, input: [String: Any]) async throws -> [String: Any] {
        let response = try await callHandlingServerRequests(
            command: "toolhost.execute",
            payload: ["tool": tool, "input": input],
            onServerRequest: { _, method, params in
                await handleServerRequest(method: method, params: params)
            })
        return (response["result"] as? [String: Any]) ?? [:]
    }

    /// `tool.confirm` (A3-Swift): surface the daemon's bounded, redacted
    /// `ConfirmRequest` on the governance card and return the owner's decision.
    /// `params` carries tool/call_id/risk_class/reason/detail — NEVER the tool's
    /// full input or file contents. The reply is the strict two-field shape the
    /// daemon's parser expects.
    static func handleToolConfirm(params: [String: Any]) async -> [String: Any] {
        // `call_id` is mandatory (the daemon echoes it defensively). Missing or
        // malformed params ⇒ deny (fail-closed; never prompt without a way to
        // bind the reply to the request).
        guard let callID = params["call_id"] as? String, !callID.isEmpty else {
            return ["approved": false]
        }
        let tool = (params["tool"] as? String) ?? "a tool"
        let risk = (params["risk_class"] as? String) ?? "dangerous"
        let message = toolConfirmMessage(
            tool: tool, risk: risk, detail: params["detail"])
        // Production: the real governance card. There is NO test override here —
        // the strict reply shape + the fail-closed logic are unit-tested via the
        // pure `toolConfirmReply` builder below (oracle MAJOR-1: a global mutable
        // auto-approval actor was a structural bypass footgun; removed).
        let approved = await requestApproval(
            title: "Fae wants to run a tool",
            message: message)
        return toolConfirmReply(callID: callID, approved: approved)
    }

    /// Build the STRICT two-field `tool.confirm` reply `{approved, call_id}`.
    /// Pure (no card, no global state) — this is what unit tests assert the
    /// shape against, so the test seam is a pure function, not a mutable actor
    /// that could bypass the UI in production (oracle MAJOR-1). Matches the
    // daemon's `deny_unknown_fields` parser exactly — any extra field flips
    // approval into a malformed-deny.
    static func toolConfirmReply(callID: String, approved: Bool) -> [String: Any] {
        ["approved": approved, "call_id": callID]
    }

    /// Compose a REDACTED confirmation message from the bounded `ConfirmRequest`.
    /// Never echoes file contents, `old_text`, or `new_text` — only the path,
    /// the incoming byte count, whether an existing file is overwritten, and a
    /// bounded command preview. All fields are already server-bounded.
    static func toolConfirmMessage(tool: String, risk: String, detail: Any?) -> String {
        guard let detail = detail as? [String: Any] else {
            return "Fae wants to run \(tool) (\(risk)). Allow?"
        }
        // `detail` is an externally-tagged enum: {"WriteEdit": {...}} or
        // {"Shell": {...}} (mirrors the Rust ConfirmDetail serde shape).
        if let writeEdit = detail["WriteEdit"] as? [String: Any] {
            let path = (writeEdit["path"] as? String) ?? "(unknown path)"
            let newBytes = writeEdit["new_bytes"] as? Int ?? 0
            let oldExists = writeEdit["old_exists"] as? Bool ?? false
            let verb = oldExists ? "overwrite" : "write"
            return "Fae wants to \(verb) \(path) (\(newBytes) bytes). Allow?"
        }
        if let shell = detail["Shell"] as? [String: Any] {
            let preview = (shell["command_preview"] as? String) ?? "(no preview)"
            return "Fae wants to run: `\(preview)`. Allow?"
        }
        return "Fae wants to run \(tool) (\(risk)). Allow?"
    }

    // MARK: - Durable workspace root approval (B-Swift)

    /// `workspace.confirm_root` (B-Swift): surface the daemon's bounded root-
    /// approval request on the governance card and return the owner's decision.
    /// DISTINCT from `tool.confirm` — the owner authorizes a PLACE (once per
    /// session), not a tool per call. `params` carries `call_id` + the
    /// canonicalized absolute `path` + a fixed blast-radius `note`. NEVER the
    /// directory's contents. The reply is the strict `{approved, call_id}` shape
    /// B-Rust's parser requires (call_id is mandatory; missing ⇒ deny).
    static func handleWorkspaceConfirmRoot(params: [String: Any]) async -> [String: Any] {
        // `call_id` is mandatory (B-Rust requires it; a missing/blank id can't
        // bind the reply to the request ⇒ deny fail-closed, never prompt).
        guard let callID = params["call_id"] as? String, !callID.isEmpty else {
            return ["approved": false, "call_id": ""]
        }
        let path = (params["path"] as? String) ?? "(unknown path)"
        let note = (params["note"] as? String) ?? ""
        let message = workspaceConfirmRootMessage(path: path, note: note)
        // Production: the real governance card. NO test override (oracle MAJOR-1
        // precedent from A3-Swift — a global mutable auto-approve actor was a
        // structural bypass footgun; removed). The strict reply shape is
        // unit-tested via the pure `workspaceConfirmRootReply` builder below.
        let approved = await requestApproval(
            title: "Fae wants a workspace folder",
            message: message)
        return workspaceConfirmRootReply(callID: callID, approved: approved)
    }

    /// Build the STRICT two-field `workspace.confirm_root` reply
    /// `{approved, call_id}`. Pure (no card, no global state) — this is what
    /// unit tests assert the shape against (oracle MAJOR-1 precedent: the test
    /// seam is a pure function, not a mutable actor). Matches B-Rust's
    /// `deny_unknown_fields` parser exactly — any extra field denies.
    static func workspaceConfirmRootReply(callID: String, approved: Bool) -> [String: Any] {
        ["approved": approved, "call_id": callID]
    }

    /// Compose a REDACTED root-approval message from the bounded request: the
    /// canonicalized absolute directory path + the fixed blast-radius note.
    /// NEVER echoes directory contents or a file listing. All fields are
    /// already server-bounded + canonicalized.
    static func workspaceConfirmRootMessage(path: String, note: String) -> String {
        var message = "Fae wants to use this folder as its workspace:\n\(path)"
        if !note.isEmpty {
            message += "\n\(note)"
        }
        message += "\n\nAllow? (this lasts for the session.)"
        return message
    }

    /// The id of the option that approves (kind/name contains "allow"), else the
    /// first option — `nil` only when the agent offered none.
    static func firstAllowOption(_ options: [[String: Any]]) -> String? {
        let allow = options.first { option in
            let kind = (option["kind"] as? String ?? "").lowercased()
            let name = (option["name"] as? String ?? "").lowercased()
            return kind.contains("allow") || name.contains("allow")
        }
        return (allow?["id"] as? String) ?? (options.first?["id"] as? String)
    }

    /// Human-readable approval-card body for a permission request.
    static func permissionMessage(title: String, options: [[String: Any]]) -> String {
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = label.isEmpty ? "an action" : "“\(label)”"
        return "A delegated agent wants to \(action). Allow it?"
    }

    /// Present Fae's governance approval card and await the user's yes/no. Reuses
    /// the existing `.faeGovernanceConfirmation*` round-trip (the same card tool
    /// approvals use).
    @MainActor
    private static func requestApproval(title: String, message: String) async -> Bool {
        let requestID = UUID().uuidString
        return await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .faeGovernanceConfirmationRespond,
                object: nil,
                queue: .main
            ) { note in
                guard let info = note.userInfo,
                      (info["request_id"] as? String) == requestID
                else { return }
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: (info["approved"] as? Bool) ?? false)
            }
            NotificationCenter.default.post(
                name: .faeGovernanceConfirmationRequested,
                object: nil,
                userInfo: [
                    "request_id": requestID,
                    "title": title,
                    "message": message,
                    "confirm_label": "Allow",
                ])
        }
    }

    /// Validate a daemon response, mapping a failure's classified `error.code`
    /// (gap A4) to a user-facing message. `ok` responses pass through.
    static func validate(_ raw: [String: Any]) throws -> [String: Any] {
        if (raw["ok"] as? Bool) == true { return raw }
        let code = ((raw["error"] as? [String: Any])?["code"] as? String) ?? "agent_error"
        throw DaemonAgentClientError.agentFailed(friendlyAgentError(code))
    }

    /// Map a daemon agent error code to an actionable, user-facing message.
    static func friendlyAgentError(_ code: String) -> String {
        switch code {
        case "auth_error":
            return "The agent needs to be signed in. Open its CLI and log in, then try again."
        case "rate_limited":
            return "The agent is rate-limited right now. Try again in a little while."
        case "network_error":
            return "Couldn't reach the agent's service. Check your connection and try again."
        case "unknown_agent":
            return "That agent isn't installed or recognized."
        case "agent_launch_failed":
            return "The agent failed to launch."
        case "unknown_session":
            return "That agent session is no longer active."
        case "session_closed":
            return "The agent session is closed."
        case "bad_request":
            return "The agent request was malformed."
        default:
            return "The agent delegation failed (\(code))."
        }
    }

    /// Like `call`, but server-request frames during the round trip are routed to
    /// `onServerRequest` and answered on the same connection.
    private static func callHandlingServerRequests(
        command: String,
        payload: [String: Any],
        onServerRequest: @escaping (String, String, [String: Any]) async -> [String: Any]
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
        let raw = try await connection.roundTrip(
            frame: frame, expectRequestID: requestID, onServerRequest: onServerRequest)
        return try validate(raw)
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
    static func call(
        command: String, payload: [String: Any]
    ) async throws -> [String: Any] {
        // BLOCKER-1 (A3+B): `toolhost.execute` AND `toolhost.set_root` MUST
        // use the server-request-aware path (`callHandlingServerRequests`).
        // `toolhost.execute` emits a `tool.confirm` server-request; `set_root`
        // emits a `workspace.confirm_root` server-request. The plain `roundTrip`
        // below would SKIP either (the daemon parks forever awaiting the reply
        // → deadlock). Refuse both here so neither can be misrouted onto the
        // plain path. (B-Swift note: set_root + execute must also share a
        // persistent connection — see DaemonToolHostSession. A one-shot
        // call here would also lose the per-connection approved root.)
        if command == "toolhost.execute" || command == "toolhost.set_root" {
            throw DaemonAgentClientError.agentFailed(
                "\(command) requires the server-request-aware round-trip (BLOCKER-1)"
            )
        }
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
        return try validate(raw)
    }

    /// Authenticate the connection with the bootstrap token (first frame on the
    /// connection, protocol v2) — the same handshake `DaemonLLMEngine` and
    /// `DaemonTTSEngine` use. The token is hash-verified per connection, so a
    /// third authenticated session alongside the LLM + TTS connections is fine.
    static func authenticate(
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
