import Foundation

/// Skill-aware channel setup helper for conversational onboarding.
///
/// Lets the model inspect channel setup state and apply channel config fields
/// without requiring users to edit config files manually.
struct ChannelSetupTool: Tool {
    let name = "channel_setup"
    let description = "Inspect and configure channel skills. Actions: list, status, next_prompt, request_form, set, disconnect. Use this to find missing channel fields and save user-provided values safely."
    let parametersSchema = #"{"action":"string (required: list|status|next_prompt|request_form|set|disconnect)","channel":"string (required for status|next_prompt|request_form|set|disconnect)","values":"object (required for set)"}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"channel_setup","arguments":{"action":"next_prompt","channel":"discord"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        let action = (input["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !action.isEmpty else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "list":
            return await listChannels()

        case "status":
            guard let channel = normalizedChannel(input["channel"]) else {
                return .error("Missing required parameter: channel")
            }
            return await statusForChannel(channel)

        case "next_prompt", "next":
            guard let channel = normalizedChannel(input["channel"]) else {
                return .error("Missing required parameter: channel")
            }
            return await nextPromptForChannel(channel)

        case "request_form", "form":
            guard let channel = normalizedChannel(input["channel"]) else {
                return .error("Missing required parameter: channel")
            }
            return await requestFormForChannel(channel)

        case "set":
            guard let channel = normalizedChannel(input["channel"]) else {
                return .error("Missing required parameter: channel")
            }
            guard let values = input["values"] as? [String: Any], !values.isEmpty else {
                return .error("Missing required parameter: values")
            }
            return await applyValues(channel: channel, values: values)

        case "disconnect":
            guard let channel = normalizedChannel(input["channel"]) else {
                return .error("Missing required parameter: channel")
            }
            return await disconnect(channel: channel)

