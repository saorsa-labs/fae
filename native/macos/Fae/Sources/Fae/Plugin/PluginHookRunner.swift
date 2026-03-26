import Foundation

/// Executes plugin hooks at lifecycle points (PreToolUse, PostToolUse, etc.).
///
/// Discovers `hooks/hooks.json` in installed plugins, runs hook scripts as
/// subprocesses (Python/shell), and returns their JSON responses.
///
/// Hook scripts receive `HookInput` as JSON on stdin and write `HookResponse`
/// as JSON to stdout. Non-zero exit or timeout → passthrough (fail-open).
actor PluginHookRunner {

    /// All registered hooks across all enabled plugins, grouped by event.
    private var hooks: [HookEvent: [RegisteredHook]] = [:]

    private struct RegisteredHook: Sendable {
        let pluginId: String
        let definition: HookDefinition
    }

    // MARK: - Registration

    /// Discover and register hooks from all installed plugins.
    func loadHooks(from plugins: [InstalledPlugin]) {
        hooks.removeAll()

        for plugin in plugins where plugin.isEnabled {
            guard let config = PluginHookConfig.load(from: plugin.directoryURL) else {
                continue
            }

            for (event, definitions) in config.hooks {
                for definition in definitions {
                    let registered = RegisteredHook(
                        pluginId: plugin.id,
                        definition: definition
                    )
                    hooks[event, default: []].append(registered)
                }
            }
        }

        let totalCount = hooks.values.reduce(0) { $0 + $1.count }
        if totalCount > 0 {
            NSLog(
                "PluginHookRunner: loaded %d hooks from %d events",
                totalCount,
                hooks.count
            )
        }
    }

    /// Check if any hooks are registered for an event.
    func hasHooks(for event: HookEvent) -> Bool {
        guard let eventHooks = hooks[event] else { return false }
        return !eventHooks.isEmpty
    }

    // MARK: - Execution

    /// Run all hooks for a given event and return the aggregate response.
    ///
    /// Hooks run sequentially. If any hook blocks, execution stops and the
    /// block response is returned. System messages are collected from all hooks.
    ///
    /// Fail-open: if a hook script crashes, times out, or returns invalid JSON,
    /// it is treated as a passthrough (no block, no message).
    func runHooks(event: HookEvent, input: HookInput) async -> HookResponse {
        guard let eventHooks = hooks[event], !eventHooks.isEmpty else {
            return .passthrough
        }

        var collectedMessages: [String] = []

        for hook in eventHooks {
            let response = await executeHook(hook: hook, input: input)

            if let msg = response.systemMessage, !msg.isEmpty {
                collectedMessages.append("[\(hook.pluginId)] \(msg)")
            }

            if response.shouldBlock {
                let blockMessage = collectedMessages.isEmpty
                    ? nil
                    : collectedMessages.joined(separator: "\n")
                return HookResponse(
                    systemMessage: blockMessage,
                    block: true,
                    metadata: response.metadata
                )
            }
        }

        if collectedMessages.isEmpty {
            return .passthrough
        }

        return HookResponse(
            systemMessage: collectedMessages.joined(separator: "\n"),
            block: false,
            metadata: nil
        )
    }

    // MARK: - Private

    /// Execute a single hook script.
    private func executeHook(hook: RegisteredHook, input: HookInput) async -> HookResponse {
        let command = hook.definition.command
        let timeout = hook.definition.timeout

        // Encode input to JSON.
        guard let inputData = try? JSONEncoder().encode(input) else {
            NSLog("PluginHookRunner: failed to encode input for %@", hook.pluginId)
            return .passthrough
        }

        // Parse command into executable + arguments.
        let components = parseCommand(command)
        guard let executable = components.first else {
            NSLog("PluginHookRunner: empty command for %@", hook.pluginId)
            return .passthrough
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Resolve executable path.
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
        } else {
            // Search common paths for the executable.
            process.executableURL = resolveExecutable(executable)
        }

        guard process.executableURL != nil else {
            NSLog(
                "PluginHookRunner: executable not found '%@' for plugin '%@'",
                executable,
                hook.pluginId
            )
            return .passthrough
        }

        process.arguments = Array(components.dropFirst())
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Write input to stdin.
        stdinPipe.fileHandleForWriting.write(inputData)
        stdinPipe.fileHandleForWriting.closeFile()

        do {
            try process.run()
        } catch {
            NSLog(
                "PluginHookRunner: failed to launch hook for %@: %@",
                hook.pluginId,
                error.localizedDescription
            )
            return .passthrough
        }

        // Wait with timeout.
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                process.waitUntilExit()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !completed {
            process.terminate()
            NSLog("PluginHookRunner: hook timed out (%ds) for %@", timeout, hook.pluginId)
            return .passthrough
        }

        guard process.terminationStatus == 0 else {
            NSLog(
                "PluginHookRunner: hook exited with %d for %@",
                process.terminationStatus,
                hook.pluginId
            )
            return .passthrough
        }

        // Read stdout and parse JSON response.
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard !outputData.isEmpty,
              let response = try? JSONDecoder().decode(HookResponse.self, from: outputData)
        else {
            return .passthrough
        }

        return response
    }

    /// Parse a shell command string into components.
    ///
    /// Handles basic quoting (double quotes only).
    private func parseCommand(_ command: String) -> [String] {
        var components: [String] = []
        var current = ""
        var inQuote = false

        for char in command {
            if char == "\"" {
                inQuote.toggle()
            } else if char == " " && !inQuote {
                if !current.isEmpty {
                    components.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            components.append(current)
        }
        return components
    }

    /// Resolve an executable name to a full path.
    private func resolveExecutable(_ name: String) -> URL? {
        let searchPaths = [
            "/usr/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/zerobrew/bin",
        ]

        // Also check if `name` is python3, node, bun, etc.
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // Try `which` as fallback.
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = [name]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        } catch {
            // Swallow — just return nil.
        }

        return nil
    }
}
