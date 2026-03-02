import Foundation

/// Snapshot used by Settings and diagnostics to understand what Fae can
/// configure right now (especially channel skills) without hardcoded UI state.
struct SettingsCapabilityManifest: Codable, Sendable {
    struct ChannelCapability: Codable, Sendable {
        enum State: String, Codable, Sendable {
            case configured
            case missingInput = "missing_input"
            case skillDisabled = "skill_disabled"
            case globalDisabled = "global_disabled"
        }

        let skillName: String
        let kind: String
        let key: String
        let displayName: String
        let state: State
        let requiredFields: [String]
        let missingFields: [String]
        let actionNames: [String]
    }

    let generatedAt: Date
    let channelsEnabled: Bool
    let channels: [ChannelCapability]
}

enum SettingsCapabilityManifestBuilder {
    static func build(
        config: FaeConfig,
        skillManager: SkillManager
    ) async -> SettingsCapabilityManifest {
        let channelSkills = await skillManager.configurableSkills(kind: "channel")

        let channels = channelSkills.map { descriptor -> SettingsCapabilityManifest.ChannelCapability in
            let missing = missingFields(for: descriptor.requiredFieldIDs, key: descriptor.key, config: config)
            let state: SettingsCapabilityManifest.ChannelCapability.State
            if !config.channels.enabled {
                state = .globalDisabled
            } else if !descriptor.isEnabled {
                state = .skillDisabled
            } else if missing.isEmpty {
                state = .configured
            } else {
                state = .missingInput
            }

            return .init(
                skillName: descriptor.name,
                kind: descriptor.kind,
                key: descriptor.key,
                displayName: descriptor.displayName,
                state: state,
                requiredFields: descriptor.requiredFieldIDs,
                missingFields: missing,
                actionNames: descriptor.actionNames
            )
        }

        return SettingsCapabilityManifest(
            generatedAt: Date(),
            channelsEnabled: config.channels.enabled,
            channels: channels.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        )
    }

    private static func missingFields(
        for requiredFields: [String],
        key: String,
        config: FaeConfig
    ) -> [String] {
        guard !requiredFields.isEmpty else { return [] }

        let keyLower = key.lowercased()
        return requiredFields.filter { field in
            let value = fieldValue(channelKey: keyLower, fieldID: field, config: config)
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
    }

    private static func fieldValue(
        channelKey: String,
        fieldID: String,
        config: FaeConfig
    ) -> String? {
        switch (channelKey, fieldID.lowercased()) {
        case ("discord", "bot_token"), ("discord", "bottoken"):
            return CredentialManager.retrieve(key: "channels.discord.bot_token")
                ?? config.channels.discord.botToken
        case ("discord", "guild_id"), ("discord", "guildid"):
            return config.channels.discord.guildId

        case ("whatsapp", "access_token"), ("whatsapp", "accesstoken"):
            return CredentialManager.retrieve(key: "channels.whatsapp.access_token")
                ?? config.channels.whatsapp.accessToken
        case ("whatsapp", "phone_number_id"), ("whatsapp", "phonenumberid"):
            return config.channels.whatsapp.phoneNumberId
        case ("whatsapp", "verify_token"), ("whatsapp", "verifytoken"):
            return CredentialManager.retrieve(key: "channels.whatsapp.verify_token")
                ?? config.channels.whatsapp.verifyToken

        // iMessage generally has no required API credential fields in local mode.
        default:
            return nil
        }
    }
}
