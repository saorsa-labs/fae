import SwiftUI

struct SettingsOtherLLMsTab: View {
    var commandSender: HostCommandSender?

    @State private var remoteProviderPreset: String = "openrouter"
    @State private var remoteBaseURL: String = "https://openrouter.ai/api"
    @State private var remoteModel: String = "openai/gpt-4.1-mini"
    @State private var openRouterAPIKey: String = ""
    @State private var providerAPIKey: String = ""
    @State private var hasStoredAPIKey: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var connectionStatus: String?
    @State private var discoveredModels: [String] = []
    @State private var showingModelPicker = false
    @State private var modelSearchText = ""

    private let openRouterKeychainKey = "llm.openrouter.api_key"

    private var selectedPreset: CoworkBackendPreset {
        CoworkBackendPresetCatalog.preset(id: remoteProviderPreset)
            ?? CoworkBackendPresetCatalog.preset(id: "openrouter")
            ?? CoworkLLMProviderKind.openAICompatibleExternal.defaultPreset
    }

    private var providerCredentialKey: String {
        "llm.remote_provider.\(selectedPreset.id).api_key"
    }

    private var suggestedModels: [String] {
        selectedPreset.suggestedModels
    }

    private var availableModels: [String] {
        var seen = Set<String>()
        return ([remoteModel] + discoveredModels + suggestedModels)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private var filteredModels: [String] {
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableModels }
        return availableModels.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection
                setupSection
                privacySection
            }
            .padding(24)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadState()
        }
        .sheet(isPresented: $showingModelPicker) {
            modelPickerSheet
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Other LLMs", systemImage: "network.badge.shield.half.filled")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Choose a remote provider, store its API key securely, and pick the exact model Fae should use for new remote sessions.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if selectedPreset.id == "openrouter" {
                    Link(destination: URL(string: "https://openrouter.ai/settings/keys")!) {
                        Label("Create OpenRouter key", systemImage: "key.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.borderedProminent)

                    Link(destination: URL(string: "https://openrouter.ai/models")!) {
                        Label("Browse models", systemImage: "square.stack.3d.up")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        showingModelPicker = true
                        modelSearchText = ""
                    } label: {
                        Label("Choose model", systemImage: "square.stack.3d.up")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var setupSection: some View {
        SettingsCard(title: "Remote provider setup", icon: "slider.horizontal.3", color: .blue) {
            VStack(alignment: .leading, spacing: 14) {
                Text("We store API keys securely in your macOS Keychain. Non-secret defaults like provider, base URL, and preferred model stay in Fae's config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Remote provider")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Picker("Remote provider", selection: $remoteProviderPreset) {
                        ForEach(CoworkBackendPresetCatalog.presets.filter { $0.providerKind != .faeLocalhost }, id: \.id) { preset in
                            Text(preset.displayName).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: remoteProviderPreset) {
                        applySelectedPresetDefaults()
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current provider")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(selectedPreset.displayName)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(hasStoredAPIKey ? "Key stored securely" : "No key stored yet")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(hasStoredAPIKey ? .green : .secondary)
                }

                SecureField(hasStoredAPIKey ? "Replace API key" : selectedPreset.apiKeyPlaceholder, text: $providerAPIKey)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button("Save API key") {
                        saveAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if hasStoredAPIKey {
                        Button("Clear stored key") {
                            CredentialManager.delete(key: providerCredentialKey)
                            if selectedPreset.id == "openrouter" {
                                CredentialManager.delete(key: openRouterKeychainKey)
                            }
                            hasStoredAPIKey = false
                            providerAPIKey = ""
                            connectionStatus = "\(selectedPreset.displayName) key removed from Keychain."
                        }
                        .buttonStyle(.bordered)
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Base URL")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        TextField("Base URL", text: $remoteBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!selectedPreset.allowsCustomBaseURL)
                            .onChange(of: remoteBaseURL) {
                                persistRemoteDefaults()
                            }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Preferred model for new remote sessions")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        HStack(spacing: 8) {
                            Text(remoteModel)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(remoteModel.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button("Choose") {
                                modelSearchText = ""
                                showingModelPicker = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }

                HStack(spacing: 10) {
                    Button(isTestingConnection ? "Testing…" : "Test connection & load models") {
                        Task { await testRemoteConnection() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTestingConnection || !hasUsableAPIKey)

                    Button("Use provider defaults") {
                        applySelectedPresetDefaults(forceModelReset: true)
                        connectionStatus = "\(selectedPreset.displayName) is now your preferred remote provider in Fae."
                    }
                    .buttonStyle(.bordered)
                }

                if let connectionStatus {
                    Text(connectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modelPickerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose \(selectedPreset.displayName) model")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            TextField("Search models", text: $modelSearchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredModels, id: \.self) { model in
                        Button {
                            remoteModel = model
                            persistRemoteDefaults()
                            showingModelPicker = false
                        } label: {
                            HStack {
                                Text(model)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white)
                                Spacer()
                                if remoteModel == model {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    showingModelPicker = false
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        .preferredColorScheme(.dark)
    }

    private var privacySection: some View {
        SettingsCard(title: "Privacy and commercial reality", icon: "lock.shield", color: .purple) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Using OpenRouter through Fae can reduce direct exposure because Fae keeps local-only workspace context on this Mac and only forwards shareable prompt context to remote models.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))

                Text("OpenRouter also gives you one routing layer instead of wiring Fae directly to several frontier providers. That can simplify operational privacy choices, but it does not eliminate third-party processing or guarantee GDPR, retention, or sector-specific compliance on its own.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Text("Before sending personal, confidential, or regulated data, review OpenRouter's current privacy/DPA terms and the selected model provider's own policy. Fae helps minimize what leaves your Mac; it cannot promise what a remote provider does after receipt.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasUsableAPIKey: Bool {
        hasStoredAPIKey || !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadState() {
        let config = FaeConfig.load()
        remoteProviderPreset = config.llm.remoteProviderPreset
        remoteBaseURL = config.llm.remoteBaseURL
        remoteModel = config.llm.remoteModel
        providerAPIKey = ""
        hasStoredAPIKey = CredentialManager.retrieve(key: providerCredentialKey) != nil
            || (remoteProviderPreset == "openrouter" && CredentialManager.retrieve(key: openRouterKeychainKey) != nil)
    }

    private func applySelectedPresetDefaults(forceModelReset: Bool = false) {
        let preset = selectedPreset
        remoteBaseURL = preset.defaultBaseURL
        if forceModelReset || remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !availableModels.contains(remoteModel) {
            remoteModel = preset.suggestedModels.first ?? remoteModel
        }
        discoveredModels = []
        providerAPIKey = ""
        hasStoredAPIKey = CredentialManager.retrieve(key: providerCredentialKey) != nil
            || (preset.id == "openrouter" && CredentialManager.retrieve(key: openRouterKeychainKey) != nil)
        persistRemoteDefaults()
    }

    private func saveAPIKey() {
        let trimmed = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try CredentialManager.store(key: providerCredentialKey, value: trimmed)
            if selectedPreset.id == "openrouter" {
                try CredentialManager.store(key: openRouterKeychainKey, value: trimmed)
            }
            hasStoredAPIKey = true
            connectionStatus = "\(selectedPreset.displayName) key stored securely in Keychain."
            persistRemoteDefaults()
            providerAPIKey = ""
        } catch {
            connectionStatus = error.localizedDescription
        }
    }

    private func persistRemoteDefaults() {
        commandSender?.sendCommand(name: "config.patch", payload: ["key": "llm.remote_provider_preset", "value": remoteProviderPreset])
        commandSender?.sendCommand(name: "config.patch", payload: ["key": "llm.remote_base_url", "value": remoteBaseURL])
        commandSender?.sendCommand(name: "config.patch", payload: ["key": "llm.remote_model", "value": remoteModel])
    }

    @MainActor
    private func testRemoteConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }

        let apiKey = effectiveAPIKey
        do {
            let report = try await CoworkProviderConnectionTester.testConnection(
                providerKind: selectedPreset.providerKind,
                runtimeDescriptor: nil,
                baseURL: remoteBaseURL,
                apiKey: apiKey
            )
            discoveredModels = report.discoveredModels
            if !report.discoveredModels.contains(remoteModel), let first = report.discoveredModels.first {
                remoteModel = first
                persistRemoteDefaults()
            }
            connectionStatus = report.statusText
        } catch {
            connectionStatus = error.localizedDescription
        }
    }

    private var effectiveAPIKey: String? {
        let trimmed = providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let stored = CredentialManager.retrieve(key: providerCredentialKey) {
            return stored
        }
        if selectedPreset.id == "openrouter" {
            return CredentialManager.retrieve(key: openRouterKeychainKey)
        }
        return nil
    }
}
