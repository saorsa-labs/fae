import CryptoKit
import Foundation

/// Per-skill integrity envelope for tamper detection.
struct SkillIntegrityManifest: Codable, Sendable {
    let algorithm: String
    let checksums: [String: String] // relative path -> digest hex
    let signature: String?
}

/// Declarative capability manifest for executable skills.
///
/// Stored as `MANIFEST.json` in each skill directory.
struct SkillCapabilityManifest: Codable, Sendable {
    let schemaVersion: Int
    let capabilities: [String]
    let allowedTools: [String]
    let allowedDomains: [String]
    let dataClasses: [String]
    let riskTier: SkillRiskTier
    let timeoutSeconds: Int
    let integrity: SkillIntegrityManifest?

    static let currentSchemaVersion = 1

    static func conservativeDefault(for type: SkillType) -> SkillCapabilityManifest {
        switch type {
        case .instruction:
            return SkillCapabilityManifest(
                schemaVersion: currentSchemaVersion,
                capabilities: ["instructions"],
                allowedTools: [],
                allowedDomains: [],
                dataClasses: ["none"],
                riskTier: .low,
                timeoutSeconds: 15,
                integrity: nil
            )

        case .executable:
            return SkillCapabilityManifest(
                schemaVersion: currentSchemaVersion,
                capabilities: ["execute"],
                allowedTools: ["run_skill"],
                allowedDomains: [],
                dataClasses: ["local_files"],
                riskTier: .medium,
                timeoutSeconds: 30,
                integrity: nil
            )
        }
    }

    func withIntegrity(_ integrity: SkillIntegrityManifest) -> SkillCapabilityManifest {
        SkillCapabilityManifest(
            schemaVersion: schemaVersion,
            capabilities: capabilities,
            allowedTools: allowedTools,
            allowedDomains: allowedDomains,
            dataClasses: dataClasses,
            riskTier: riskTier,
            timeoutSeconds: timeoutSeconds,
            integrity: integrity
        )
    }
}

enum SkillRiskTier: String, Codable, Sendable {
    case low
    case medium
    case high
}

enum SkillManifestPolicy {
    static let fileName = "MANIFEST.json"

    static func manifestURL(for skillDirectory: URL) -> URL {
        skillDirectory.appendingPathComponent(fileName)
    }

    /// Build a checksum map for SKILL.md and executable scripts.
    static func buildIntegrity(for skillDirectory: URL) -> SkillIntegrityManifest {
        var checksums: [String: String] = [:]

        let skillMd = skillDirectory.appendingPathComponent("SKILL.md")
        if let digest = checksum(for: skillMd) {
            checksums["SKILL.md"] = digest
        }

        let scriptsDir = skillDirectory.appendingPathComponent("scripts")
        if let files = try? FileManager.default.contentsOfDirectory(at: scriptsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "py" {
                let relative = "scripts/\(file.lastPathComponent)"
                if let digest = checksum(for: file) {
                    checksums[relative] = digest
                }
            }
        }

        return SkillIntegrityManifest(
            algorithm: "sha256",
            checksums: checksums,
            signature: nil
        )
    }

    static func verifyIntegrity(
        _ integrity: SkillIntegrityManifest,
        skillDirectory: URL
    ) -> String? {
        guard integrity.algorithm.lowercased() == "sha256" else {
            return "Unsupported integrity algorithm: \(integrity.algorithm)"
        }

        for (relative, expected) in integrity.checksums {
            let fileURL = skillDirectory.appendingPathComponent(relative)
            guard let actual = checksum(for: fileURL) else {
                return "Integrity check failed: missing file \(relative)"
            }
            if actual != expected {
                return "Integrity check failed: file \(relative) appears modified"
            }
        }

        return nil
    }

    private static func checksum(for fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
