import Foundation
import MLX
import MLXLMCommon
import MLXVLM

// Use MLXLMCommon's WiredSumPolicy (extends MLX's WiredMemoryPolicy)
typealias FaeWiredSumPolicy = MLXLMCommon.WiredSumPolicy

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

    /// The loaded operator LLM model ID (set after successful load).
    private(set) var loadedModelId: String?

    /// The recommended context size (tokens) for the loaded operator model.
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

    /// Keyword classifier for barge-in interrupt detection.
    /// Non-critical: if unavailable, barge-in falls back to acoustic-only decisions.
    private(set) var keywordClassifier: MLXKeywordClassifier?

    /// Semantic turn detector for adaptive endpointing.
    /// Non-critical: if unavailable, endpointing falls back to rule-based heuristics.
    private(set) var turnDetector: MLXTurnDetector?

    /// Post-VAD speech verifier — rejects music/noise segments that Silero misclassifies.
    /// Non-critical: if unavailable, segments pass through with spectral tilt filter only.
    private(set) var speechVerifier: MLXSpeechVerifier?

    /// Streaming ASR engine (Moonshine V2) — fast-path for partial transcripts.
    /// Non-critical: if unavailable, streaming falls back to growing-buffer Qwen3-ASR.
    private(set) var parakeetEngine: (any StreamingSTTEngine)?

    /// Whether the streaming ASR fast-path is available.
    var parakeetAvailable: Bool {
        parakeetEngine != nil
    }

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
        let bus = self.eventBus

        NSLog("ModelManager: loading VLM on-demand (%@) — download may be required", modelId)
        bus.send(.runtimeProgress(stage: "vlm_loading", progress: 0))

        try await engine.load(modelID: modelId) { progress in
            let fraction = progress.fractionCompleted
            let totalMB = progress.totalUnitCount / 1_000_000
            let completedMB = progress.completedUnitCount / 1_000_000
            bus.send(.runtimeProgress(stage: "vlm_downloading", progress: fraction))
            if fraction < 1.0 {
                NSLog("ModelManager: downloading VLM %lld/%lld MB (%.0f%%)", completedMB, totalMB, fraction * 100)
            }
        }

        bus.send(.runtimeProgress(stage: "vlm_loading", progress: 1.0))
        eventBus.send(.modelLoaded(engine: "vlm", modelId: modelId))
        self.vlmEngine = engine
        NSLog("ModelManager: VLM loaded on-demand (%@)", modelId)
        return engine
    }

    /// Unload the VLM engine to reclaim RAM.
    ///
    /// When using a shared multimodal container, this only drops the VLM reference —
    /// the container stays alive via the LLM engine.
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
        llm: any LLMEngine,
        tts: any TTSEngine,
        speaker: CoreMLSpeakerEncoder? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil,
        config: FaeConfig
    ) async throws {
        let (modelId, recommendedContext) = FaeConfig.recommendedModel(preset: config.llm.voiceModelPreset)
        let effectiveContext = config.llm.contextSizeTokens > 0
            ? min(recommendedContext, config.llm.contextSizeTokens)
            : recommendedContext
        self.recommendedContextSize = effectiveContext
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
        let isMultimodal = FaeConfig.isMultimodalLLM(modelId: modelId)
        do {
            // Qwen3.5 MoE models are natively multimodal but vision inference through
            // the 35B MoE is impractically slow (~3 min per screenshot). Always load as
            // text-only LLM — vision uses the lightweight on-demand Qwen3-VL-4B instead.
            // See: https://github.com/ml-explore/mlx-swift-lm/issues/148
            if isMultimodal {
                NSLog("ModelManager: multimodal LLM detected — loading as text-only (vision via on-demand VLM for speed)")
            }
            // Use progress-aware load when available (MLXLLMEngine) to report
            // HuggingFace download progress to the UI instead of freezing.
            if let mlxLLM = llm as? MLXLLMEngine {
                let bus = self.eventBus
                try await mlxLLM.load(modelID: modelId) { progress in
                    let fraction = progress.fractionCompleted
                    let totalMB = progress.totalUnitCount / 1_000_000
                    let completedMB = progress.completedUnitCount / 1_000_000
                    // Map download progress to the LLM portion (0.35–0.55) of overall startup.
                    let overall = 0.35 + fraction * 0.20
                    bus.send(.runtimeProgress(stage: "downloading", progress: overall))
                    if fraction < 1.0 {
                        NSLog("ModelManager: downloading LLM %lld/%lld MB (%.0f%%)", completedMB, totalMB, fraction * 100)
                    }
                }
            } else {
                try await llm.load(modelID: modelId)
            }
            loadedModelId = modelId
            eventBus.send(.modelLoaded(engine: "llm", modelId: modelId))
            eventBus.send(.runtimeProgress(stage: "load_complete", progress: 0.6))
            eventBus.send(.runtimeProgress(stage: "llm", progress: 1.0))

            // Setup wired memory policy for GPU memory management.
            // This helps prevent OOM by coordinating memory limits across tasks.
            setupWiredMemoryPolicy()

            if let measurableLLM = llm as? MLXLLMEngine {
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
                if let measurement = try? await measurableLLM.measureMemory(
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
            } else {
                memoryMeasurement = nil
            }

            // Persist model ID for Settings UI
            FaeEnvironment.defaults.set(modelId, forKey: "fae.loaded_model_id")
            FaeEnvironment.defaults.set(true, forKey: "fae.runtime.operator_loaded")
        } catch {
            FaeEnvironment.defaults.set(false, forKey: "fae.runtime.operator_loaded")
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
                            await store.enroll(
                                label: "fae_self",
                                embedding: embedding,
                                role: .faeSelf,
                                displayName: "Fae"
                            )
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

        // Keyword classifier — non-critical, degrades gracefully to acoustic-only barge-in.
        if MLXKeywordClassifier.modelExists {
            let classifier = MLXKeywordClassifier()
            do {
                try await classifier.load(modelPath: MLXKeywordClassifier.defaultModelPath)
                self.keywordClassifier = classifier
                NSLog("ModelManager: keyword classifier loaded")
            } catch {
                NSLog("ModelManager: keyword classifier load failed (degraded — acoustic-only barge-in): %@",
                      error.localizedDescription)
            }
        } else {
            NSLog("ModelManager: keyword classifier not found at %@ — acoustic-only barge-in",
                  MLXKeywordClassifier.defaultModelPath.path)
        }

        // Streaming ASR — Moonshine V2 (true incremental decode, ~50ms first partial).
        // FAE_DISABLE_STREAMING_ASR=1 skips load (useful for test harnesses that inject text).
        let streamingASRDisabledByEnv = Self.isStreamingASRDisabledByEnvironment(
            ProcessInfo.processInfo.environment
        )
        if streamingASRDisabledByEnv {
            NSLog("ModelManager: streaming ASR skipped (FAE_DISABLE_STREAMING_ASR=1)")
        } else if config.streamingASR.enabled {
            await loadStreamingASRIfAvailable(config: config)
        } else {
            NSLog("ModelManager: streaming ASR disabled in config")
        }

        // Turn detector — non-critical, degrades gracefully to rule-based heuristics.
        if MLXTurnDetector.modelExists {
            let td = MLXTurnDetector()
            do {
                try await td.load(modelPath: MLXTurnDetector.defaultModelPath)
                self.turnDetector = td
                NSLog("ModelManager: turn detector loaded")
            } catch {
                NSLog("ModelManager: turn detector load failed (rule-based fallback): %@",
                      error.localizedDescription)
            }
        } else {
            NSLog("ModelManager: turn detector model not found — using rule-based endpointing")
        }

        // Speech verifier — non-critical, degrades gracefully to spectral tilt filter.
        if MLXSpeechVerifier.modelExists {
            let sv = MLXSpeechVerifier()
            do {
                try await sv.load(modelPath: MLXSpeechVerifier.defaultModelPath)
                self.speechVerifier = sv
                NSLog("ModelManager: speech verifier loaded")
            } catch {
                NSLog("ModelManager: speech verifier load failed (spectral tilt fallback): %@",
                      error.localizedDescription)
            }
        } else {
            NSLog("ModelManager: speech verifier model not found — using spectral tilt filter only")
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
        FaeEnvironment.defaults.set(source, forKey: "fae.tts.runtime_voice_source")
        FaeEnvironment.defaults.set(lockApplied, forKey: "fae.tts.runtime_voice_lock_applied")
        FaeEnvironment.defaults.set(Date().timeIntervalSince1970, forKey: "fae.tts.runtime_voice_status_ts")
    }

    // MARK: - Streaming ASR (Moonshine V2)

    /// Load the Moonshine V2 streaming ASR engine.
    ///
    /// Non-fatal: if loading fails, the pipeline falls back to growing-buffer
    /// Qwen3-ASR for streaming partials.  Auto-downloads from HuggingFace
    /// on first use (~300MB for tiny variant).
    private func loadStreamingASRIfAvailable(config: FaeConfig) async {
        let engine = MoonshineStreamingEngine(modelId: config.streamingASR.modelId)

        eventBus.send(.runtimeProgress(stage: "streaming_asr", progress: 0))
        do {
            try await engine.load()
            self.parakeetEngine = engine
            eventBus.send(.modelLoaded(engine: "streaming_asr", modelId: config.streamingASR.modelId))
            eventBus.send(.runtimeProgress(stage: "streaming_asr", progress: 1.0))
            NSLog("ModelManager: Moonshine streaming ASR loaded (%@)", config.streamingASR.modelId)
        } catch {
            NSLog(
                "ModelManager: Moonshine streaming ASR load failed (degraded — growing-buffer fallback): %@",
                error.localizedDescription
            )
            eventBus.send(.runtimeProgress(stage: "streaming_asr_failed", progress: 1.0))
        }
    }

    /// Testable check for the `FAE_DISABLE_STREAMING_ASR` env var.
    static func isStreamingASRDisabledByEnvironment(_ env: [String: String]) -> Bool {
        env["FAE_DISABLE_STREAMING_ASR"] == "1"
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
        FaeEnvironment.defaults.set(estimatedKVBytes, forKey: "fae.estimated_kv_bytes")
        FaeEnvironment.defaults.set(recommendedContextSize, forKey: "fae.recommended_context_size")
    }
}
