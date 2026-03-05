import Foundation

struct AgentDelegateTool: Tool {
    let name = "delegate_agent"
    let description = "Delegate a task to an installed external agent CLI such as Codex, Claude Code, or Pi."
    let parametersSchema = #"{"provider":"string (required — codex|claude|pi)","prompt":"string (required — task to delegate)","workdir":"string (optional — working directory for the delegate agent)","mode":"string (optional — read_only|read_write, default read_only)","model":"string (optional — provider-specific model name)","append_system_prompt":"string (optional — extra system guidance appended for the delegate)","secret_bindings":{"type":"object","description":"optional map of ENV_VAR -> keychain key. Secret values are injected into the delegate process environment"}}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"delegate_agent","arguments":{"provider":"codex","mode":"read_write","workdir":"~/Projects/app","prompt":"Implement the failing parser fix and run the relevant tests."}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let providerRaw = input["provider"] as? String,
              let provider = DelegateProvider(rawValue: providerRaw.lowercased())
        else {
            return .error("Missing or invalid provider. Use codex, claude, or pi.")
        }

        guard let prompt = input["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .error("Missing required parameter: prompt")
        }

        let mode = DelegateMode(rawValue: (input["mode"] as? String ?? "read_only").lowercased()) ?? .readOnly
        let appendSystemPrompt = input["append_system_prompt"] as? String
        let model = input["model"] as? String
        let secretBindings = parseStringMap(input["secret_bindings"]) ?? [:]

        let workdir: URL
        if let rawPath = input["workdir"] as? String, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: rawPath).expandingTildeInPath
            workdir = URL(fileURLWithPath: expanded).standardized.resolvingSymlinksInPath()
        } else {
            workdir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .standardized
                .resolvingSymlinksInPath()
        }

        guard FileManager.default.fileExists(atPath: workdir.path) else {
            return .error("Working directory does not exist: \(workdir.path)")
        }

        do {
            let output = try await ExternalAgentDelegate.run(
                provider: provider,
                prompt: prompt,
                workdir: workdir,
                mode: mode,
                model: model,
                appendSystemPrompt: appendSystemPrompt,
                secretBindings: secretBindings
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let final = trimmed.isEmpty ? "[delegate returned no text]" : trimmed
            return .success(final.count > 20_000 ? String(final.prefix(20_000)) + "\n[truncated]" : final)
        } catch {
            return .error("Delegate execution failed: \(error.localizedDescription)")
        }
    }

    private func parseStringMap(_ raw: Any?) -> [String: String]? {
        guard let rawDict = raw as? [String: Any] else { return nil }
        var parsed: [String: String] = [:]
        for (key, value) in rawDict {
            guard let stringValue = value as? String else { return nil }
            parsed[key] = stringValue
        }
        return parsed
    }
}

private enum DelegateProvider: String {
    case codex
    case claude
    case pi
}

private enum DelegateMode: String {
    case readOnly = "read_only"
    case readWrite = "read_write"
}

private enum ExternalAgentDelegate {
    static func run(
        provider: DelegateProvider,
        prompt: String,
        workdir: URL,
        mode: DelegateMode,
        model: String?,
        appendSystemPrompt: String?,
        secretBindings: [String: String]
    ) async throws -> String {
        let environment = try resolveSecretBindings(secretBindings)

        switch provider {
        case .codex:
            return try await runCodex(
                prompt: prompt,
                workdir: workdir,
                mode: mode,
                model: model,
                appendSystemPrompt: appendSystemPrompt,
                environment: environment
            )
        case .claude:
            return try await runClaude(
                prompt: prompt,
                workdir: workdir,
                mode: mode,
                model: model,
                appendSystemPrompt: appendSystemPrompt,
                environment: environment
            )
        case .pi:
            return try await runPi(
                prompt: prompt,
                workdir: workdir,
                mode: mode,
                model: model,
                appendSystemPrompt: appendSystemPrompt,
                environment: environment
            )
        }
    }

