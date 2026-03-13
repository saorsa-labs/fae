import SwiftUI

/// Consolidated Models & Performance settings tab.
///
/// Sections:
/// - Models: Voice model selection, vision model
/// - Performance: KV cache optimization, prefill tuning
/// - Voice: Speaking speed, voice identity lock
struct SettingsModelsPerformanceTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case models = "Models"
        case performance = "Performance"
        case voice = "Voice"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .models: return "cpu"
            case .performance: return "gauge.with.dots.needle.67percent"
            case .voice: return "waveform"
            }
        }
    }

    var commandSender: HostCommandSender?

    @State private var section: Section = .models
    @State private var hydratingFromConfig: Bool = false
    @State private var hasLoadedConfig: Bool = false
    @State private var showRestartNotice: Bool = false

    // MARK: - Model Settings
    @AppStorage("voiceModelPreset") private var voiceModelPreset: String = "auto"
    @AppStorage("dualModelEnabled") private var dualModelEnabled: Bool = true
    @AppStorage("conciergeModelPreset") private var conciergeModelPreset: String = "auto"
    @AppStorage("thinkingEnabled") private var thinkingEnabled: Bool = false
    @AppStorage("thinkingLevel") private var thinkingLevel: String = FaeThinkingLevel.fast.rawValue
    @AppStorage("visionEnabled") private var visionEnabled: Bool = false
    @AppStorage("visionModelPreset") private var visionModelPreset: String = "auto"

    // MARK: - Performance Settings
    @AppStorage("kvQuantBits") private var kvQuantBits: Int = 4
    @AppStorage("kvQuantEnabled") private var kvQuantEnabled: Bool = true
    @AppStorage("maxKVCacheSize") private var maxKVCacheSize: Int = 0  // 0 = unlimited
    @AppStorage("slidingWindowEnabled") private var slidingWindowEnabled: Bool = false
    @AppStorage("kvQuantStartTokens") private var kvQuantStartTokens: Int = 512
    @AppStorage("repetitionContextSize") private var repetitionContextSize: Int = 64
    @AppStorage("prefillStepSize") private var prefillStepSize: Int = 0  // 0 = auto

    // MARK: - Voice Settings
    @AppStorage("voiceSpeed") private var voiceSpeed: Double = 1.1
    @AppStorage("ttsVoiceIdentityLock") private var voiceIdentityLock: Bool = true
    @AppStorage("bargeInEnabled") private var bargeInEnabled: Bool = true
    @AppStorage("acousticWakeEnabled") private var acousticWakeEnabled: Bool = true
    @AppStorage("acousticWakeThreshold") private var acousticWakeThreshold: Double = 0.82

    // MARK: - System Info
    @State private var systemRAM: String = "—"
    @State private var loadedModel: String = "—"
    @State private var estimatedKVSavings: String = "~4x"
    @State private var wakeTemplateCount: Int = 0

    private let voiceModelOptions = LocalModelCatalog.voiceOptions

    private let conciergeModelOptions: [(label: String, value: String, ram: String)] = [
        ("Auto (Legacy)", "auto", "32+ GB"),
    ]

    private let visionModelOptions = LocalModelCatalog.visionOptions

    var body: some View {
        VStack(spacing: 0) {
            // Section Picker
            sectionPicker
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 0) {
                    switch section {
                    case .models:
                        modelsSection
                    case .performance:
                        performanceSection
                    case .voice:
                        voiceSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadSystemInfo()
            if !hasLoadedConfig {
                hasLoadedConfig = true
                Task { @MainActor in
                    await hydrateFromBackendConfig()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .faePipelineState)) { _ in
            loadSystemInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .faeRuntimeState)) { _ in
            loadSystemInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .faeModelLoaded)) { _ in
            loadSystemInfo()
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
                            .fill(section == sec ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .foregroundColor(section == sec ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Models Section

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Local LLM stack
            SettingsCard(title: "Local LLM Stack", icon: "cpu", color: .blue) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable dual-model local pipeline", isOn: $dualModelEnabled)
                        .onChange(of: dualModelEnabled) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("llm.dual_model_enabled", value: dualModelEnabled)
                            showRestartNotice = true
                        }

                    Picker("Operator model", selection: $voiceModelPreset) {
                        ForEach(voiceModelOptions, id: \.value) { opt in
                            HStack {
                                Text(opt.label)
                                Spacer()
                                Text(opt.ram)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(opt.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: voiceModelPreset) {
                        guard !hydratingFromConfig else { return }
                        patchConfig("llm.voice_model_preset", value: voiceModelPreset)
                        showRestartNotice = true
                    }

                    if dualModelEnabled {
                        Picker("Concierge model", selection: $conciergeModelPreset) {
                            ForEach(conciergeModelOptions, id: \.value) { opt in
                                HStack {
                                    Text(opt.label)
                                    Spacer()
                                    Text(opt.ram)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(opt.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: conciergeModelPreset) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("llm.concierge_model_preset", value: conciergeModelPreset)
                            showRestartNotice = true
                        }
                    }

                    if let cacheStatus = LocalModelCatalog.voiceCacheStatus(for: voiceModelPreset) {
                        cacheStatusView(cacheStatus.text, cached: cacheStatus.cached)
                    }

                    Text(dualModelEnabled
                         ? "Single-model Qwen is the recommended path. Dual-model remains available as a legacy option."
                         : "Single-model mode uses the selected Qwen3.5 operator model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                            patchConfig("llm.thinking_level", value: level.rawValue)
                        }

                        Text((FaeThinkingLevel(rawValue: thinkingLevel) ?? .fast).shortDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Vision Model
            SettingsCard(title: "Vision", icon: "eye", color: .purple) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Vision", isOn: $visionEnabled)
                        .onChange(of: visionEnabled) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("vision.enabled", value: visionEnabled)
                            showRestartNotice = true
                        }

                    if visionEnabled {
                        Picker("Vision Model", selection: $visionModelPreset) {
                            ForEach(visionModelOptions, id: \.value) { opt in
                                Text(opt.label).tag(opt.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: visionModelPreset) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("vision.model_preset", value: visionModelPreset)
                            showRestartNotice = true
                        }

                        if let cacheStatus = LocalModelCatalog.visionCacheStatus(for: visionModelPreset) {
                            cacheStatusView(cacheStatus.text, cached: cacheStatus.cached)
                        }
                    }

                    Text("Vision loads an additional VLM on demand. Requires 24+ GB RAM.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Restart Notice
            if showRestartNotice {
                restartNoticeView
            }
        }
    }

    // MARK: - Performance Section

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            // System Status
            SettingsCard(title: "System Status", icon: "memorychip", color: .green) {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System RAM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(systemRAM)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                    }

                    Divider()
                        .frame(height: 40)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Active Stack")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(loadedModel)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }

                    Spacer()
                }
            }

            // KV Cache Optimization
            SettingsCard(title: "KV Cache Optimization", icon: "bolt.fill", color: .orange) {
                VStack(alignment: .leading, spacing: 16) {
                    // Enable/Disable Toggle
                    HStack {
                        Toggle("Enable KV Cache Quantization", isOn: $kvQuantEnabled)
                            .onChange(of: kvQuantEnabled) {
                                guard !hydratingFromConfig else { return }
                                patchConfig("llm.kv_quant_bits", value: kvQuantEnabled ? kvQuantBits : nil)
                            }

                        Spacer()

                        if kvQuantEnabled {
                            Text(estimatedKVSavings + " memory savings")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }

                    if kvQuantEnabled {
                        // Quantization Bits
                        HStack {
                            Text("Quantization")
                                .font(.subheadline)
                            Spacer()
                            Picker("", selection: $kvQuantBits) {
                                Text("4-bit (4x savings)").tag(4)
                                Text("8-bit (2x savings)").tag(8)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                            .onChange(of: kvQuantBits) {
                                guard !hydratingFromConfig else { return }
                                patchConfig("llm.kv_quant_bits", value: kvQuantBits)
                                updateEstimatedSavings()
                            }
                        }

                        // Start Threshold
                        HStack {
                            Text("Start After")
                                .font(.subheadline)
                            Spacer()
                            Picker("", selection: $kvQuantStartTokens) {
                                Text("256 tokens").tag(256)
                                Text("512 tokens").tag(512)
                                Text("1024 tokens").tag(1024)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 140)
                            .onChange(of: kvQuantStartTokens) {
                                guard !hydratingFromConfig else { return }
                                patchConfig("llm.kv_quant_start_tokens", value: kvQuantStartTokens)
                            }
                        }

                        Text("Initial context stays at full precision for better quality.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Sliding Window
            SettingsCard(title: "Context Window", icon: "arrow.left.arrow.right", color: .cyan) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Sliding Window", isOn: $slidingWindowEnabled)
                        .onChange(of: slidingWindowEnabled) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("llm.max_kv_cache_size", value: slidingWindowEnabled ? maxKVCacheSize : nil)
                        }

                    if slidingWindowEnabled {
                        HStack {
                            Text("Window Size")
                                .font(.subheadline)
                            Spacer()
                            Picker("", selection: $maxKVCacheSize) {
                                Text("8K tokens").tag(8192)
                                Text("16K tokens").tag(16384)
                                Text("32K tokens").tag(32768)
                                Text("64K tokens").tag(65536)
                                Text("128K tokens").tag(131072)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 140)
                            .onChange(of: maxKVCacheSize) {
                                guard !hydratingFromConfig else { return }
                                patchConfig("llm.max_kv_cache_size", value: maxKVCacheSize)
                            }
                        }
                    }

                    Text("Sliding window bounds memory for long conversations by rotating out old context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Advanced
            SettingsCard(title: "Advanced", icon: "slider.horizontal.3", color: .gray) {
                VStack(alignment: .leading, spacing: 12) {
                    // Repetition Context
                    HStack {
                        Text("Repetition Penalty Window")
                            .font(.subheadline)
                        Spacer()
                        Picker("", selection: $repetitionContextSize) {
                            Text("20 tokens").tag(20)
                            Text("64 tokens").tag(64)
                            Text("128 tokens").tag(128)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                        .onChange(of: repetitionContextSize) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("llm.repetition_context_size", value: repetitionContextSize)
                        }
                    }

                    // Prefill Step Size
                    HStack {
                        Text("Prefill Chunk Size")
                            .font(.subheadline)
                        Spacer()
                        Picker("", selection: $prefillStepSize) {
                            Text("Auto").tag(0)
                            Text("256").tag(256)
                            Text("512").tag(512)
                            Text("1024").tag(1024)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                        .onChange(of: prefillStepSize) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("llm.prefill_step_size", value: prefillStepSize == 0 ? nil : prefillStepSize)
                        }
                    }

                    Text("Larger repetition windows catch more patterns. Auto prefill adapts to model size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Voice Section

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Speaking Speed
            SettingsCard(title: "Speaking Speed", icon: "gauge.with.needle", color: .indigo) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Slider(value: $voiceSpeed, in: 0.8...1.4, step: 0.05)
                            .onChange(of: voiceSpeed) {
                                guard !hydratingFromConfig else { return }
                                patchConfig("tts.speed", value: Float(voiceSpeed))
                            }

                        Text(String(format: "%.2fx", voiceSpeed))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }

                    HStack(spacing: 0) {
                        Text("Slower")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Faster")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Voice Identity
            SettingsCard(title: "Voice Identity", icon: "person.wave.2", color: .pink) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Lock to Canonical Fae Voice", isOn: $voiceIdentityLock)
                        .onChange(of: voiceIdentityLock) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("tts.voice_identity_lock", value: voiceIdentityLock)
                            showRestartNotice = true
                        }

                    Text("When enabled, Fae always uses the bundled fae.wav voice reference.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Wake Word
            SettingsCard(title: "Wake Word", icon: "waveform.badge.mic", color: .orange) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Acoustic Wake Detection", isOn: $acousticWakeEnabled)
                        .onChange(of: acousticWakeEnabled) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("conversation.acoustic_wake_enabled", value: acousticWakeEnabled)
                        }

                    HStack {
                        Text("Trained wake samples")
                            .font(.subheadline)
                        Spacer()
                        Text("\(wakeTemplateCount)")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(wakeTemplateCount >= WakeWordAcousticDetector.minTemplateCount ? .green : (wakeTemplateCount == 1 ? .orange : .secondary))
                    }

                    if acousticWakeEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Match Threshold")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", acousticWakeThreshold))
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            Slider(value: $acousticWakeThreshold, in: 0.60...0.90, step: 0.01)
                                .onChange(of: acousticWakeThreshold) {
                                    guard !hydratingFromConfig else { return }
                                    patchConfig("conversation.acoustic_wake_threshold", value: acousticWakeThreshold)
                                }
                        }
                    }

                    Text(
                        wakeTemplateCount == 0
                            ? "Acoustic wake detection uses your own ‘Hey Fae’ samples. Ask Fae to tune your wake phrase if you want audio-level wakeups before STT."
                            : wakeTemplateCount == 1
                                ? "Fae has one wake sample and is still learning. Add at least one more clean sample so the detector can require agreement across multiple examples."
                                : "Uses your enrolled wake-phrase audio as a pre-STT wake detector with multi-sample agreement for fewer false positives. Text wake matching still stays on as a fallback."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // Barge-In
            SettingsCard(title: "Interaction", icon: "hand.raised", color: .teal) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Allow Barge-In (Interrupt Fae)", isOn: $bargeInEnabled)
                        .onChange(of: bargeInEnabled) {
                            guard !hydratingFromConfig else { return }
                            patchConfig("barge_in.enabled", value: bargeInEnabled)
                        }

                    Text("Speak while Fae is talking to interrupt her. Disable if echo causes issues.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Restart Notice
            if showRestartNotice {
                restartNoticeView
            }
        }
    }

    // MARK: - Restart Notice

    private var restartNoticeView: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart Required")
                    .font(.subheadline.weight(.semibold))
                Text("Fae reloads the local pipeline automatically for model changes. First-time downloads can take a while.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func loadSystemInfo() {
        let totalGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        systemRAM = "\(totalGB) GB"

        let config = FaeConfig.load()
        let plan = FaeConfig.recommendedLocalModelStack(config: config)
        let defaults = UserDefaults.standard
        loadedModel = LocalModelStatusFormatter.stackSummary(
            plan: plan,
            loadedOperatorModelId: defaults.string(forKey: "fae.loaded_model_id"),
            loadedConciergeModelId: defaults.string(forKey: "fae.loaded_concierge_model_id"),
            conciergeLoaded: defaults.bool(forKey: "fae.runtime.concierge_loaded"),
            conciergeRuntime: defaults.string(forKey: "fae.runtime.concierge_runtime"),
            conciergeWorkerLastError: defaults.string(forKey: "fae.runtime.concierge_worker_last_error")
        )

        updateEstimatedSavings()
    }

    private func updateEstimatedSavings() {
        estimatedKVSavings = kvQuantBits == 4 ? "~4x" : "~2x"
    }

    private func patchConfig(_ key: String, value: Any?) {
        if let v = value {
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": key, "value": v]
            )
        } else {
            // Send nil to clear the value
            commandSender?.sendCommand(
                name: "config.patch",
                payload: ["key": key, "value": NSNull()]
            )
        }
    }

    @ViewBuilder
    private func cacheStatusView(_ text: String, cached: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: cached ? "internaldrive.fill" : "arrow.down.circle")
                .foregroundStyle(cached ? .green : .orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func hydrateFromBackendConfig() async {
        guard let sender = commandSender as? FaeCore else { return }

        hydratingFromConfig = true
        defer { hydratingFromConfig = false }

        // Fetch LLM config
        if let response = await sender.queryCommand(name: "config.get", payload: ["key": "llm"]) {
            if let payload = response["payload"] as? [String: Any],
               let llm = payload["llm"] as? [String: Any]
            {
                if let preset = llm["voice_model_preset"] as? String {
                    voiceModelPreset = normalizedVoiceModelPreset(preset)
                }
                if let dualEnabled = llm["dual_model_enabled"] as? Bool {
                    dualModelEnabled = dualEnabled
                }
                if let conciergePreset = llm["concierge_model_preset"] as? String {
                    conciergeModelPreset = normalizedConciergeModelPreset(conciergePreset)
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
                if let kvBits = llm["kv_quant_bits"] as? Int {
                    kvQuantBits = kvBits
                    kvQuantEnabled = true
                } else {
                    kvQuantEnabled = false
                }
                if let maxKV = llm["max_kv_cache_size"] as? Int, maxKV > 0 {
                    maxKVCacheSize = maxKV
                    slidingWindowEnabled = true
                }
                if let kvStart = llm["kv_quant_start_tokens"] as? Int {
                    kvQuantStartTokens = kvStart
                }
                if let repCtx = llm["repetition_context_size"] as? Int {
                    repetitionContextSize = repCtx
                }
                if let prefill = llm["prefill_step_size"] as? Int {
                    prefillStepSize = prefill
                }
            }
        }

        // Fetch Vision config
        if let response = await sender.queryCommand(name: "config.get", payload: ["key": "vision"]) {
            if let payload = response["payload"] as? [String: Any],
               let vision = payload["vision"] as? [String: Any]
            {
                if let enabled = vision["enabled"] as? Bool {
                    visionEnabled = enabled
                }
                if let preset = vision["model_preset"] as? String {
                    visionModelPreset = preset
                }
            }
        }

        // Fetch TTS config
        if let response = await sender.queryCommand(name: "config.get", payload: ["key": "tts"]) {
            if let payload = response["payload"] as? [String: Any],
               let tts = payload["tts"] as? [String: Any]
            {
                if let speed = tts["speed"] as? Double {
                    voiceSpeed = speed
                }
                if let lock = tts["voice_identity_lock"] as? Bool {
                    voiceIdentityLock = lock
                }
            }
        }

        // Fetch conversation / wake config
        if let response = await sender.queryCommand(name: "config.get", payload: ["key": "conversation"]) {
            if let payload = response["payload"] as? [String: Any],
               let conversation = payload["conversation"] as? [String: Any]
            {
                if let enabled = conversation["acoustic_wake_enabled"] as? Bool {
                    acousticWakeEnabled = enabled
                }
                if let threshold = conversation["acoustic_wake_threshold"] as? Double {
                    acousticWakeThreshold = threshold
                }
                if let templateCount = conversation["wake_template_count"] as? Int {
                    wakeTemplateCount = templateCount
                }
            }
        }

        // Fetch barge-in config
        if let response = await sender.queryCommand(name: "config.get", payload: ["key": "barge_in"]) {
            if let payload = response["payload"] as? [String: Any],
               let bargeIn = payload["barge_in"] as? [String: Any]
            {
                if let enabled = bargeIn["enabled"] as? Bool {
                    bargeInEnabled = enabled
                }
            }
        }

        loadSystemInfo()
    }

    private func normalizedVoiceModelPreset(_ preset: String) -> String {
        let canonical = FaeConfig.canonicalVoiceModelPreset(preset)
        return voiceModelOptions.contains(where: { $0.value == canonical }) ? canonical : "auto"
    }

    private func normalizedConciergeModelPreset(_ preset: String) -> String {
        let canonical = FaeConfig.canonicalConciergeModelPreset(preset)
        return conciergeModelOptions.contains(where: { $0.value == canonical }) ? canonical : "auto"
    }
}

// MARK: - Settings Card Component

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24, height: 24)
                    .background(color.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
