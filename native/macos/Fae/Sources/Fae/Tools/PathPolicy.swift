import Foundation

/// Result of path validation.
enum PathValidation {
    case allowed(canonicalPath: String)
    case blocked(reason: String)
}

/// Write-path security policy for Fae's file tools.
///
/// Reads are NEVER restricted — Fae is local and should read anything the user can.
/// Only write/edit operations are validated against a blocklist of sensitive paths.
///
/// Ported from: `legacy/rust-core/src/fae_llm/tools/path_validation.rs`
enum PathPolicy {

    /// Validate a path for write/edit operations.
    ///
    /// - Returns `.allowed(canonicalPath)` if the path is safe to write
    /// - Returns `.blocked(reason)` if the path is protected
    static func validateWritePath(_ path: String) -> PathValidation {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardized
        let resolved = url.resolvingSymlinksInPath().path
        let lowered = resolved.lowercased()

        // Block system paths.
        for prefix in blockedSystemPrefixes {
            if lowered.hasPrefix(prefix) {
                return .blocked(reason: "Cannot write to system path: \(prefix)")
            }
        }

        // Block sensitive dotfiles in home directory.
        let home = NSHomeDirectory()
        let homeLower = home.lowercased()
        if lowered.hasPrefix(homeLower) {
            let relative = String(resolved.dropFirst(home.count))
            let relativeLower = relative.lowercased()

            for dotfile in blockedDotfiles {
                if relativeLower == dotfile || relativeLower.hasPrefix(dotfile + "/") {
                    return .blocked(reason: "Cannot write to protected file: ~\(dotfile)")
                }
            }

            // Block Fae's own data directory files (force use of self_config/Settings/approval).
            // Protects BOTH production (fae/) and dev (fae-dev/) unconditionally — a dev-mode
            // tool must not be able to write to production data files and vice versa.
            for faeRoot in Self.protectedFaeRoots {
                if lowered.hasPrefix(faeRoot) {
                    let filename = URL(fileURLWithPath: resolved).lastPathComponent.lowercased()
                    if Self.protectedFaeFiles.contains(filename) {
                        return .blocked(
                            reason: "Cannot write to \(filename) directly. Use the appropriate tool or Settings."
                        )
                    }
                }
            }
        }

        return .allowed(canonicalPath: resolved)
    }

    // MARK: - Fae Data Protection

    /// Both production and dev data roots — protects files in either regardless of current mode.
    private static let protectedFaeRoots: [String] = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return [
            appSupport.appendingPathComponent("fae").path.lowercased(),
            appSupport.appendingPathComponent("fae-dev").path.lowercased(),
        ]
    }()

    /// Filenames within the Fae data directory that are never directly writable by tools.
    private static let protectedFaeFiles: Set<String> = [
        "config.toml", "fae.db", "scheduler.db", "soul.md",
        "speakers.json", "approved_tools.json",
    ]

    // MARK: - Blocklists

    /// System path prefixes that are never writable (case-insensitive on macOS).
    private static let blockedSystemPrefixes: [String] = [
        "/bin",
        "/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/system",
        "/library",  // top-level /Library (not ~/Library)
        "/etc",
        "/var",
        "/private/etc",
        "/private/var",
    ]

    /// Dotfiles/directories relative to home that are blocked for writes.
    /// Paths are compared case-insensitively (macOS APFS default).
    private static let blockedDotfiles: [String] = [
        // Shell profiles
        "/.bashrc",
        "/.bash_profile",
        "/.bash_login",
        "/.bash_logout",
        "/.zshrc",
        "/.zshenv",
        "/.zprofile",
        "/.zlogin",
        "/.zlogout",
        "/.profile",
        "/.login",
        // Secrets / credentials (most critical — never writable by tools)
        "/.secrets",
        "/.env",
        "/.envrc",
        "/.saorsa-keys",
        // Version control
        "/.gitconfig",
        // Cryptographic credentials
        "/.ssh",
        "/.gnupg",
        // Cloud provider credentials
        "/.aws",
        "/.azure",
        "/.kube",
        "/.docker",
        // Package manager credentials
        "/.npmrc",
        "/.pypirc",
        "/.cargo/credentials.toml",
        // Network credentials
        "/.netrc",
        // Fae internal (managed by GitVaultManager, not tools)
        "/.fae-vault",
        "/.fae-vault-dev",
    ]
}
