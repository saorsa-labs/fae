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

            // Block Fae's own config (force use of self_config tool or Settings UI).
            let faeConfigSuffix = "/library/application support/fae/config.toml"
            if lowered.hasSuffix(faeConfigSuffix) {
                return .blocked(
                    reason: "Cannot write to Fae's config.toml directly. Use the self_config tool or Settings."
                )
            }
        }

        return .allowed(canonicalPath: resolved)
    }

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
        "/.gitconfig",
        "/.ssh",
        "/.gnupg",
        "/.aws",
        "/.azure",
        "/.kube",
        "/.docker",
        "/.npmrc",
        "/.netrc",
        "/.fae-vault",
    ]
}
