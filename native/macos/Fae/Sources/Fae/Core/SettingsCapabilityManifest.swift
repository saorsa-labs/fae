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
        let supportsDisconnect: Bool
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
            let missing = missingFields(for: descriptor.fields, key: descriptor.key, config: config)
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
                actionNames: descriptor.actionNames,
                supportsDisconnect: descriptor.supportsDisconnect
            )
        }

        return SettingsCapabilityManifest(
            generatedAt: Date(),
            channelsEnabled: config.channels.enabled,
            channels: channels.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        )
    }

    private static func missingFields(
        for fields: [SkillManager.ConfigurableFieldDescriptor],
        key: String,
        config: FaeConfig
    ) -> [String] {
        let requiredFields = fields.filter(\.required)
        guard !requiredFields.isEmpty else { return [] }

        return requiredFields.compactMap { field in
            let value = ChannelSettingsStore.value(
                channelKey: key,
                field: field,
                config: config
            )
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                ? field.id
                : nil
        }
    }
}
