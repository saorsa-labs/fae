import Foundation

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

    /// The loaded LLM model ID (set after successful load).
    private(set) var loadedModelId: String?

    /// The recommended context size (tokens) for the loaded model, based on RAM tier.
    private(set) var recommendedContextSize: Int = 16_384

    /// Load all pipeline models (STT, LLM, TTS, Speaker) with progress events.
    ///
    /// Uses degraded-mode loading: if one engine fails, the others still load.
    /// The LLM is the critical engine — if it fails, the pipeline cannot respond.
    /// STT/TTS/Speaker failures result in degraded mode (text-only, no voice,
    /// or no voice identity).
    func loadAll(
        stt: MLXSTTEngine,
        llm: MLXLLMEngine,
        tts: MLXTTSEngine,
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
        } catch {
            NSLog("ModelManager: LLM load failed (critical): %@", error.localizedDescription)
            throw MLEngineError.loadFailed("LLM", error)
        }

        // TTS — degraded mode if it fails (no spoken output).
        eventBus.send(.runtimeProgress(stage: "tts", progress: 0.66))
        eventBus.send(.runtimeProgress(stage: "load_started", progress: 0.68))
        do {
            try await tts.load(modelID: config.tts.modelId)
            eventBus.send(.runtimeProgress(stage: "load_complete", progress: 0.85))
            eventBus.send(.runtimeProgress(stage: "tts", progress: 0.85))
        } catch {
            NSLog("ModelManager: TTS load failed (degraded — no voice output): %@", error.localizedDescription)
            failedEngines.append("TTS")
            eventBus.send(.runtimeProgress(stage: "load_complete", progress: 0.85))
        }

        // Load voice for CustomVoice TTS models. Priority:
        // 1. Config-specified custom voice path
        // 2. Default custom voice at ~/Library/Application Support/fae/custom_voice.wav
        // 3. Bundled fae.wav
        if failedEngines.contains("TTS") == false, config.tts.modelId.contains("CustomVoice") {
            var voiceLoaded = false

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
                        NSLog("ModelManager: Fae voice loaded from bundle")
                    } catch {
                        NSLog("ModelManager: voice load failed (using default): %@", error.localizedDescription)
                    }
                } else {
                    NSLog("ModelManager: fae.wav not found in bundle, using default voice")
                }
            }
        }

        // Speaker encoder — loads with mel-spectral fallback if no Core ML model.
        if let speaker, config.speaker.enabled {
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
}
