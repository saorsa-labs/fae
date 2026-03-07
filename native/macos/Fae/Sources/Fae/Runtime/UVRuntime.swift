import Foundation

/// Centralized manager for the uv Python runtime.
///
/// Provides a single source of truth for locating uv, checking availability,
/// and running Python scripts with PEP 723 inline metadata.
///
/// Usage:
/// ```swift
/// let uv = UVRuntime.shared
/// if await uv.isAvailable() {
///     let process = try uv.createScriptProcess(scriptPath: url)
///     try process.run()
/// }
/// ```
public actor UVRuntime {
    
    public static let shared = UVRuntime()
    
    // MARK: - Types
    
    public enum UVError: LocalizedError {
        case notInstalled
        case installationFailed(String)
        case scriptNotFound(String)
        case executionFailed(String)
        
        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "uv is not installed. Python features require uv to be installed."
            case .installationFailed(let msg):
                return "Failed to install uv: \(msg)"
            case .scriptNotFound(let path):
                return "Python script not found: \(path)"
            case .executionFailed(let msg):
                return "Script execution failed: \(msg)"
            }
        }
    }
    
    public struct UVInfo: Sendable {
        public let path: String
        public let version: String
        public let source: UVSource
    }
    
    public enum UVSource: String, Sendable {
        case bundled = "bundled"
        case userLocal = "~/.local/bin"
        case homebrew = "/opt/homebrew/bin"
        case system = "/usr/local/bin"
        case path = "PATH"
    }
    
    // MARK: - State
    
    private var cachedPath: String?
    private var cachedInfo: UVInfo?
    
    // MARK: - Search Paths
    
    /// Ordered list of paths to search for uv binary.
    /// First match wins. Bundled path is checked first.
    private static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            // Bundled with app (future)
            Bundle.main.resourceURL?.appendingPathComponent("bin/uv").path,
            Bundle.faeResources.resourceURL?.appendingPathComponent("bin/uv").path,
            // User install (standard uv install location)
            "\(home)/.local/bin/uv",
            // Homebrew (Apple Silicon)
            "/opt/homebrew/bin/uv",
            // Homebrew (Intel) / manual install
            "/usr/local/bin/uv",
            // Zerobrew
            "/opt/zerobrew/bin/uv",
        ].compactMap { $0 }
    }
    
    // MARK: - Public API
    
    /// Check if uv is available on this system.
    public func isAvailable() async -> Bool {
        await findUV() != nil
    }
    
    /// Get information about the installed uv.
    public func info() async -> UVInfo? {
        if let cached = cachedInfo {
            return cached
        }
        guard let path = await findUV() else { return nil }
        
        // Get version
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let version = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            
            let source = sourceForPath(path)
            let info = UVInfo(path: path, version: version, source: source)
            cachedInfo = info
            return info
        } catch {
            return nil
        }
    }
    
    /// Get the path to uv, or nil if not installed.
    public func path() async -> String? {
        await findUV()
    }
    
    /// Ensure uv is available, installing if needed with user approval.
    ///
    /// This is the preferred method for code that needs uv. It will:
    /// 1. Check if uv is already installed
    /// 2. If not, show an approval dialog to the user
    /// 3. If approved, install uv automatically
    /// 4. Return the path to uv, or throw if unavailable
    ///
    /// Fae takes care of her users - no command line typing required.
    ///
    /// - Returns: Path to the uv binary
    /// - Throws: UVError.notInstalled if user declined or installation failed
    public func ensureAvailable() async throws -> String {
        // Fast path: already installed
        if let path = await findUV() {
            return path
        }
        
        // Use DependencyInstaller for approval and installation
        let result = await DependencyInstaller.shared.ensureInstalled(.uv)
        
        switch result {
        case .success:
            // Clear cache and find the new installation
            clearCache()
            if let path = await findUV() {
                return path
            }
            throw UVError.installationFailed("Installation reported success but uv not found")
            
        case .userDeclined:
            throw UVError.notInstalled
            
        case .failed(let message):
            throw UVError.installationFailed(message)
        }
    }
    
    /// Create a Process configured to run a Python script via `uv run --script`.
    ///
    /// The caller is responsible for:
    /// - Setting up stdin/stdout/stderr pipes if needed
    /// - Calling `run()` and `waitUntilExit()`
    /// - Handling errors
    ///
    /// - Parameters:
    ///   - scriptPath: URL to the Python script
    ///   - arguments: Additional arguments to pass to the script
    ///   - environment: Additional environment variables (merged with process env)
    /// - Returns: Configured Process ready to run
    public func createScriptProcess(
        scriptPath: URL,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> Process {
        guard let uvPath = await findUV() else {
            throw UVError.notInstalled
        }
        
        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            throw UVError.scriptNotFound(scriptPath.path)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--script", scriptPath.path] + arguments
        
        // Merge environment
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env
        
        return process
    }
    
    /// Run a Python script and return its output.
    ///
    /// For simple scripts that produce text output. For streaming or
    /// binary protocols, use `createScriptProcess()` instead.
    ///
    /// - Parameters:
    ///   - scriptPath: URL to the Python script
    ///   - input: Data to write to stdin (optional)
    ///   - arguments: Additional arguments
    ///   - environment: Additional environment variables
    ///   - timeout: Maximum execution time in seconds (nil = no timeout)
    /// - Returns: Tuple of (stdout, stderr) as strings
    public func runScript(
        scriptPath: URL,
        input: Data? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval? = 30
    ) async throws -> (stdout: String, stderr: String) {
        let process = try await createScriptProcess(
            scriptPath: scriptPath,
            arguments: arguments,
            environment: environment
        )
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
        
        try process.run()
        
        // Write input if provided
        if let input = input {
            stdinPipe.fileHandleForWriting.write(input)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        
        // Handle timeout
        if let timeout = timeout {
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                }
            }
            
            process.waitUntilExit()
            timeoutTask.cancel()
        } else {
            process.waitUntilExit()
        }
        
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        
        if process.terminationStatus != 0 {
            throw UVError.executionFailed(
                "Exit code \(process.terminationStatus): \(stderr)"
            )
        }
        
        return (stdout, stderr)
    }
    
    /// Install uv using the official installer script.
    ///
    /// This runs `curl -LsSf https://astral.sh/uv/install.sh | sh` which
    /// installs uv to ~/.local/bin/uv.
    ///
    /// - Returns: Path to the installed uv binary
    public func install() async throws -> String {
        NSLog("UVRuntime: Installing uv...")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "curl -LsSf https://astral.sh/uv/install.sh | sh"
        ]
        
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw UVError.installationFailed(errMsg)
        }
        
        // Clear cache and verify
        cachedPath = nil
        cachedInfo = nil
        
        guard let path = await findUV() else {
            throw UVError.installationFailed("Installation completed but uv not found")
        }
        
        NSLog("UVRuntime: Installed uv at %@", path)
        return path
    }
    
    /// Clear the cached uv path (useful after install/uninstall).
    public func clearCache() {
        cachedPath = nil
        cachedInfo = nil
    }
    
    // MARK: - Private
    
    private func findUV() async -> String? {
        if let cached = cachedPath {
            // Verify it still exists
            if FileManager.default.isExecutableFile(atPath: cached) {
                return cached
            }
            cachedPath = nil
        }
        
        // Search known paths
        for path in Self.searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPath = path
                NSLog("UVRuntime: Found uv at %@", path)
                return path
            }
        }
        
        // Try PATH lookup via /usr/bin/env
        let path = findInPath()
        if let path = path {
            cachedPath = path
            NSLog("UVRuntime: Found uv in PATH at %@", path)
        }
        return path
    }
    
    private func findInPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["uv"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path = path, !path.isEmpty {
                    return path
                }
            }
        } catch {
            // Ignore - uv not in PATH
        }
        return nil
    }
    
    private func sourceForPath(_ path: String) -> UVSource {
        if path.contains("Contents/Resources") {
            return .bundled
        } else if path.contains("/.local/bin") {
            return .userLocal
        } else if path.hasPrefix("/opt/homebrew") {
            return .homebrew
        } else if path.hasPrefix("/usr/local") {
            return .system
        } else {
            return .path
        }
    }
}

// Note: Uses Bundle.faeResources from ResourceBundle.swift
