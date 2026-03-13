import SwiftUI

/// Models & voice settings tab: model selection, voice customization, prosody controls.
struct SettingsModelsTab: View {
    var commandSender: HostCommandSender?

    @AppStorage("thinkingEnabled") private var thinkingEnabled: Bool = false
    @AppStorage("thinkingLevel") private var thinkingLevel: String = FaeThinkingLevel.fast.rawValue
    @AppStorage("visionEnabled") private var visionEnabled: Bool = false
    @AppStorage("visionModelPreset") private var visionModelPreset: String = "auto"
    @AppStorage("voiceModelPreset") private var voiceModelPreset: String = "auto"
    @AppStorage("voiceIdentityEnabled") private var voiceIdentityEnabled: Bool = false
    @AppStorage("voiceIdentityMode") private var voiceIdentityMode: String = "assist"
    @AppStorage("voiceIdentityApprovalRequiresMatch") private var voiceIdentityApprovalRequiresMatch: Bool = false
    @AppStorage("voiceSpeed") private var voiceSpeed: Double = 1.1
    @AppStorage("ttsVoiceIdentityLock") private var voiceIdentityLock: Bool = true
    @AppStorage("ttsVoice") private var selectedVoice: String = "fae"
    @State private var previewingVoice: String? = nil
    @State private var hydratingFromConfig: Bool = false
    @State private var hasLoadedConfig: Bool = false
    @State private var showRestartNotice: Bool = false
    @State private var customVoiceSource: String = "Default (fae.wav)"
    @State private var customReferenceText: String = ""
    @State private var runtimeVoiceSource: String = "unknown"
    @State private var runtimeVoiceLockApplied: Bool = false
    @State private var showFilePicker: Bool = false

    private let voiceModelOptions = LocalModelCatalog.voiceOptions

    private let voiceIdentityModes: [(label: String, value: String, description: String)] = [
        ("Assist (Recommended)", "assist", "Uses speaker matching but still allows direct-address fallback for regular conversation."),
        ("Enforce", "enforce", "Only accepts the enrolled speaker for gated voice interaction.")
    ]

    private let visionModelOptions = LocalModelCatalog.visionOptions

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

    private struct KokoroVoiceOption: Identifiable {
        let id: String
        let label: String
        let accent: String
        let gender: String
    }

    private let kokoroVoices: [KokoroVoiceOption] = [
        KokoroVoiceOption(id: "fae",        label: "Fae",     accent: "Scottish",         gender: "Female"),
        KokoroVoiceOption(id: "af_heart",   label: "Heart",   accent: "American",         gender: "Female"),
        KokoroVoiceOption(id: "af_bella",   label: "Bella",   accent: "American",         gender: "Female"),
        KokoroVoiceOption(id: "af_aoede",   label: "Aoede",   accent: "American",         gender: "Female"),
        KokoroVoiceOption(id: "af_nicole",  label: "Nicole",  accent: "American",         gender: "Female"),
        KokoroVoiceOption(id: "af_sky",     label: "Sky",     accent: "American",         gender: "Female"),
        KokoroVoiceOption(id: "bf_emma",    label: "Emma",    accent: "British",          gender: "Female"),
        KokoroVoiceOption(id: "bf_isabella",label: "Isabella",accent: "British",          gender: "Female"),
        KokoroVoiceOption(id: "am_adam",    label: "Adam",    accent: "American",         gender: "Male"),
        KokoroVoiceOption(id: "am_echo",    label: "Echo",    accent: "American",         gender: "Male"),
        KokoroVoiceOption(id: "bm_daniel",  label: "Daniel",  accent: "British",          gender: "Male"),
    ]

