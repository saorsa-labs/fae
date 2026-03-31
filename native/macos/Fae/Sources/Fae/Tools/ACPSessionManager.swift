import Foundation

actor ACPSessionManager {

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

    /// Public snapshot type for UI / scheduler diagnostics.
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

        /// Maps to ACPX CLI startup flags.
        var cliFlags: [String] {
            switch self {
            case .approveReads:
                return ["--approve-reads"]
            case .approveAll:
                return ["--approve-all"]
            case .denyAll:
                return ["--deny-all"]
            }
        }
    }

    struct ACPSession {
        let id: String
        let agent: String
        let cwd: String
        let name: String?

        let createdAt: Date
        var lastActivityAt: Date
        var status: SessionStatus

        var process: Process?
        var stdinPipe: Pipe?
        var stdoutPipe: Pipe?

        var turnCount: Int
        var toolCallsThisTurn: [ToolCallInfo]
        var lastResponse: String?
        var accumulatedResponse: String

        var approvalPolicy: ApprovalPolicy
    }

    enum SessionError: LocalizedError {
        case acpxNotFound
        case sessionNotFound(String)
        case sessionClosed(String)
        case promptAlreadyInFlight(String)
        case processLaunchFailed(String)
        case stdinUnavailable
        case promptTimeout(TimeInterval)
        case requestSerializationFailed(String)
        case tooManySessions(Int)

        var errorDescription: String? {
            switch self {
            case .acpxNotFound:
                return "acpx binary not found in bundled resources or fallback locations."
            case .sessionNotFound(let sessionId):
                return "ACP session not found: \(sessionId)"
            case .sessionClosed(let sessionId):
                return "ACP session is closed: \(sessionId)"
            case .promptAlreadyInFlight(let sessionId):
                return "ACP session already has a prompt in flight: \(sessionId)"
            case .processLaunchFailed(let reason):
                return "Failed to launch acpx: \(reason)"
            case .stdinUnavailable:
                return "ACP session stdin is unavailable."
            case .promptTimeout(let seconds):
                return "ACP prompt timed out after \(Int(seconds)) seconds"
            case .requestSerializationFailed(let reason):
                return "Failed to serialize ACP request: \(reason)"
            case .tooManySessions(let count):
                return "Too many active ACP sessions (\(count)); close one before starting another."
            }
        }
    }

    private struct PendingPrompt {
        let continuation: CheckedContinuation<Result<ACPResponse, Swift.Error>, Never>
        let timeoutTask: Task<Void, Never>
    }

    private static let readOnlyTools: Set<String> = [
        "read", "window_control", "session_search", "web_search", "fetch_url",
        "calendar", "reminders", "contacts", "mail", "notes",
        "scheduler_list", "roleplay",
        "activate_skill",
        "input_request",
        "find_element",
        "voice_identity",
        "till_done"
    ]

    private var sessions: [String: ACPSession] = [:]
    private var pendingPrompts: [String: PendingPrompt] = [:]
    private var stdoutBuffers: [String: String] = [:]

    private let parser = ACPEventParser()
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

        let acpxPath = try await findACPXPath()
        let sessionId = UUID().uuidString
        let expandedCWD = NSString(string: cwd).expandingTildeInPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: acpxPath)
        process.arguments = [agent, "--cwd", expandedCWD] + approvalPolicy.cliFlags
        process.currentDirectoryURL = URL(fileURLWithPath: expandedCWD)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let now = Date()
        sessions[sessionId] = ACPSession(
            id: sessionId,
            agent: agent,
            cwd: expandedCWD,
            name: name,
            createdAt: now,
            lastActivityAt: now,
            status: .idle,
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            turnCount: 0,
            toolCallsThisTurn: [],
            lastResponse: nil,
            accumulatedResponse: "",
            approvalPolicy: approvalPolicy
        )

        process.terminationHandler = { [sessionId] terminatedProcess in
            Task {
                await self.handleProcessTermination(
                    sessionId: sessionId,
                    terminationStatus: terminatedProcess.terminationStatus
                )
            }
        }

        do {
            try process.run()
            startReadingStdout(for: sessionId, from: stdoutPipe)
            startReadingStderr(for: sessionId, from: stderrPipe)
        } catch {
            sessions.removeValue(forKey: sessionId)
            throw SessionError.processLaunchFailed(error.localizedDescription)
        }

        return sessionId
    }

    func prompt(
        sessionId: String,
        text: String,
        attachments: [ACPContentBlock] = []
    ) async throws -> ACPResponse {
        var session = try requireSession(sessionId)

        guard pendingPrompts[sessionId] == nil else {
            throw SessionError.promptAlreadyInFlight(sessionId)
        }

        session.turnCount += 1
        session.status = .prompting
        session.lastActivityAt = Date()
        session.toolCallsThisTurn = []
        session.accumulatedResponse = ""
        session.lastResponse = nil
        sessions[sessionId] = session

        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<ACPResponse, Swift.Error>, Never>) in
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(defaultPromptTimeout * 1_000_000_000))
                    await self.failPendingPrompt(
                        sessionId: sessionId,
                        error: SessionError.promptTimeout(self.defaultPromptTimeout)
                    )
                }

                pendingPrompts[sessionId] = PendingPrompt(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                do {
                    try send(
                        request: .prompt(sessionId: sessionId, text: text, attachments: attachments),
                        to: sessionId
                    )
                } catch {
                    if let pending = pendingPrompts.removeValue(forKey: sessionId) {
                        pending.timeoutTask.cancel()
                    }
                    continuation.resume(returning: .failure(error))
                }
            }

            switch result {
            case .success(let response):
                return response
            case .failure(let error):
                throw error
            }
        } onCancel: {
            Task {
                await self.cancel(sessionId: sessionId)
                await self.failPendingPrompt(sessionId: sessionId, error: CancellationError())
            }
        }
    }

    func status(sessionId: String) -> SessionStatus {
        sessions[sessionId]?.status ?? .failed(error: "Session not found")
    }

    func cancel(sessionId: String) async {
        guard sessions[sessionId] != nil else { return }
        do {
            try send(request: .cancelTurn(sessionId: sessionId), to: sessionId)
        } catch {
            NSLog("ACPSessionManager: failed to send cancel_turn for %@ — %@", sessionId, error.localizedDescription)
        }
    }

    func close(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        session.stdoutPipe?.fileHandleForReading.readabilityHandler = nil

        if let process = session.process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.interrupt()
                // Final wait before SIGKILL.
                let killDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < killDeadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        session.status = .closed
        session.lastActivityAt = Date()
        session.process = nil
        session.stdinPipe = nil
        session.stdoutPipe = nil
        sessions[sessionId] = session

        await failPendingPrompt(sessionId: sessionId, error: SessionError.sessionClosed(sessionId))
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
                case .prompting, .streaming, .awaitingApproval:
                    return false
                default:
                    return true
                }
            }
            .map(\.id)

        for sessionId in staleIDs {
            await close(sessionId: sessionId)
        }
    }

    // MARK: - Process I/O

    private func startReadingStdout(for sessionId: String, from pipe: Pipe) {
        stdoutBuffers[sessionId] = ""
        let reader = pipe.fileHandleForReading

        reader.readabilityHandler = { [sessionId] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                Task {
                    await self.flushStdoutBuffer(for: sessionId)
                }
                return
            }

            let chunk = String(data: data, encoding: .utf8) ?? ""
            Task {
                await self.consumeStdoutChunk(chunk, for: sessionId)
            }
        }
    }

    private func startReadingStderr(for sessionId: String, from pipe: Pipe) {
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                NSLog("ACPSessionManager [%@] stderr: %@", sessionId, text)
            }
        }
    }
    private func consumeStdoutChunk(_ chunk: String, for sessionId: String) async {
        var buffer = stdoutBuffers[sessionId, default: ""]
        buffer.append(chunk)

        let lines = buffer.components(separatedBy: "\n")
        stdoutBuffers[sessionId] = lines.last ?? ""

        for line in lines.dropLast() where !line.isEmpty {
            await handleStdoutLine(line, sessionId: sessionId)
        }
    }

    private func flushStdoutBuffer(for sessionId: String) async {
        guard let remainder = stdoutBuffers[sessionId], !remainder.isEmpty else { return }
        stdoutBuffers[sessionId] = ""
        await handleStdoutLine(remainder, sessionId: sessionId)
    }

    private func handleStdoutLine(_ line: String, sessionId: String) async {
        guard sessions[sessionId] != nil else { return }

        do {
            guard let event = try parser.parse(line: line) else { return }
            await handle(event: event)
        } catch {
            NSLog(
                "ACPSessionManager: failed to parse ACP event line for %@ — %@",
                sessionId,
                error.localizedDescription
            )
        }
    }

    private func handle(event: ACPEvent) async {
        switch event {
        case .agentMessageChunk(let sessionId, let content, _):
            guard var session = sessions[sessionId] else { return }
            session.accumulatedResponse.append(content)
            session.lastActivityAt = Date()
            session.status = .streaming(tokensReceived: tokenEstimate(for: session.accumulatedResponse))
            sessions[sessionId] = session

        case .toolCall(let sessionId, let toolName, let toolCallId, let input):
            guard var session = sessions[sessionId] else { return }
            session.lastActivityAt = Date()
            session.toolCallsThisTurn.append(
                ToolCallInfo(
                    toolName: toolName,
                    toolCallId: toolCallId,
                    input: input,
                    output: "",
                    isComplete: false
                )
            )
            sessions[sessionId] = session

        case .toolUpdate(let sessionId, let toolCallId, let output, let isComplete):
            guard var session = sessions[sessionId] else { return }
            session.lastActivityAt = Date()

            if let idx = session.toolCallsThisTurn.firstIndex(where: { $0.toolCallId == toolCallId }) {
                var info = session.toolCallsThisTurn[idx]
                info.output.append(output)
                info.isComplete = isComplete
                session.toolCallsThisTurn[idx] = info
            }

            sessions[sessionId] = session

        case .requestPermission(let sessionId, let toolName, let description, let requestId):
            guard var session = sessions[sessionId] else { return }
            session.status = .awaitingApproval(toolName: toolName, description: description)
            session.lastActivityAt = Date()
            sessions[sessionId] = session

            let approved = shouldApprove(toolName: toolName, policy: session.approvalPolicy)
            do {
                try send(request: .approvePermission(requestId: requestId, approved: approved), to: sessionId)

                if approved, var updated = sessions[sessionId] {
                    updated.status = .streaming(tokensReceived: tokenEstimate(for: updated.accumulatedResponse))
                    sessions[sessionId] = updated
                }
            } catch {
                NSLog(
                    "ACPSessionManager: failed to send permission response for %@ — %@",
                    sessionId,
                    error.localizedDescription
                )
            }

        case .sessionComplete(let sessionId, let stopReason):
            guard var session = sessions[sessionId] else { return }

            session.status = .completed(stopReason: stopReason)
            session.lastResponse = session.accumulatedResponse
            session.lastActivityAt = Date()
            sessions[sessionId] = session

            completePromptIfNeeded(
                sessionId: sessionId,
                response: ACPResponse(
                    text: session.accumulatedResponse,
                    toolCalls: session.toolCallsThisTurn,
                    stopReason: stopReason
                )
            )

        case .error(let sessionId, _, let message):
            if let sessionId, var session = sessions[sessionId] {
                session.status = .failed(error: message)
                session.lastActivityAt = Date()
                sessions[sessionId] = session

                await failPendingPrompt(
                    sessionId: sessionId,
                    error: NSError(
                        domain: "ACPSessionManager",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                )
            } else {
                NSLog("ACPSessionManager: ACP error without session id — %@", message)
            }
        }
    }

    private func handleProcessTermination(sessionId: String, terminationStatus: Int32) async {
        guard var session = sessions[sessionId] else { return }

        session.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        session.process = nil
        session.stdinPipe = nil
        session.stdoutPipe = nil
        session.lastActivityAt = Date()

        if case .completed = session.status {
            // Keep completed status.
        } else if case .closed = session.status {
            // Keep closed status.
        } else if terminationStatus == 0 {
            session.status = .closed
        } else {
            session.status = .failed(error: "acpx terminated with code \(terminationStatus)")
        }

        sessions[sessionId] = session

        if case .failed(let message) = session.status {
            await failPendingPrompt(
                sessionId: sessionId,
                error: NSError(
                    domain: "ACPSessionManager",
                    code: Int(terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            )
        } else if case .closed = session.status {
            await failPendingPrompt(sessionId: sessionId, error: SessionError.sessionClosed(sessionId))
        }
    }

    // MARK: - Request Sending

    private func send(request: ACPRequest, to sessionId: String) throws {
        guard let session = sessions[sessionId],
              let stdin = session.stdinPipe?.fileHandleForWriting
        else {
            throw SessionError.stdinUnavailable
        }

        let line: String
        do {
            line = try request.serializedLine()
        } catch {
            throw SessionError.requestSerializationFailed(error.localizedDescription)
        }

        guard let data = line.data(using: .utf8) else {
            throw SessionError.requestSerializationFailed("UTF-8 encoding failure")
        }

        do {
            try stdin.write(contentsOf: data)
            if var updated = sessions[sessionId] {
                updated.lastActivityAt = Date()
                sessions[sessionId] = updated
            }
        } catch {
            throw error
        }
    }

    // MARK: - Prompt Completion

    private func completePromptIfNeeded(sessionId: String, response: ACPResponse) {
        guard let pending = pendingPrompts.removeValue(forKey: sessionId) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: .success(response))
    }

    private func failPendingPrompt(sessionId: String, error: Swift.Error) async {
        guard let pending = pendingPrompts.removeValue(forKey: sessionId) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: .failure(error))
    }

    // MARK: - Helpers

    private func requireSession(_ sessionId: String) throws -> ACPSession {
        guard let session = sessions[sessionId] else {
            throw SessionError.sessionNotFound(sessionId)
        }

        if case .closed = session.status {
            throw SessionError.sessionClosed(sessionId)
        }

        return session
    }

    private func shouldApprove(toolName: String, policy: ApprovalPolicy) -> Bool {
        switch policy {
        case .approveAll:
            return true
        case .denyAll:
            return false
        case .approveReads:
            return isReadTool(toolName)
        }
    }

    private func isReadTool(_ toolName: String) -> Bool {
        Self.readOnlyTools.contains(toolName.lowercased())
    }

    private func tokenEstimate(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

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

        // Auto-install acpx on first use — try bun first, fall back to npm.
        NSLog("ACPSessionManager: acpx not found — attempting auto-install")
        if let installed = await autoInstallACPX() {
            return installed
        }

        throw SessionError.acpxNotFound
    }

    /// Attempt to install acpx globally via bun or npm.
    /// Returns the installed binary path on success, nil on failure.
    private func autoInstallACPX() async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Try bun first (faster, preferred).
        let bunPath = await findInPATH(binary: "bun")
        if let bunPath {
            let result = await runInstallProcess(
                executable: bunPath,
                arguments: ["install", "-g", "acpx"]
            )
            if result {
                let candidate = "\(home)/.bun/bin/acpx"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    NSLog("ACPSessionManager: acpx installed via bun at %@", candidate)
                    return candidate
                }
            }
        }

        // Fall back to npm.
        let npmPath = await findInPATH(binary: "npm")
        if let npmPath {
            let result = await runInstallProcess(
                executable: npmPath,
                arguments: ["install", "-g", "acpx"]
            )
            if result {
                // npm global bin varies — check common locations.
                let npmCandidates = [
                    "\(home)/.npm/bin/acpx",
                    "/usr/local/bin/acpx",
                    "\(home)/.local/bin/acpx",
                ]
                for candidate in npmCandidates {
                    if FileManager.default.isExecutableFile(atPath: candidate) {
                        NSLog("ACPSessionManager: acpx installed via npm at %@", candidate)
                        return candidate
                    }
                }
                // Try PATH as last resort after npm install.
                if let pathResult = await findInPATH(binary: "acpx") {
                    NSLog("ACPSessionManager: acpx installed via npm at %@", pathResult)
                    return pathResult
                }
            }
        }

        NSLog("ACPSessionManager: auto-install failed — neither bun nor npm could install acpx")
        return nil
    }

    /// Run an install command and return true if exit code is 0.
    private func runInstallProcess(executable: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                NSLog("ACPSessionManager: install process failed to launch: %@", error.localizedDescription)
                continuation.resume(returning: false)
            }
        }
    }

    private func findInPATH(binary: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [binary]

            // Signed apps inherit a minimal PATH — supply a rich one so we
            // find binaries in common developer locations (~/.bun/bin, etc.).
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            process.environment = [
                "PATH": [
                    "\(home)/.bun/bin",
                    "\(home)/.local/bin",
                    "\(home)/.cargo/bin",
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/usr/bin",
                    "/bin",
                ].joined(separator: ":"),
                "HOME": home,
            ]

            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { _ in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty, process.terminationStatus == 0 {
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
