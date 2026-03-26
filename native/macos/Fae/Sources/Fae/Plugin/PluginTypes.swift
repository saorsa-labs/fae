import Foundation

/// Represents a parsed `.claude-plugin/plugin.json` manifest.
struct PluginManifest: Codable, Sendable {
    let name: String
    let description: String
    let version: String?
    let keywords: [String]?
    let author: PluginAuthor?

    struct PluginAuthor: Codable, Sendable {
        let name: String
        let email: String?
    }
}

/// An installed plugin on disk at `~/.fae-plugins/<name>/`.
struct InstalledPlugin: Sendable {
    let manifest: PluginManifest
    let directoryURL: URL
    let skills: [PluginSkillEntry]
    let agents: [PluginAgentEntry]
    var isEnabled: Bool

    /// The plugin's unique identifier (directory name).
    var id: String { directoryURL.lastPathComponent }
}

/// A skill discovered inside a plugin's `skills/` directory.
struct PluginSkillEntry: Sendable {
    let name: String
    let skillURL: URL
    /// Translated Fae SkillMetadata for this plugin skill.
    let metadata: SkillMetadata
}

/// An agent definition discovered inside a plugin's `agents/` directory.
struct PluginAgentEntry: Sendable {
    let name: String
    let fileURL: URL
    /// Agent body (markdown instructions) converted to a Fae instruction skill.
    let metadata: SkillMetadata
}

/// Source from which a plugin can be installed.
enum PluginSource: Sendable {
    /// Git repository URL (HTTPS).
    case git(url: String, ref: String?)
    /// Local directory path.
    case local(path: String)
}

/// Errors during plugin operations.
enum PluginError: LocalizedError, Sendable {
    case notFound(String)
    case alreadyInstalled(String)
    case invalidManifest(String)
    case installFailed(String)
    case removeFailed(String)
    case gitCloneFailed(String)
    case disabled(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name): return "Plugin '\(name)' not found"
        case .alreadyInstalled(let name): return "Plugin '\(name)' is already installed"
        case .invalidManifest(let reason): return "Invalid plugin manifest: \(reason)"
        case .installFailed(let reason): return "Plugin install failed: \(reason)"
        case .removeFailed(let reason): return "Plugin removal failed: \(reason)"
        case .gitCloneFailed(let reason): return "Git clone failed: \(reason)"
        case .disabled(let name): return "Plugin '\(name)' is disabled"
        }
    }
}
