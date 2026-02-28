import Foundation

/// Input sanitization for shell commands and content.
///
/// Ported from: `legacy/rust-core/src/fae_llm/tools/input_sanitize.rs`
enum InputSanitizer {

    /// Characters considered shell metacharacters.
    private static let shellMetacharacters: Set<Character> = [
        ";", "&", "|", "$", "`", "(", ")", "{", "}", "<", ">",
        "!", "\\", "\n", "\r", "\0",
    ]

    /// Check if a string contains shell metacharacters.
    static func containsShellMetacharacters(_ input: String) -> Bool {
        input.contains(where: { shellMetacharacters.contains($0) })
    }

    /// Sanitize command input by stripping shell metacharacters.
    ///
    /// Returns the sanitized string and whether any characters were removed.
    static func sanitizeCommandInput(_ input: String) -> (sanitized: String, modified: Bool) {
        let filtered = String(input.filter { !shellMetacharacters.contains($0) })
        return (filtered, filtered != input)
    }

    /// Sanitize content input — only strips null bytes.
    ///
    /// Content (file bodies, text) is more permissive than commands.
    static func sanitizeContentInput(_ input: String) -> (sanitized: String, modified: Bool) {
        let filtered = input.replacingOccurrences(of: "\0", with: "")
        return (filtered, filtered != input)
    }

    // MARK: - Bash Command Classification

    /// Known-safe command prefixes for the bash tool.
    ///
    /// Commands matching these prefixes still require approval — the approval card
    /// shows the full command. Unknown commands get a stronger warning.
    static let knownSafeCommandPrefixes: [String] = [
        "ls", "cat", "head", "tail", "grep", "find", "wc", "sort", "uniq",
        "diff", "file", "which", "whoami", "date", "echo", "git", "uv",
        "python3", "pip", "npm", "node", "cargo", "swift", "curl", "wget",
        "open", "pbcopy", "pbpaste", "defaults read", "mkdir", "cp", "mv",
        "touch", "pwd", "env", "printenv", "man", "less", "more", "tree",
        "du", "df", "stat", "md5", "shasum", "base64", "jq", "xargs",
        "just", "make", "brew", "zb",
    ]

    /// Classify a bash command as known-safe or unknown.
    ///
    /// Extracts the first word/phrase of the command and checks against the allowlist.
    /// Returns `nil` if the command matches a known-safe prefix, or a warning string if unknown.
    static func classifyBashCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty command" }

        // Check multi-word prefixes first (e.g. "defaults read").
        for prefix in knownSafeCommandPrefixes where prefix.contains(" ") {
            if trimmed.hasPrefix(prefix + " ") || trimmed == prefix {
                return nil
            }
        }

        // Extract the first word (command name).
        let firstWord: String
        if let spaceIdx = trimmed.firstIndex(of: " ") {
            firstWord = String(trimmed[..<spaceIdx])
        } else {
            firstWord = trimmed
        }

        // Strip any leading path (e.g. /usr/bin/env → env).
        let basename = (firstWord as NSString).lastPathComponent

        if knownSafeCommandPrefixes.contains(basename) {
            return nil
        }

        return "Unknown command '\(basename)' — review carefully before approving"
    }
}
