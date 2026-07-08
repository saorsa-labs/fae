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
            pattern: #"rm\s+-[^\s]*r[^\s]*\s+(~/?\s*$|\$HOME\s*$|\$\{HOME\}\s*$)"#,
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
        //
        // nonLocalOnly=true  → blocked only when an external/co-work model is active
        // nonLocalOnly=false → blocked for all models (always)

        self.zeroAccessPaths = [
            // Secrets tier — ALWAYS zero-access, for every model (security-override
            // FLAW-3). This set mirrors the daemon's `secrets_relative()`
            // (`crates/fae-daemon/src/toolhost/isolation.rs`) EXACTLY. These were
            // previously split: only the first four were always-on, and the rest
            // were nonLocalOnly:true — but `ModelLocality` is permanently `.local`
            // in production, so those rules NEVER fired: no block, therefore no
            // `SecurityDenial`, therefore the human-gated authorize card could
            // never be offered for `~/.ssh` etc. Always-blocking (a) hardens
            // local-model reads as defense-in-depth (the daemon seatbelt already
            // denies them for routed bash) and (b) makes every daemon Secrets-tier
            // path produce the card with a precise target. They stay Secrets tier
            // (allow-once / 5-min only, never "always") via `SecurityTier.classify`.
            PathRule(path: "~/.secrets",              nonLocalOnly: false),
            PathRule(path: "~/.env",                  nonLocalOnly: false),
            PathRule(path: "~/.envrc",                nonLocalOnly: false),
            PathRule(path: "~/.saorsa-keys",          nonLocalOnly: false),
            PathRule(path: "~/.ssh",                  nonLocalOnly: false),
            PathRule(path: "~/.gnupg",                nonLocalOnly: false),
            PathRule(path: "~/.aws",                  nonLocalOnly: false),
            PathRule(path: "~/.azure",                nonLocalOnly: false),
            PathRule(path: "~/.kube",                 nonLocalOnly: false),
            PathRule(path: "~/.docker/config.json",   nonLocalOnly: false),
            PathRule(path: "~/.netrc",                nonLocalOnly: false),
            PathRule(path: "~/.npmrc",                nonLocalOnly: false),
            PathRule(path: "~/.pypirc",               nonLocalOnly: false),
            // Fae identity — ALWAYS zero-access (nonLocalOnly:false). These are the
            // three paths CLAUDE.md documents as unconditionally "zero-access via
            // DamageControlPolicy": the Git Vault, voice identity, and the system
            // directive. They were previously nonLocalOnly:true, but `ModelLocality`
            // is permanently `.local` in production (setModelLocality has no caller),
            // so a non-local-only rule NEVER fired — the documented protection was
            // dead. The LLM has no legitimate reason to read/raw-write these via the
            // generic read/write/edit/bash tools (the directive is mutated through
            // SelfConfigTool, which is not gated here; speaker identity + the vault
            // are managed by dedicated file-IO paths, not the `read` tool). So block
            // them for every model, including local (prompt injection can steer the
            // local model too).
            PathRule(path: "~/.fae-vault",                                        nonLocalOnly: false),
            PathRule(path: "~/.fae-vault-dev",                                    nonLocalOnly: false),
            PathRule(path: "~/Library/Application Support/fae/speakers.json",     nonLocalOnly: false),
            PathRule(path: "~/Library/Application Support/fae/directive.md",       nonLocalOnly: false),
            PathRule(path: "~/Library/Application Support/fae-dev/speakers.json", nonLocalOnly: false),
            PathRule(path: "~/Library/Application Support/fae-dev/directive.md",  nonLocalOnly: false),
            // Fae-integrity, ALWAYS zero-access (security-override Wave 2, L8):
            // the standing grant store + the model-artifact lock are Fae's own
            // trust anchors. The daemon's Fae-integrity/never set covers these too,
            // and refuses any human-gated override for them (belt-and-suspenders).
            PathRule(path: "~/Library/Application Support/fae/grant-store.json",     nonLocalOnly: false),
            PathRule(path: "~/Library/Application Support/fae/models.lock",          nonLocalOnly: false),
            PathRule(path: "~/Library/Application Support/fae-dev/grant-store.json", nonLocalOnly: false),
            PathRule(path: "~/Library/Application Support/fae-dev/models.lock",      nonLocalOnly: false),
            // config.toml + soul.md are NOT in the documented zero-access set: they
            // stay non-local-only (the pre-existing behavior — the local model may
            // read its own config/soul; only an external model is denied).
            PathRule(path: "~/Library/Application Support/fae/config.toml",        nonLocalOnly: true),
            PathRule(path: "~/Library/Application Support/fae/soul.md",            nonLocalOnly: true),
        ]

        // MARK: No-delete paths (bash rm/mv → confirm_manual, always active)

        self.noDeletePaths = [
            PathRule(path: "~/Library/Application Support/fae/"),
            PathRule(path: "~/Library/Application Support/fae-dev/"),
            PathRule(path: "~/.fae-vault"),
            PathRule(path: "~/.fae-vault-dev"),
        ]

        // MARK: Read-only paths (writes/edits denied — empty by default, user-configurable)

        self.readOnlyPaths = []
    }

    // MARK: - Evaluation

    /// Evaluate a tool call and return a `DCVerdict`.
    ///
    /// Called in `PipelineCoordinator.executeTool` before the outbound guard and
    /// `TrustedActionBroker`. A non-`.allow` verdict short-circuits the normal evaluation.
    ///
    /// `exemptZeroAccessTarget` (security-override FLAW-2): the ONE home-expanded
    /// zero-access rule path a human just authorized on the hardware card. On the
    /// approved re-submit the gate re-runs in FULL — catastrophe patterns,
    /// no-delete paths, read-only paths, and every OTHER zero-access rule still
    /// apply — and skips ONLY the single rule whose expanded path exactly equals
    /// the authorized target. `nil` (every ordinary call) ⇒ no exemption.
    func evaluate(
        toolName: String,
        arguments: [String: Any],
        locality: ModelLocality,
        exemptZeroAccessTarget: String? = nil
    ) -> DCVerdict {
        // Zero-access path check: applies to read, write, edit, and bash.
        //
        // read/write/edit compare the (home/$HOME-normalized, symlink-resolved)
        // argument path — a raw "~/.secrets" is normalized to an absolute path so
        // the prefix compare is not defeated by the tilde form the tool examples
        // teach the model. bash has no single path field, so we scan the command
        // text for any protected path in its absolute, ~ , or $HOME spelling
        // (quotes/backslash-escapes tolerated) — otherwise `bash: cat ~/.secrets`
        // would sail past this gate entirely.
        if ["read", "write", "edit", "bash"].contains(toolName) {
            let argForms = Self.normalizedArgumentForms(
                Self.extractPath(toolName: toolName, arguments: arguments))
            let bashCommand = toolName == "bash" ? (arguments["command"] as? String ?? "") : nil
            for rule in zeroAccessPaths {
                guard !rule.nonLocalOnly || locality == .nonLocal else { continue }
                let expanded = Self.expandPath(rule.path)
                // FLAW-2: skip ONLY the exact rule the human authorized (compare on
                // the same expanded form `securityDenialTarget` returned). Every
                // other zero-access rule still blocks a chained second target.
                if let exempt = exemptZeroAccessTarget, expanded == exempt { continue }
                let hitByArg = argForms.contains { $0 == expanded || $0.hasPrefix(expanded + "/") }
                let hitByBash = bashCommand.map {
                    Self.commandReferencesPath(command: $0, expandedPath: expanded)
                } ?? false
                if hitByArg || hitByBash {
                    let why = rule.nonLocalOnly
                        ? "Access to '\(rule.path)' is blocked when a non-local model is active. Credential files are zero-access."
                        : "Access to '\(rule.path)' is blocked — this is a protected zero-access path."
                    return .block(reason: why)
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
            // Token-based catastrophe check FIRST — robust to trailing slashes,
            // quotes, backslash-escapes, $HOME/${HOME}/~ spellings, and extra
            // arguments that the anchored regex rules below miss (e.g.
            // `rm -rf "$HOME"`, `rm -rf ~/Documents/`, `rm -rf ~/Desktop ~/Movies`).
            if let rmVerdict = Self.destructiveRmVerdict(command: command) {
                return rmVerdict
            }
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

    /// The protected zero-access path this tool call would touch, if any
    /// (security-override Wave 2, Part A). Returns the home-EXPANDED absolute path
    /// of the first matching zero-access rule — the `target` a `SecurityDenial`
    /// carries and a post-click override relaxes. `nil` if the call touches no
    /// zero-access path, so an ordinary bash-pattern / read-only block is NOT
    /// surfaced as an (overridable) security denial. Mirrors the zero-access scan
    /// in `evaluate` exactly (same rules, same match logic).
    func securityDenialTarget(
        toolName: String,
        arguments: [String: Any],
        locality: ModelLocality
    ) -> String? {
        guard ["read", "write", "edit", "bash"].contains(toolName) else { return nil }
        let argForms = Self.normalizedArgumentForms(
            Self.extractPath(toolName: toolName, arguments: arguments))
        let bashCommand = toolName == "bash" ? (arguments["command"] as? String ?? "") : nil
        for rule in zeroAccessPaths {
            guard !rule.nonLocalOnly || locality == .nonLocal else { continue }
            let expanded = Self.expandPath(rule.path)
            let hitByArg = argForms.contains { $0 == expanded || $0.hasPrefix(expanded + "/") }
            let hitByBash = bashCommand.map {
                Self.commandReferencesPath(command: $0, expandedPath: expanded)
            } ?? false
            if hitByArg || hitByBash { return expanded }
        }
        return nil
    }

    // MARK: - Helpers

    static func expandPath(_ path: String) -> String {
        guard path.hasPrefix("~/") || path == "~" else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst(1)  // drop the "~"
    }

    static func extractPath(toolName: String, arguments: [String: Any]) -> String? {
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

    /// Normalize a raw tool-argument path into absolute, standardized forms so a
    /// prefix compare against an expanded rule path is not defeated by `~`,
    /// `$HOME`, `..`, or a symlink into a protected directory. Returns the empty
    /// set for a nil/empty input. Includes both the standardized path and its
    /// symlink-resolved form (the latter catches a symlink whose target is a
    /// protected path).
    static func normalizedArgumentForms(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        let expanded = expandHomeForms(raw)
        let standardized = (expanded as NSString).standardizingPath
        let resolved = (standardized as NSString).resolvingSymlinksInPath
        return standardized == resolved ? [standardized] : [standardized, resolved]
    }

    /// Expand the shell home spellings (`~`, `~/…`, `$HOME`, `${HOME}`) at the
    /// start of a path to the current user's home directory.
    static func expandHomeForms(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" || path == "$HOME" || path == "${HOME}" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        if path.hasPrefix("$HOME/") { return home + path.dropFirst("$HOME".count) }
        if path.hasPrefix("${HOME}/") { return home + path.dropFirst("${HOME}".count) }
        return path
    }

    /// Strip shell quoting and backslash-escapes so a path containing a space
    /// (e.g. the fae data dir "Application Support") or a quoted `"$HOME"`
    /// normalizes to a literal form the protected-path needles can match. Not a
    /// full shell parser — it only removes `'`, `"`, and backslash-escapes, which
    /// is enough to defeat the trivial quoting a model emits to write a path.
    static func normalizeCommandForPathMatch(_ command: String) -> String {
        var out = ""
        out.reserveCapacity(command.count)
        var i = command.startIndex
        while i < command.endIndex {
            let c = command[i]
            if c == "\\" {
                let next = command.index(after: i)
                if next < command.endIndex {
                    out.append(command[next])
                    i = command.index(after: next)
                    continue
                }
            } else if c != "\"" && c != "'" {
                out.append(c)
            }
            i = command.index(after: i)
        }
        return out
    }

    /// True if a bash command references the given expanded path in its absolute,
    /// `~`, or `$HOME`/`${HOME}` spelling (quotes/backslash-escapes tolerated).
    /// Used for the zero-access gate, where any read/write/pipe of a protected
    /// path — not just a delete — must be blocked.
    static func commandReferencesPath(command: String, expandedPath: String) -> Bool {
        let normalized = normalizeCommandForPathMatch(command)
        return protectedNeedles(for: expandedPath).contains { normalized.contains($0) }
    }

    /// The absolute / `~` / `$HOME` / `${HOME}` spellings of an expanded path.
    /// A trailing slash on a directory rule (e.g. the fae data dir) is stripped so
    /// the needle matches a command targeting the dir with OR without the slash
    /// (`rm -rf …/fae` and `rm -rf …/fae/` both hit). Over-matching a sibling that
    /// shares the prefix is fail-safe for these protect/deny rules.
    private static func protectedNeedles(for expandedPath: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var base = expandedPath
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        guard base.hasPrefix(home) else { return [base] }
        let suffix = String(base.dropFirst(home.count))  // e.g. "/.secrets"
        return [base, "~" + suffix, "$HOME" + suffix, "${HOME}" + suffix]
    }

    /// Returns true if the shell command looks like it targets the given expanded
    /// path (absolute, `~`, or `$HOME` form; quotes/backslash-escapes tolerated).
    static func commandTargetsPath(command: String, expandedPath: String) -> Bool {
        commandReferencesPath(command: command, expandedPath: expandedPath)
    }

    /// Token-based catastrophe check for `rm` targeting the filesystem root, the
    /// home directory, or a whole major user folder. Robust to trailing slashes,
    /// quotes, backslash-escapes, `~`/`$HOME`/`${HOME}` spellings, and additional
    /// arguments — the forms the anchored regex rules miss. Returns the strongest
    /// applicable verdict, or nil when the command is not a catastrophic `rm`.
    static func destructiveRmVerdict(command: String) -> DCVerdict? {
        let normalized = normalizeCommandForPathMatch(command)
        let lower = normalized.lowercased()
        // Must be an `rm` invocation with a recursive flag.
        guard lower.range(of: #"(^|[;&|(]\s*|\s)rm\s"#, options: .regularExpression) != nil,
              lower.range(of: #"\brm\s+(-[a-z]*r[a-z]*|--recursive)\b"#, options: .regularExpression) != nil
        else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let majorFolders = ["Documents", "Desktop", "Library", "Movies", "Music", "Pictures", "Downloads"]
        for rawToken in normalized.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            if rawToken.hasPrefix("-") { continue }  // skip flags
            let expanded = expandHomeForms(rawToken)
            var target = (expanded as NSString).standardizingPath
            if target.count > 1 && target.hasSuffix("/") { target = String(target.dropLast()) }
            if target == "/" {
                return .block(reason: "Recursive deletion from filesystem root would destroy the entire system.")
            }
            if target == home {
                return .disaster(reason: "Entire home directory deletion — all your files, configs, and data would be permanently lost.")
            }
            for folder in majorFolders where target == home + "/" + folder {
                return .disaster(reason: "Deletion of a major user folder (\(folder)) — irreversible data loss.")
            }
        }
        return nil
    }

    /// Returns true if the command includes a destructive shell verb (rm, mv).
    static func isDestructiveShellCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        // Match "rm " or "rm\t" or "rm;" to avoid false positives on "remove_file.sh"
        return lower.range(of: #"\brm\b|\bmv\b"#, options: .regularExpression) != nil
    }

    static func matches(pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            // Fail closed: an invalid pattern is a programming error in a
            // catastrophic-command rule. Silently returning false would disable
            // the protection the rule exists to provide, so treat the command as
            // matching (deny) and log loudly so the broken rule is caught.
            NSLog("DamageControlPolicy: invalid regex pattern %@ — failing closed (treating as match)", pattern)
            return true
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
