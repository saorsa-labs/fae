import Foundation

// MARK: - Pipeline Mode

/// Operating mode of the voice pipeline.
enum PipelineMode: String, Sendable {
    /// Full pipeline: Capture -> VAD -> STT -> LLM -> TTS -> Playback.
    case conversation
    /// Capture -> VAD -> STT -> print (no LLM or TTS).
    case transcribeOnly
    /// Text injection -> LLM -> TTS -> Playback (no audio capture).
    case textOnly
    /// Capture -> VAD -> STT -> LLM (no TTS playback).
    case llmOnly
}

// MARK: - Degraded Mode

/// Degraded operating mode when individual engines fail to load.
/// (`noSTT` removed in S18 kill-list 3/3 — ASR happens inside the LLM turn.)
enum PipelineDegradedMode: String, Sendable {
    /// All engines loaded and operational.
    case full
    /// LLM engine unavailable.
    case noLLM
    /// TTS engine unavailable.
    case noTTS
    /// Pipeline cannot operate.
    case unavailable
}

// MARK: - Gate State

/// Whether the pipeline is accepting speech input.
enum GateState: Sendable {
    /// Discard all transcriptions.
    case idle
    /// Forward transcriptions to LLM.
    case active
}

// MARK: - Deterministic Turn Actions

/// Actions that can be resolved without the LLM (arithmetic, name recall).
enum DeterministicEasyTurnAction: Equatable {
    /// Simple arithmetic expression with a precomputed reply.
    case arithmetic(reply: String)
    /// User told Fae their name; reply includes acknowledgment.
    case rememberUserName(name: String, reply: String)
    /// User asked for their name; reply includes the recalled name.
    case recallUserName(reply: String)
}

// MARK: - Voice Attention Decision

/// Decision made by the fused voice attention filter after evaluating
/// gate state, wake word, speaker identity, and enrollment state.
enum VoiceAttentionDecision: Equatable {
    /// Pipeline is idle and no wake word detected; ignore silently.
    case ignoreWhileSleeping
    /// Wake word or sufficient speech detected; transition to active.
    case wakeAndContinue
    /// Direct address required but not detected; drop.
    case dropDirectAddress
    /// Short idle utterance without wake word; drop.
    case dropShortIdle
    /// Speaker role does not permit conversation; drop.
    case dropSpeaker
    /// Speech passes all gates; process normally.
    case allow
}

// MARK: - Streaming Speaker Similarity Decision

/// Decision from the streaming speaker similarity check.
enum StreamingSpeakerSimilarityDecision: Equatable {
    /// Similarity above accept threshold; allow processing.
    case allow
    /// Similarity below reject threshold; reject as unknown speaker.
    case reject
    /// Similarity in the ambiguous zone; defer to full-segment check.
    case undecided
}
