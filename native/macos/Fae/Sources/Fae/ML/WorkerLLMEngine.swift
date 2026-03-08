import Foundation
import MLXLMCommon

private enum WorkerLLMError: LocalizedError {
    case executableUnavailable
    case transportUnavailable
    case malformedResponse
    case commandTimeout(String)
    case streamTimeout(String)
    case workerFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "Unable to locate Fae executable for worker launch"
        case .transportUnavailable:
            return "Worker transport is not available"
        case .malformedResponse:
            return "Worker returned a malformed response"
        case .commandTimeout(let command):
            return "Worker command timed out: \(command)"
        case .streamTimeout(let detail):
            return "Worker stream timed out: \(detail)"
        case .workerFailed(let message):
            return message
        }
    }
}

enum WorkerStreamWatchdogPhase: Sendable {
    case awaitingFirstEvent
    case streamingActive

    var description: String {
        switch self {
        case .awaitingFirstEvent:
            return "waiting for first token"
        case .streamingActive:
            return "stream stalled"
        }
    }
}

struct WorkerStreamWatchdogPolicy {
    static let initialResponseTimeoutNanoseconds: UInt64 = 45_000_000_000
    static let activeStreamTimeoutNanoseconds: UInt64 = 15_000_000_000

    static func timeout(for phase: WorkerStreamWatchdogPhase) -> UInt64 {
        switch phase {
        case .awaitingFirstEvent:
            return initialResponseTimeoutNanoseconds
        case .streamingActive:
            return activeStreamTimeoutNanoseconds
        }
    }
}

