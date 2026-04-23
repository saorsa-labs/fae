import Foundation

// MARK: - Public types

/// A single PII span detected in text.
public struct PrivacyFilterSpan: Sendable, Equatable {
    public let category: String
    public let text: String
    public let start: Int
    public let end: Int

    public init(category: String, text: String, start: Int, end: Int) {
        self.category = category
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Result of scanning text for PII.
public struct PrivacyFilterResult: Sendable, Equatable {
    public let spans: [PrivacyFilterSpan]
    public let redacted: String
    public let hasPII: Bool
    /// True when the filter could not run (daemon unavailable, timeout, etc.).
    /// Callers should fail-open — PII scrub is best-effort, not a hard security gate.
    public let unavailable: Bool

    public init(spans: [PrivacyFilterSpan], redacted: String, hasPII: Bool, unavailable: Bool) {
        self.spans = spans
        self.redacted = redacted
        self.hasPII = hasPII
        self.unavailable = unavailable
    }

    /// A pass-through result for when the filter is disabled or fails.
    public static func passthrough(_ text: String) -> PrivacyFilterResult {
        PrivacyFilterResult(spans: [], redacted: text, hasPII: false, unavailable: true)
    }
}

/// Errors emitted by `PrivacyFilterBridge` during startup.
public enum PrivacyFilterBridgeError: Error, LocalizedError, Sendable {
    case uvNotAvailable
    case scriptNotFound(String)
    case processSpawnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .uvNotAvailable:
            return "uv Python runtime is not installed"
        case .scriptNotFound(let path):
            return "privacy_filter.py not found at \(path)"
        case .processSpawnFailed(let detail):
            return "Failed to spawn privacy filter daemon: \(detail)"
        }
    }
}

/// Abstraction so `CoworkToolExecutor` can be tested without spawning a real subprocess.
public protocol PrivacyFilterScanning: Sendable {
    func scan(_ text: String) async -> PrivacyFilterResult
}

// MARK: - Bridge

