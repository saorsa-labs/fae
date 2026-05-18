import Foundation

/// Manages multi-turn external coding-agent sessions via `acpx <agent> exec`.
///
/// **Design — per-turn exec, Fae-managed history (2026-05-17).**
///
/// The earlier "long-lived acpx subprocess + JSON-RPC over stdin" design didn't
/// work in production: `acpx` is a CLI *client*, not a JSON-RPC server, and the
/// underlying processes it spawns are short-lived per-prompt. acpx 0.4.0's named
/// session model (`sessions new --name X` + `prompt -s X`) also doesn't persist
/// across CLI invocations — `prompt` rejects named sessions with NO_SESSION.
///
/// So this manager keeps state on Fae's side instead. Each session is a logical
/// container for an agent identity, working directory, approval policy, and an
/// accumulated conversation history. Every `prompt(...)` shells out to
/// `acpx [global-opts] <agent> exec <full-transcript>` and parses the NDJSON
/// output for the assistant's reply.
///
/// Trade-offs:
/// - ✅ Works against acpx 0.4.0 as it actually behaves today
/// - ✅ Same model as one-shot `delegate_agent`, just multi-turn
/// - ❌ Agent-side state (e.g. codex's plan/notebook) does not persist across
///   turns — Fae re-feeds the entire transcript every time
/// - ❌ Attachments in the public API are accepted for source compatibility but
///   not yet forwarded to the agent (acpx exec is text-only)
///
/// The public surface (`startSession`, `prompt`, `status`, `cancel`, `close`,
/// `activeSessions`, plus the result/error types) is preserved so
/// `AgentSessionTool` and the existing tests do not need to change.
actor ACPSessionManager {

    // MARK: - Public Types

    enum SessionStatus: Sendable, Equatable {
        case idle
        case prompting
        case streaming(tokensReceived: Int)
        case awaitingApproval(toolName: String, description: String)
        case completed(stopReason: String)
        case failed(error: String)
        case closed
    }

    struct ToolCallInfo: Sendable, Equatable {
        let toolName: String
        let toolCallId: String
        var input: String
        var output: String
        var isComplete: Bool
    }

    struct ACPResponse: Sendable, Equatable {
        let text: String
        let toolCalls: [ToolCallInfo]
        let stopReason: String
    }

    struct SessionInfo: Sendable, Equatable {
        let id: String
        let agent: String
        let cwd: String
        let name: String?
        let status: SessionStatus
        let turnCount: Int
        let createdAt: Date
        let lastActivityAt: Date
    }

    enum ApprovalPolicy: Sendable, Equatable {
        case approveReads
        case approveAll
        case denyAll

        var cliFlags: [String] {
            switch self {
            case .approveReads: return ["--approve-reads"]
            case .approveAll:   return ["--approve-all"]
            case .denyAll:      return ["--deny-all"]
            }
        }
    }

    enum SessionError: LocalizedError {
        case acpxNotFound
        case sessionNotFound(String)
        case sessionClosed(String)
        case promptAlreadyInFlight(String)
        case processLaunchFailed(String)
        case promptTimeout(TimeInterval)
        case tooManySessions(Int)
        case agentFailed(exitCode: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .acpxNotFound:
                return "acpx binary not found in bundled resources or fallback locations."
            case .sessionNotFound(let id):
                return "ACP session not found: \(id)"
            case .sessionClosed(let id):
                return "ACP session is closed: \(id)"
            case .promptAlreadyInFlight(let id):
                return "ACP session already has a prompt in flight: \(id)"
            case .processLaunchFailed(let r):
                return "Failed to launch acpx: \(r)"
            case .promptTimeout(let s):
                return "ACP prompt timed out after \(Int(s)) seconds"
            case .tooManySessions(let c):
                return "Too many active ACP sessions (\(c)); close one before starting another."
            case .agentFailed(let code, let message):
                return "acpx exec failed (exit=\(code)): \(message)"
            }
        }
    }

    // MARK: - Internal State

    private struct Turn: Sendable {
        enum Role: String, Sendable { case user, assistant }
        let role: Role
        let text: String
    }

    private struct ACPSession {
        let id: String
        let agent: String
        let cwd: String
        let name: String?

        let createdAt: Date
        var lastActivityAt: Date
        var status: SessionStatus

        var turnCount: Int
        var history: [Turn]
        var lastToolCalls: [ToolCallInfo]
        var approvalPolicy: ApprovalPolicy

        /// When a prompt is in flight, the process so cancel() can terminate it.
        var inflight: Process?
    }

    private var sessions: [String: ACPSession] = [:]
    private let defaultPromptTimeout: TimeInterval
    private let maxConcurrentSessions: Int

    init(promptTimeout: TimeInterval = 600, maxConcurrentSessions: Int = 5) {
        self.defaultPromptTimeout = promptTimeout
        self.maxConcurrentSessions = maxConcurrentSessions
    }

    // MARK: - Public API

    func startSession(
        agent: String,
        cwd: String,
        name: String? = nil,
        approvalPolicy: ApprovalPolicy = .approveReads
    ) async throws -> String {
        let activeCount = sessions.values.filter { session in
            if case .closed = session.status { return false }
            if case .failed = session.status { return false }
            return true
        }.count
        guard activeCount < maxConcurrentSessions else {
            throw SessionError.tooManySessions(activeCount)
        }

        // Resolve acpx eagerly so we fail fast at startSession rather than mid-prompt.
        _ = try await findACPXPath()

        let sessionId = UUID().uuidString
        let expandedCWD = NSString(string: cwd).expandingTildeInPath
        let now = Date()

        sessions[sessionId] = ACPSession(
            id: sessionId,
            agent: agent,
            cwd: expandedCWD,
            name: name,
            createdAt: now,
            lastActivityAt: now,
            status: .idle,
            turnCount: 0,
            history: [],
            lastToolCalls: [],
            approvalPolicy: approvalPolicy,
            inflight: nil
        )
        return sessionId
    }

    func prompt(
        sessionId: String,
        text: String,
        attachments: [ACPContentBlock] = []
    ) async throws -> ACPResponse {
        var session = try requireSession(sessionId)
        if session.inflight != nil {
            throw SessionError.promptAlreadyInFlight(sessionId)
        }
        if !attachments.isEmpty {
            NSLog("ACPSessionManager: attachments are not yet forwarded to acpx exec — dropping %d block(s) for session %@",
                  attachments.count, sessionId)
        }

        session.turnCount += 1
        session.status = .prompting
        session.lastActivityAt = Date()
        session.lastToolCalls = []
        sessions[sessionId] = session

        let acpxPath = try await findACPXPath()
        let transcript = buildTranscript(history: session.history, newUserText: text)

        // `acpx [globals] <agent> exec <prompt>` — see ACPSmokeTests for the
        // contract we're matching. exec is one-shot; we get the agent's reply
        // back as a stream of NDJSON events on stdout.
        var args: [String] = [
            "--cwd", session.cwd,
            "--format", "json",
        ]
        args.append(contentsOf: session.approvalPolicy.cliFlags)
        args.append(session.agent)
        args.append("exec")
        args.append(transcript)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: acpxPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: session.cwd)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            session.status = .failed(error: error.localizedDescription)
            sessions[sessionId] = session
            throw SessionError.processLaunchFailed(error.localizedDescription)
        }

        // Track the live process so cancel() can stop it.
        session.inflight = process
        sessions[sessionId] = session

        // Drive the subprocess to completion with a wall-clock deadline. The
        // continuation resolves once the process exits OR the timeout fires;
        // in either case we've cleared `inflight` before resuming.
        let timeout = defaultPromptTimeout
        let (stdoutData, stderrData, exitCode): (Data, Data, Int32)
        do {
            (stdoutData, stderrData, exitCode) = try await runProcess(
                process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                timeout: timeout
            )
        } catch {
            await clearInflight(sessionId: sessionId, status: .failed(error: error.localizedDescription))
            throw error
        }

        await clearInflight(sessionId: sessionId, status: nil)
        guard var refreshed = sessions[sessionId] else {
            throw SessionError.sessionNotFound(sessionId)
        }

        let parsed = parseExecOutput(stdoutData)
        refreshed.lastActivityAt = Date()

        if exitCode != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let combined = parsed.errorMessage ?? stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = combined.isEmpty ? "acpx exec exited with code \(exitCode)" : combined
            refreshed.status = .failed(error: message)
            sessions[sessionId] = refreshed
            throw SessionError.agentFailed(exitCode: exitCode, message: message)
        }

        if !parsed.text.isEmpty {
            refreshed.history.append(Turn(role: .user, text: text))
            refreshed.history.append(Turn(role: .assistant, text: parsed.text))
        }
        refreshed.lastToolCalls = parsed.toolCalls
        refreshed.status = .completed(stopReason: parsed.stopReason)
        sessions[sessionId] = refreshed

        return ACPResponse(
            text: parsed.text,
            toolCalls: parsed.toolCalls,
            stopReason: parsed.stopReason
        )
    }

    func status(sessionId: String) -> SessionStatus {
        sessions[sessionId]?.status ?? .failed(error: "Session not found")
    }

    func cancel(sessionId: String) async {
        guard let session = sessions[sessionId], let process = session.inflight else { return }
        if process.isRunning { process.terminate() }
    }

    func close(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }
        if let process = session.inflight, process.isRunning {
            process.terminate()
        }
        session.inflight = nil
        session.status = .closed
        session.lastActivityAt = Date()
        sessions[sessionId] = session
    }

    func activeSessions() -> [SessionInfo] {
        sessions.values
            .map {
                SessionInfo(
                    id: $0.id,
                    agent: $0.agent,
                    cwd: $0.cwd,
                    name: $0.name,
                    status: $0.status,
                    turnCount: $0.turnCount,
                    createdAt: $0.createdAt,
                    lastActivityAt: $0.lastActivityAt
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func cleanupStaleSessions(olderThan: TimeInterval) async {
        let cutoff = Date().addingTimeInterval(-olderThan)
        let staleIDs = sessions.values
            .filter { session in
                guard session.lastActivityAt < cutoff else { return false }
                switch session.status {
                case .prompting, .streaming, .awaitingApproval: return false
                default: return true
                }
            }
            .map(\.id)

        for sessionId in staleIDs {
            await close(sessionId: sessionId)
        }
    }

    // MARK: - Private Helpers

    private func requireSession(_ sessionId: String) throws -> ACPSession {
        guard let session = sessions[sessionId] else {
            throw SessionError.sessionNotFound(sessionId)
        }
        if case .closed = session.status {
            throw SessionError.sessionClosed(sessionId)
        }
        return session
    }

    private func clearInflight(sessionId: String, status: SessionStatus?) async {
        guard var session = sessions[sessionId] else { return }
        session.inflight = nil
        if let status { session.status = status }
        sessions[sessionId] = session
    }

    /// Stitch prior turns + new user text into a single transcript blob suitable
    /// for `acpx <agent> exec`. Format is intentionally agent-agnostic — codex,
    /// claude and pi all accept free-form prompts.
    private func buildTranscript(history: [Turn], newUserText: String) -> String {
        guard !history.isEmpty else { return newUserText }
        var lines: [String] = []
        for turn in history {
            switch turn.role {
            case .user:      lines.append("User: \(turn.text)")
            case .assistant: lines.append("Assistant: \(turn.text)")
            }
        }
        lines.append("User: \(newUserText)")
        return lines.joined(separator: "\n\n")
    }

    private struct ExecParseResult {
        var text: String = ""
        var toolCalls: [ToolCallInfo] = []
        var stopReason: String = "unknown"
        var errorMessage: String? = nil
    }

    /// codex-acp emits transport-layer warnings as plain `agent_message_chunk`
    /// events — they're indistinguishable from real assistant text at the
    /// protocol level. Filter the known ones so they don't pollute the
    /// conversation history we re-feed each turn.
    private static let agentNoiseMarkers: [String] = [
        "Falling back from WebSockets to HTTPS transport",
        "stream disconnected before completion",
        "no native root CA certificates found",
    ]

    private static func isAgentTransportNoise(_ text: String) -> Bool {
        agentNoiseMarkers.contains(where: text.contains)
    }

    /// Walk NDJSON output from `acpx --format json <agent> exec`. We only need
    /// the assistant text chunks, optional tool-call updates, and the final
    /// stopReason from the `session/prompt` result.
    private func parseExecOutput(_ data: Data) -> ExecParseResult {
        guard let raw = String(data: data, encoding: .utf8) else { return ExecParseResult() }
        var result = ExecParseResult()
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                result.errorMessage = message
                continue
            }

            if let resultBlock = json["result"] as? [String: Any],
               let stopReason = resultBlock["stopReason"] as? String {
                result.stopReason = stopReason
                continue
            }

            guard let params = json["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  let kind = update["sessionUpdate"] as? String
            else { continue }

            switch kind {
            case "agent_message_chunk":
                if let content = update["content"] as? [String: Any],
                   let text = content["text"] as? String,
                   !Self.isAgentTransportNoise(text) {
                    result.text += text
                }
            case "tool_call":
                if let toolName = update["title"] as? String ?? update["name"] as? String,
                   let toolCallId = update["toolCallId"] as? String {
                    let input = (update["rawInput"] as? String) ?? ""
                    result.toolCalls.append(
                        ToolCallInfo(
                            toolName: toolName,
                            toolCallId: toolCallId,
                            input: input,
                            output: "",
                            isComplete: false
                        )
                    )
                }
            case "tool_call_update":
                if let toolCallId = update["toolCallId"] as? String,
                   let idx = result.toolCalls.firstIndex(where: { $0.toolCallId == toolCallId }) {
                    var info = result.toolCalls[idx]
                    if let content = update["rawOutput"] as? String { info.output += content }
                    if let status = update["status"] as? String, status == "completed" || status == "failed" {
                        info.isComplete = true
                    }
                    result.toolCalls[idx] = info
                }
            default:
                continue
            }
        }
        return result
    }

    /// Run a Process to completion, returning (stdout, stderr, exitCode). Fires
    /// `terminate()` if `timeout` expires; throws SessionError.promptTimeout.
    private func runProcess(
        _ process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeout: TimeInterval
    ) async throws -> (Data, Data, Int32) {
        try await withThrowingTaskGroup(of: (Data, Data, Int32)?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<(Data, Data, Int32), Never>) in
                    process.terminationHandler = { proc in
                        let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                        let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                        cont.resume(returning: (outData, errData, proc.terminationStatus))
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning { process.terminate() }
                throw SessionError.promptTimeout(timeout)
            }
            guard let value = try await group.next(), let unwrapped = value else {
                throw SessionError.processLaunchFailed("no result")
            }
            group.cancelAll()
            return unwrapped
        }
    }

    // MARK: - acpx binary discovery (unchanged from prior implementation)

    private func findACPXPath() async throws -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        let candidates: [String?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Binaries/acpx").path,
            Bundle.faeResources.resourceURL?.appendingPathComponent("Binaries/acpx").path,
            "/usr/local/bin/acpx",
            "\(home)/.npm/bin/acpx",
            "\(home)/.bun/bin/acpx",
            "\(home)/.local/bin/acpx",
            await findInPATH(binary: "acpx"),
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let expanded = NSString(string: candidate).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        NSLog("ACPSessionManager: acpx not found — attempting auto-install")
        if let installed = await autoInstallACPX() {
            return installed
        }

        throw SessionError.acpxNotFound
    }

    private func autoInstallACPX() async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        if let bunPath = await findInPATH(binary: "bun") {
            if await runInstallProcess(executable: bunPath, arguments: ["install", "-g", "acpx"]) {
                let candidate = "\(home)/.bun/bin/acpx"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    NSLog("ACPSessionManager: acpx installed via bun at %@", candidate)
                    return candidate
                }
            }
        }

        if let npmPath = await findInPATH(binary: "npm") {
            if await runInstallProcess(executable: npmPath, arguments: ["install", "-g", "acpx"]) {
                let candidate = "\(home)/.npm/bin/acpx"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    NSLog("ACPSessionManager: acpx installed via npm at %@", candidate)
                    return candidate
                }
            }
        }
        return nil
    }

    private func runInstallProcess(executable: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    private func findInPATH(binary: String) async -> String? {
        await withCheckedContinuation { continuation in
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = [binary]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = Pipe()
            which.terminationHandler = { _ in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (path?.isEmpty == false) ? path : nil)
            }
            do {
                try which.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
