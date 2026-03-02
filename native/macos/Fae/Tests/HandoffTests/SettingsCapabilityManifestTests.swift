import Foundation
import XCTest
@testable import Fae

final class SettingsCapabilityManifestTests: XCTestCase {

    func testBuildManifestMarksMissingFields() async throws {
        let manager = SkillManager()
        let skillName = "channel_discord_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        defer { try? FileManager.default.removeItem(at: SkillManager.skillsDirectory.appendingPathComponent(skillName)) }

        try await createChannelSkill(
            manager: manager,
            skillName: skillName,
            channelKey: "discord",
            displayName: "Discord",
            requiredFields: ["bot_token", "guild_id"]
        )

        var config = FaeConfig()
        config.channels.enabled = true

        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)
        let discord = manifest.channels.first(where: { $0.key == "discord" && $0.skillName == skillName })

        XCTAssertNotNil(discord)
        XCTAssertEqual(discord?.state, .missingInput)
        XCTAssertEqual(Set(discord?.missingFields ?? []), Set(["bot_token", "guild_id"]))
    }

    func testBuildManifestMarksConfiguredFromLegacyConfig() async throws {
        let manager = SkillManager()
        let skillName = "channel_discord_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        defer { try? FileManager.default.removeItem(at: SkillManager.skillsDirectory.appendingPathComponent(skillName)) }

        try await createChannelSkill(
            manager: manager,
            skillName: skillName,
            channelKey: "discord",
            displayName: "Discord",
            requiredFields: ["bot_token", "guild_id"]
        )

        var config = FaeConfig()
        config.channels.enabled = true
        config.channels.discord.botToken = "test-bot-token"
        config.channels.discord.guildId = "123456789"

        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)
        let discord = manifest.channels.first(where: { $0.key == "discord" && $0.skillName == skillName })

        XCTAssertNotNil(discord)
        XCTAssertEqual(discord?.state, .configured)
        XCTAssertEqual(discord?.missingFields, [])
    }

    func testBuildManifestMarksGlobalDisabled() async throws {
        let manager = SkillManager()
        let skillName = "channel_discord_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        defer { try? FileManager.default.removeItem(at: SkillManager.skillsDirectory.appendingPathComponent(skillName)) }

        try await createChannelSkill(
            manager: manager,
            skillName: skillName,
            channelKey: "discord",
            displayName: "Discord",
            requiredFields: ["bot_token", "guild_id"]
        )

        var config = FaeConfig()
        config.channels.enabled = false

        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)
        let discord = manifest.channels.first(where: { $0.key == "discord" && $0.skillName == skillName })

        XCTAssertNotNil(discord)
        XCTAssertEqual(discord?.state, .globalDisabled)
    }

    func testBuildManifestReadsSecretFromKeychainFallback() async throws {
        let manager = SkillManager()
        let skillName = "channel_discord_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        defer { try? FileManager.default.removeItem(at: SkillManager.skillsDirectory.appendingPathComponent(skillName)) }

        try await createChannelSkill(
            manager: manager,
            skillName: skillName,
            channelKey: "discord",
            displayName: "Discord",
            requiredFields: ["bot_token", "guild_id"]
        )

        let key = "channels.discord.bot_token"
        let existing = CredentialManager.retrieve(key: key)
        defer {
            if let existing {
                try? CredentialManager.store(key: key, value: existing)
            } else {
                CredentialManager.delete(key: key)
            }
        }

        try CredentialManager.store(key: key, value: "keychain-token")

        var config = FaeConfig()
        config.channels.enabled = true
        config.channels.discord.botToken = nil
        config.channels.discord.guildId = "123456789"

        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)
        let discord = manifest.channels.first(where: { $0.key == "discord" && $0.skillName == skillName })

        XCTAssertNotNil(discord)
        XCTAssertEqual(discord?.state, .configured)
        XCTAssertEqual(discord?.missingFields, [])
    }

    private func createChannelSkill(
        manager: SkillManager,
        skillName: String,
        channelKey: String,
        displayName: String,
        requiredFields: [String]
    ) async throws {
        _ = try await manager.createSkill(
            name: skillName,
            description: "Channel skill test fixture",
            body: "Fixture body for channel skill capability tests.",
            scriptContent: "print('ok')"
        )

        let skillDir = SkillManager.skillsDirectory.appendingPathComponent(skillName)
        let manifestURL = SkillManifestPolicy.manifestURL(for: skillDir)

        let fields = requiredFields.map { fieldID in
            SkillSettingsField(
                id: fieldID,
                type: fieldID.contains("token") ? .secret : .text,
                label: fieldID,
                required: true,
                prompt: "Enter \(fieldID)",
                placeholder: nil,
                help: nil,
                defaultValue: nil,
                options: nil,
                validation: nil,
                sensitive: fieldID.contains("token"),
                store: fieldID.contains("token") ? .secretStore : .configStore
            )
        }

        let manifest = SkillCapabilityManifest(
            schemaVersion: 1,
            capabilities: ["execute", "status", "configure"],
            allowedTools: ["run_skill"],
            allowedDomains: [],
            dataClasses: ["local_files"],
            riskTier: .medium,
            timeoutSeconds: 30,
            integrity: SkillManifestPolicy.buildIntegrity(for: skillDir),
            settings: SkillSettingsContract(
                version: 1,
                kind: "channel",
                key: channelKey,
                displayName: displayName,
                description: "Configure \(displayName)",
                fields: fields,
                actions: SkillSettingsActions(
                    status: "status",
                    configure: "configure",
                    test: nil,
                    disconnect: nil,
                    sendSample: nil
                )
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL)
    }
}
