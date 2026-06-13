import Darwin
import Foundation
import MLXLMCommon

// MARK: - Daemon process registry

/// PIDs of every fae-daemon this app has spawned, killable SYNCHRONOUSLY from
/// `applicationShouldTerminate`. The actor's async `shutdown()` never runs on
/// quit (the delegate returns `.terminateNow` before any Task gets scheduled),
/// which left orphaned daemons holding the model in RAM after every app quit.
enum DaemonProcessRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids: [Int32] = []

    static func register(_ pid: Int32) {
        lock.lock()
        pids.append(pid)
        lock.unlock()
    }

    static func unregister(_ pid: Int32) {
        lock.lock()
        pids.removeAll { $0 == pid }
        lock.unlock()
    }

    /// SIGTERM every registered daemon. Safe to call multiple times and for
    /// already-dead PIDs (kill on a reaped pid just returns ESRCH).
    static func terminateAll() {
        lock.lock()
        let snapshot = pids
        pids.removeAll()
        lock.unlock()
        for pid in snapshot {
            if kill(pid, SIGTERM) == 0 {
                NSLog("DaemonProcessRegistry: sent SIGTERM to fae-daemon pid %d", pid)
            }
        }
    }
}

// MARK: - Errors

/// Errors surfaced by `DaemonLLMEngine`. Every case carries enough context to
/// diagnose the failure from logs — the engine fails loud so `FaeCore` can fall
/// back to the in-process MLX engine.
enum DaemonLLMEngineError: LocalizedError {
    case binaryNotConfigured
    case binaryNotFound(String)
    case launchFailed(String)
    case socketTimeout(path: String, seconds: Int)
    case tokenUnreadable(String)
    case connectionFailed(String)
    case notConnected
    case responseTimedOut(String)
    case protocolError(String)
    case daemonError(String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .binaryNotConfigured:
            return "Daemon LLM lane enabled but no daemon binary configured. "
                + "Set llm.daemonBinaryPath in config.toml (absolute path to fae-daemon) "
                + "or export FAE_DAEMON_BIN."
        case .binaryNotFound(let path):
            return "fae-daemon binary not found or not executable at: \(path). "
                + "Build it with `cargo build -p fae-daemon --release` and point "
                + "llm.daemonBinaryPath (or FAE_DAEMON_BIN) at the binary."
        case .launchFailed(let detail):
            return "fae-daemon failed to launch: \(detail)"
        case .socketTimeout(let path, let seconds):
            return "fae-daemon socket did not appear at \(path) within \(seconds)s "
                + "(model load may have failed — check daemon logs)"
        case .tokenUnreadable(let path):
            return "fae-daemon bootstrap token unreadable at: \(path)"
        case .connectionFailed(let detail):
            return "fae-daemon socket connection failed: \(detail)"
        case .notConnected:
            return "fae-daemon socket is not connected"
        case .responseTimedOut(let requestID):
            return "fae-daemon did not answer request \(requestID) in time"
        case .protocolError(let detail):
            return "fae-daemon protocol error: \(detail)"
        case .daemonError(let message):
            return "fae-daemon returned an error: \(message)"
        case .notLoaded:
            return "Daemon LLM engine not loaded"
        }
    }
}

// MARK: - Wire protocol helpers (pure, unit-testable)

/// Pure helpers for the fae-daemon NDJSON wire protocol (v2).
///
/// One JSON object per line. Every command frame:
/// `{"v":2,"request_id":"rN","command":"...","payload":{...}}`.
/// Responses echo `request_id` and carry `ok` plus an optional `result`.
enum DaemonWire {
    /// Result of one non-streaming daemon turn.
    struct Turn {
        var text: String
        var toolCalls: [ToolCallPayload]
        var finishReason: String?
    }

    /// A single tool call extracted from a daemon turn result.
    struct ToolCallPayload {
        var name: String
        var arguments: [String: any Sendable]
    }

    /// Paths announced by the daemon on stdout at startup.
    struct StartupPaths {
        var runDir: String?
        var socketPath: String?
        var tokenPath: String?
    }