        default:
            return .error("Unsupported action '\(action)'. Use list|status|next_prompt|request_form|set|disconnect")
        }
    }

    private func listChannels() async -> ToolResult {
        let config = FaeConfig.load()
        let manager = SkillManager()
        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)

        guard !manifest.channels.isEmpty else {
            return .success("No channel skills discovered.")
        }

        var lines: [String] = ["## Channel Skills"]
        for channel in manifest.channels {
            let missing = channel.missingFields.isEmpty ? "none" : channel.missingFields.joined(separator: ", ")
            lines.append("- \(channel.displayName) (key=\(channel.key)) — state=\(channel.state.rawValue), missing=\(missing)")
        }
        lines.append("")
        lines.append("Tip: use next_prompt for one-by-one chat questions, or request_form to show a guided multi-field form.")

        return .success(lines.joined(separator: "\n"))
    }

    private func statusForChannel(_ channel: String) async -> ToolResult {
        let config = FaeConfig.load()
        let manager = SkillManager()
        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)

        guard let entry = findChannel(channel, in: manifest.channels) else {
            return .error("Channel '\(channel)' not found in discovered channel skills")
        }

        let missing = entry.missingFields.isEmpty ? "none" : entry.missingFields.joined(separator: ", ")
        let output = """
        Channel: \(entry.displayName)
        Key: \(entry.key)
        State: \(entry.state.rawValue)
        Missing fields: \(missing)
        Actions: \(entry.actionNames.joined(separator: ", "))
        """
        return .success(output)
    }

    private func nextPromptForChannel(_ channel: String) async -> ToolResult {
        let config = FaeConfig.load()
        let manager = SkillManager()
        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)
        let descriptors = await manager.configurableSkills(kind: "channel")

        guard let entry = findChannel(channel, in: manifest.channels) else {
            return .error("Channel '\(channel)' not found in discovered channel skills")
        }

        guard let descriptor = findDescriptor(channel, in: descriptors) else {
            return .error("Channel '\(channel)' settings contract unavailable")
        }

        guard !entry.missingFields.isEmpty else {
            return .success("\(entry.displayName) is already configured. You can offer to run a connection test.")
        }

        let missingSet = Set(entry.missingFields.map(canonicalFieldID))
        let orderedMissingFields = descriptor.fields.filter { field in
            field.required && missingSet.contains(canonicalFieldID(field.id))
        }

        guard let firstMissing = orderedMissingFields.first else {
            return .success("\(entry.displayName) has missing setup fields, but none are mappable to prompts. Ask the user to open Settings > Skills & Channels.")
        }

        let prompt = firstMissing.prompt ?? "Please provide your \(firstMissing.label)."
        let placeholder = firstMissing.placeholder ?? ""
        let sensitivityHint = firstMissing.sensitive ? "(sensitive; do not echo back full value)" : ""
        let remainingIDs = orderedMissingFields.map(\.id)

        let output = """
        Channel: \(entry.displayName)
        Next required field: \(firstMissing.id)
        Ask user: \(prompt) \(sensitivityHint)
        Placeholder: \(placeholder)
        Remaining required fields: \(remainingIDs.joined(separator: ", "))

        After user replies, call channel_setup with action=set and values={"\(firstMissing.id)":"<user_value>"}, then call next_prompt again.
        """
        return .success(output)
    }

    private func requestFormForChannel(_ channel: String) async -> ToolResult {
        guard isFormFlowEnabled() else {
            return .success("Guided channel forms are currently disabled by rollout flag. Use next_prompt + set for stepwise setup.")
        }

        let config = FaeConfig.load()
        let manager = SkillManager()
        let manifest = await SettingsCapabilityManifestBuilder.build(config: config, skillManager: manager)
        let descriptors = await manager.configurableSkills(kind: "channel")

        guard let entry = findChannel(channel, in: manifest.channels) else {
            return .error("Channel '\(channel)' not found in discovered channel skills")
        }

        guard let descriptor = findDescriptor(channel, in: descriptors) else {
            return .error("Channel '\(channel)' settings contract unavailable")
        }

        let missingSet = Set(entry.missingFields.map(canonicalFieldID))
        let requiredMissing = descriptor.fields.filter { field in
            field.required && missingSet.contains(canonicalFieldID(field.id))
        }

        guard !requiredMissing.isEmpty else {
            return .success("\(entry.displayName) is already configured. No form is needed.")
        }

        let formFields = requiredMissing.map {
            InputRequestBridge.FormField(
                id: $0.id,
                label: $0.label,
                placeholder: $0.placeholder ?? "",
                isSecure: $0.sensitive,
                required: true,
                minLength: $0.validation?.minLength,
                maxLength: $0.validation?.maxLength,
                regex: $0.validation?.regex,
                allowedValues: $0.validation?.allowedValues,
                mustBeHttps: $0.validation?.mustBeHttps ?? ($0.type == .url)
            )
        }

        let prompt = "Fill in the required fields for \(entry.displayName). Sensitive values are never shown in plain text once submitted."
        recordLocalRolloutMetric("channel_setup.request_form.opened")

        let values = await InputRequestBridge.shared.requestForm(
            title: "\(entry.displayName) setup",
            prompt: prompt,
            fields: formFields
        )

        guard let values, !values.isEmpty else {
            recordLocalRolloutMetric("channel_setup.request_form.cancelled")
            return .success("[user cancelled input]")
        }

        recordLocalRolloutMetric("channel_setup.request_form.submitted")

        let anyValues = values.reduce(into: [String: Any]()) { partial, item in
            partial[item.key] = item.value
        }
        return await applyValues(channel: channel, values: anyValues)
    }

    private func applyValues(channel: String, values: [String: Any]) async -> ToolResult {
        let manager = SkillManager()
        let descriptors = await manager.configurableSkills(kind: "channel")
        guard let descriptor = findDescriptor(channel, in: descriptors) else {
            return .error("Channel '\(channel)' settings contract unavailable")
        }

        var applied: [String] = []
        let fieldsByCanonicalID = Dictionary(
            uniqueKeysWithValues: descriptor.fields.map { (canonicalFieldID($0.id), $0) }
        )

        do {
            for (field, value) in values {
                let normalizedField = canonicalFieldID(field)
                guard let descriptorField = fieldsByCanonicalID[normalizedField] else {
                    continue
                }

                try ChannelSettingsStore.setValue(
                    channelKey: descriptor.key,
                    field: descriptorField,
                    rawValue: normalizedPersistedValue(fieldID: normalizedField, value: value)
                )
                applied.append(descriptorField.id)
            }
        } catch {
            return .error("Failed to save channel settings: \(error.localizedDescription)")
        }

        if applied.isEmpty {
            return .error("No supported fields were provided for channel '\(channel)'")
        }

        let status = await statusForChannel(channel)
        let summary = "Applied fields: \(applied.joined(separator: ", "))\n\n\(status.output)"
        return .success(summary)
    }

    private func disconnect(channel: String) async -> ToolResult {
        let manager = SkillManager()
        let descriptors = await manager.configurableSkills(kind: "channel")
        guard let descriptor = findDescriptor(channel, in: descriptors) else {
            return .error("Channel '\(channel)' settings contract unavailable")
        }

        do {
            try ChannelSettingsStore.clearChannel(
                channelKey: descriptor.key,
                fields: descriptor.fields
            )
        } catch {
            return .error("Failed to disconnect \(channel): \(error.localizedDescription)")
        }

        if descriptor.fields.isEmpty {
            return .success("\(descriptor.displayName) has no persisted fields to clear.")
        }

        return .success("Disconnected \(descriptor.displayName). All contract-backed fields were cleared.")
    }

    private func normalizedPersistedValue(fieldID: String, value: Any) -> Any {
        if fieldID == "allowedchannelids" || fieldID == "allowednumbers" {
            if let list = value as? [String] {
                return list
            }
            if let csv = value as? String {
                return csv
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }

        if let stringValue = value as? String {
            return stringValue
        }
        return "\(value)"
    }

    private func findDescriptor(
        _ requested: String,
        in descriptors: [SkillManager.ConfigurableSkillDescriptor]
    ) -> SkillManager.ConfigurableSkillDescriptor? {
        let key = normalizeChannelKey(requested)
        return descriptors.first(where: {
            normalizeChannelKey($0.key) == key ||
                normalizeChannelKey($0.displayName) == key ||
                normalizeChannelKey($0.name) == key
        })
    }

    private func normalizedChannel(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let normalized = normalizeChannelKey(raw)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizeChannelKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func canonicalFieldID(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func isFormFlowEnabled() -> Bool {
        let key = "fae.feature.channel_setup_forms"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }

    private func recordLocalRolloutMetric(_ key: String) {
        let defaults = UserDefaults.standard
        let current = defaults.integer(forKey: key)
        defaults.set(current + 1, forKey: key)
    }

    private func findChannel(
        _ requested: String,
        in channels: [SettingsCapabilityManifest.ChannelCapability]
    ) -> SettingsCapabilityManifest.ChannelCapability? {
        let key = normalizeChannelKey(requested)
        return channels.first(where: {
            normalizeChannelKey($0.key) == key ||
                normalizeChannelKey($0.displayName) == key ||
                normalizeChannelKey($0.skillName) == key
        })
    }
}
