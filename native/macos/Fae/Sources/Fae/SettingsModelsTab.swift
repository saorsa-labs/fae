import SwiftUI

/// Models & voice settings tab: model selection, voice customization, prosody controls.
struct SettingsModelsTab: View {
    var commandSender: HostCommandSender?

    @AppStorage("thinkingEnabled") private var thinkingEnabled: Bool = false
    @AppStorage("visionEnabled") private var visionEnabled: Bool = false
    @AppStorage("visionModelPreset") private var visionModelPreset: String = "auto"
    @AppStorage("voiceModelPreset") private var voiceModelPreset: String = "auto"
    @AppStorage("voiceIdentityEnabled") private var voiceIdentityEnabled: Bool = false
    @AppStorage("voiceIdentityMode") private var voiceIdentityMode: String = "assist"
    @AppStorage("voiceIdentityApprovalRequiresMatch") private var voiceIdentityApprovalRequiresMatch: Bool = false
    @AppStorage("voiceSpeed") private var voiceSpeed: Double = 1.1
    @AppStorage("ttsVoiceIdentityLock") private var voiceIdentityLock: Bool = true
    @State private var hydratingFromConfig: Bool = false
    @State private var hasLoadedConfig: Bool = false
    @State private var showRestartNotice: Bool = false
    @State private var customVoiceSource: String = "Default (fae.wav)"
    @State private var customReferenceText: String = ""
    @State private var runtimeVoiceSource: String = "unknown"
    @State private var runtimeVoiceLockApplied: Bool = false
    @State private var showFilePicker: Bool = false

    private let voiceModelOptions: [(label: String, value: String, description: String)] = [
        ("Auto (Recommended)", "auto",
         "Selects the best Qwen3.5 model for your system RAM — from 35B-A3B on 64+ GB to 0.8B on 8 GB."),
        ("Qwen3.5-35B-A3B", "qwen3_5_35b_a3b",
         "MoE flagship (3B active). Best quality. Requires 64+ GB RAM."),
        ("Qwen3.5-27B", "qwen3_5_27b",
         "Dense 27B. Excellent quality. Requires 32+ GB RAM."),
        ("Qwen3.5-9B", "qwen3_5_9b",
         "Hybrid 9B. Great balance of quality and speed. Requires 24+ GB RAM."),
        ("Qwen3.5-4B", "qwen3_5_4b",
         "Hybrid 4B. Good quality, fast responses. Requires 16+ GB RAM."),
        ("Qwen3.5-2B", "qwen3_5_2b",
         "Compact 2B. Decent quality, very fast. Requires 12+ GB RAM."),
        ("Qwen3.5-0.8B", "qwen3_5_0_8b",
         "Tiny 0.8B. Basic quality, instant responses. Runs on 8+ GB RAM."),
    ]

    private let voiceIdentityModes: [(label: String, value: String, description: String)] = [
        ("Assist (Recommended)", "assist", "Uses speaker matching but still allows direct-address fallback for regular conversation."),
        ("Enforce", "enforce", "Only accepts the enrolled speaker for gated voice interaction.")
    ]

    private let visionModelOptions: [(label: String, value: String, description: String)] = [
        ("Auto", "auto", "Selects the best VLM for your system RAM. Requires 24+ GB."),
        ("Qwen3-VL-4B (8-bit)", "qwen3_vl_4b_8bit", "Higher quality. Requires 48+ GB RAM alongside LLM."),
        ("Qwen3-VL-4B (4-bit)", "qwen3_vl_4b_4bit", "Memory-efficient. Requires 24+ GB RAM alongside LLM."),
    ]

    var body: some View {
        Form {
            faeVoiceSection
            voiceProsodySection
            voiceIdentitySection
            voiceModelSection
            visionSection
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

            Toggle("Lock to canonical Fae voice (fae.wav)", isOn: $voiceIdentityLock)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .onChange(of: voiceIdentityLock) {
                    guard !hydratingFromConfig else { return }
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "tts.voice_identity_lock", "value": voiceIdentityLock]
                    )
                    showRestartNotice = true
                }

