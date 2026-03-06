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
    /// Optional static policy guard for scripts that import raw network APIs.
    var allowNetwork: Bool? = nil
    /// Optional static policy guard for scripts that spawn subprocesses or shells.
    var allowSubprocess: Bool? = nil
    let integrity: SkillIntegrityManifest?
    /// Optional settings contract used by conversational setup and Settings UI.
    let settings: SkillSettingsContract?

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
                allowNetwork: false,
                allowSubprocess: false,
                integrity: nil,
                settings: nil
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
                allowNetwork: false,
                allowSubprocess: false,
                integrity: nil,
                settings: nil
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
            allowNetwork: allowNetwork,
            allowSubprocess: allowSubprocess,
            integrity: integrity,
            settings: settings
        )
    }
}

enum SkillRiskTier: String, Codable, Sendable {
    case low
    case medium
    case high
}

/// Declarative settings contract for a skill (optional).
///
/// This allows Fae to ask users only for missing configuration values and to
/// render guided forms in Settings without hardcoding per-skill UI.
struct SkillSettingsContract: Codable, Sendable {
    let version: Int
    let kind: String
    let key: String
    let displayName: String
    let description: String?
    let fields: [SkillSettingsField]
    let actions: SkillSettingsActions

    enum CodingKeys: String, CodingKey {
        case version
        case kind
        case key
        case displayName = "display_name"
        case description
        case fields
        case actions
    }
}

struct SkillSettingsField: Codable, Sendable {
    let id: String
    let type: SkillSettingsFieldType
    let label: String
    let required: Bool
    let prompt: String?
    let placeholder: String?
    let help: String?
    let defaultValue: String?
    let options: [SkillSettingsOption]?
    let validation: SkillSettingsValidation?
    let sensitive: Bool?
    let store: SkillSettingsStore?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case label
        case required
        case prompt
        case placeholder
        case help
        case defaultValue = "default"
        case options
        case validation
        case sensitive
        case store
    }
}

enum SkillSettingsFieldType: String, Codable, Sendable {
    case text
    case secret
    case bool
    case select
    case multiselect
    case number
    case url
    case phone
    case json
}

struct SkillSettingsOption: Codable, Sendable {
    let value: String
    let label: String
}

struct SkillSettingsValidation: Codable, Sendable {
    let minLength: Int?
    let maxLength: Int?
    let regex: String?
    let allowedValues: [String]?
    let minNumber: Double?
    let maxNumber: Double?
    let mustBeHttps: Bool?
    let mustBeNonEmptyTrimmed: Bool?

    enum CodingKeys: String, CodingKey {
        case minLength = "min_length"
        case maxLength = "max_length"
        case regex
        case allowedValues = "allowed_values"
        case minNumber = "min_number"
        case maxNumber = "max_number"
        case mustBeHttps = "must_be_https"
        case mustBeNonEmptyTrimmed = "must_be_non_empty_trimmed"
    }
}

enum SkillSettingsStore: String, Codable, Sendable {
    case configStore = "config_store"
    case secretStore = "secret_store"
}

struct SkillSettingsActions: Codable, Sendable {
    let status: String?
    let configure: String?
    let test: String?
    let disconnect: String?
    let sendSample: String?

    enum CodingKeys: String, CodingKey {
        case status
        case configure
        case test
        case disconnect
        case sendSample = "send_sample"
    }
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
