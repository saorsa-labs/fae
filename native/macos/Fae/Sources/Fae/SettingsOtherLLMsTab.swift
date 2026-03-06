import SwiftUI

struct SettingsOtherLLMsTab: View {
    var commandSender: HostCommandSender?

    @State private var remoteProviderPreset: String = "openrouter"
    @State private var remoteBaseURL: String = "https://openrouter.ai/api"
    @State private var remoteModel: String = "openai/gpt-4.1-mini"
    @State private var openRouterAPIKey: String = ""
    @State private var hasStoredAPIKey: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var connectionStatus: String?
    @State private var discoveredModels: [String] = []

    private let openRouterKeychainKey = "llm.openrouter.api_key"

    private var suggestedModels: [String] {
        CoworkBackendPresetCatalog.preset(id: "openrouter")?.suggestedModels
            ?? ["openai/gpt-4.1-mini", "anthropic/claude-sonnet-4", "google/gemini-2.5-pro"]
    }

    private var availableModels: [String] {
        var seen = Set<String>()
        return (discoveredModels + suggestedModels).filter { seen.insert($0).inserted }
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
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Other LLMs", systemImage: "network.badge.shield.half.filled")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("The easiest high-flexibility setup is OpenRouter. You get one API key, a wide model catalog, and Fae still keeps local-only workspace context on your Mac.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
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
            }
        }
    }

    private var setupSection: some View {
        SettingsCard(title: "OpenRouter setup", icon: "slider.horizontal.3", color: .blue) {
            VStack(alignment: .leading, spacing: 14) {
                Text("We store the API key securely in your macOS Keychain. Non-secret defaults like provider, base URL, and preferred model stay in Fae's config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remote provider")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text("OpenRouter")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(hasStoredAPIKey ? "Key stored securely" : "No key stored yet")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(hasStoredAPIKey ? .green : .secondary)
                }

                SecureField(hasStoredAPIKey ? "Replace OpenRouter API key" : "Paste your OpenRouter API key", text: $openRouterAPIKey)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button("Save API key") {
                        saveAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if hasStoredAPIKey {
                        Button("Clear stored key") {
                            CredentialManager.delete(key: openRouterKeychainKey)
                            hasStoredAPIKey = false
                            openRouterAPIKey = ""
                            connectionStatus = "OpenRouter key removed from Keychain."
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
                            .onChange(of: remoteBaseURL) {
                                persistRemoteDefaults()
                            }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Preferred model for new remote sessions")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Picker("Model", selection: $remoteModel) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: remoteModel) {
                            persistRemoteDefaults()
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button(isTestingConnection ? "Testing…" : "Test connection & load models") {
                        Task { await testOpenRouterConnection() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTestingConnection || !hasUsableAPIKey)

                    Button("Use OpenRouter defaults") {
                        remoteProviderPreset = "openrouter"
                        persistRemoteDefaults()
                        connectionStatus = "OpenRouter is now your preferred remote provider in Fae."
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
        hasStoredAPIKey || !openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadState() {
        let config = FaeConfig.load()
        remoteProviderPreset = config.llm.remoteProviderPreset
        remoteBaseURL = config.llm.remoteBaseURL
        remoteModel = config.llm.remoteModel
        hasStoredAPIKey = CredentialManager.retrieve(key: openRouterKeychainKey) != nil
    }

    private func saveAPIKey() {
        let trimmed = openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try CredentialManager.store(key: openRouterKeychainKey, value: trimmed)
            hasStoredAPIKey = true
            connectionStatus = "OpenRouter key stored securely in Keychain."
            persistRemoteDefaults()
            openRouterAPIKey = ""
        } catch {
            connectionStatus = error.localizedDescription
        }
    }

    private func persistRemoteDefaults() {
        commandSender?.sendCommand(name: "config.patch", payload: ["key": "llm.remote_provider_preset", "value": "openrouter"])
        commandSender?.sendCommand(name: "config.patch", payload: ["key": "llm.remote_base_url", "value": remoteBaseURL])
        commandSender?.sendCommand(name: "config.patch", payload: ["key": "llm.remote_model", "value": remoteModel])
    }

    @MainActor
    private func testOpenRouterConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }

        let apiKey = effectiveAPIKey
        do {
            let report = try await CoworkProviderConnectionTester.testConnection(
                providerKind: .openAICompatibleExternal,
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
        let trimmed = openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return CredentialManager.retrieve(key: openRouterKeychainKey)
    }
}