            HStack(spacing: 8) {
                Button("Choose Reference Audio") {
                    showFilePicker = true
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .disabled(voiceIdentityLock)

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
                .disabled(voiceIdentityLock)
            }

            if customVoiceSource != "Default (fae.wav)", !voiceIdentityLock {
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

            Text(runtimeVoiceStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("WAV must be mono PCM 16-bit, 2-8 seconds of clear speech. Restart to apply.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var voiceProsodySection: some View {
        Section("Voice Style") {
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
            Text("When on, Qwen3.5 reasons step by step before answering. Slower but more thorough for complex questions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var visionSection: some View {
        Section("Vision") {
            Toggle("Enable Vision", isOn: $visionEnabled)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .onChange(of: visionEnabled) {
                    guard !hydratingFromConfig else { return }
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "vision.enabled", "value": visionEnabled]
                    )
                    showRestartNotice = true
                }

            Picker("Vision Model", selection: $visionModelPreset) {
                ForEach(visionModelOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .disabled(!visionEnabled)
            .onChange(of: visionModelPreset) {
                guard !hydratingFromConfig else { return }
                commandSender?.sendCommand(
                    name: "config.patch",
                    payload: ["key": "vision.model_preset", "value": visionModelPreset]
                )
                showRestartNotice = true
            }

            if let current = visionModelOptions.first(where: { $0.value == visionModelPreset }) {
                Text(current.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Permission status badges.
            let permissions = PermissionStatusProvider.current()
            HStack(spacing: 12) {
                permissionBadge("Screen Recording", granted: permissions.screenRecording)
                permissionBadge("Camera", granted: permissions.camera)
                permissionBadge("Accessibility", granted: AccessibilityBridge.isAccessibilityEnabled())
            }
            .font(.system(size: 11, design: .rounded))

            Text("Vision loads an additional VLM model on demand. Requires 24+ GB RAM. Screen Recording and Camera permissions are requested when first used.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func permissionBadge(_ label: String, granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .secondary)
            Text(label)
                .foregroundStyle(granted ? .primary : .secondary)
        }
    }

    private var runtimeVoiceStatusText: String {
        let sourceLabel: String
        switch runtimeVoiceSource {
        case "locked_bundled_fae_wav":
            sourceLabel = "Canonical bundled fae.wav"
        case "custom_config_path":
            sourceLabel = "Custom voice (configured path)"
        case "custom_default_path":
            sourceLabel = "Custom voice (default custom_voice.wav)"
        case "bundled_fae_wav_fallback":
            sourceLabel = "Bundled fae.wav fallback"
        case "model_default":
            sourceLabel = "Model default voice"
        default:
            sourceLabel = "Unknown"
        }

        return "Runtime voice source: \(sourceLabel). Voice lock \(runtimeVoiceLockApplied ? "applied" : "not applied")."
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
        async let visionResponse = sender.queryCommand(
            name: "config.get",
            payload: ["key": "vision"]
        )

        let (voiceIdentity, voiceModel, ttsConfig, visionConfig) = await (
            voiceIdentityResponse,
            voiceModelResponse,
            ttsResponse,
            visionResponse
        )

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
            if let speed = tts["speed"] as? Double {
                voiceSpeed = speed
            }
            if let lock = tts["voice_identity_lock"] as? Bool {
                voiceIdentityLock = lock
            }
            if let source = tts["runtime_voice_source"] as? String, !source.isEmpty {
                runtimeVoiceSource = source
            }
            if let lockApplied = tts["runtime_voice_lock_applied"] as? Bool {
                runtimeVoiceLockApplied = lockApplied
            }
        }

        let visionPayload = unwrapPayload(visionConfig)
        if let vision = visionPayload["vision"] as? [String: Any] {
            if let enabled = vision["enabled"] as? Bool {
                visionEnabled = enabled
            }
            if let presetRaw = vision["model_preset"] as? String {
                let preset: String
                switch presetRaw {
                case "qwen3_vl_8b":
                    preset = "qwen3_vl_4b_8bit"
                case "qwen3_vl_4b":
                    preset = "qwen3_vl_4b_4bit"
                default:
                    preset = presetRaw
                }
                if visionModelOptions.contains(where: { $0.value == preset }) {
                    visionModelPreset = preset
                }
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
