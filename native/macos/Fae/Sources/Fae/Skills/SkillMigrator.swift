import Foundation

/// Migrates legacy flat `.py` skill files to the new directory-based format.
///
/// On first run, scans `~/Library/Application Support/fae/skills/` for orphan
/// `.py` files and wraps each in its own directory with a generated SKILL.md.
enum SkillMigrator {

    /// Marker file written after migration to prevent re-runs.
    static let migrationMarker = ".skills_migrated_v2"

    /// Run migration if not already done. Returns count of migrated skills.
    @discardableResult
    static func migrateIfNeeded() -> Int {
        let skillsDir = SkillManager.skillsDirectory
        let fm = FileManager.default

        // Ensure skills directory exists.
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        // Check for marker.
        let markerURL = skillsDir.appendingPathComponent(migrationMarker)
        if fm.fileExists(atPath: markerURL.path) {
            return 0
        }

        // Scan for orphan .py files at the top level.
        guard let contents = try? fm.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return 0
        }

        let orphanPy = contents.filter { url in
            url.pathExtension == "py" && !url.lastPathComponent.hasPrefix(".")
        }

        guard !orphanPy.isEmpty else {
            // No orphans — write marker and return.
            writeMarker(at: markerURL)
            return 0
        }

        var migratedCount = 0

        for pyURL in orphanPy {
            let skillName = pyURL.deletingPathExtension().lastPathComponent
            let skillDir = skillsDir.appendingPathComponent(skillName)
            let scriptsDir = skillDir.appendingPathComponent("scripts")
            let skillMDURL = skillDir.appendingPathComponent("SKILL.md")
            let destPy = scriptsDir.appendingPathComponent(pyURL.lastPathComponent)

            do {
                // Create directory structure.
                try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

                // Move .py into scripts/
                try fm.moveItem(at: pyURL, to: destPy)

                // Generate SKILL.md
                let skillMD = """
                    ---
                    name: \(skillName)
                    description: Migrated Python skill (update this description).
                    metadata:
                      author: user
                      version: "1.0"
                    ---

                    This skill was automatically migrated from a standalone Python script.
                    Run via the run_skill tool.
                    """
                try skillMD.write(to: skillMDURL, atomically: true, encoding: .utf8)

                // Generate conservative MANIFEST.json for executable skills.
                let integrity = SkillManifestPolicy.buildIntegrity(for: skillDir)
                let manifest = SkillCapabilityManifest
                    .conservativeDefault(for: .executable)
                    .withIntegrity(integrity)
                let manifestURL = skillDir.appendingPathComponent(SkillManifestPolicy.fileName)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let manifestData = try encoder.encode(manifest)
                try manifestData.write(to: manifestURL)

                migratedCount += 1
                NSLog("SkillMigrator: migrated '%@' to directory format", skillName)
            } catch {
                NSLog(
                    "SkillMigrator: failed to migrate '%@': %@",
                    skillName, error.localizedDescription
                )
            }
        }

        // Write marker.
        writeMarker(at: markerURL)

        if migratedCount > 0 {
            NSLog("SkillMigrator: migrated %d skills to v2 directory format", migratedCount)
        }

        return migratedCount
    }

    private static func writeMarker(at url: URL) {
        let content = "Migrated on \(ISO8601DateFormatter().string(from: Date()))\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
