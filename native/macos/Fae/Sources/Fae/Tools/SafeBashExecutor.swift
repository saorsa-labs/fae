import Foundation

/// Constrained shell execution helper for high-risk bash tool usage.
enum SafeBashExecutor {
    private static let deniedPatterns: [String] = [
        "rm -rf /",
        "rm -rf ~",
        "mkfs",
        "shutdown",
        "reboot",
        "diskutil erasedisk",
        ":(){:|:&};:",
        "sudo ",
        "launchctl unload",
        "launchctl remove",
        "chown -r",
        "chmod 777",
    ]

    private static let deniedRegexes: [String] = [
        #"(?i)\b(curl|wget)\b[^\n|]*\|\s*(sh|bash|zsh)\b"#,
        #"(?i)\b(eval|exec)\s*\("#,
        #"(?i)>\s*(/etc|/private/etc|~/.ssh|~/.zshrc|~/.bashrc|~/.profile)"#,
    ]

    static func execute(command: String, timeoutSeconds: Int) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        let normalized = command.lowercased()
        for pattern in deniedPatterns where normalized.contains(pattern) {
            throw NSError(
                domain: "SafeBashExecutor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Command blocked by safety policy: \(pattern)"]
            )
        }

        for regexPattern in deniedRegexes {
            if let regex = try? NSRegularExpression(pattern: regexPattern),
               regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
            {
                throw NSError(
                    domain: "SafeBashExecutor",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Command blocked by advanced safety policy"]
                )
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        // Constrained environment: expose only a minimal set.
        let home = NSHomeDirectory()
        let minimalPath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = [
            "PATH": minimalPath,
            "HOME": home,
            "USER": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
        ]

        // Constrain working directory to a safe local path.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardized.resolvingSymlinksInPath()
        if cwd.path.hasPrefix(home) {
            process.currentDirectoryURL = cwd
        } else {
            process.currentDirectoryURL = URL(fileURLWithPath: home)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let outputTask = Task<(Data, Data), Never> {
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            return (outData, errData)
        }

        do {
            let status = try await waitForExit(process: process, timeoutSeconds: timeoutSeconds)
            let (outData, errData) = await outputTask.value
            return (status, outData, errData)
        } catch {
            if process.isRunning {
                process.terminate()
            }
            _ = await outputTask.value
            throw error
        }
    }

    private static func waitForExit(process: Process, timeoutSeconds: Int) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning {
            try Task.checkCancellation()
            if Date() >= deadline {
                let pid = process.processIdentifier
                kill(-pid, SIGTERM)
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning {
                    kill(-pid, SIGKILL)
                }
                throw NSError(
                    domain: "SafeBashExecutor",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Command timed out after \(timeoutSeconds)s"]
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return process.terminationStatus
    }
}
