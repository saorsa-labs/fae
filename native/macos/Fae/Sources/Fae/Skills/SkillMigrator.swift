import Foundation

/// Migrates legacy flat skill files to the directory-based Agent Skills layout.
///
/// Supported legacy inputs:
/// - top-level `.py` files in `~/Library/Application Support/fae/skills/`
/// - flat `.py` / `.md` files in `~/.fae/skills/`
enum SkillMigrator {

    /// Marker file written after migration to prevent re-runs.
    static let migrationMarker = ".skills_migrated_v3"

    /// Run migration if not already done. Returns count of migrated skills.
    @discardableResult
    static func migrateIfNeeded() -> Int {
        let destinationRoot = SkillManager.skillsDirectory
        let fm = FileManager.default

        try? fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let markerURL = destinationRoot.appendingPathComponent(migrationMarker)
        if fm.fileExists(atPath: markerURL.path) {
            return 0
        }

        let sources = [
            destinationRoot,
            SkillManager.legacySkillsDirectory,
        ]

        var migratedCount = 0
        for source in sources {
            migratedCount += migrateFlatFiles(from: source, into: destinationRoot, fm: fm)
        }

        writeMarker(at: markerURL)

        if migratedCount > 0 {
            NSLog("SkillMigrator: migrated %d legacy skills to directory format", migratedCount)
        }

        return migratedCount
    }

    private static func migrateFlatFiles(from sourceRoot: URL, into destinationRoot: URL, fm: FileManager) -> Int {
        guard let contents = try? fm.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return 0
        }

        var migratedCount = 0

        for entry in contents {
            guard !entry.lastPathComponent.hasPrefix(".") else { continue }

            switch entry.pathExtension.lowercased() {
            case "py":
                if migratePythonFile(entry, destinationRoot: destinationRoot, fm: fm) {
                    migratedCount += 1
                }
            case "md":
                if migrateMarkdownFile(entry, destinationRoot: destinationRoot, fm: fm) {
                    migratedCount += 1
                }
            default:
                continue
            }
        }

        return migratedCount
    }

    private static func migratePythonFile(_ sourceURL: URL, destinationRoot: URL, fm: FileManager) -> Bool {
        let skillName = sourceURL.deletingPathExtension().lastPathComponent
        let skillDir = destinationRoot.appendingPathComponent(skillName, isDirectory: true)
        let scriptsDir = skillDir.appendingPathComponent("scripts", isDirectory: true)
        let skillMDURL = skillDir.appendingPathComponent("SKILL.md")
        let destinationScript = scriptsDir.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

            if fm.fileExists(atPath: destinationScript.path) {
                try fm.removeItem(at: destinationScript)
            }
            try moveOrReplace(sourceURL, to: destinationScript, fm: fm)

            if !fm.fileExists(atPath: skillMDURL.path) {
                let skillMD = """
                    ---
                    name: \(skillName)
                    description: Migrated Python skill (update this description).
                    metadata:
                      author: user
                      version: "1.0"
                    ---

                    This skill was automatically migrated from a legacy standalone Python script.
                    Use the `run_skill` tool to execute it.
                    """
                try skillMD.write(to: skillMDURL, atomically: true, encoding: .utf8)
            }

            writeManifestIfExecutable(skillDir: skillDir)
            NSLog("SkillMigrator: migrated legacy Python skill '%@'", skillName)
            return true
        } catch {
            NSLog("SkillMigrator: failed to migrate '%@': %@", skillName, error.localizedDescription)
            return false
        }
    }

    private static func migrateMarkdownFile(_ sourceURL: URL, destinationRoot: URL, fm: FileManager) -> Bool {
        let inferredName = sourceURL.deletingPathExtension().lastPathComponent
        guard sourceURL.lastPathComponent != "SKILL.md" else { return false }

        do {
            let raw = try String(contentsOf: sourceURL, encoding: .utf8)
            let content = normalizeSkillMarkdown(name: inferredName, content: raw)
            let skillName = inferredSkillName(from: content) ?? inferredName
            let skillDir = destinationRoot.appendingPathComponent(skillName, isDirectory: true)
            let skillMDURL = skillDir.appendingPathComponent("SKILL.md")

            try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
            try content.write(to: skillMDURL, atomically: true, encoding: .utf8)

            if sourceURL.standardizedFileURL != skillMDURL.standardizedFileURL {
                try? fm.removeItem(at: sourceURL)
            }

            NSLog("SkillMigrator: migrated legacy markdown skill '%@'", skillName)
            return true
        } catch {
            NSLog("SkillMigrator: failed to migrate markdown skill '%@': %@", inferredName, error.localizedDescription)
            return false
        }
    }

    private static func normalizeSkillMarkdown(name: String, content: String) -> String {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---") {
            return content
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            ---
            name: \(name)
            description: Imported legacy skill (update this description).
            metadata:
              author: user
              version: "1.0"
            ---

            \(trimmed)
            """
    }

    private static func inferredSkillName(from content: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("name:") {
                return String(trimmed.dropFirst("name:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private static func writeManifestIfExecutable(skillDir: URL) {
        let integrity = SkillManifestPolicy.buildIntegrity(for: skillDir)
        let manifest = SkillCapabilityManifest
            .conservativeDefault(for: .executable)
            .withIntegrity(integrity)
        let manifestURL = skillDir.appendingPathComponent(SkillManifestPolicy.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let manifestData = try? encoder.encode(manifest) {
            try? manifestData.write(to: manifestURL)
        }
    }

    private static func moveOrReplace(_ sourceURL: URL, to destinationURL: URL, fm: FileManager) throws {
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return
        }

        do {
            try fm.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destinationURL, options: .atomic)
            try? fm.removeItem(at: sourceURL)
        }
    }

    private static func writeMarker(at url: URL) {
        let content = "Migrated on \(ISO8601DateFormatter().string(from: Date()))\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
