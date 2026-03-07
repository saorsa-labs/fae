import Foundation

struct SafeSkillProcessHandles {
    let process: Process
    let stdin: Pipe
    let stdout: Pipe
    let stderr: Pipe
}

/// Error thrown when uv is not available for skill execution.
enum SafeSkillExecutorError: LocalizedError {
    case uvNotInstalled
    
    var errorDescription: String? {
        switch self {
        case .uvNotInstalled:
            return "uv is not installed. Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh"
        }
    }
}

/// Constrained process launcher for executable skills.
enum SafeSkillExecutor {
    
    /// Create a process to run a Python skill script via uv.
    ///
    /// - Parameters:
    ///   - skillName: Name of the skill (for environment variable)
    ///   - scriptPath: Path to the Python script
    ///   - uvPath: Path to the uv binary (obtain via `UVRuntime.shared.path()`)
    ///   - timeoutSeconds: Maximum execution time
    ///   - memoryLimitKB: Memory limit for the process
    ///   - cpuLimitSeconds: CPU time limit
    ///   - additionalEnvironment: Extra environment variables
    /// - Returns: Process handles for stdin/stdout/stderr
    static func createProcess(
        skillName: String,
        scriptPath: String,
        uvPath: String,
        timeoutSeconds: Int,
        memoryLimitKB: Int = 1_048_576,
        cpuLimitSeconds: Int = 20,
        additionalEnvironment: [String: String] = [:]
    ) throws -> SafeSkillProcessHandles {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        let escapedScript = shellEscape(scriptPath)
        let escapedUV = shellEscape(uvPath)
        process.arguments = [
            "-c",
            // ulimit calls are best-effort — some CI/sandbox environments don't support
            // certain setrlimit resource types (e.g. RLIMIT_AS on macOS 14 GitHub runners).
            // Use '|| true' so a failed ulimit never aborts skill execution.
            "ulimit -t \(cpuLimitSeconds) 2>/dev/null || true; "
                + "ulimit -v \(memoryLimitKB) 2>/dev/null || true; "
                + "ulimit -n 64 2>/dev/null || true; "
                + "exec \(escapedUV) run --script \(escapedScript)",
        ]

        let home = NSHomeDirectory()
        var environment = [
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": home,
            "USER": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "FAE_SKILL_NAME": skillName,
            "FAE_SKILL_TIMEOUT": String(timeoutSeconds),
        ]
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }
        process.environment = environment

        // Restrict cwd to the skill's own scripts directory.
        let scriptURL = URL(fileURLWithPath: scriptPath).standardized.resolvingSymlinksInPath()
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        return SafeSkillProcessHandles(process: process, stdin: stdin, stdout: stdout, stderr: stderr)
    }

    static func waitForExit(process: Process, timeoutSeconds: Int) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning {
            try Task.checkCancellation()
            if Date() >= deadline {
                process.terminate()
                try? await Task.sleep(nanoseconds: 400_000_000)
                if process.isRunning {
                    process.interrupt()
                }
                throw NSError(
                    domain: "SafeSkillExecutor",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Skill timed out after \(timeoutSeconds)s"]
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return process.terminationStatus
    }

    private static func shellEscape(_ input: String) -> String {
        "'" + input.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
