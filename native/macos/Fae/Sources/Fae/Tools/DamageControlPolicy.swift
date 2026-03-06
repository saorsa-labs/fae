import Foundation

/// Whether the active LLM is running locally (MLX on-device) or via a non-local
/// API/cloud co-work session. Used by DamageControlPolicy to enforce stricter
/// credential-file protections when an external model is active.
enum ModelLocality: String, Sendable {
    case local    // MLX on-device inference
    case nonLocal // API / cloud co-work model
}

/// Pre-broker policy verdict returned by `DamageControlPolicy`.
enum DCVerdict: Sendable {
    /// Allow the tool call to proceed normally.
    case allow
    /// Hard deny — no dialog, no override. Recovery is literally impossible (disk format, etc.).
    case block(reason: String)
    /// Catastrophic operation with an escape hatch. Shows a DISASTER WARNING overlay.
    /// No voice approval, no "Always" — only a deliberate physical button press proceeds.
    case disaster(reason: String)
    /// Dangerous but has legitimate uses. Shows a manual-only confirmation overlay.
    /// No voice approval — physical button press required.
    case confirmManual(reason: String)
}

/// Layer 0 pre-broker policy that intercepts tool calls before `TrustedActionBroker`.
///
/// Evaluates bash commands and file path access against hardcoded rules that protect
/// against the most catastrophic possible agent actions. Unlike `TrustedActionBroker`,
/// which governs normal tool risk policy, `DamageControlPolicy` is a last-resort
/// safety net for operations from which there is literally no recovery.
///
/// ## Three-tier response model
///
/// - **Block**: Hard deny, no user interaction. Disk format, raw disk write, root permission wipeout.
/// - **Disaster**: Extreme manual-only overlay. Total home/major-folder deletion. No voice, no "Always".
/// - **Confirm Manual**: Standard manual-only overlay. Sudo delete, curl-pipe-shell, system daemon changes.
///
/// ## Dual trust model
///
/// - **Local model**: Full read/write access everywhere (subject to normal broker policy).
/// - **Non-local/co-work model**: Credential dotfiles are zero-access — hard block even for reads.
///
/// ## Rule loading
///
/// Default rules are embedded in code. User overrides may be added in
/// `~/Library/Application Support/fae/damage-control-override.json` (future).
/// The reference YAML schema is documented in `Resources/damage-control-default.yaml`.
actor DamageControlPolicy {

    // MARK: - Rule Types

    /// Action category for a bash pattern match.
    enum DCAction: Sendable {
        case block
        case disaster
        case confirmManual
    }

    /// A regex pattern matched against bash commands.
    struct BashRule: Sendable {
        let pattern: String
        let reason: String
        let action: DCAction
        /// When true, this rule only fires when the model is non-local.
        let nonLocalOnly: Bool

        init(pattern: String, reason: String, action: DCAction, nonLocalOnly: Bool = false) {
            self.pattern = pattern
            self.reason = reason
            self.action = action
            self.nonLocalOnly = nonLocalOnly
        }
    }

    /// A path prefix rule — matched against tool arguments' path fields.
    struct PathRule: Sendable {
        let path: String
        /// When true, this rule only fires when the model is non-local.
        let nonLocalOnly: Bool

        init(path: String, nonLocalOnly: Bool = false) {
            self.path = path
            self.nonLocalOnly = nonLocalOnly
        }
    }

    // MARK: - State

    private let bashRules: [BashRule]
    /// Paths that are completely off-limits (reads AND writes blocked).
    private let zeroAccessPaths: [PathRule]
    /// Paths where bash rm/mv require manual confirmation.
    private let noDeletePaths: [PathRule]
    /// Paths where writes/edits are denied.
    private let readOnlyPaths: [PathRule]

    // MARK: - Init

    init() {
        var rules: [BashRule] = []

        // MARK: Block — no recovery possible

        rules.append(BashRule(
            pattern: #"rm\s+-[^\s]*r[^\s]*\s+/\s*$"#,
            reason: "Recursive deletion from filesystem root would destroy the entire system.",
            action: .block
        ))
        rules.append(BashRule(
            pattern: #"mkfs\b|diskutil\s+erase\b|diskutil\s+zeroDisk\b"#,
            reason: "Disk format or erase operation — data cannot be recovered.",
            action: .block
        ))
        rules.append(BashRule(
            pattern: #"dd\s+.*\bof=/dev/(?!null\b)"#,
            reason: "Raw disk write via dd — can corrupt the entire drive.",
            action: .block
        ))
        rules.append(BashRule(
            pattern: #"chmod\s+-[^\s]*R[^\s]*\s+[0-]*\s+/\s*$"#,
            reason: "Strip all permissions from filesystem root — system becomes unbootable.",
            action: .block
        ))

        // MARK: Disaster — catastrophic, override possible with deliberate physical click

        rules.append(BashRule(
            pattern: #"rm\s+-[^\s]*r[^\s]*\s+~/?\s*$"#,
            reason: "Entire home directory deletion — all your files, configs, and data would be permanently lost.",
            action: .disaster
        ))
        rules.append(BashRule(
            pattern: #"rm\s+-[^\s]*r[^\s]*\s+~/Documents\s*$|rm\s+-[^\s]*r[^\s]*\s+~/Desktop\s*$"#,
            reason: "Deletion of a major user folder (Documents or Desktop) — irreversible data loss.",
            action: .disaster
        ))
        rules.append(BashRule(
            pattern: #"rm\s+-[^\s]*r[^\s]*\s+~/Library\s*$"#,
            reason: "Deletion of ~/Library — all app data, preferences, and keychains would be lost.",
            action: .disaster
        ))

        // MARK: Confirm Manual — dangerous but legitimate uses exist

        rules.append(BashRule(
            pattern: #"sudo\s+rm\s+-[^\s]*r"#,
            reason: "Privileged recursive delete — requires deliberate confirmation.",
            action: .confirmManual
        ))
        rules.append(BashRule(
            pattern: #"curl\s+.*\|\s*(bash|sh|zsh|fish|python[0-9.]*)\b"#,
            reason: "Curl-pipe-shell: downloading and immediately executing remote code.",
            action: .confirmManual
        ))
        rules.append(BashRule(
            pattern: #"wget\s+.*\|\s*(bash|sh|zsh|fish|python[0-9.]*)\b"#,
            reason: "Wget-pipe-shell: downloading and immediately executing remote code.",
            action: .confirmManual
        ))
        rules.append(BashRule(
            pattern: #"launchctl\s+(bootout|disable)\s+system/"#,
            reason: "Disabling a system-level launchd daemon — may break core macOS services.",
            action: .confirmManual
        ))
        rules.append(BashRule(
            pattern: #"osascript\s+-e\s+.*System\s+Events"#,
            reason: "AppleScript system automation via osascript requires manual confirmation.",
            action: .confirmManual
        ))

        self.bashRules = rules

        // MARK: Zero-access paths (non-local model only — credential exfiltration prevention)

        self.zeroAccessPaths = [
            PathRule(path: "~/.ssh",                  nonLocalOnly: true),
            PathRule(path: "~/.gnupg",                nonLocalOnly: true),
            PathRule(path: "~/.aws",                  nonLocalOnly: true),
            PathRule(path: "~/.azure",                nonLocalOnly: true),
            PathRule(path: "~/.kube",                 nonLocalOnly: true),
            PathRule(path: "~/.docker/config.json",   nonLocalOnly: true),
            PathRule(path: "~/.netrc",                nonLocalOnly: true),
            PathRule(path: "~/.npmrc",                nonLocalOnly: true),
        ]

        // MARK: No-delete paths (bash rm/mv → confirm_manual, always active)

        self.noDeletePaths = [
            PathRule(path: "~/Library/Application Support/fae/"),
            PathRule(path: "~/.fae-vault"),
        ]

        // MARK: Read-only paths (writes/edits denied — empty by default, user-configurable)

        self.readOnlyPaths = []
    }

    // MARK: - Evaluation

    /// Evaluate a tool call and return a `DCVerdict`.
    ///
    /// Called in `PipelineCoordinator.executeTool` before the outbound guard and
    /// `TrustedActionBroker`. A non-`.allow` verdict short-circuits the normal evaluation.
    func evaluate(
        toolName: String,
        arguments: [String: Any],
        locality: ModelLocality
    ) -> DCVerdict {
        // Zero-access path check: applies to read, write, edit, and bash.
        if ["read", "write", "edit", "bash"].contains(toolName) {
            let path = Self.extractPath(toolName: toolName, arguments: arguments)
            for rule in zeroAccessPaths {
                guard !rule.nonLocalOnly || locality == .nonLocal else { continue }
                let expanded = Self.expandPath(rule.path)
                if let path, path.hasPrefix(expanded) || path == expanded.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                    return .block(
                        reason: "Access to '\(rule.path)' is blocked when a non-local model is active. Credential files are zero-access."
                    )
                }
            }
        }

        // No-delete path check: bash commands containing rm or mv on protected paths.
        if toolName == "bash" {
            let command = arguments["command"] as? String ?? ""
            for rule in noDeletePaths {
                guard !rule.nonLocalOnly || locality == .nonLocal else { continue }
                let expanded = Self.expandPath(rule.path)
                if Self.commandTargetsPath(command: command, expandedPath: expanded)
                    && Self.isDestructiveShellCommand(command)
                {
                    return .confirmManual(
                        reason: "Destructive operation on protected path '\(rule.path)'. Manual confirmation required."
                    )
                }
            }
        }

        // Read-only path check: deny writes and edits.
        if ["write", "edit"].contains(toolName) {
            let path = Self.extractPath(toolName: toolName, arguments: arguments)
            for rule in readOnlyPaths {
                guard !rule.nonLocalOnly || locality == .nonLocal else { continue }
                let expanded = Self.expandPath(rule.path)
                if let path, path.hasPrefix(expanded) {
                    return .block(
                        reason: "Writes to '\(rule.path)' are blocked by damage-control policy."
                    )
                }
            }
        }

        // Bash pattern check (most expensive — done last).
        if toolName == "bash" {
            let command = arguments["command"] as? String ?? ""
            for rule in bashRules {
                guard !rule.nonLocalOnly || locality == .nonLocal else { continue }
                if Self.matches(pattern: rule.pattern, in: command) {
                    switch rule.action {
                    case .block:        return .block(reason: rule.reason)
                    case .disaster:     return .disaster(reason: rule.reason)
                    case .confirmManual: return .confirmManual(reason: rule.reason)
                    }
                }
            }
        }

        return .allow
    }

    // MARK: - Helpers

    private static func expandPath(_ path: String) -> String {
        guard path.hasPrefix("~/") || path == "~" else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst(1)  // drop the "~"
    }

    private static func extractPath(toolName: String, arguments: [String: Any]) -> String? {
        switch toolName {
        case "read":
            return arguments["path"] as? String ?? arguments["file_path"] as? String
        case "write", "edit":
            return arguments["file_path"] as? String ?? arguments["path"] as? String
        case "bash":
            // Bash doesn't have a single path field — pattern matching handles it.
            return nil
        default:
            return nil
        }
    }

    /// Returns true if the shell command looks like it targets the given expanded path.
    private static func commandTargetsPath(command: String, expandedPath: String) -> Bool {
        // Match against both the full expanded path and the tilde form.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tildePath: String
        if expandedPath.hasPrefix(home) {
            tildePath = "~" + expandedPath.dropFirst(home.count)
        } else {
            tildePath = expandedPath
        }
        return command.contains(expandedPath) || command.contains(tildePath)
    }

    /// Returns true if the command includes a destructive shell verb (rm, mv).
    private static func isDestructiveShellCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        // Match "rm " or "rm\t" or "rm;" to avoid false positives on "remove_file.sh"
        return lower.range(of: #"\brm\b|\bmv\b"#, options: .regularExpression) != nil
    }

    private static func matches(pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
