import SwiftUI

/// Models & voice settings tab: model selection, voice customization, prosody controls.
struct SettingsModelsTab: View {
    var commandSender: HostCommandSender?

    @AppStorage("thinkingEnabled") private var thinkingEnabled: Bool = false
    @AppStorage("voiceModelPreset") private var voiceModelPreset: String = "auto"
    @AppStorage("voiceIdentityEnabled") private var voiceIdentityEnabled: Bool = false
    @AppStorage("voiceIdentityMode") private var voiceIdentityMode: String = "assist"
    @AppStorage("voiceIdentityApprovalRequiresMatch") private var voiceIdentityApprovalRequiresMatch: Bool = true
    @AppStorage("emotionalProsody") private var emotionalProsody: Bool = false
    @AppStorage("voiceWarmth") private var voiceWarmth: Double = 3.0
    @AppStorage("voiceSpeed") private var voiceSpeed: Double = 1.1
    @State private var hydratingFromConfig: Bool = false
    @State private var hasLoadedConfig: Bool = false
    @State private var showRestartNotice: Bool = false
    @State private var customVoiceSource: String = "Default (fae.wav)"
    @State private var customReferenceText: String = ""
    @State private var showFilePicker: Bool = false

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
            faeVoiceSection
            voiceProsodySection
            voiceIdentitySection
            voiceModelSection
            referenceSection
        }
        .formStyle(.grouped)
        .onAppear {
            guard !hasLoadedConfig else { return }
            hasLoadedConfig = true
            Task { @MainActor in
                await hydrateFromBackendConfig()
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.wav],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var faeVoiceSection: some View {
        Section("Fae's Voice") {
            HStack {
                Label("Current Voice", systemImage: "waveform")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Text(customVoiceSource)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Choose Reference Audio") {
                    showFilePicker = true
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))

                Button("Reset to Default") {
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "tts.custom_voice_path", "value": "nil"]
                    )
                    customVoiceSource = "Default (fae.wav)"
                    customReferenceText = ""
                    showRestartNotice = true
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }

            if customVoiceSource != "Default (fae.wav)" {
                TextField("Reference text (what's spoken in the WAV)", text: $customReferenceText)
                    .font(.system(size: 11, design: .rounded))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customReferenceText) {
                        guard !hydratingFromConfig else { return }
                        commandSender?.sendCommand(
                            name: "config.patch",
                            payload: ["key": "tts.custom_reference_text", "value": customReferenceText]
                        )
                    }
            }

            Text("WAV must be mono PCM 16-bit, 2-8 seconds of clear speech. Restart to apply.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var voiceProsodySection: some View {
        Section("Voice Style") {
            Toggle("Emotional Prosody", isOn: $emotionalProsody)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .onChange(of: emotionalProsody) {
                    guard !hydratingFromConfig else { return }
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "tts.emotional_prosody", "value": emotionalProsody]
                    )
                }

            Text(emotionalProsody
                 ? "Instruct mode: Fae adjusts tone to match content (warm, caring, excited). Uses a different voice timbre."
                 : "ICL mode: Fae speaks with her cloned voice — natural but emotionally neutral.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if emotionalProsody {
                HStack {
                    Text("Voice Warmth")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Slider(value: $voiceWarmth, in: 1...5, step: 0.5) {
                        Text("Warmth")
                    }
                    Text(String(format: "%.1f", voiceWarmth))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                .onChange(of: voiceWarmth) {
                    guard !hydratingFromConfig else { return }
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "tts.warmth", "value": Float(voiceWarmth)]
                    )
                }
            }

            HStack {
                Text("Speaking Speed")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Slider(value: $voiceSpeed, in: 0.8...1.4, step: 0.05) {
                    Text("Speed")
                }
                Text(String(format: "%.2fx", voiceSpeed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .onChange(of: voiceSpeed) {
                guard !hydratingFromConfig else { return }
                commandSender?.sendCommand(
                    name: "config.patch",
                    payload: ["key": "tts.speed", "value": Float(voiceSpeed)]
                )
            }
        }
    }

    @ViewBuilder
    private var voiceIdentitySection: some View {
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
    }

    @ViewBuilder
    private var voiceModelSection: some View {
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

            Toggle("Enable Thinking Mode", isOn: $thinkingEnabled)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .onChange(of: thinkingEnabled) {
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "llm.thinking_enabled", "value": thinkingEnabled]
                    )
                }
            Text("When on, Qwen3 reasons step by step before answering. Slower but more thorough for complex questions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var referenceSection: some View {
        Section("Reference") {
            Text("Read-only model/provider details have moved to Help > Model & Voice Reference.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Config Hydration

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
        async let ttsResponse = sender.queryCommand(
            name: "config.get",
            payload: ["key": "tts"]
        )

        let (voiceIdentity, voiceModel, ttsConfig) = await (voiceIdentityResponse, voiceModelResponse, ttsResponse)

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

        let ttsPayload = unwrapPayload(ttsConfig)
        if let tts = ttsPayload["tts"] as? [String: Any] {
            if let path = tts["custom_voice_path"] as? String, !path.isEmpty {
                customVoiceSource = URL(fileURLWithPath: path).lastPathComponent
            }
            if let refText = tts["custom_reference_text"] as? String {
                customReferenceText = refText
            }
            if let prosody = tts["emotional_prosody"] as? Bool {
                emotionalProsody = prosody
            }
            if let warmth = tts["warmth"] as? Double {
                voiceWarmth = warmth
            }
            if let speed = tts["speed"] as? Double {
                voiceSpeed = speed
            }
        }
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        // Copy to app support and set config.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        guard let dest = appSupport?.appendingPathComponent("fae/custom_voice.wav") else { return }

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }

            // Access security-scoped resource for sandboxed file access.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            try fm.copyItem(at: url, to: dest)

            customVoiceSource = url.lastPathComponent
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": "tts.custom_voice_path", "value": dest.path]
            )
            showRestartNotice = true
        } catch {
            NSLog("SettingsModelsTab: failed to import voice: %@", error.localizedDescription)
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