    private static func runCodex(
        prompt: String,
        workdir: URL,
        mode: DelegateMode,
        model: String?,
        appendSystemPrompt: String?,
        environment: [String: String]
    ) async throws -> String {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-codex-\(UUID().uuidString).txt")

        var args = [
            "codex", "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "-C", workdir.path,
            "-o", outputFile.path,
        ]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["-m", model])
        }

        switch mode {
        case .readOnly:
            args.append(contentsOf: ["-s", "read-only"])
        case .readWrite:
            args.append("--full-auto")
        }

        args.append(buildPrompt(prompt: prompt, mode: mode, appendSystemPrompt: appendSystemPrompt))
        let result = try await runProcess(args: args, workdir: workdir, environment: environment, timeoutSeconds: 600)
        defer { try? FileManager.default.removeItem(at: outputFile) }

        let finalMessage = (try? String(contentsOf: outputFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let finalMessage, !finalMessage.isEmpty {
            return finalMessage
        }

        return bestEffortOutput(stdout: result.stdout, stderr: result.stderr)
    }

    private static func runClaude(
        prompt: String,
        workdir: URL,
        mode: DelegateMode,
        model: String?,
        appendSystemPrompt: String?,
        environment: [String: String]
    ) async throws -> String {
        var args = [
            "claude",
            "-p",
            "--output-format", "text",
            "--permission-mode", mode == .readOnly ? "plan" : "dontAsk",
        ]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        let systemPrompt = [
            mode == .readOnly
                ? "Operate in analysis mode only. Do not modify files."
                : "You may modify files in the working directory when the task requires it.",
            appendSystemPrompt ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        if !systemPrompt.isEmpty {
            args.append(contentsOf: ["--append-system-prompt", systemPrompt])
        }
        args.append(buildPrompt(prompt: prompt, mode: mode, appendSystemPrompt: nil))

        let result = try await runProcess(args: args, workdir: workdir, environment: environment, timeoutSeconds: 600)
        return bestEffortOutput(stdout: result.stdout, stderr: result.stderr)
    }

    private static func runPi(
        prompt: String,
        workdir: URL,
        mode: DelegateMode,
        model: String?,
        appendSystemPrompt: String?,
        environment: [String: String]
    ) async throws -> String {
        var args = [
            "pi",
            "-p",
            "--mode", "text",
            "--no-session",
            "--tools", mode == .readOnly ? "read,grep,find,ls" : "read,bash,edit,write,grep,find,ls",
        ]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        if let appendSystemPrompt, !appendSystemPrompt.isEmpty {
            args.append(contentsOf: ["--append-system-prompt", appendSystemPrompt])
        }
        args.append(buildPrompt(prompt: prompt, mode: mode, appendSystemPrompt: nil))

        let result = try await runProcess(args: args, workdir: workdir, environment: environment, timeoutSeconds: 600)
        return bestEffortOutput(stdout: result.stdout, stderr: result.stderr)
    }

    private static func buildPrompt(prompt: String, mode: DelegateMode, appendSystemPrompt: String?) -> String {
        let modeInstruction = mode == .readOnly
            ? "Stay read-only. Analyze, explain, and propose changes, but do not modify files."
            : "You may inspect and modify files in the working directory to complete the task."

        var parts = [
            modeInstruction,
            "Work only inside the supplied working directory unless the task explicitly requires more context.",
            prompt.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let appendSystemPrompt, !appendSystemPrompt.isEmpty {
            parts.insert(appendSystemPrompt, at: 1)
        }
        return parts.joined(separator: "\n\n")
    }

    private static func runProcess(
        args: [String],
        workdir: URL,
        environment: [String: String],
        timeoutSeconds: Int
    ) async throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = workdir

        var mergedEnv = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnv[key] = value
        }
        process.environment = mergedEnv

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

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning {
            try Task.checkCancellation()
            if Date() >= deadline {
                process.terminate()
                throw NSError(
                    domain: "AgentDelegateTool",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Delegate process timed out after \(timeoutSeconds)s"]
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let (outData, errData) = await outputTask.value
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0, out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(
                domain: "AgentDelegateTool",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "Delegate process exited with code \(process.terminationStatus)" : err]
            )
        }

        return (out, err)
    }

    private static func bestEffortOutput(stdout: String, stderr: String) -> String {
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStdout.isEmpty { return trimmedStdout }
        return stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveSecretBindings(_ bindings: [String: String]) throws -> [String: String] {
        var resolved: [String: String] = [:]

        for (envName, keychainKey) in bindings {
            guard isSafeEnvironmentVariableName(envName) else {
                throw NSError(
                    domain: "AgentDelegateTool",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid env name '\(envName)'"]
                )
            }

            guard let value = CredentialManager.retrieve(key: keychainKey), !value.isEmpty else {
                throw NSError(
                    domain: "AgentDelegateTool",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing stored secret '\(keychainKey)'"]
                )
            }

            resolved[envName] = value
        }

        return resolved
    }

    private static func isSafeEnvironmentVariableName(_ value: String) -> Bool {
        let pattern = "^[A-Z][A-Z0-9_]{1,63}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}
