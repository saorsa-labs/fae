import SwiftUI

/// Models & Privacy settings tab — ADR-014 cloud lane configuration.
///
/// Sections:
/// - Privacy: Three-state privacy lane selector with guarantees
/// - Cloud Models: Provider, base URL, model, API key, budget
struct SettingsModelsPrivacyTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case privacy = "Privacy"
        case cloud = "Cloud Models"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .privacy: return "lock.shield"
            case .cloud: return "cloud"
            }
        }
    }

    var commandSender: HostCommandSender?

    @State private var section: Section = .privacy
    @State private var hydratingFromConfig: Bool = false
    @State private var hasLoadedConfig: Bool = false

    // MARK: - Privacy lane
    @State private var privacyLane: String = "local"

    // MARK: - Cloud model config (mirrors existing remote* keys)
    @State private var remoteProviderPreset: String = "openrouter"
    @State private var remoteBaseURL: String = "https://openrouter.ai/api"
    @State private var remoteModel: String = "openai/gpt-4.1-mini"
    @State private var cloudDailyBudgetUSD: Double = 2.0
    @State private var cloudDailyBudgetText: String = "2.0"

    // MARK: - API key (Keychain — never stored in config)
    @State private var apiKeyInput: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var showingApiKey: Bool = false
    @State private var keyFeedback: String = ""

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    switch section {
                    case .privacy:
                        privacySection
                    case .cloud:
                        cloudSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            refreshKeyStatus()
            if !hasLoadedConfig {
                hasLoadedConfig = true
                Task { @MainActor in
                    await hydrateFromBackendConfig()
                }
            }
        }
    }

    // MARK: - Section Picker

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(Section.allCases) { sec in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        section = sec
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: sec.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(sec.rawValue)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(section == sec ? FaeDesign.heatherMist.opacity(0.20) : Color.clear)
                    )
                    .foregroundColor(section == sec ? FaeDesign.heatherMistText : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard(title: "Privacy Lane", icon: "lock.shield", color: FaeDesign.heatherMist) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Where Fae sends your conversations")
                        .font(.system(size: 13, design: .serif))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        laneOption(
                            value: "local",
                            label: "Private — everything stays on this Mac",
                            detail: "All turns are handled by the on-device model. No conversation data leaves your machine. This is the default."
                        )
                        laneOption(
                            value: "fleet",
                            label: "My devices — route to my own fleet",
                            detail: "Allows routing to other devices you own and have registered. Conversation data stays within your personal fleet."
                        )
                        laneOption(
                            value: "all",
                            label: "Allow cloud models",
                            detail: "Enables routing to cloud providers (e.g. OpenRouter) when the local model cannot handle a request. Requires an API key. A PII membrane filters sensitive content; a daily budget cap prevents unexpected spend."
                        )
                    }

                    if privacyLane != "local" {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(FaeDesign.statusWarning)
                            Text("Changes to the privacy lane take effect at the next daemon start.")
                                .font(.system(size: 11))
                                .foregroundStyle(FaeDesign.statusWarning)
                        }
                        .padding(.top, 4)
                    }
                }
            }

            SettingsCard(title: "Guarantees", icon: "checkmark.seal", color: FaeDesign.lochGreyGreen) {
                VStack(alignment: .leading, spacing: 10) {
                    guaranteeRow(
                        icon: "cpu",
                        color: FaeDesign.heatherMist,
                        title: "Local first",
                        body: "The on-device model always runs first. Cloud is only reached when the local model hands off explicitly."
                    )
                    Divider()
                    guaranteeRow(
                        icon: "eye.slash",
                        color: FaeDesign.lochGreyGreen,
                        title: "PII membrane",
                        body: "The daemon applies a privacy filter before any text reaches a cloud provider, redacting names, addresses, and other identifiable details."
                    )
                    Divider()
                    guaranteeRow(
                        icon: "banknote",
                        color: FaeDesign.faeGold,
                        title: "Daily budget cap",
                        body: "A hard spending limit (set in the Cloud Models section) blocks further cloud calls for the day once the cap is reached."
                    )
                    Divider()
                    guaranteeRow(
                        icon: "arrow.uturn.backward",
                        color: FaeDesign.highlandAmber,
                        title: "Automatic local fallback",
                        body: "If the cloud is unavailable, the budget is exhausted, or the PII membrane blocks a request, Fae falls back to the on-device model and tells you."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func laneOption(value: String, label: String, detail: String) -> some View {
        Button {
            guard !hydratingFromConfig else { return }
            privacyLane = value
            patchConfig("llm.privacy_lane", value: value)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: privacyLane == value
                      ? "largecircle.fill.circle"
                      : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(privacyLane == value ? FaeDesign.heatherMistText : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(privacyLane == value ? FaeDesign.heatherMistText : .primary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func guaranteeRow(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(body)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Cloud Models Section

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard(title: "OpenRouter API Key", icon: "key", color: FaeDesign.faeGold) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The key is stored in the macOS Keychain and injected into the daemon at launch. It never appears in logs or config files.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if hasStoredKey {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(FaeDesign.statusSuccess)
                                .font(.system(size: 12))
                            Text("API key stored in Keychain")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(FaeDesign.statusSuccess)
                            Spacer()
                            Button("Remove") {
                                CredentialManager.delete(key: "openrouter.apiKey")
                                refreshKeyStatus()
                                keyFeedback = "Key removed"
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            .foregroundStyle(FaeDesign.statusError)
                        }
                    }

                    HStack(spacing: 8) {
                        Group {
                            if showingApiKey {
                                TextField("sk-or-…", text: $apiKeyInput)
                            } else {
                                SecureField("Paste API key…", text: $apiKeyInput)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        Button(showingApiKey ? "Hide" : "Show") {
                            showingApiKey.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                        Button("Save") {
                            let trimmed = apiKeyInput.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else {
                                keyFeedback = "Key cannot be empty"
                                return
                            }
                            do {
                                try CredentialManager.store(key: "openrouter.apiKey", value: trimmed)
                                apiKeyInput = ""
                                showingApiKey = false
                                refreshKeyStatus()
                                keyFeedback = "Key saved"
                            } catch {
                                keyFeedback = "Failed to save: \(error.localizedDescription)"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(FaeDesign.heatherMist)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if !keyFeedback.isEmpty {
                        Text(keyFeedback)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard(title: "Provider", icon: "network", color: FaeDesign.lochGreyGreen) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Provider preset")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Spacer()
                        TextField("openrouter", text: $remoteProviderPreset)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .font(.system(size: 12))
                            .onSubmit {
                                guard !hydratingFromConfig else { return }
                                patchConfig("llm.remote_provider_preset", value: remoteProviderPreset)
                            }
                    }

                    HStack {
                        Text("Base URL")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Spacer()
                        TextField("https://openrouter.ai/api", text: $remoteBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .font(.system(size: 12))
                            .onSubmit {
                                guard !hydratingFromConfig else { return }
                                patchConfig("llm.remote_base_url", value: remoteBaseURL)
                            }
                    }

                    HStack {
                        Text("Model")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Spacer()
                        TextField("openai/gpt-4.1-mini", text: $remoteModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .font(.system(size: 12))
                            .onSubmit {
                                guard !hydratingFromConfig else { return }
                                patchConfig("llm.remote_model", value: remoteModel)
                            }
                    }

                    Text("Changes to provider settings take effect at the next daemon start.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Daily Budget", icon: "banknote", color: FaeDesign.faeGold) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The daemon enforces this hard cap on cloud API spend per UTC day. When the cap is reached, Fae falls back to the local model for the rest of the day.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Text("Limit (USD/day)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Spacer()
                        TextField("2.00", text: $cloudDailyBudgetText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit {
                                commitBudget()
                            }
                        Text("USD")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Text("Valid range: $0.01 – $100.00. Takes effect at next daemon start.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func patchConfig(_ key: String, value: Any) {
        commandSender?.sendCommand(
            name: "config.patch",
            payload: ["key": key, "value": value]
        )
    }

    private func refreshKeyStatus() {
        hasStoredKey = CredentialManager.retrieve(key: "openrouter.apiKey") != nil
    }

    private func commitBudget() {
        guard !hydratingFromConfig else { return }
        if let parsed = Double(cloudDailyBudgetText.trimmingCharacters(in: .whitespaces)) {
            let clamped = min(max(parsed, 0.01), 100.0)
            cloudDailyBudgetUSD = clamped
            cloudDailyBudgetText = String(format: "%.2f", clamped)
            patchConfig("llm.cloud_daily_budget_usd", value: clamped)
        } else {
            // Reset to last known good value on bad input
            cloudDailyBudgetText = String(format: "%.2f", cloudDailyBudgetUSD)
        }
    }

    @MainActor
    private func hydrateFromBackendConfig() async {
        guard let sender = commandSender as? FaeCore else { return }

        hydratingFromConfig = true
        defer { hydratingFromConfig = false }

        if let response = await sender.queryCommand(name: "config.get", payload: ["key": "llm"]),
           let payload = response["payload"] as? [String: Any],
           let llm = payload["llm"] as? [String: Any]
        {
            if let lane = llm["privacyLane"] as? String {
                privacyLane = ["local", "fleet", "all"].contains(lane) ? lane : "local"
            }
            if let preset = llm["remoteProviderPreset"] as? String { remoteProviderPreset = preset }
            if let url = llm["remoteBaseURL"] as? String { remoteBaseURL = url }
            if let model = llm["remoteModel"] as? String { remoteModel = model }
            if let budget = llm["cloudDailyBudgetUSD"] as? Double {
                cloudDailyBudgetUSD = budget
                cloudDailyBudgetText = String(format: "%.2f", budget)
            }
        }
    }
}
