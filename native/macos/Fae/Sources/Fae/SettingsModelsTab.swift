import SwiftUI

/// Voice settings tab: model selection and voice identity controls.
struct SettingsModelsTab: View {
    var commandSender: HostCommandSender?

    @AppStorage("voiceModelPreset") private var voiceModelPreset: String = "auto"
    @AppStorage("voiceIdentityEnabled") private var voiceIdentityEnabled: Bool = false
    @AppStorage("voiceIdentityMode") private var voiceIdentityMode: String = "assist"
    @AppStorage("voiceIdentityApprovalRequiresMatch") private var voiceIdentityApprovalRequiresMatch: Bool = true
    @State private var hydratingFromConfig: Bool = false
    @State private var hasLoadedConfig: Bool = false
    @State private var showRestartNotice: Bool = false

    private let voiceModelOptions: [(label: String, value: String, description: String)] = [
        ("Auto (Recommended)", "auto", "Uses Qwen3-8B on 48+ GB, Qwen3-4B on 32+ GB, otherwise Qwen3-1.7B."),
        ("Qwen3-8B", "qwen3_8b", "Highest quality responses. Best for systems with 48+ GB RAM."),
        ("Qwen3-4B", "qwen3_4b", "Higher instruction quality, slightly slower first response."),
        ("Qwen3-1.7B", "qwen3_1_7b", "Good balance of quality and speed."),
        ("Qwen3-0.6B", "qwen3_0_6b", "Fastest response time, lower quality. Best for quick voice interactions.")
    ]

    private let voiceIdentityModes: [(label: String, value: String, description: String)] = [
        ("Assist (Recommended)", "assist", "Uses speaker matching but still allows direct-address fallback for regular conversation."),
        ("Enforce", "enforce", "Only accepts the enrolled speaker for gated voice interaction.")
    ]

    var body: some View {
        Form {
            Section("Voice Identity") {
                Toggle("Enable Voice Identity", isOn: $voiceIdentityEnabled)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .onChange(of: voiceIdentityEnabled) {
                        guard !hydratingFromConfig else { return }
                        commandSender?.sendCommand(
                            name: "config.patch",
                            payload: ["key": "voice_identity.enabled", "value": voiceIdentityEnabled]
                        )
                    }

                Picker("Mode", selection: $voiceIdentityMode) {
                    ForEach(voiceIdentityModes, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!voiceIdentityEnabled)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .onChange(of: voiceIdentityMode) {
                    guard !hydratingFromConfig else { return }
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "voice_identity.mode", "value": voiceIdentityMode]
                    )
                }

                Toggle("Require Voice Match for Approvals", isOn: $voiceIdentityApprovalRequiresMatch)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .disabled(!voiceIdentityEnabled)
                    .onChange(of: voiceIdentityApprovalRequiresMatch) {
                        guard !hydratingFromConfig else { return }
                        commandSender?.sendCommand(
                            name: "config.patch",
                            payload: [
                                "key": "voice_identity.approval_requires_match",
                                "value": voiceIdentityApprovalRequiresMatch,
                            ]
                        )
                    }

                if let currentMode = voiceIdentityModes.first(where: { $0.value == voiceIdentityMode }) {
                    Text(currentMode.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Voice identity is off by default and can be enrolled during onboarding.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Voice Model") {
                Picker("Voice Model", selection: $voiceModelPreset) {
                    ForEach(voiceModelOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .onChange(of: voiceModelPreset) {
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "llm.voice_model_preset", "value": voiceModelPreset]
                    )
                    if !hydratingFromConfig {
                        showRestartNotice = true
                    }
                }

                if let current = voiceModelOptions.first(where: { $0.value == voiceModelPreset }) {
                    Text(current.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if showRestartNotice {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Restart Fae for this change to take effect.")
                            .font(.footnote)
                    }
                    .foregroundStyle(.orange)
                }
            }

            Section("Reference") {
                Text("Read-only model/provider details have moved to Help > Model & Voice Reference.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !hasLoadedConfig else { return }
            hasLoadedConfig = true
            Task { @MainActor in
                await hydrateFromBackendConfig()
            }
        }
    }

    @MainActor
    private func hydrateFromBackendConfig() async {
        guard let sender = commandSender as? FaeCore else { return }

        async let voiceIdentityResponse = sender.queryCommand(
            name: "config.get",
            payload: ["key": "voice_identity"]
        )
        async let voiceModelResponse = sender.queryCommand(
            name: "config.get",
            payload: ["key": "llm.voice_model_preset"]
        )

        let (voiceIdentity, voiceModel) = await (voiceIdentityResponse, voiceModelResponse)

        hydratingFromConfig = true
        defer { hydratingFromConfig = false }

        let voicePayload = unwrapPayload(voiceIdentity)
        if let identity = voicePayload["voice_identity"] as? [String: Any] {
            if let enabled = identity["enabled"] as? Bool {
                voiceIdentityEnabled = enabled
            }
            if let mode = identity["mode"] as? String,
               voiceIdentityModes.contains(where: { $0.value == mode })
            {
                voiceIdentityMode = mode
            }
            if let requireMatch = identity["approval_requires_match"] as? Bool {
                voiceIdentityApprovalRequiresMatch = requireMatch
            }
        }

        let modelPayload = unwrapPayload(voiceModel)
        if let llm = modelPayload["llm"] as? [String: Any],
           let preset = llm["voice_model_preset"] as? String,
           voiceModelOptions.contains(where: { $0.value == preset })
        {
            voiceModelPreset = preset
        }
    }

    private func unwrapPayload(_ response: [String: Any]?) -> [String: Any] {
        guard let response else { return [:] }
        if let payload = response["payload"] as? [String: Any] {
            return payload
        }
        return response
    }
}