/// Manages a long-lived Python daemon that runs OpenAI Privacy Filter via
/// `mlx-embeddings`. Communicates over the JSON-line protocol implemented by
/// `scripts/privacy_filter.py --daemon`.
///
/// Cold start (first scan): ~5s Python env install + ~1.5s Metal graph compile.
/// Warm scans: ~18ms on M2 Max for short text.
///
/// Failure policy: **fail-open**. If the daemon can't start, crashes mid-run,
/// or a request times out, `scan()` returns a pass-through result with
/// `unavailable: true`. PII scrub is a best-effort enhancement; it must not
/// prevent users from collaborating with CoWork.
public actor PrivacyFilterBridge: PrivacyFilterScanning {

    // MARK: - Configuration

    private let uvPath: String
    private let scriptURL: URL
    private let modelId: String
    private let requestTimeout: TimeInterval
    private let startupTimeout: TimeInterval
    private let cooldown: TimeInterval
    private let maxRestarts: Int

    // MARK: - Runtime state

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var pendingLine: String = ""
    private var restartCount: Int = 0
    private var unavailableUntil: Date?

    // MARK: - Init

    public init(
        uvPath: String,
        scriptURL: URL,
        modelId: String = "openai/privacy-filter",
        requestTimeout: TimeInterval = 10,
        startupTimeout: TimeInterval = 120,
        cooldown: TimeInterval = 300,
        maxRestarts: Int = 3
    ) {
        self.uvPath = uvPath
        self.scriptURL = scriptURL
        self.modelId = modelId
        self.requestTimeout = requestTimeout
        self.startupTimeout = startupTimeout
        self.cooldown = cooldown
        self.maxRestarts = maxRestarts
    }

    /// Default factory: looks up `uv` via `UVRuntime` and resolves the script
    /// from the Fae resource bundle.
    public static func createDefault() async throws -> PrivacyFilterBridge {
        guard let uv = await UVRuntime.shared.path() else {
            throw PrivacyFilterBridgeError.uvNotAvailable
        }
        guard let scriptURL = Bundle.faeResources.url(
            forResource: "privacy_filter",
            withExtension: "py",
            subdirectory: "Scripts"
        ) else {
            throw PrivacyFilterBridgeError.scriptNotFound("Scripts/privacy_filter.py")
        }
        return PrivacyFilterBridge(uvPath: uv, scriptURL: scriptURL)
    }

    // MARK: - Public API

    /// Scan `text` for PII. Fail-open: if the daemon is unavailable, returns
    /// the input text with `unavailable: true`.
    public func scan(_ text: String) async -> PrivacyFilterResult {
        if text.isEmpty {
            return PrivacyFilterResult(spans: [], redacted: text, hasPII: false, unavailable: false)
        }
        if let until = unavailableUntil, Date() < until {
            return .passthrough(text)
        }
        do {
            try await ensureRunning()
            let response = try await sendRequest(text: text)
            return try parseResponse(response, originalText: text)
        } catch {
            markUnavailable(reason: "\(error)")
            return .passthrough(text)
        }
    }

    /// Shut down the daemon. Idempotent.
    public func shutdown() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        try? stdin?.close()
        try? stdout?.close()
        process = nil
        stdin = nil
        stdout = nil
        pendingLine = ""
    }

    // MARK: - Lifecycle

    private func ensureRunning() async throws {
        if let proc = process, proc.isRunning {
            return
        }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw PrivacyFilterBridgeError.scriptNotFound(scriptURL.path)
        }
        if restartCount >= maxRestarts {
            throw PrivacyFilterBridgeError.processSpawnFailed(
                "exceeded max restart budget (\(maxRestarts))"
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uvPath)
        proc.arguments = [
            "run", "--no-project",
            "--python", "3.13",
            "--with", "mlx-embeddings @ git+https://github.com/Blaizzy/mlx-embeddings",
            "python3", scriptURL.path,
            "--daemon",
            "--model", modelId,
        ]

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        proc.environment = [
            "PATH": "\(home)/.local/bin:\(home)/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": home,
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName(),
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // Forward stderr to /dev/null — Python warnings/install chatter would
        // otherwise pollute the parent process log. Real errors surface as
        // JSON `{"error": ...}` on stdout.
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            restartCount += 1
            throw PrivacyFilterBridgeError.processSpawnFailed("\(error)")
        }

        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.pendingLine = ""
    }

    private func markUnavailable(reason: String) {
        unavailableUntil = Date().addingTimeInterval(cooldown)
        restartCount += 1
        if let proc = process, !proc.isRunning {
            process = nil
            stdin = nil
            stdout = nil
        }
        NSLog("PrivacyFilterBridge: marking unavailable (reason: %@), cooldown %gs", reason, cooldown)
    }

    // MARK: - Daemon protocol

    private struct DaemonRequest: Encodable {
        let id: String
        let text: String
    }

    private struct DaemonSpan: Decodable {
        let category: String
        let text: String
        let start: Int
        let end: Int
    }

    private struct DaemonResponse: Decodable {
        let id: String?
        let text: String?
        let spans: [DaemonSpan]?
        let redacted: String?
        let hasPII: Bool?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case id, text, spans, redacted, error
            case hasPII = "has_pii"
        }
    }

    private func sendRequest(text: String) async throws -> DaemonResponse {
        guard let stdin = stdin, let stdout = stdout else {
            throw PrivacyFilterBridgeError.processSpawnFailed("stdin/stdout not wired")
        }

        let request = DaemonRequest(id: UUID().uuidString, text: text)
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        var line = requestData
        line.append(0x0A)  // newline terminator
        try stdin.write(contentsOf: line)

        let deadline = Date().addingTimeInterval(requestTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let responseLine = try readLine(from: stdout) {
                let decoder = JSONDecoder()
                let response = try decoder.decode(DaemonResponse.self, from: Data(responseLine.utf8))
                if response.id == request.id || response.id == nil {
                    return response
                }
                // Drop stale responses that don't match our id; keep reading.
                continue
            }
            // No full line yet — briefly yield and retry.
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PrivacyFilterBridgeError.processSpawnFailed("request timed out after \(requestTimeout)s")
    }

    /// Incrementally read a newline-delimited line from the daemon's stdout.
    /// Returns `nil` if no complete line is available yet.
    private func readLine(from handle: FileHandle) throws -> String? {
        let chunk = handle.availableData
        if chunk.isEmpty {
            // Detect EOF (daemon exited): availableData returns empty when
            // the child has closed stdout.
            if let proc = process, !proc.isRunning {
                throw PrivacyFilterBridgeError.processSpawnFailed("daemon exited unexpectedly")
            }
            // Check pending buffer for a complete line from prior reads.
            return extractLine()
        }
        guard let chunkString = String(data: chunk, encoding: .utf8) else {
            throw PrivacyFilterBridgeError.processSpawnFailed("non-UTF-8 output from daemon")
        }
        pendingLine.append(chunkString)
        return extractLine()
    }

    private func extractLine() -> String? {
        guard let newlineIndex = pendingLine.firstIndex(of: "\n") else {
            return nil
        }
        let line = String(pendingLine[pendingLine.startIndex..<newlineIndex])
        pendingLine = String(pendingLine[pendingLine.index(after: newlineIndex)...])
        return line.isEmpty ? extractLine() : line
    }

    private func parseResponse(_ response: DaemonResponse, originalText: String) throws -> PrivacyFilterResult {
        if let errorMessage = response.error {
            throw PrivacyFilterBridgeError.processSpawnFailed(errorMessage)
        }
        let spans = (response.spans ?? []).map {
            PrivacyFilterSpan(category: $0.category, text: $0.text, start: $0.start, end: $0.end)
        }
        let redacted = response.redacted ?? originalText
        let hasPII = response.hasPII ?? !spans.isEmpty
        return PrivacyFilterResult(spans: spans, redacted: redacted, hasPII: hasPII, unavailable: false)
    }
}
