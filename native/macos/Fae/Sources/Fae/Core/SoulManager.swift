import Foundation

/// Manages SOUL.md — Fae's character contract.
///
/// On first launch, copies the bundled default to the user's data directory.
/// Loaded fresh every turn so edits take effect immediately.
enum SoulManager {

    static var userSoulURLOverride: URL?

    /// User's editable soul file path.
    static var userSoulURL: URL {
        if let override = userSoulURLOverride {
            return override
        }
                return FaeDirectories.soulFile
    }

    /// Read the bundled default SOUL.md from the resource bundle.
    static func defaultSoul() -> String {
        if let url = Bundle.faeResources.url(forResource: "SOUL", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.isEmpty
        {
            return content
        }
        // Hardcoded fallback if bundle resource is missing.
        return """
            You are Fae, a warm and curious AI companion. Be concise, genuine, and helpful.
            Remember what matters. Use tools when needed. Be quiet when not addressed.
            """
    }

    /// Load the user's soul, falling back to the bundled default.
    static func loadSoul() -> String {
        let url = userSoulURL
        if FileManager.default.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return content
        }
        return defaultSoul()
    }

    /// Condensed soul for voice-optimized first turn (reduces prefill by ~2K tokens).
    /// Preserves essential personality traits while cutting SOUL.md from 8.8K to ~1.4K chars.
    /// Full SOUL is used on subsequent turns when KV cache is warm.
    static func loadCondensedSoul() -> String {
        """
        Fae is warm, curious, playful, and concise. Bright and cheery, takes people seriously \
        without taking herself too seriously. Never uses the same greeting twice. Admits uncertainty \
        without apology. Has a bright wit.

        She remembers without being asked. Holds what matters, lets go of what doesn't. Updates \
        gracefully when corrected. Uses tools when needed, confirms outcomes.

        There when needed, quiet when not. Thinks before speaking — always. She'd rather take 30 \
        seconds to give a correct answer than rush something half-right. Adjusts energy to match yours.

        Direct address from owner → respond fully. Background noise → stay quiet. \
        Uncertain → err on silence. Primary user is a capable adult — no unsolicited caveats.

        Proactive: picks up on dates, people, interests. Morning briefings like a friend over coffee. \
        Gentle nudges, never nags. Never installs anything without a yes.
        """
    }

    /// Save new soul content to the user's data directory.
    static func saveSoul(_ text: String) throws {
        let url = userSoulURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reset the user's soul to the bundled default.
    static func resetToDefault() throws {
        try saveSoul(defaultSoul())
    }

    /// If the user's soul file doesn't exist, copy the bundled default there.
    static func ensureUserCopy() {
        let url = userSoulURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try saveSoul(defaultSoul())
            NSLog("SoulManager: copied default SOUL.md to %@", url.path)
        } catch {
            NSLog("SoulManager: failed to copy default SOUL.md: %@", error.localizedDescription)
        }
    }

    /// Whether the user's soul file differs from the bundled default.
    static var isModified: Bool {
        let url = userSoulURL
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return false }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
            != defaultSoul().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Line count of the current soul file.
    static var lineCount: Int {
        loadSoul().components(separatedBy: .newlines).count
    }
}
