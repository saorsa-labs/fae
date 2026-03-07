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

    func testBuildManifestReadsContractBackedValuesForCustomChannel() async throws {
        let manager = SkillManager()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let skillName = "channel_matrix_\(suffix)"
        let channelKey = "matrix\(suffix)"

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
            try? ChannelSettingsStore.clearValue(
                channelKey: channelKey,
                fieldID: "homeserver_url",
                store: .configStore
            )
            try? ChannelSettingsStore.clearValue(
                channelKey: channelKey,
                fieldID: "access_token",
                store: .secretStore
            )
        }

        try await createChannelSkill(
            manager: manager,
            skillName: skillName,
            channelKey: channelKey,
            displayName: "Matrix",
            requiredFields: ["homeserver_url", "access_token"]
        )

        try ChannelSettingsStore.setValue(
            channelKey: channelKey,
            fieldID: "homeserver_url",
            store: .configStore,
            rawValue: "https://matrix.example.com"
        )
        try ChannelSettingsStore.setValue(
            channelKey: channelKey,
            fieldID: "access_token",
            store: .secretStore,
            rawValue: "matrix-secret-token"
        )

        var config = FaeConfig()
        config.channels.enabled = true

        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)
        let matrix = manifest.channels.first(where: { $0.key == channelKey && $0.skillName == skillName })

        XCTAssertNotNil(matrix)
        XCTAssertEqual(matrix?.state, .configured)
        XCTAssertEqual(matrix?.missingFields, [])
    }

    func testBuildManifestOnlyReportsStillMissingRequiredFields() async throws {
        let manager = SkillManager()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let skillName = "channel_progressive_\(suffix)"
        let channelKey = "progressive\(suffix)"

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
            try? ChannelSettingsStore.clearValue(
                channelKey: channelKey,
                fieldID: "bot_token",
                store: .secretStore
            )
            try? ChannelSettingsStore.clearValue(
                channelKey: channelKey,
                fieldID: "guild_id",
                store: .configStore
            )
            try? ChannelSettingsStore.clearValue(
                channelKey: channelKey,
                fieldID: "nickname",
                store: .configStore
            )
        }

        try await createChannelSkill(
            manager: manager,
            skillName: skillName,
            channelKey: channelKey,
            displayName: "Progressive Chat",
            fields: [
                SkillSettingsField(
                    id: "bot_token",
                    type: .secret,
                    label: "Bot Token",
                    required: true,
                    prompt: "What is your bot token?",
                    placeholder: nil,
                    help: nil,
                    defaultValue: nil,
                    options: nil,
                    validation: nil,
                    sensitive: true,
                    store: .secretStore
                ),
                SkillSettingsField(
                    id: "guild_id",
                    type: .text,
                    label: "Guild ID",
                    required: true,
                    prompt: "What is your guild ID?",
                    placeholder: nil,
                    help: nil,
                    defaultValue: nil,
                    options: nil,
                    validation: nil,
                    sensitive: false,
                    store: .configStore
                ),
                SkillSettingsField(
                    id: "nickname",
                    type: .text,
                    label: "Nickname",
                    required: false,
                    prompt: "Optional nickname",
                    placeholder: nil,
                    help: nil,
                    defaultValue: nil,
                    options: nil,
                    validation: nil,
                    sensitive: false,
                    store: .configStore
                ),
            ]
        )

        try ChannelSettingsStore.setValue(
            channelKey: channelKey,
            fieldID: "guild_id",
            store: .configStore,
            rawValue: "guild-123"
        )

        var config = FaeConfig()
        config.channels.enabled = true

        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)
        let progressive = manifest.channels.first(where: { $0.key == channelKey && $0.skillName == skillName })

        XCTAssertNotNil(progressive)
        XCTAssertEqual(progressive?.state, .missingInput)
        XCTAssertEqual(progressive?.requiredFields, ["bot_token", "guild_id"])
        XCTAssertEqual(progressive?.missingFields, ["bot_token"])
        XCTAssertFalse(progressive?.missingFields.contains("nickname") ?? true)
    }

    private func createChannelSkill(
        manager: SkillManager,
        skillName: String,
        channelKey: String,
        displayName: String,
        requiredFields: [String]
    ) async throws {
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

        try await createChannelSkill(
            manager: manager,
            skillName: skillName,
            channelKey: channelKey,
            displayName: displayName,
            fields: fields
        )
    }

    private func createChannelSkill(
        manager: SkillManager,
        skillName: String,
        channelKey: String,
        displayName: String,
        fields: [SkillSettingsField]
    ) async throws {
        _ = try await manager.createSkill(
            name: skillName,
            description: "Channel skill test fixture",
            body: "Fixture body for channel skill capability tests.",
            scriptContent: "print('ok')"
        )

        let skillDir = SkillManager.skillsDirectory.appendingPathComponent(skillName)
        let manifestURL = SkillManifestPolicy.manifestURL(for: skillDir)

        let manifest = SkillCapabilityManifest(
            schemaVersion: 1,
            capabilities: ["execute", "status", "configure"],
            allowedTools: ["run_skill"],
            allowedDomains: [],
            dataClasses: ["local_files"],
            riskTier: .medium,
            timeoutSeconds: 30,
            allowNetwork: false,
            allowSubprocess: false,
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