actor WorkerLLMEngine: LLMEngine {
    private let role: WorkerProcessRole
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var commandContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var pendingCommandTimeouts: [String: Task<Void, Never>] = [:]
    private var streamContinuations: [String: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation] = [:]
    private var streamWatchdogs: [String: Task<Void, Never>] = [:]
    private var lastLoadedModelID: String?
    private var restartCount: Int = 0
    private let commandTimeoutNanoseconds: UInt64 = 30_000_000_000

    private(set) var isLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted

    init(role: WorkerProcessRole) {
        self.role = role
    }

    func load(modelID: String) async throws {
        loadState = .loading
        try await ensureProcess()
        let requestID = UUID().uuidString
        try await sendAwaitingAck(
            LLMWorkerRequest(
                requestID: requestID,
                command: "load",
                role: role,
                modelID: modelID,
                messages: nil,
                systemPrompt: nil,
                options: nil
            )
        )
        isLoaded = true
        loadState = .loaded
        lastLoadedModelID = modelID
        persistWorkerState(lastError: nil)
    }

    func generate(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let requestID = UUID().uuidString
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.cancelStream(requestID: requestID)
                }
            }

            Task {
                do {
                    try await self.ensureProcess()
                    self.registerStreamContinuation(continuation, requestID: requestID)
                    try self.send(
                        LLMWorkerRequest(
                            requestID: requestID,
                            command: "generate",
                            role: self.role,
                            modelID: nil,
                            messages: messages.map(WorkerLLMMessage.init),
                            systemPrompt: systemPrompt,
                            options: WorkerGenerationOptions(options)
                        )
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func warmup() async {
        do {
            try await ensureProcess()
            try await sendAwaitingAck(
                LLMWorkerRequest(
                    requestID: UUID().uuidString,
                    command: "warmup",
                    role: role,
                    modelID: nil,
                    messages: nil,
                    systemPrompt: nil,
                    options: nil
                )
            )
        } catch {
            NSLog("WorkerLLMEngine[%@]: warmup failed: %@", role.rawValue, error.localizedDescription)
        }
    }

    func synchronizeSession(history: [LLMMessage]) async {
        do {
            try await ensureProcess()
            try await sendAwaitingAck(
                LLMWorkerRequest(
                    requestID: UUID().uuidString,
                    command: "sync_session",
                    role: role,
                    modelID: nil,
                    messages: history.map(WorkerLLMMessage.init),
                    systemPrompt: nil,
                    options: nil
                )
            )
        } catch {
            NSLog("WorkerLLMEngine[%@]: sync_session failed: %@", role.rawValue, error.localizedDescription)
        }
    }

    func resetSession() async {
        do {
            try await ensureProcess()
            try await sendAwaitingAck(
                LLMWorkerRequest(
                    requestID: UUID().uuidString,
                    command: "reset_session",
                    role: role,
                    modelID: nil,
                    messages: nil,
                    systemPrompt: nil,
                    options: nil
                )
            )
        } catch {
            NSLog("WorkerLLMEngine[%@]: reset_session failed: %@", role.rawValue, error.localizedDescription)
        }
    }

    private func registerStreamContinuation(
        _ continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation,
        requestID: String
    ) {
        streamContinuations[requestID] = continuation
        armStreamWatchdog(for: requestID, phase: .awaitingFirstEvent)
    }

    private func cancelStream(requestID: String) async {
        streamContinuations.removeValue(forKey: requestID)
        clearStreamTracking(requestID: requestID)
        guard process?.isRunning == true else { return }
        try? send(
            LLMWorkerRequest(
                requestID: requestID,
                command: "cancel",
                role: role,
                modelID: nil,
                messages: nil,
                systemPrompt: nil,
                options: nil
            )
        )
    }

    private func armStreamWatchdog(for requestID: String, phase: WorkerStreamWatchdogPhase) {
        streamWatchdogs[requestID]?.cancel()
        let timeout = WorkerStreamWatchdogPolicy.timeout(for: phase)
        streamWatchdogs[requestID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            await self?.handleStreamTimeout(requestID: requestID, phase: phase)
        }
    }

    private func noteStreamProgress(requestID: String) {
        guard streamContinuations[requestID] != nil else { return }
        armStreamWatchdog(for: requestID, phase: .streamingActive)
    }

    private func clearStreamTracking(requestID: String) {
        streamWatchdogs[requestID]?.cancel()
        streamWatchdogs.removeValue(forKey: requestID)
    }

    private func handleStreamTimeout(requestID: String, phase: WorkerStreamWatchdogPhase) {
        guard let continuation = streamContinuations.removeValue(forKey: requestID) else { return }
        clearStreamTracking(requestID: requestID)
        let error = WorkerLLMError.streamTimeout(phase.description)
        continuation.finish(throwing: error)
        persistWorkerState(lastError: error.localizedDescription)

        try? send(
            LLMWorkerRequest(
                requestID: requestID,
                command: "cancel",
                role: role,
                modelID: nil,
                messages: nil,
                systemPrompt: nil,
                options: nil
            )
        )

        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func ensureProcess() async throws {
        if let process, process.isRunning {
            return
        }

        let executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--llm-worker", "--role", role.rawValue]

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError

        try process.run()

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading
        self.readTask?.cancel()
        self.readTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.readResponses(from: stdout.fileHandleForReading)
        }

        if lastLoadedModelID != nil {
            restartCount += 1
        }
        persistWorkerState(lastError: nil)
        NSLog("WorkerLLMEngine[%@]: launched worker pid=%d", role.rawValue, process.processIdentifier)

        if let lastLoadedModelID, !isLoaded {
            try await sendAwaitingAck(
                LLMWorkerRequest(
                    requestID: UUID().uuidString,
                    command: "load",
                    role: role,
                    modelID: lastLoadedModelID,
                    messages: nil,
                    systemPrompt: nil,
                    options: nil
                )
            )
            isLoaded = true
            loadState = .loaded
            persistWorkerState(lastError: nil)
            NSLog("WorkerLLMEngine[%@]: restored model %@ after worker restart", role.rawValue, lastLoadedModelID)
        }
    }

    private func sendAwaitingAck(_ request: LLMWorkerRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commandContinuations[request.requestID] = continuation
            pendingCommandTimeouts[request.requestID] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.commandTimeoutNanoseconds ?? 30_000_000_000)
                await self?.timeoutCommand(requestID: request.requestID, command: request.command)
            }
            do {
                try send(request)
            } catch {
                pendingCommandTimeouts[request.requestID]?.cancel()
                pendingCommandTimeouts.removeValue(forKey: request.requestID)
                commandContinuations.removeValue(forKey: request.requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func timeoutCommand(requestID: String, command: String) {
        guard let continuation = commandContinuations.removeValue(forKey: requestID) else { return }
        pendingCommandTimeouts[requestID]?.cancel()
        pendingCommandTimeouts.removeValue(forKey: requestID)
        let error = WorkerLLMError.commandTimeout(command)
        continuation.resume(throwing: error)
        persistWorkerState(lastError: error.localizedDescription)
    }

    private func send(_ request: LLMWorkerRequest) throws {
        guard let stdinHandle else {
            throw WorkerLLMError.transportUnavailable
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        guard var line = String(data: data, encoding: .utf8) else {
            throw WorkerLLMError.transportUnavailable
        }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else {
            throw WorkerLLMError.transportUnavailable
        }
        try stdinHandle.write(contentsOf: lineData)
    }

    private func readResponses(from stdout: FileHandle) async {
        do {
            for try await line in stdout.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let data = trimmed.data(using: .utf8) else { continue }
                let response = try JSONDecoder().decode(LLMWorkerResponse.self, from: data)
                handle(response: response)
            }
        } catch {
            handleWorkerTermination(error: error)
            return
        }

        handleWorkerTermination(error: nil)
    }

    private func handle(response: LLMWorkerResponse) {
        pendingCommandTimeouts[response.requestID]?.cancel()
        pendingCommandTimeouts.removeValue(forKey: response.requestID)

        switch response.type {
        case "ack":
            if let continuation = commandContinuations.removeValue(forKey: response.requestID) {
                continuation.resume()
            }

        case "text":
            noteStreamProgress(requestID: response.requestID)
            streamContinuations[response.requestID]?.yield(.text(response.text ?? ""))

        case "tool_call":
            noteStreamProgress(requestID: response.requestID)
            guard let toolName = response.toolName else { return }
            let arguments = (response.toolArguments ?? [:]).mapValues(\.anyValue)
            let toolCall = ToolCall(function: .init(name: toolName, arguments: arguments))
            streamContinuations[response.requestID]?.yield(.toolCall(toolCall))

        case "end":
            clearStreamTracking(requestID: response.requestID)
            if let continuation = streamContinuations.removeValue(forKey: response.requestID) {
                continuation.finish()
            }

        case "error":
            clearStreamTracking(requestID: response.requestID)
            let error = WorkerLLMError.workerFailed(response.error ?? "Unknown worker error")
            if let continuation = commandContinuations.removeValue(forKey: response.requestID) {
                continuation.resume(throwing: error)
            }
            if let stream = streamContinuations.removeValue(forKey: response.requestID) {
                stream.finish(throwing: error)
            }

        default:
            clearStreamTracking(requestID: response.requestID)
            let error = WorkerLLMError.malformedResponse
            if let continuation = commandContinuations.removeValue(forKey: response.requestID) {
                continuation.resume(throwing: error)
            }
            if let stream = streamContinuations.removeValue(forKey: response.requestID) {
                stream.finish(throwing: error)
            }
        }
    }

    private func handleWorkerTermination(error: Error?) {
        let failure = error ?? WorkerLLMError.transportUnavailable
        loadState = .failed(failure.localizedDescription)
        isLoaded = false
        process = nil
        stdinHandle = nil
        stdoutHandle = nil

        for (_, timeoutTask) in pendingCommandTimeouts {
            timeoutTask.cancel()
        }
        pendingCommandTimeouts.removeAll()

        for (_, watchdog) in streamWatchdogs {
            watchdog.cancel()
        }
        streamWatchdogs.removeAll()

        for (_, continuation) in commandContinuations {
            continuation.resume(throwing: failure)
        }
        commandContinuations.removeAll()

        for (_, continuation) in streamContinuations {
            continuation.finish(throwing: failure)
        }
        streamContinuations.removeAll()

        persistWorkerState(lastError: failure.localizedDescription)
        NSLog("WorkerLLMEngine[%@]: worker terminated (%@)", role.rawValue, failure.localizedDescription)
    }

    private func persistWorkerState(lastError: String?) {
        let prefix = role.rawValue == WorkerProcessRole.operatorModel.rawValue ? "operator" : "concierge"
        UserDefaults.standard.set("worker_process", forKey: "fae.runtime.\(prefix)_runtime")
        UserDefaults.standard.set(restartCount, forKey: "fae.runtime.\(prefix)_worker_restarts")
        UserDefaults.standard.set(lastError, forKey: "fae.runtime.\(prefix)_worker_last_error")
    }
}

final class LLMWorkerService {
    private let role: WorkerProcessRole
    private let engine = MLXLLMEngine()
    private let stdoutLock = NSLock()
    private var generationTasks: [String: Task<Void, Never>] = [:]

    init(role: WorkerProcessRole) {
        self.role = role
    }

    func run() {
        let stdin = FileHandle.standardInput
        var buffered = Data()

        while true {
            let data = stdin.availableData
            if data.isEmpty { break }
            buffered.append(data)

            while let newlineRange = buffered.range(of: Data([0x0A])) {
                let lineData = buffered.subdata(in: buffered.startIndex..<newlineRange.lowerBound)
                buffered.removeSubrange(buffered.startIndex...newlineRange.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                handle(line: line)
            }
        }
    }

    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }

        do {
            let request = try JSONDecoder().decode(LLMWorkerRequest.self, from: data)
            guard request.role == role else {
                send(
                    LLMWorkerResponse(
                        requestID: request.requestID,
                        type: "error",
                        role: role,
                        text: nil,
                        error: "Worker role mismatch",
                        toolName: nil,
                        toolArguments: nil
                    )
                )
                return
            }

            switch request.command {
            case "load":
                runSync(requestID: request.requestID) {
                    guard let modelID = request.modelID else {
                        throw WorkerLLMError.workerFailed("Missing model ID")
                    }
                    try await self.engine.load(modelID: modelID)
                }

            case "warmup":
                Task {
                    await self.engine.warmup()
                    self.sendAck(requestID: request.requestID)
                }

            case "sync_session":
                Task {
                    await self.engine.synchronizeSession(history: (request.messages ?? []).map(\.llmMessage))
                    self.sendAck(requestID: request.requestID)
                }

            case "reset_session":
                Task {
                    await self.engine.resetSession()
                    self.sendAck(requestID: request.requestID)
                }

            case "generate":
                guard let systemPrompt = request.systemPrompt,
                      let options = request.options
                else {
                    sendError(requestID: request.requestID, message: "Missing generation payload")
                    return
                }
                let messages = (request.messages ?? []).map(\.llmMessage)
                let task = Task {
                    let stream = await self.engine.generate(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        options: options.generationOptions
                    )
                    do {
                        for try await event in stream {
                            switch event {
                            case .text(let text):
                                self.send(
                                    LLMWorkerResponse(
                                        requestID: request.requestID,
                                        type: "text",
                                        role: self.role,
                                        text: text,
                                        error: nil,
                                        toolName: nil,
                                        toolArguments: nil
                                    )
                                )
                            case .toolCall(let call):
                                let args = call.function.arguments.mapValues { WorkerJSONValue.from(any: $0.anyValue) ?? .null }
                                self.send(
                                    LLMWorkerResponse(
                                        requestID: request.requestID,
                                        type: "tool_call",
                                        role: self.role,
                                        text: nil,
                                        error: nil,
                                        toolName: call.function.name,
                                        toolArguments: args
                                    )
                                )
                            case .info:
                                continue
                            }
                        }
                        self.send(
                            LLMWorkerResponse(
                                requestID: request.requestID,
                                type: "end",
                                role: self.role,
                                text: nil,
                                error: nil,
                                toolName: nil,
                                toolArguments: nil
                            )
                        )
                    } catch {
                        self.sendError(requestID: request.requestID, message: error.localizedDescription)
                    }
                    self.generationTasks.removeValue(forKey: request.requestID)
                }
                generationTasks[request.requestID] = task

            case "cancel":
                generationTasks[request.requestID]?.cancel()
                generationTasks.removeValue(forKey: request.requestID)
                sendAck(requestID: request.requestID)

            default:
                sendError(requestID: request.requestID, message: "Unsupported worker command: \(request.command)")
            }
        } catch {
            sendError(requestID: "unknown", message: error.localizedDescription)
        }
    }

    private func runSync(requestID: String, operation: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await operation()
                self.sendAck(requestID: requestID)
            } catch {
                self.sendError(requestID: requestID, message: error.localizedDescription)
            }
        }
    }

    private func sendAck(requestID: String) {
        send(
            LLMWorkerResponse(
                requestID: requestID,
                type: "ack",
                role: role,
                text: nil,
                error: nil,
                toolName: nil,
                toolArguments: nil
            )
        )
    }

    private func sendError(requestID: String, message: String) {
        send(
            LLMWorkerResponse(
                requestID: requestID,
                type: "error",
                role: role,
                text: nil,
                error: message,
                toolName: nil,
                toolArguments: nil
            )
        )
    }

    private func send(_ response: LLMWorkerResponse) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }

        do {
            let data = try JSONEncoder().encode(response)
            if let line = String(data: data, encoding: .utf8)?.appending("\n"),
               let lineData = line.data(using: .utf8)
            {
                try FileHandle.standardOutput.write(contentsOf: lineData)
            }
        } catch {
            NSLog("LLMWorkerService[%@]: failed to send response: %@", role.rawValue, error.localizedDescription)
        }
    }
}
