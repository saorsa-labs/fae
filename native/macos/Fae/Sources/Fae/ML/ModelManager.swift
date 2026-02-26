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

    /// Load all pipeline models (STT, LLM, TTS) with progress events.
    func loadAll(
        stt: MLXSTTEngine,
        llm: MLXLLMEngine,
        tts: MLXTTSEngine,
        config: FaeConfig
    ) async throws {
        let (modelId, _) = FaeConfig.recommendedModel(preset: config.llm.voiceModelPreset)

        // STT
        eventBus.send(.runtimeProgress(stage: "stt", progress: 0))
        do {
            try await stt.load(modelID: config.stt.modelId)
            eventBus.send(.runtimeProgress(stage: "stt", progress: 1.0))
        } catch {
            NSLog("ModelManager: STT load failed: %@", error.localizedDescription)
            throw MLEngineError.loadFailed("STT", error)
        }

        // LLM
        eventBus.send(.runtimeProgress(stage: "llm", progress: 0.33))
        do {
            try await llm.load(modelID: modelId)
            eventBus.send(.runtimeProgress(stage: "llm", progress: 1.0))
        } catch {
            NSLog("ModelManager: LLM load failed: %@", error.localizedDescription)
            throw MLEngineError.loadFailed("LLM", error)
        }

        // TTS
        eventBus.send(.runtimeProgress(stage: "tts", progress: 0.66))
        do {
            try await tts.load()
            eventBus.send(.runtimeProgress(stage: "tts", progress: 1.0))
        } catch {
            NSLog("ModelManager: TTS load failed: %@", error.localizedDescription)
            throw MLEngineError.loadFailed("TTS", error)
        }

        eventBus.send(.runtimeProgress(stage: "ready", progress: 1.0))
        NSLog("ModelManager: all models loaded")
    }
}