    @ViewBuilder
    private var faeVoiceSection: some View {
        Section("Fae's Voice") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a voice for Fae. Tap the play button to preview.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                let columns = [
                    GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 10)
                ]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(kokoroVoices) { voice in
                        voiceCard(voice)
                    }
                }
            }
            .padding(.vertical, 4)

            if customVoiceSource != "Default (fae.wav)", selectedVoice == "fae" {
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
        }
    }

    @ViewBuilder
    private func voiceCard(_ voice: KokoroVoiceOption) -> some View {
        let isSelected = selectedVoice == voice.id
        let isPreviewing = previewingVoice == voice.id

        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: voice.gender == "Female" ? "person.crop.circle" : "person.crop.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(isSelected ? .white : .secondary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .offset(x: 4, y: -4)
                }
            }

            Text(voice.label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? .white : .primary)

            Text(voice.accent)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)

            Button {
                previewVoice(voice.id)
            } label: {
                Image(systemName: isPreviewing ? "waveform" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white : .accentColor)
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(isPreviewing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectVoice(voice.id)
        }
    }

    private func selectVoice(_ voiceID: String) {
        guard !hydratingFromConfig else { return }
        selectedVoice = voiceID
        let isFae = voiceID == "fae"
        voiceIdentityLock = isFae
        commandSender?.sendCommand(
            name: "config.patch",
            payload: ["key": "tts.voice_identity_lock", "value": isFae]
        )
        commandSender?.sendCommand(
            name: "config.patch",
            payload: ["key": "tts.voice", "value": voiceID]
        )
    }

    private func previewVoice(_ voiceID: String) {
        guard previewingVoice == nil else { return }
        previewingVoice = voiceID
        commandSender?.sendCommand(
            name: "tts.preview_voice",
            payload: ["voice": voiceID]
        )
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if previewingVoice == voiceID { previewingVoice = nil }
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

            if let cacheStatus = LocalModelCatalog.voiceCacheStatus(for: voiceModelPreset) {
                cacheStatusView(cacheStatus.text, cached: cacheStatus.cached)
            }

            if showRestartNotice {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Fae reloads the local pipeline automatically for model changes. First-time downloads can take a while.")
                        .font(.footnote)
                }
                .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Thinking level")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                Picker("Thinking level", selection: $thinkingLevel) {
                    ForEach(FaeThinkingLevel.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: thinkingLevel) {
                    guard !hydratingFromConfig,
                          let level = FaeThinkingLevel(rawValue: thinkingLevel)
                    else { return }
                    thinkingEnabled = level.enablesThinking
                    commandSender?.sendCommand(
                        name: "config.patch",
                        payload: ["key": "llm.thinking_level", "value": level.rawValue]
                    )
                }

                Text((FaeThinkingLevel(rawValue: thinkingLevel) ?? .fast).shortDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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

            if let cacheStatus = LocalModelCatalog.visionCacheStatus(for: visionModelPreset) {
                cacheStatusView(cacheStatus.text, cached: cacheStatus.cached)
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

    private func cacheStatusView(_ text: String, cached: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: cached ? "internaldrive.fill" : "arrow.down.circle")
                .foregroundStyle(cached ? .green : .orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
            payload: ["key": "llm"]
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
        if let llm = modelPayload["llm"] as? [String: Any] {
            if let preset = llm["voice_model_preset"] as? String,
               let canonicalPreset = normalizedVoiceModelPreset(preset),
               voiceModelOptions.contains(where: { $0.value == canonicalPreset })
            {
                voiceModelPreset = canonicalPreset
            }
            if let levelRaw = llm["thinking_level"] as? String,
               let level = FaeThinkingLevel(rawValue: levelRaw)
            {
                thinkingLevel = level.rawValue
                thinkingEnabled = level.enablesThinking
            } else if let thinking = llm["thinking_enabled"] as? Bool {
                thinkingEnabled = thinking
                thinkingLevel = thinking ? FaeThinkingLevel.balanced.rawValue : FaeThinkingLevel.fast.rawValue
            }
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
            if let voice = tts["voice"] as? String, !voice.isEmpty {
                selectedVoice = voice
            } else if let lock = tts["voice_identity_lock"] as? Bool, lock {
                selectedVoice = "fae"
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

    private func normalizedVoiceModelPreset(_ preset: String) -> String? {
        let canonical = FaeConfig.canonicalVoiceModelPreset(preset)
        return voiceModelOptions.contains(where: { $0.value == canonical }) ? canonical : nil
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
