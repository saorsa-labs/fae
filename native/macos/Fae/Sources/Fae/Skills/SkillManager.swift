import Foundation

/// Manages Python skill packages via subprocess JSON-RPC.
///
/// Skills are Python scripts invoked via `uv run` with PEP 723 metadata.
/// Communication is JSON-RPC over stdin/stdout.
///
/// Replaces: `src/skills/` (10,593 lines)
actor SkillManager {
    private var runningProcesses: [String: Process] = [:]

    /// Skill directory: ~/Library/Application Support/fae/skills/
    static var skillsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/skills")
    }

    /// Audio input directory for skill file handoff.
    static var audioInputDirectory: URL {
        skillsDirectory.deletingLastPathComponent()
            .appendingPathComponent("skill_audio/input")
    }

    /// Audio output directory for skill file handoff.
    static var audioOutputDirectory: URL {
        skillsDirectory.deletingLastPathComponent()
            .appendingPathComponent("skill_audio/output")
    }

    /// Build audio context paths for skill execution (creates directories if needed).
    static func audioContextForSkill() -> [String: Any] {
        let inputDir = audioInputDirectory
        let outputDir = audioOutputDirectory
        try? FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        return [
            "audio_input_dir": inputDir.path,
            "audio_output_dir": outputDir.path,
        ]
    }

    /// List installed skills by scanning the skills directory.
    func listSkills() -> [String] {
        Self.installedSkillNames()
    }

    /// List installed skill names (static — no actor instance needed).
    static func installedSkillNames() -> [String] {
        let dir = skillsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "py" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Execute a skill by name with the given input.
    func execute(skillName: String, input: [String: Any]) async throws -> String {
        let scriptPath = Self.skillsDirectory
            .appendingPathComponent("\(skillName).py").path

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw SkillError.notFound(skillName)
        }

        // Build JSON-RPC request.
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "execute",
            "params": input,
            "id": 1,
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              let requestStr = String(data: requestData, encoding: .utf8)
        else {
            throw SkillError.serializationFailed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uv", "run", "--script", scriptPath]

        // Ensure uv and user-installed tools are in PATH (GUI apps have minimal PATH).
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(existing)"
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        runningProcesses[skillName] = process

        // Send request via stdin.
        guard let requestBytes = requestStr.data(using: .utf8) else {
            runningProcesses.removeValue(forKey: skillName)
            process.terminate()
            throw SkillError.serializationFailed
        }
        stdin.fileHandleForWriting.write(requestBytes)
        stdin.fileHandleForWriting.closeFile()

        let timeoutSeconds = 30
        let outputTask = Task<(Data, Data), Never> {
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            return (outData, errData)
        }

        do {
            let status = try await waitForExit(process: process, timeoutSeconds: timeoutSeconds)
            runningProcesses.removeValue(forKey: skillName)

            let (outData, errData) = await outputTask.value
            let output = String(data: outData, encoding: .utf8) ?? ""

            guard status == 0 else {
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                throw SkillError.executionFailed(skillName, errStr)
            }

            return output
        } catch {
            if process.isRunning {
                process.terminate()
            }
            runningProcesses.removeValue(forKey: skillName)
            _ = await outputTask.value
            throw error
        }
    }

    private func waitForExit(process: Process, timeoutSeconds: Int) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning {
            try Task.checkCancellation()
            if Date() >= deadline {
                process.terminate()
                throw SkillError.timedOut(timeoutSeconds)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return process.terminationStatus
    }

    /// Check health of all running skill processes.
    func healthCheck() -> [String: Bool] {
        var status: [String: Bool] = [:]
        for (name, process) in runningProcesses {
            status[name] = process.isRunning
        }
        return status
    }

    enum SkillError: LocalizedError {
        case notFound(String)
        case serializationFailed
        case executionFailed(String, String)
        case timedOut(Int)

        var errorDescription: String? {
            switch self {
            case .notFound(let name): return "Skill not found: \(name)"
            case .serializationFailed: return "Failed to serialize skill request"
            case .executionFailed(let name, let err): return "Skill '\(name)' failed: \(err)"
            case .timedOut(let seconds): return "Skill timed out after \(seconds)s"
            }
        }
    }
}
