import Foundation

/// The kind of skill — instruction-only or executable with scripts.
enum SkillType: String, Codable, Sendable {
    /// Markdown-only: SKILL.md body injects into LLM context as instructions.
    case instruction
    /// Has `scripts/` directory with Python scripts invoked via `uv run --script`.
    case executable
}

/// Where the skill comes from.
enum SkillTier: String, Codable, Sendable {
    /// Bundled in app `Resources/Skills/` — immutable (can only be disabled).
    case builtin
    /// User-created or imported into `~/Library/Application Support/fae/skills/`.
    case personal
    /// Imported from a URL (stored alongside personal skills).
    case community
}

/// Health status of a skill.
enum SkillHealthStatus: Sendable {
    case healthy
    case degraded(String)
    case broken(String)
}

/// Parsed metadata from a SKILL.md frontmatter.
struct SkillMetadata: Sendable {
    let name: String
    let description: String
    let author: String?
    let version: String?
    let type: SkillType
    let tier: SkillTier
    var isEnabled: Bool
    let directoryURL: URL
}

/// Full skill record including lazy-loaded body content.
struct SkillRecord: Sendable {
    let metadata: SkillMetadata
    /// Full SKILL.md body (everything after frontmatter). Loaded on demand.
    let fullBody: String?
}
