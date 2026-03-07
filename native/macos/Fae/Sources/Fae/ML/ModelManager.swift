import Foundation
import MLX
import MLXLMCommon

// Use MLXLMCommon's WiredSumPolicy (extends MLX's WiredMemoryPolicy)
typealias FaeWiredSumPolicy = MLXLMCommon.WiredSumPolicy

/// Errors for ML engine operations.
enum MLEngineError: LocalizedError {
    case notLoaded(String)
    case loadFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .notLoaded(let engine):
            return "\(engine) engine not loaded"
        case .loadFailed(let engine, let error):
            return "\(engine) engine failed to load: \(error.localizedDescription)"
        }
    }
}

/// Orchestrates loading of all ML models with progress reporting.
///
/// Replaces: model loading logic from `src/host/handler.rs`
actor ModelManager {
    private let eventBus: FaeEventBus

    init(eventBus: FaeEventBus) {
        self.eventBus = eventBus
    }

    func effectiveTTSModelID(for config: FaeConfig) -> String {
        let rawModelID = config.tts.modelId
        guard rawModelID.lowercased().hasPrefix("kokoro") else {
            return rawModelID
        }

        let voice: String
        if config.tts.voiceIdentityLock {
            voice = "fae"
        } else if !config.tts.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voice = config.tts.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            voice = "af_heart"
        }

        return "kokoro:\(voice):\(config.tts.speed)"
    }

    /// The loaded LLM model ID (set after successful load).
    private(set) var loadedModelId: String?

    /// The recommended context size (tokens) for the loaded model, based on RAM tier.
    private(set) var recommendedContextSize: Int = 16_384

    /// Memory measurement from the last model load (for diagnostics).
    private(set) var memoryMeasurement: WiredMemoryMeasurement?

    /// Wired memory policy for GPU memory management during inference.
    /// Helps prevent OOM by coordinating memory limits across concurrent tasks.
    private var wiredPolicy: FaeWiredSumPolicy?

    /// Conservative fallback for KV bytes/token when no measured value is available.
    private let fallbackKVBytesPerToken = 2048

    /// On-demand VLM engine — loaded only when vision tools are invoked.
    private var vlmEngine: MLXVLMEngine?

    /// Get a wired memory ticket for inference using measured or estimated budgets.
    func generationTicket(promptTokens: Int, expectedNewTokens: Int) -> WiredMemoryTicket? {
        guard let wiredPolicy else { return nil }

        let totalTokens = max(promptTokens + expectedNewTokens, 1)
        let kvBytesPerToken: Int = {
            guard let measurement = memoryMeasurement, measurement.tokenCount > 0 else {
                return fallbackKVBytesPerToken
            }
            return max(measurement.kvBytes / max(measurement.tokenCount, 1), 512)
        }()

        let weightBytes = memoryMeasurement?.weightBytes ?? 0
        let workspaceBytes = memoryMeasurement?.workspaceBytes ?? 256 * 1_024 * 1_024
        let estimatedKVBytes = totalTokens * kvBytesPerToken
        let ticketSize = weightBytes + workspaceBytes + estimatedKVBytes

        return wiredPolicy.ticket(size: ticketSize, kind: WiredMemoryTicketKind.active)
    }

    /// Get memory budget info for diagnostics/settings UI.
    var memoryBudget: (weights: Int, kv: Int, workspace: Int)? {
        guard let m = memoryMeasurement else { return nil }
        return (m.weightBytes, m.kvBytes, m.workspaceBytes)
    }

    /// Load the VLM engine on-demand if vision is enabled and sufficient RAM exists.
    ///
    /// Returns the engine if already loaded or successfully loaded. Returns nil if
    /// vision is disabled or insufficient RAM.
    func loadVLMIfNeeded(config: FaeConfig) async throws -> MLXVLMEngine? {
        if let engine = vlmEngine, await engine.isLoaded { return engine }
        guard config.vision.enabled else { return nil }
        guard let (modelId, _) = FaeConfig.recommendedVLMModel(preset: config.vision.modelPreset) else {
            NSLog("ModelManager: VLM not available — insufficient RAM for vision model")
            return nil
        }
        let engine = MLXVLMEngine()
        try await engine.load(modelID: modelId)
        eventBus.send(.modelLoaded(engine: "vlm", modelId: modelId))
        self.vlmEngine = engine
        NSLog("ModelManager: VLM loaded on-demand (%@)", modelId)
        return engine
    }

    /// Unload the VLM engine to reclaim RAM.
    func unloadVLM() {
        vlmEngine = nil
        NSLog("ModelManager: VLM unloaded")
    }

    /// Load all pipeline models (STT, LLM, TTS, Speaker) with progress events.
    ///
    /// Uses degraded-mode loading: if one engine fails, the others still load.
    /// The LLM is the critical engine — if it fails, the pipeline cannot respond.
    /// STT/TTS/Speaker failures result in degraded mode (text-only, no voice,
    /// or no voice identity).
    func loadAll(
        stt: MLXSTTEngine,
        llm: MLXLLMEngine,
        tts: any TTSEngine,
        speaker: CoreMLSpeakerEncoder? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil,
        config: FaeConfig
    ) async throws {
        let (modelId, recommendedContext) = FaeConfig.recommendedModel(preset: config.llm.voiceModelPreset)
        self.recommendedContextSize = recommendedContext
        var failedEngines: [String] = []

        // STT — degraded mode if it fails (text input only).
        eventBus.send(.runtimeProgress(stage: "stt", progress: 0))
        eventBus.send(.runtimeProgress(stage: "load_started", progress: 0.05))
        do {
            try await stt.load(modelID: config.stt.modelId)
            eventBus.send(.runtimeProgress(stage: "load_complete", progress: 0.3))
            eventBus.send(.runtimeProgress(stage: "stt", progress: 1.0))
        } catch {
            NSLog("ModelManager: STT load failed (degraded — text input only): %@", error.localizedDescription)
            failedEngines.append("STT")
            eventBus.send(.runtimeProgress(stage: "load_complete", progress: 0.3))
        }

        // LLM — critical engine, throw if it fails.
        eventBus.send(.runtimeProgress(stage: "llm", progress: 0.33))
        eventBus.send(.runtimeProgress(stage: "load_started", progress: 0.35))
        do {
            try await llm.load(modelID: modelId)
            loadedModelId = modelId
            eventBus.send(.modelLoaded(engine: "llm", modelId: modelId))
            eventBus.send(.runtimeProgress(stage: "load_complete", progress: 0.6))
            eventBus.send(.runtimeProgress(stage: "llm", progress: 1.0))

            // Setup wired memory policy for GPU memory management.
            // This helps prevent OOM by coordinating memory limits across tasks.
            setupWiredMemoryPolicy()

            let prefillStep = config.llm.prefillStepSize
                ?? FaeConfig.recommendedPrefillStepSize(modelId: modelId)
            let measurementParams = GenerateParameters(
                maxTokens: 1,
                maxKVSize: config.llm.maxKVCacheSize,
                kvBits: config.llm.kvQuantBits,
                kvGroupSize: config.llm.kvGroupSize,
                quantizedKVStart: config.llm.kvQuantStartTokens,
                temperature: 0.0,
                topP: 1.0,
                repetitionPenalty: nil,
                repetitionContextSize: 0,
                prefillStepSize: prefillStep
            )
            let measurementTokens = min(max(recommendedContext / 4, 512), 2_048)
            if let measurement = try? await llm.measureMemory(
                tokenCount: measurementTokens,
                parameters: measurementParams
            ) {
                memoryMeasurement = measurement
                NSLog(
                    "ModelManager: measured wired memory weights=%dMB kv=%dMB workspace=%dMB tokens=%d",
                    measurement.weightBytes / 1_000_000,
                    measurement.kvBytes / 1_000_000,
                    measurement.workspaceBytes / 1_000_000,
                    measurement.tokenCount
                )
            }

            // Persist model ID for Settings UI
            UserDefaults.standard.set(modelId, forKey: "fae.loaded_model_id")
        } catch {
            NSLog("ModelManager: LLM load failed (critical): %@", error.localizedDescription)
            throw MLEngineError.loadFailed("LLM", error)
        }

        // TTS — degraded mode if it fails (no spoken output).
        eventBus.send(.runtimeProgress(stage: "tts", progress: 0.66))
        eventBus.send(.runtimeProgress(stage: "load_started", progress: 0.68))
        let effectiveTTSModelID = effectiveTTSModelID(for: config)
        do {
            try await tts.load(modelID: effectiveTTSModelID)
            if effectiveTTSModelID.localizedCaseInsensitiveContains("12Hz") {
                NSLog("ModelManager: TTS streaming profile = 12Hz codec")
            } else {
                NSLog("ModelManager: TTS streaming profile = non-12Hz (%@)", effectiveTTSModelID)
            }
            eventBus.send(.runtimeProgress(stage: "load_complete", progress: 0.85))
            eventBus.send(.runtimeProgress(stage: "tts", progress: 0.85))
        } catch {
            NSLog("ModelManager: TTS load failed (degraded — no voice output): %@", error.localizedDescription)
            failedEngines.append("TTS")
            eventBus.send(.runtimeProgress(stage: "load_complete", progress: 0.85))
        }

        // Load voice for CustomVoice TTS models.
        // Canonical lock path (voiceIdentityLock=true):
        //   1) bundled fae.wav (required identity source)
        //   2) if unavailable/failed, fall back to model default voice
        // Unlock path (voiceIdentityLock=false):
        //   1) config custom voice path
        //   2) default custom voice path
        //   3) bundled fae.wav
        if failedEngines.contains("TTS") == false, config.tts.modelId.contains("CustomVoice") {
            var voiceLoaded = false
            let lockEnabled = config.tts.voiceIdentityLock

            if lockEnabled {
                if let voiceURL = Bundle.faeResources.url(forResource: "fae", withExtension: "wav") {
                    do {
                        try await tts.loadVoice(
                            referenceAudioURL: voiceURL,
                            referenceText: config.tts.referenceText
                        )
                        NSLog("ModelManager: canonical Fae voice lock active — bundled fae.wav loaded")
                        voiceLoaded = true
                        persistVoiceRuntimeStatus(
                            source: "locked_bundled_fae_wav",
                            lockApplied: true
                        )
                    } catch {
                        NSLog("ModelManager: canonical voice lock failed to load fae.wav: %@", error.localizedDescription)
                    }
                } else {
                    NSLog("ModelManager: canonical voice lock requested but fae.wav missing in bundle")
                }

                if !voiceLoaded {
                    persistVoiceRuntimeStatus(
                        source: "model_default",
                        lockApplied: true
                    )
                }
            } else {
                // Try config-specified custom voice.
                if let customPath = config.tts.customVoicePath {
                    let customURL = URL(fileURLWithPath: customPath)
                    if FileManager.default.fileExists(atPath: customPath) {
                        do {
                            try await tts.loadCustomVoice(
                                url: customURL,
                                referenceText: config.tts.customReferenceText
                            )
                            NSLog("ModelManager: custom voice loaded from config path")
                            voiceLoaded = true
                            persistVoiceRuntimeStatus(
                                source: "custom_config_path",
                                lockApplied: false
                            )
                        } catch {
                            NSLog("ModelManager: custom voice at config path failed: %@", error.localizedDescription)
                        }
                    }
                }

                // Try default custom voice location.
                if !voiceLoaded {
                    let appSupport = FileManager.default.urls(
                        for: .applicationSupportDirectory, in: .userDomainMask
                    ).first
                    let defaultCustom = appSupport?.appendingPathComponent("fae/custom_voice.wav")
                    if let url = defaultCustom, FileManager.default.fileExists(atPath: url.path) {
                        do {
                            try await tts.loadCustomVoice(
                                url: url,
                                referenceText: config.tts.customReferenceText ?? config.tts.referenceText
                            )
                            NSLog("ModelManager: custom voice loaded from default location")
                            voiceLoaded = true
                            persistVoiceRuntimeStatus(
                                source: "custom_default_path",
                                lockApplied: false
                            )
                        } catch {
                            NSLog("ModelManager: default custom voice failed: %@", error.localizedDescription)
                        }
                    }
                }

                // Fall back to bundled fae.wav.
                if !voiceLoaded {
                    if let voiceURL = Bundle.faeResources.url(
                        forResource: "fae", withExtension: "wav"
                    ) {
                        do {
                            try await tts.loadVoice(
                                referenceAudioURL: voiceURL,
                                referenceText: config.tts.referenceText
                            )
                            NSLog("ModelManager: Fae voice loaded from bundle (fallback)")
                            voiceLoaded = true
                            persistVoiceRuntimeStatus(
                                source: "bundled_fae_wav_fallback",
                                lockApplied: false
                            )
                        } catch {
                            NSLog("ModelManager: voice load failed (using default): %@", error.localizedDescription)
                        }
                    } else {
                        NSLog("ModelManager: fae.wav not found in bundle, using default voice")
                    }
                }

                if !voiceLoaded {
                    persistVoiceRuntimeStatus(
                        source: "model_default",
                        lockApplied: false
                    )
                }
            }
        }

        // Speaker encoder — always loaded when available (speaker recognition is always on).
        if let speaker {
            eventBus.send(.runtimeProgress(stage: "speaker", progress: 0.86))
            do {
                try await speaker.load()
                eventBus.send(.runtimeProgress(stage: "speaker", progress: 0.88))

                // Enroll Fae's self-voiceprint from fae.wav for echo rejection.
                // When the mic captures Fae's own voice through speakers, the speaker
                // encoder will match it against this profile and drop the segment.
                if let store = speakerProfileStore,
                   let voiceURL = Bundle.faeResources.url(forResource: "fae", withExtension: "wav")
                {
                    do {
                        let voiceData = try Data(contentsOf: voiceURL)
                        let samples = MLXTTSEngine.parseWAVToFloat32(voiceData)
                        if !samples.isEmpty {
                            let embedding = try await speaker.embed(audio: samples, sampleRate: 24_000)
                            await store.enroll(label: "fae_self", embedding: embedding)
                            NSLog("ModelManager: Fae self-voiceprint enrolled for echo rejection")
                        }
                    } catch {
                        NSLog("ModelManager: self-voiceprint enrollment failed: %@",
                              error.localizedDescription)
                    }
                }
            } catch {
                NSLog("ModelManager: Speaker encoder load failed (degraded — no voice identity): %@",
                      error.localizedDescription)
                failedEngines.append("Speaker")
            }
        }

        eventBus.send(.runtimeProgress(stage: "verify_started", progress: 0.9))
        eventBus.send(.runtimeProgress(stage: "verify_complete", progress: 0.98))
        eventBus.send(.runtimeProgress(stage: "ready", progress: 1.0))

        if failedEngines.isEmpty {
            NSLog("ModelManager: all models loaded")
        } else {
            NSLog("ModelManager: loaded in degraded mode — failed engines: %@", failedEngines.joined(separator: ", "))
        }
    }

    private func persistVoiceRuntimeStatus(source: String, lockApplied: Bool) {
        UserDefaults.standard.set(source, forKey: "fae.tts.runtime_voice_source")
        UserDefaults.standard.set(lockApplied, forKey: "fae.tts.runtime_voice_lock_applied")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "fae.tts.runtime_voice_status_ts")
    }

    // MARK: - Wired Memory Management (Phase 2)

    /// Setup wired memory policy for GPU memory management.
    ///
    /// Based on research into Ollama, mistral.rs, and LM Studio:
    /// - Ollama uses progressive allocation with backoff
    /// - mistral.rs uses Metal-aware memory capping
    /// - LM Studio uses unified memory awareness
    ///
    /// We use WiredSumPolicy which sums active ticket sizes and caps
    /// at GPU.maxRecommendedWorkingSetBytes() on Apple Silicon.
    private func setupWiredMemoryPolicy() {
        // WiredSumPolicy automatically caps to recommended working set
        // This prevents OOM by coordinating memory across concurrent tasks
        wiredPolicy = FaeWiredSumPolicy(cap: nil)

        // Estimate memory based on context size
        // Formula: KV cache ≈ 2 * num_layers * ctx_size * head_dim * num_heads * 2 (K+V) * dtype_size
        // For Qwen3.5, simplified: ~2KB per token for 4-bit KV, ~8KB per token for f16
        let kvBytesPerToken = 2048  // Conservative estimate with 4-bit KV
        let estimatedKVBytes = recommendedContextSize * kvBytesPerToken

        NSLog("ModelManager: Wired memory policy configured (estimated KV: %d MB for %d tokens)",
              estimatedKVBytes / 1_000_000, recommendedContextSize)

        // Persist for Settings UI
        UserDefaults.standard.set(estimatedKVBytes, forKey: "fae.estimated_kv_bytes")
        UserDefaults.standard.set(recommendedContextSize, forKey: "fae.recommended_context_size")
    }
}
