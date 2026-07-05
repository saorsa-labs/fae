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

    /// Path to the macOS seatbelt driver. Bash is ALWAYS run under this so a
    /// prompt-injected local model cannot read the protected credential/identity
    /// files. There is no un-sandboxed execution path.
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// - Parameters:
    ///   - extraDenyReadPaths: additional absolute paths whose contents the
    ///     sandbox must deny reads of. Used by tests to point the enforcement at
    ///     hermetic temp files standing in for the real protected paths; empty
    ///     in production.
    static func execute(
        command: String,
        timeoutSeconds: Int,
        extraDenyReadPaths: [String] = []
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
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

        // Constrained environment: expose only a minimal set.
        let home = NSHomeDirectory()

        // FAIL CLOSED: bash MUST run under the OS sandbox that denies reads of
        // the protected paths. A substring/needle scan of the command (the
        // DamageControlPolicy layer) is trivially evaded (`cd ~ && cat .secrets`,
        // `cat ~/.sec*`, `f=.secrets; cat ~/$f`, `tar czf /tmp/x.tgz ~`); only a
        // kernel read-deny is sound. If the seatbelt driver is missing we REFUSE
        // — we never fall back to an un-sandboxed exec.
        guard FileManager.default.isExecutableFile(atPath: sandboxExecPath) else {
            throw NSError(
                domain: "SafeBashExecutor",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refusing to run bash: the macOS sandbox (\(sandboxExecPath)) is unavailable, "
                    + "so protected-path read denial cannot be enforced."]
            )
        }
        let profile = seatbeltProfile(home: home, extraDenyReadPaths: extraDenyReadPaths)

        // Run the shell UNDER seatbelt. Passing the profile and command as
        // discrete argv elements (not through an outer shell) avoids any
        // re-quoting hazard. If the profile fails to apply, sandbox-exec exits
        // non-zero WITHOUT ever executing the command — fail closed.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxExecPath)
        process.arguments = ["-p", profile, "/bin/zsh", "-c", command]
        let minimalPath = "\(home)/.local/bin:\(home)/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
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

    // MARK: - Seatbelt profile (protected-path read denial)

    /// Absolute paths whose file *contents* bash is denied to read, for the
    /// given home directory. This MIRRORS the always-zero-access set enforced by
    /// `DamageControlPolicy.zeroAccessPaths` (secrets/identity files) AND, as
    /// defence-in-depth, unconditionally denies the credential directories that
    /// the policy only blocks for non-local models (`~/.ssh`, `~/.aws`, …): a
    /// prompt-injected LOCAL model reading `~/.ssh/id_rsa` is exactly the C2
    /// exfiltration this layer must stop. Denying reads here is sound where the
    /// policy's command substring-match is not.
    ///
    /// Kept in sync with `DamageControlPolicy` by hand (that file is owned by a
    /// separate concern and is not edited here); both derive from the documented
    /// protected-path set.
    static func protectedReadPaths(home: String) -> [String] {
        let relative = [
            // Secrets — always zero-access regardless of model.
            ".secrets", ".env", ".envrc", ".saorsa-keys",
            // Cryptographic keys + cloud/network credentials — denied to every
            // model here (hardening the policy's non-local-only rules).
            ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker/config.json",
            ".netrc", ".npmrc", ".pypirc",
            // Fae identity + backup — always zero-access.
            ".fae-vault", ".fae-vault-dev",
            "Library/Application Support/fae/speakers.json",
            "Library/Application Support/fae/directive.md",
            "Library/Application Support/fae-dev/speakers.json",
            "Library/Application Support/fae-dev/directive.md",
        ]
        return relative.map { "\(home)/\($0)" }
    }

    /// Build a seatbelt (App Sandbox) profile that allows bash to run normally
    /// — read project files, exec tools, use the network, write to the workspace
    /// and temp dirs — but denies reading the contents of the protected paths.
    /// `(allow default)` keeps legitimate bash working; the trailing
    /// `(deny file-read* …)` rules win (last match) for the protected subpaths.
    static func seatbeltProfile(home: String, extraDenyReadPaths: [String] = []) -> String {
        let raw = protectedReadPaths(home: home) + extraDenyReadPaths
        // The kernel matches sandbox rules against the CANONICAL (symlink-
        // resolved) path of a read — e.g. `/var/...` opens as `/private/var/...`.
        // Include both the literal and the resolved form so a symlinked ancestor
        // (or `/tmp`, `/var`) cannot slip a protected read past the deny rule.
        var seen = Set<String>()
        var paths: [String] = []
        for p in raw {
            for candidate in [p, canonicalPath(p)] where seen.insert(candidate).inserted {
                paths.append(candidate)
            }
        }
        let denials = paths
            .map { "    (subpath \(seatbeltQuote($0)))" }
            .joined(separator: "\n")
        return """
            (version 1)
            (allow default)
            (deny file-read*
            \(denials)
            )
            """
    }

    /// Resolve `path` to its canonical (fully symlink-resolved) form the kernel
    /// matches sandbox rules against. `realpath` needs an existing path, so we
    /// resolve the deepest existing ancestor and re-append the remaining tail —
    /// this handles a protected path that does not yet exist (e.g. no `~/.aws`)
    /// and firmlinked prefixes (`/var` → `/private/var`, `/tmp` → `/private/tmp`)
    /// that Foundation's `resolvingSymlinksInPath()` does NOT resolve. Returns
    /// the input unchanged if nothing resolves (fail safe — the raw form is also
    /// emitted alongside).
    private static func canonicalPath(_ path: String) -> String {
        let fm = FileManager.default
        var existing = path
        var tail: [String] = []
        while !existing.isEmpty, existing != "/", !fm.fileExists(atPath: existing) {
            let url = URL(fileURLWithPath: existing)
            tail.insert(url.lastPathComponent, at: 0)
            existing = url.deletingLastPathComponent().path
        }
        guard let resolvedC = realpath(existing, nil) else { return path }
        defer { free(resolvedC) }
        let resolved = String(cString: resolvedC)
        if tail.isEmpty { return resolved }
        let base = resolved == "/" ? "" : resolved
        return base + "/" + tail.joined(separator: "/")
    }

    /// Quote a string as a seatbelt (TinyScheme) double-quoted literal.
    private static func seatbeltQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
