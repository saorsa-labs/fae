import Foundation

/// Contract-backed storage for configurable channel skills.
///
/// Non-secret values are stored in `channel_settings.json`.
/// Secret values are stored in Keychain under `channels.<channel>.<field>`.
enum ChannelSettingsStore {
    private struct StoreData: Codable {
        var version: Int = 1
        var channels: [String: [String: String]] = [:]
    }

    static var storeURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/channel_settings.json")
    }

    static func value(
        channelKey: String,
        field: SkillManager.ConfigurableFieldDescriptor,
        config: FaeConfig? = nil
    ) -> String? {
        value(
            channelKey: channelKey,
            fieldID: field.id,
            store: field.store,
            config: config
        )
    }

    static func value(
        channelKey: String,
        fieldID: String,
        store: SkillSettingsStore,
        config: FaeConfig? = nil
    ) -> String? {
        let normalizedChannel = normalizeChannelKey(channelKey)
        let normalizedField = normalizeFieldID(fieldID)

        switch store {
        case .secretStore:
            return CredentialManager.retrieve(
                key: storageKey(channelKey: normalizedChannel, fieldID: normalizedField)
            ) ?? legacyValue(channelKey: normalizedChannel, fieldID: normalizedField, config: config)

        case .configStore:
            if let stored = loadStore().channels[normalizedChannel]?[normalizedField],
               !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return stored
            }
            return legacyValue(channelKey: normalizedChannel, fieldID: normalizedField, config: config)
        }
    }

    static func setValue(
        channelKey: String,
        field: SkillManager.ConfigurableFieldDescriptor,
        rawValue: Any
    ) throws {
        try setValue(
            channelKey: channelKey,
            fieldID: field.id,
            store: field.store,
            rawValue: rawValue
        )
    }

    static func setValue(
        channelKey: String,
        fieldID: String,
        store: SkillSettingsStore,
        rawValue: Any
    ) throws {
        let normalizedChannel = normalizeChannelKey(channelKey)
        let normalizedField = normalizeFieldID(fieldID)
        let serialized = serialize(rawValue)

        switch store {
        case .secretStore:
            if let serialized, !serialized.isEmpty {
                try CredentialManager.store(
                    key: storageKey(channelKey: normalizedChannel, fieldID: normalizedField),
                    value: serialized
                )
            } else {
                CredentialManager.delete(
                    key: storageKey(channelKey: normalizedChannel, fieldID: normalizedField)
                )
            }

        case .configStore:
            var storeData = loadStore()
            var channelValues = storeData.channels[normalizedChannel] ?? [:]
            if let serialized, !serialized.isEmpty {
                channelValues[normalizedField] = serialized
            } else {
                channelValues.removeValue(forKey: normalizedField)
            }

            if channelValues.isEmpty {
                storeData.channels.removeValue(forKey: normalizedChannel)
            } else {
                storeData.channels[normalizedChannel] = channelValues
            }
            try persist(storeData)
        }

        try mirrorLegacyConfig(
            channelKey: normalizedChannel,
            fieldID: normalizedField,
            store: store,
            value: serialized
        )
    }

    static func clearValue(
        channelKey: String,
        fieldID: String,
        store: SkillSettingsStore
    ) throws {
        try setValue(
            channelKey: channelKey,
            fieldID: fieldID,
            store: store,
            rawValue: ""
        )
    }

    static func clearChannel(
        channelKey: String,
        fields: [SkillManager.ConfigurableFieldDescriptor]
    ) throws {
        for field in fields {
            try clearValue(
                channelKey: channelKey,
                fieldID: field.id,
                store: field.store
            )
        }
    }

    static func storageKey(channelKey: String, fieldID: String) -> String {
        "channels.\(normalizeChannelKey(channelKey)).\(normalizeFieldID(fieldID))"
    }

    private static func normalizeChannelKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func normalizeFieldID(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func serialize(_ rawValue: Any) -> String? {
        if let list = rawValue as? [String] {
            let cleaned = list
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned.joined(separator: ",")
        }

        let text = "\(rawValue)".trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func loadStore() -> StoreData {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(StoreData.self, from: data)
        else {
            return StoreData()
        }
        return decoded
    }

    private static func persist(_ storeData: StoreData) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storeData)

        let url = storeURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func legacyValue(
        channelKey: String,
        fieldID: String,
        config: FaeConfig?
    ) -> String? {
        guard let config else { return nil }

        switch (channelKey, fieldID) {
        case ("discord", "bot_token"):
            return CredentialManager.retrieve(key: "channels.discord.bot_token")
                ?? config.channels.discord.botToken
        case ("discord", "guild_id"):
            return config.channels.discord.guildId
        case ("discord", "allowed_channel_ids"):
            return config.channels.discord.allowedChannelIds.isEmpty
                ? nil
                : config.channels.discord.allowedChannelIds.joined(separator: ",")

        case ("whatsapp", "access_token"):
            return CredentialManager.retrieve(key: "channels.whatsapp.access_token")
                ?? config.channels.whatsapp.accessToken
        case ("whatsapp", "phone_number_id"):
            return config.channels.whatsapp.phoneNumberId
        case ("whatsapp", "verify_token"):
            return CredentialManager.retrieve(key: "channels.whatsapp.verify_token")
                ?? config.channels.whatsapp.verifyToken
        case ("whatsapp", "allowed_numbers"):
            return config.channels.whatsapp.allowedNumbers.isEmpty
                ? nil
                : config.channels.whatsapp.allowedNumbers.joined(separator: ",")

        default:
            return nil
        }
    }

    private static func mirrorLegacyConfig(
        channelKey: String,
        fieldID: String,
        store: SkillSettingsStore,
        value: String?
    ) throws {
        var config = FaeConfig.load()
        var didUpdate = true

        switch (channelKey, fieldID, store) {
        case ("discord", "bot_token", .secretStore):
            config.channels.discord.botToken = nil
        case ("discord", "guild_id", .configStore):
            config.channels.discord.guildId = value
        case ("discord", "allowed_channel_ids", .configStore):
            config.channels.discord.allowedChannelIds = parseList(value)

        case ("whatsapp", "access_token", .secretStore):
            config.channels.whatsapp.accessToken = nil
        case ("whatsapp", "phone_number_id", .configStore):
            config.channels.whatsapp.phoneNumberId = value
        case ("whatsapp", "verify_token", .secretStore):
            config.channels.whatsapp.verifyToken = nil
        case ("whatsapp", "allowed_numbers", .configStore):
            config.channels.whatsapp.allowedNumbers = parseList(value)

        default:
            didUpdate = false
        }

        guard didUpdate else { return }
        try config.save()
    }

    private static func parseList(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
