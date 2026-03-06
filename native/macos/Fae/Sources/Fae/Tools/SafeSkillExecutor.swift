import Foundation

struct SafeSkillProcessHandles {
    let process: Process
    let stdin: Pipe
    let stdout: Pipe
    let stderr: Pipe
}

/// Constrained process launcher for executable skills.
enum SafeSkillExecutor {
    static func createProcess(
        skillName: String,
        scriptPath: String,
        timeoutSeconds: Int,
        memoryLimitKB: Int = 1_048_576,
        cpuLimitSeconds: Int = 20,
        additionalEnvironment: [String: String] = [:]
    ) throws -> SafeSkillProcessHandles {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        let escaped = shellEscape(scriptPath)
        process.arguments = [
            "-c",
            // ulimit calls are best-effort — some CI/sandbox environments don't support
            // certain setrlimit resource types (e.g. RLIMIT_AS on macOS 14 GitHub runners).
            // Use '|| true' so a failed ulimit never aborts skill execution.
            "ulimit -t \(cpuLimitSeconds) 2>/dev/null || true; "
                + "ulimit -v \(memoryLimitKB) 2>/dev/null || true; "
                + "ulimit -n 64 2>/dev/null || true; "
                + "exec /usr/bin/env uv run --script \(escaped)",
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