    /// Encode one NDJSON command frame (trailing newline included).
    static func encodeFrame(
        requestID: String,
        command: String,
        payload: [String: Any]
    ) throws -> Data {
        let object: [String: Any] = [
            "v": 2,
            "request_id": requestID,
            "command": command,
            "payload": payload,
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DaemonLLMEngineError.protocolError(
                "payload for \(command) is not valid JSON")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// Parse one NDJSON line into a JSON object, or nil for non-object lines.
    static func parseObjectLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        let object = try? JSONSerialization.jsonObject(with: data)
        return object as? [String: Any]
    }

    /// Validate a response object: throws `daemonError` when `ok` is not true.
    static func unwrapResponse(_ object: [String: Any]) throws -> [String: Any] {
        if (object["ok"] as? Bool) == true { return object }
        let message: String
        if let text = object["error"] as? String {
            message = text
        } else if let dict = object["error"] as? [String: Any] {
            message = (dict["message"] as? String) ?? String(describing: dict)
        } else {
            message = "daemon returned ok=false"
        }
        throw DaemonLLMEngineError.daemonError(message)
    }

    /// Build the rich `conversation.inject_text` payload from the pipeline's
    /// chat history, system prompt and generation options.
    ///
    /// Bridging notes:
    /// - `options.turnContextPrefix` (ephemeral per-turn context the MLX engine
    ///   attaches to the appended delta) is prepended to the final user message.
    /// - `options.tools` arrive in MLX ToolSpec format
    ///   (`{"type":"function","function":{...}}`) and are flattened to the
    ///   daemon's `{name, description, parameters}` shape.
    /// - `options.audioWAVBase64` (S18 push-to-talk) attaches the clip to the
    ///   final user message, whose wire content MUST be empty — any text on the
    ///   audio message out-competes the audio and gets transcribed instead
    ///   (empirical, see docs/spikes/S18). The turn-context prefix migrates to
    ///   the system prompt for audio turns so memory recall still reaches the
    ///   model.
    static func injectTextPayload(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) -> [String: Any] {
        var wireMessages: [[String: Any]] = []
        var effectiveSystemPrompt = systemPrompt
        let lastIndex = messages.indices.last
        for (index, message) in messages.enumerated() {
            var content = message.content
            let isFinalUser = index == lastIndex && message.role == .user
            if isFinalUser, let audio = options.audioWAVBase64, !audio.isEmpty {
                if let prefix = options.turnContextPrefix, !prefix.isEmpty {
                    effectiveSystemPrompt += "\n\n" + prefix
                }
                wireMessages.append([
                    "role": message.role.rawValue,
                    "content": "",
                    "audio_wav_base64": audio,
                ])
                continue
            }
            if isFinalUser,
               let prefix = options.turnContextPrefix,
               !prefix.isEmpty
            {
                content = prefix + "\n\n" + content
            }
            wireMessages.append(["role": message.role.rawValue, "content": content])
        }

        var payload: [String: Any] = [
            "system": effectiveSystemPrompt,
            "messages": wireMessages,
            "max_tokens": options.maxTokens,
        ]
        let tools = daemonTools(from: options.tools ?? [])
        if !tools.isEmpty {
            payload["tools"] = tools
        }
        return payload
    }

    /// Flatten MLX ToolSpec dictionaries into the daemon's tool shape.
    static func daemonTools(from specs: [[String: any Sendable]]) -> [[String: Any]] {
        specs.compactMap { spec in
            let anySpec = spec.mapValues { $0 as Any }
            let function = (anySpec["function"] as? [String: Any]) ?? anySpec
            guard let name = function["name"] as? String, !name.isEmpty else { return nil }
            return [
                "name": name,
                "description": (function["description"] as? String) ?? "",
                "parameters": (function["parameters"] as? [String: Any]) ?? [String: Any](),
            ]
        }
    }

    /// Extract the turn result (`text`, `tool_calls`, `finish_reason`) from a
    /// validated `conversation.inject_text` response.
    static func parseTurn(from response: [String: Any]) -> Turn {
        let result = (response["result"] as? [String: Any]) ?? [:]
        let text = (result["text"] as? String) ?? ""
        var calls: [ToolCallPayload] = []
        for raw in (result["tool_calls"] as? [[String: Any]]) ?? [] {
            guard let name = raw["name"] as? String, !name.isEmpty else { continue }
            calls.append(
                ToolCallPayload(
                    name: name,
                    arguments: parseToolArguments(raw["arguments"])
                ))
        }
        return Turn(
            text: text,
            toolCalls: calls,
            finishReason: result["finish_reason"] as? String
        )
    }

    /// Daemon tool-call arguments arrive as a JSON-encoded string
    /// (`"arguments":"{\"a\":1}"`). Decode into a Sendable dictionary; an
    /// undecodable payload is preserved under a `raw` key rather than dropped.
    static func parseToolArguments(_ raw: Any?) -> [String: any Sendable] {
        if let text = raw as? String {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any]
            else {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [:] : ["raw": trimmed]
            }
            return dict.mapValues { sendableJSONValue($0) }
        }
        if let dict = raw as? [String: Any] {
            return dict.mapValues { sendableJSONValue($0) }
        }
        return [:]
    }

