import Foundation
import MLXLMCommon
import Darwin

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
    // Tool-rich prompts on the production 9B operator can spend well over 45s
    // in first-token prefill after a worker restart. Keep the active-stream
    // watchdog tight, but give first-token generation enough headroom to avoid
    // false-positive worker resets on legitimate tool turns.
    static let initialResponseTimeoutNanoseconds: UInt64 = 120_000_000_000
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

enum WorkerCommandTimeoutPolicy {
    // Control-plane commands should still fail fast when the worker is wedged.
    static let defaultTimeoutNanoseconds: UInt64 = 30_000_000_000
    // First-run local model loads may spend minutes resolving repo metadata,
    // downloading multi-GB weights, and compiling kernels before the worker can ack.
    static let loadTimeoutNanoseconds: UInt64 = 900_000_000_000
    static let warmupTimeoutNanoseconds: UInt64 = 180_000_000_000

    static func timeout(for command: String) -> UInt64 {
        switch command {
        case "load":
            return loadTimeoutNanoseconds
        case "warmup":
            return warmupTimeoutNanoseconds
        default:
            return defaultTimeoutNanoseconds
        }
    }
}

actor WorkerLLMEngine: LLMEngine {
    private let role: WorkerProcessRole
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var responseFileURL: URL?
    private var readTask: Task<Void, Never>?
    private var commandContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var pendingCommandTimeouts: [String: Task<Void, Never>] = [:]
    private var streamContinuations: [String: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation] = [:]
    private var streamWatchdogs: [String: Task<Void, Never>] = [:]
    private var streamWatchdogGenerations: [String: UInt64] = [:]
    private var lastLoadedModelID: String?
    private var restartCount: Int = 0
    private var launchGeneration: UInt64 = 0

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
        _ = history
        // Session sync is a cache-reuse hint in MLXLLMEngine, not a correctness requirement.
        // Keep worker-backed generation reliable by avoiding an extra cross-process round trip
        // on every conversation update.
    }

    func resetSession() async {
        // Reset is only needed to clear reusable session cache state. Worker-backed turns send the
        // full message list every time, so skipping this round trip is safer than stalling the live
        // conversation loop on a non-essential worker command.
    }

    func shutdown() async {
        for (_, timeoutTask) in pendingCommandTimeouts {
            timeoutTask.cancel()
        }
        pendingCommandTimeouts.removeAll()

        for (_, watchdog) in streamWatchdogs {
            watchdog.cancel()
        }
        streamWatchdogs.removeAll()
        streamWatchdogGenerations.removeAll()

        for (_, continuation) in commandContinuations {
            continuation.resume(throwing: WorkerLLMError.transportUnavailable)
        }
        commandContinuations.removeAll()

        for (_, continuation) in streamContinuations {
            continuation.finish(throwing: WorkerLLMError.transportUnavailable)
        }
        streamContinuations.removeAll()

        readTask?.cancel()
        readTask = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil

        try? stdinHandle?.close()
        stdinHandle = nil
        if let responseFileURL {
            try? FileManager.default.removeItem(at: responseFileURL)
        }
        responseFileURL = nil

        isLoaded = false
        loadState = .notStarted
        persistWorkerState(lastError: nil)
        NSLog("WorkerLLMEngine[%@]: shutdown complete", role.rawValue)
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
        let generation = (streamWatchdogGenerations[requestID] ?? 0) &+ 1
        streamWatchdogGenerations[requestID] = generation
        let timeout = WorkerStreamWatchdogPolicy.timeout(for: phase)
        streamWatchdogs[requestID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            await self?.handleStreamTimeout(requestID: requestID, phase: phase, generation: generation)
        }
    }

    private func noteStreamProgress(requestID: String) {
        guard streamContinuations[requestID] != nil else { return }
        armStreamWatchdog(for: requestID, phase: .streamingActive)
    }

    private func clearStreamTracking(requestID: String) {
        streamWatchdogs[requestID]?.cancel()
        streamWatchdogs.removeValue(forKey: requestID)
        streamWatchdogGenerations.removeValue(forKey: requestID)
    }

    private func handleStreamTimeout(requestID: String, phase: WorkerStreamWatchdogPhase, generation: UInt64) {
        guard streamWatchdogGenerations[requestID] == generation else { return }
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
        let responseFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-worker-\(role.rawValue)-\(UUID().uuidString).ndjson")
        FileManager.default.createFile(atPath: responseFileURL.path, contents: nil)

        process.arguments = [
            "--llm-worker",
            "--role", role.rawValue,
            "--response-file", responseFileURL.path,
        ]

        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError

        try process.run()

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.responseFileURL = responseFileURL
        launchGeneration &+= 1
        let activeLaunchGeneration = launchGeneration
        self.readTask?.cancel()
        self.readTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await Self.readResponses(from: responseFileURL, launchGeneration: activeLaunchGeneration, owner: self)
        }
        // Model residency belongs to the worker subprocess, not the parent actor.
        // A freshly launched worker always starts empty and must reload any prior model.
        self.isLoaded = false

        if lastLoadedModelID != nil {
            restartCount += 1
        }
        persistWorkerState(lastError: nil)
        NSLog("WorkerLLMEngine[%@]: launched worker pid=%d", role.rawValue, process.processIdentifier)

        if let lastLoadedModelID {
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
            let timeout = WorkerCommandTimeoutPolicy.timeout(for: request.command)
            pendingCommandTimeouts[request.requestID] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
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
        NSLog("WorkerLLMEngine[%@]: timeout request=%@ command=%@", role.rawValue, requestID, command)
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

    private static func readResponses(
        from responseFileURL: URL,
        launchGeneration: UInt64,
        owner: WorkerLLMEngine
    ) async {
        var buffered = Data()
        await owner.logReaderStart(launchGeneration: launchGeneration)
        guard let fileHandle = try? FileHandle(forReadingFrom: responseFileURL) else {
            await owner.handleWorkerTermination(
                error: WorkerLLMError.workerFailed("Unable to open worker response file"),
                launchGeneration: launchGeneration
            )
            return
        }
        defer { try? fileHandle.close() }

        var offset: UInt64 = 0
        do {
            while !Task.isCancelled {
                try fileHandle.seek(toOffset: offset)
                let chunk = try fileHandle.readToEnd() ?? Data()
                if chunk.isEmpty {
                    if !(await owner.isWorkerProcessRunning(launchGeneration: launchGeneration)) {
                        break
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                offset += UInt64(chunk.count)
                await owner.logReaderChunk(launchGeneration: launchGeneration, byteCount: chunk.count)
                buffered.append(chunk)

                while let newlineIndex = buffered.firstIndex(of: 0x0A) {
                    let lineData = buffered.subdata(in: buffered.startIndex..<newlineIndex)
                    buffered.removeSubrange(buffered.startIndex...newlineIndex)

                    guard let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !line.isEmpty,
                          let data = line.data(using: .utf8)
                    else {
                        continue
                    }

                    await owner.logReaderLine(launchGeneration: launchGeneration, line: line)
                    let response = try JSONDecoder().decode(LLMWorkerResponse.self, from: data)
                    await owner.handle(response: response, launchGeneration: launchGeneration)
                }
            }
        } catch {
            await owner.handleWorkerTermination(error: error, launchGeneration: launchGeneration)
            return
        }

        await owner.handleWorkerTermination(error: nil, launchGeneration: launchGeneration)
    }

    private func logReaderStart(launchGeneration: UInt64) {
        NSLog("WorkerLLMEngine[%@]: reader start launch=%llu", role.rawValue, launchGeneration)
    }

    private func logReaderChunk(launchGeneration: UInt64, byteCount: Int) {
        NSLog("WorkerLLMEngine[%@]: reader chunk launch=%llu bytes=%d", role.rawValue, launchGeneration, byteCount)
    }

    private func logReaderLine(launchGeneration: UInt64, line: String) {
        NSLog("WorkerLLMEngine[%@]: reader line launch=%llu %@", role.rawValue, launchGeneration, line)
    }

    private func isWorkerProcessRunning(launchGeneration: UInt64) -> Bool {
        guard launchGeneration == self.launchGeneration else { return false }
        return process?.isRunning == true
    }

    private func handle(response: LLMWorkerResponse, launchGeneration: UInt64) {
        guard launchGeneration == self.launchGeneration else { return }
        pendingCommandTimeouts[response.requestID]?.cancel()
        pendingCommandTimeouts.removeValue(forKey: response.requestID)

        switch response.type {
        case "ack":
            NSLog("WorkerLLMEngine[%@]: ack request=%@", role.rawValue, response.requestID)
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

    private func handleWorkerTermination(error: Error?, launchGeneration: UInt64) {
        guard launchGeneration == self.launchGeneration else { return }
        let failure = error ?? WorkerLLMError.transportUnavailable
        loadState = .failed(failure.localizedDescription)
        isLoaded = false
        process = nil
        stdinHandle = nil
        if let responseFileURL {
            try? FileManager.default.removeItem(at: responseFileURL)
        }
        responseFileURL = nil

        for (_, timeoutTask) in pendingCommandTimeouts {
            timeoutTask.cancel()
        }
        pendingCommandTimeouts.removeAll()

        for (_, watchdog) in streamWatchdogs {
            watchdog.cancel()
        }
        streamWatchdogs.removeAll()
        streamWatchdogGenerations.removeAll()

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
    private let responseHandle: FileHandle?

    init(role: WorkerProcessRole, responseFileURL: URL?) {
        self.role = role
        if let responseFileURL {
            self.responseHandle = try? FileHandle(forWritingTo: responseFileURL)
            _ = try? self.responseHandle?.seekToEnd()
        } else {
            self.responseHandle = nil
        }
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
        NSLog("LLMWorkerService[%@]: send ack request=%@", role.rawValue, requestID)
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
        NSLog("LLMWorkerService[%@]: send error request=%@ message=%@", role.rawValue, requestID, message)
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
                if let responseHandle {
                    try responseHandle.seekToEnd()
                    try responseHandle.write(contentsOf: lineData)
                } else {
                    let result = lineData.withUnsafeBytes { rawBuffer -> ssize_t in
                        guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                        return Darwin.write(STDOUT_FILENO, baseAddress, rawBuffer.count)
                    }
                    if result < 0 {
                        let err = errno
                        NSLog("LLMWorkerService[%@]: stdout write failed errno=%d", role.rawValue, err)
                    } else if result != lineData.count {
                        NSLog(
                            "LLMWorkerService[%@]: short stdout write wrote=%zd expected=%d",
                            role.rawValue,
                            result,
                            lineData.count
                        )
                    }
                }
            }
        } catch {
            NSLog("LLMWorkerService[%@]: failed to send response: %@", role.rawValue, error.localizedDescription)
        }
    }
}