    /// Convert a JSONSerialization value into a concrete Sendable value
    /// suitable for `MLXLMCommon.ToolCall.Function(arguments:)`.
    static func sendableJSONValue(_ value: Any) -> any Sendable {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            if CFNumberIsFloatType(number) {
                return number.doubleValue
            }
            return number.intValue
        case let array as [Any]:
            return array.map { sendableJSONValue($0) }
        case let dict as [String: Any]:
            return dict.mapValues { sendableJSONValue($0) }
        case is NSNull:
            return Optional<String>.none as String?
        default:
            return String(describing: value)
        }
    }

    /// Parse the daemon's startup stdout for announced paths. Lines look like:
    /// `run dir : /path (0700)`, `token   : /path (0600)`,
    /// `listening on /path (NDJSON)`. The trailing parenthesised annotation is
    /// commentary, not part of the path (paths themselves contain spaces —
    /// "Application Support" — so only a trailing `(...)` group is stripped).
    /// Missing values stay nil — callers fall back to the default run dir.
    static func parseStartupPaths(lines: [String]) -> StartupPaths {
        var paths = StartupPaths()
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("run dir"), let value = valueAfterColon(line) {
                paths.runDir = value
            } else if lower.hasPrefix("token"), let value = valueAfterColon(line) {
                paths.tokenPath = value
            } else if let marker = lower.range(of: "listening on ") {
                // The daemon prefixes this line ("fae-daemon: listening on …"),
                // so match anywhere, not at line start.
                let value = stripTrailingAnnotation(String(line[marker.upperBound...]))
                if !value.isEmpty { paths.socketPath = value }
            }
        }
        return paths
    }

    private static func valueAfterColon(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let value = stripTrailingAnnotation(String(line[line.index(after: colon)...]))
        return value.isEmpty ? nil : value
    }

    /// Drop a trailing ` (...)` annotation (e.g. ` (0700)`, ` (NDJSON)`).
    private static func stripTrailingAnnotation(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(")"), let open = value.range(of: " (", options: .backwards) {
            value = String(value[..<open.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}

// MARK: - Stdout accumulator

/// Thread-safe accumulator for the daemon's stdout/stderr stream.
private final class DaemonOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        lock.lock()
        text += chunk
        // Bound memory: the daemon can be chatty during long model loads.
        if text.count > 64_000 {
            text = String(text.suffix(32_000))
        }
        lock.unlock()
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func tail(_ maxChars: Int = 500) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(text.suffix(maxChars))
    }
}

// MARK: - Unix socket connection

/// Blocking POSIX Unix-domain-socket connection with all I/O serialized on a
/// private dispatch queue. `roundTrip` performs write + read-until-match as one
/// atomic operation, so concurrent callers can never interleave frames or steal
/// each other's responses.
///
/// Shared by `DaemonLLMEngine` and `DaemonTTSEngine` — each opens its OWN
/// connection (LLM turns serialize for minutes; TTS must not queue behind
/// them), distinguished by `queueLabel`.
final class DaemonSocketConnection: @unchecked Sendable {
    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var buffer = Data()

    /// Receive timeout per recv() call. Generous: a full local turn on a large
    /// model can take minutes.
    private static let receiveTimeoutSeconds: Int = 600

    init(queueLabel: String = "fae.daemon-llm.socket") {
        self.queue = DispatchQueue(label: queueLabel)
    }

    func connect(to path: String) throws {
        try queue.sync { try connectLocked(to: path) }
    }

    /// Send one frame and read response lines until the object whose
    /// `request_id` matches arrives. Unrelated lines (events, stale frames)
    /// are skipped, bounded by `maxSkippedLines`.
    func roundTrip(frame: Data, expectRequestID: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.writeLocked(frame)
                    let response = try self.readMatchingResponseLocked(
                        requestID: expectRequestID, maxSkippedLines: 200)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        queue.sync {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
            buffer.removeAll()
        }
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: queue-confined internals

    private func connectLocked(to path: String) throws {
        guard fd < 0 else { return }
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw DaemonLLMEngineError.connectionFailed("socket(): \(Self.errnoString())")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
        var pathBytes = Array(path.utf8)
        guard pathBytes.count <= maxPathLength else {
            Darwin.close(sock)
            throw DaemonLLMEngineError.connectionFailed(
                "socket path too long (\(pathBytes.count) > \(maxPathLength)): \(path)")
        }
        pathBytes.append(0)
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source.prefix(destination.count))
            }
        }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let detail = Self.errnoString()
            Darwin.close(sock)
            throw DaemonLLMEngineError.connectionFailed("connect(\(path)): \(detail)")
        }

        var timeout = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(
            sock, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        _ = setsockopt(
            sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size))

        fd = sock
    }

    private func writeLocked(_ data: Data) throws {
        guard fd >= 0 else { throw DaemonLLMEngineError.notConnected }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(fd, base + offset, bytes.count - offset, 0)
            }
            if written <= 0 {
                if errno == EINTR { continue }
                throw DaemonLLMEngineError.connectionFailed("send(): \(Self.errnoString())")
            }
            offset += written
        }
    }

    private func readMatchingResponseLocked(
        requestID: String,
        maxSkippedLines: Int
    ) throws -> [String: Any] {
        for _ in 0...maxSkippedLines {
            let line = try readLineLocked()
            guard let object = DaemonWire.parseObjectLine(line) else { continue }
            guard (object["request_id"] as? String) == requestID else { continue }
            return object
        }
        throw DaemonLLMEngineError.responseTimedOut(requestID)
    }

    private func readLineLocked() throws -> String {
        guard fd >= 0 else { throw DaemonLLMEngineError.notConnected }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw DaemonLLMEngineError.protocolError("non-UTF8 frame from daemon")
                }
                return line
            }

            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.recv(fd, base, raw.count, 0)
            }
            if count == 0 {
                throw DaemonLLMEngineError.connectionFailed("daemon closed the connection")
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw DaemonLLMEngineError.responseTimedOut(
                        "recv timed out after \(Self.receiveTimeoutSeconds)s")
                }
                throw DaemonLLMEngineError.connectionFailed("recv(): \(Self.errnoString())")
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private static func errnoString() -> String {
        if let cString = strerror(errno) {
            return String(cString: cString)
        }
        return "errno \(errno)"
    }
}

// MARK: - Engine

/// LLM engine that routes turns to the local Rust `fae-daemon` (mistral.rs)
/// over its NDJSON Unix-socket protocol instead of running MLX in-process.
///
/// Enabled via `llm.useDaemonEngine` (see `FaeConfig.LlmConfig`). The daemon is
/// launched as a child process with `FAE_MODEL_ID` set; the engine waits for
/// the daemon's Unix socket, authenticates with the bootstrap token, then
/// serves turns via `conversation.inject_text`.
///
/// Streaming bridge: the daemon is non-streaming (the full turn arrives in one
/// response), so the engine emits the complete text as a single `.text` event
/// followed by any `.toolCall` events, then finishes the stream. Session
/// caching methods (`synchronizeSession`, `prefillSession`, `resetSession`)
/// are no-ops because every turn ships the full message history.
actor DaemonLLMEngine: LLMEngine {
    private let configuredBinaryPath: String?
    /// Model the daemon serves (exported as `FAE_MODEL_ID` at launch). Exposed
    /// so ModelManager can report the REAL model in UI labels instead of the
    /// ignored MLX preset id.
    let daemonModelID: String
    private let eventBus: FaeEventBus?

    private var process: Process?
    private var connection: DaemonSocketConnection?
    private var requestCounter = 0
    private let output = DaemonOutputAccumulator()

    /// Socket/token paths of the live daemon, set once connected. Exposed so
    /// sibling lanes (daemon TTS) can open their own connection to the same
    /// daemon process instead of queueing behind LLM turns on this one.
    private(set) var endpoints: (socketPath: String, tokenPath: String)?

    private(set) var loadState: MLEngineLoadState = .notStarted

    var isLoaded: Bool { loadState.isLoaded }

    /// Seconds to wait for the daemon socket. Model load can take minutes on
    /// first launch (weights download + load), so this is deliberately long.
    private static let socketWaitTimeoutSeconds: TimeInterval = 600

    private static var defaultDataDirectory: URL {
        // Mirrors fae-daemon's data_directory(): macOS uses Application
        // Support; the .local/share path is the Linux/XDG layout.
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("fae", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("fae", isDirectory: true)
        #endif
    }

    private static var defaultRunDirectory: URL {
        defaultDataDirectory.appendingPathComponent("run", isDirectory: true)
    }

    /// Copy the bundled fail-closed model lock into `<fae data dir>/models.lock`,
    /// where `fae-daemon` verifies Gemma artifacts before loading mistral.rs.
    /// Idempotent: an existing byte-identical file is left untouched; a
    /// different lock is replaced by the bundled release pin so production
    /// launches always enforce the reviewed snapshot.
    static func installBundledModelsLock() {
        guard let bundled = Bundle.faeResources.url(
            forResource: "models", withExtension: "lock", subdirectory: "Models")
        else {
            NSLog("DaemonLLMEngine: no bundled models.lock — daemon will fail closed if lock is required")
            return
        }
        let target = defaultDataDirectory.appendingPathComponent("models.lock")
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: defaultDataDirectory, withIntermediateDirectories: true)
            if let installed = try? Data(contentsOf: target),
               let bundledData = try? Data(contentsOf: bundled),
               installed == bundledData
            {
                return
            }
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: bundled, to: target)
            NSLog("DaemonLLMEngine: installed models.lock at %@", target.path)
        } catch {
            NSLog(
                "DaemonLLMEngine: models.lock install failed (%@) — daemon will fail closed",
                error.localizedDescription)
        }
    }

    /// - Parameters:
    ///   - binaryPath: Absolute path to the fae-daemon binary
    ///     (`llm.daemonBinaryPath`). `FAE_DAEMON_BIN` overrides it.
    ///   - modelID: Model id exported as `FAE_MODEL_ID` at daemon launch.
    ///   - eventBus: Optional bus for `runtimeProgress` events during the
    ///     potentially long daemon startup.
    init(binaryPath: String?, modelID: String, eventBus: FaeEventBus? = nil) {
        self.configuredBinaryPath = binaryPath
        self.daemonModelID = modelID
        self.eventBus = eventBus
    }

    deinit {
        connection?.close()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    // MARK: LLMEngine

    /// Launch the daemon, wait for its socket, connect and authenticate.
    ///
    /// The `modelID` parameter (the MLX preset id chosen by ModelManager) is
    /// intentionally ignored — the daemon serves the model fixed at init via
    /// `FAE_MODEL_ID`. Idempotent: a second call while loaded is a no-op so
    /// ModelManager's `loadAll` can safely re-invoke `load` after FaeCore has
    /// already brought the daemon up.
    func load(modelID: String) async throws {
        if isLoaded { return }
        loadState = .loading
        do {
            try await launchAndConnect()
            loadState = .loaded
            NSLog(
                "DaemonLLMEngine: connected to fae-daemon (daemon model %@; MLX preset id %@ ignored)",
                daemonModelID, modelID)
        } catch {
            loadState = .failed(error.localizedDescription)
            internalShutdown()
            throw error
        }
    }

    func generate(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream<LLMStreamEvent, Error> {
            (continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: DaemonLLMEngineError.notLoaded)
                    return
                }
                do {
                    let turn = try await self.runTurn(
                        messages: messages, systemPrompt: systemPrompt, options: options)
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    // When the daemon returned structured tool calls, the raw
                    // text is the model's tool-call markup (e.g. Gemma 4's
                    // "<|tool_call>call:…") — never speakable output. Rely on
                    // the structured calls alone in that case. EXCEPT on audio
                    // turns (S18): the text then begins with the `[heard]:`
                    // transcription line, which the pipeline must receive even
                    // when the turn is a pure tool call — it strips the line
                    // and any tool-call residue before anything is spoken.
                    let isAudioTurn = options.audioWAVBase64?.isEmpty == false
                    if !turn.text.isEmpty && (turn.toolCalls.isEmpty || isAudioTurn) {
                        continuation.yield(.text(turn.text))
                    }
                    for call in turn.toolCalls {
                        continuation.yield(
                            .toolCall(
                                MLXLMCommon.ToolCall(
                                    function: MLXLMCommon.ToolCall.Function(
                                        name: call.name, arguments: call.arguments))))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func shutdown() async {
        internalShutdown()
        loadState = .notStarted
    }

    // MARK: - Internals

    private func runTurn(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) async throws -> DaemonWire.Turn {
        guard isLoaded, let connection else { throw DaemonLLMEngineError.notLoaded }
        let requestID = nextRequestID()
        let payload = DaemonWire.injectTextPayload(
            messages: messages, systemPrompt: systemPrompt, options: options)
        let frame = try DaemonWire.encodeFrame(
            requestID: requestID, command: "conversation.inject_text", payload: payload)
        let raw = try await connection.roundTrip(frame: frame, expectRequestID: requestID)
        do {
            let response = try DaemonWire.unwrapResponse(raw)
            return DaemonWire.parseTurn(from: response)
        } catch {
            // The wire error is a coarse code — surface the daemon's own
            // output (where the engine logs the real failure) alongside it.
            NSLog(
                "DaemonLLMEngine: turn %@ failed (%@) — daemon tail: %@",
                requestID, error.localizedDescription, output.tail(1_500))
            throw error
        }
    }

    private func nextRequestID() -> String {
        requestCounter += 1
        return "r\(requestCounter)"
    }

    /// Resolution order: `FAE_DAEMON_BIN` env → `llm.daemonBinaryPath` config
    /// → the daemon embedded in the app bundle (`Contents/MacOS/fae-daemon`,
    /// shipped by `just run-dev` / `run-native-with-ui-shell`).
    private func resolveBinaryURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidate: String?
        if let env = environment["FAE_DAEMON_BIN"], !env.isEmpty {
            candidate = env
        } else if let configured = configuredBinaryPath, !configured.isEmpty {
            candidate = configured
        } else if let bundled = Bundle.main.url(forAuxiliaryExecutable: "fae-daemon"),
                  FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return bundled
        } else {
            candidate = nil
        }
        guard let raw = candidate, !raw.isEmpty else {
            throw DaemonLLMEngineError.binaryNotConfigured
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expanded) else {
            throw DaemonLLMEngineError.binaryNotFound(expanded)
        }
        return URL(fileURLWithPath: expanded)
    }

    private func launchAndConnect() async throws {
        Self.installBundledModelsLock()
        let binary = try resolveBinaryURL()

        let daemonProcess = Process()
        daemonProcess.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        environment["FAE_MODEL_ID"] = daemonModelID
        if environment["FAE_ISQ"] == nil,
           ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024
        {
            // Q8 ISQ on high-RAM machines: ~2x weight memory for far better
            // numeric headroom — in testing it eliminated visible Metal
            // NaN-logits failures (Q4K needed the daemon's padded retries
            // and still exhausted them on some prompt lengths). Q4K remains
            // the default below 32 GB.
            environment["FAE_ISQ"] = "Q8_0"
        }
        if environment["FAE_DEV"] == "1", environment["FAE_MODELS_LOCK"] == nil {
            environment["FAE_MODELS_LOCK"] = "off"
        }
        daemonProcess.environment = environment

        let pipe = Pipe()
        daemonProcess.standardOutput = pipe
        daemonProcess.standardError = pipe
        let accumulator = output
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            accumulator.append(data)
        }

        do {
            try daemonProcess.run()
        } catch {
            throw DaemonLLMEngineError.launchFailed(
                "could not exec \(binary.path): \(error.localizedDescription)")
        }
        process = daemonProcess
        DaemonProcessRegistry.register(daemonProcess.processIdentifier)
        NSLog(
            "DaemonLLMEngine: launched fae-daemon pid %d (FAE_MODEL_ID=%@)",
            daemonProcess.processIdentifier, daemonModelID)

        // Resolve socket/token paths: parse the daemon's startup stdout, fall
        // back to the platform default run directory.
        let defaultRunDir = Self.defaultRunDirectory
        var socketPath = defaultRunDir.appendingPathComponent("fae-daemon.sock").path
        var tokenPath = defaultRunDir.appendingPathComponent("bootstrap.token").path

        // Wait for the socket and a successful connection. Model load can take
        // minutes — poll with a generous timeout and surface progress.
        let started = Date()
        var lastProgressAt = Date.distantPast
        var liveConnection: DaemonSocketConnection?
        while liveConnection == nil {
            let announced = DaemonWire.parseStartupPaths(lines: accumulator.lines())
            if let runDir = announced.runDir {
                socketPath = runDir + "/fae-daemon.sock"
                tokenPath = runDir + "/bootstrap.token"
            }
            if let announcedSocket = announced.socketPath { socketPath = announcedSocket }
            if let announcedToken = announced.tokenPath { tokenPath = announcedToken }

            if !daemonProcess.isRunning {
                throw DaemonLLMEngineError.launchFailed(
                    "fae-daemon exited during startup — output tail: \(accumulator.tail())")
            }
            if Date().timeIntervalSince(started) > Self.socketWaitTimeoutSeconds {
                throw DaemonLLMEngineError.socketTimeout(
                    path: socketPath, seconds: Int(Self.socketWaitTimeoutSeconds))
            }

            if FileManager.default.fileExists(atPath: socketPath) {
                let attempt = DaemonSocketConnection()
                do {
                    try attempt.connect(to: socketPath)
                    liveConnection = attempt
                    break
                } catch {
                    // Stale socket from a previous run, or the daemon is not
                    // accepting yet — keep polling until the timeout.
                    attempt.close()
                }
            }

            if Date().timeIntervalSince(lastProgressAt) > 5 {
                lastProgressAt = Date()
                let fraction = min(
                    Date().timeIntervalSince(started) / Self.socketWaitTimeoutSeconds, 1.0)
                // Map onto the LLM slice (0.35–0.55) of overall startup progress.
                eventBus?.send(
                    .runtimeProgress(stage: "daemon_llm", progress: 0.35 + fraction * 0.2))
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        guard let establishedConnection = liveConnection else {
            throw DaemonLLMEngineError.socketTimeout(
                path: socketPath, seconds: Int(Self.socketWaitTimeoutSeconds))
        }

        // Authenticate (first frame on the connection, protocol v2).
        let token: String
        do {
            token = try String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            establishedConnection.close()
            throw DaemonLLMEngineError.tokenUnreadable(tokenPath)
        }
        guard !token.isEmpty else {
            establishedConnection.close()
            throw DaemonLLMEngineError.tokenUnreadable(tokenPath)
        }

        let requestID = nextRequestID()
        let authFrame = try DaemonWire.encodeFrame(
            requestID: requestID,
            command: "session.authenticate",
            payload: [
                "client_id": "swift-frontend-bootstrap",
                "token": token,
            ])
        do {
            let raw = try await establishedConnection.roundTrip(
                frame: authFrame, expectRequestID: requestID)
            _ = try DaemonWire.unwrapResponse(raw)
        } catch {
            establishedConnection.close()
            throw error
        }

        connection = establishedConnection
        endpoints = (socketPath: socketPath, tokenPath: tokenPath)
    }

    private func internalShutdown() {
        connection?.close()
        connection = nil
        endpoints = nil
        if let process {
            if process.isRunning {
                process.terminate()
            }
            DaemonProcessRegistry.unregister(process.processIdentifier)
        }
        process = nil
    }
}
