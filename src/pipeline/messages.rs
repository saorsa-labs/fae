//! Message types passed between pipeline stages.

use std::time::Instant;

/// Control events emitted by stages to coordinate interruption and UI state.
#[derive(Debug, Clone)]
pub enum ControlEvent {
    /// VAD detected the start of user speech (barge-in signal).
    UserSpeechStart {
        /// Timestamp for the chunk that triggered speech start.
        captured_at: Instant,
        /// RMS energy of the triggering chunk.
        rms: f32,
    },
    /// Assistant playback started (first non-empty audio queued).
    AssistantSpeechStart,
    /// Assistant playback ended (response completed).
    AssistantSpeechEnd {
        /// Whether playback ended due to interruption.
        interrupted: bool,
    },
    /// MFCC+DTW wake word spotter detected the keyword in raw audio.
    WakewordDetected,
}

/// A chunk of raw audio samples from the microphone.
#[derive(Debug, Clone)]
pub struct AudioChunk {
    /// Interleaved f32 samples, mono, at the configured input sample rate.
    pub samples: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Timestamp when this chunk was captured.
    pub captured_at: Instant,
}

/// A complete speech segment detected by VAD, ready for STT.
#[derive(Debug, Clone)]
pub struct SpeechSegment {
    /// Concatenated audio samples for the entire utterance.
    pub samples: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// When the speech segment started.
    pub started_at: Instant,
}

/// A transcription result from the STT engine.
#[derive(Debug, Clone)]
pub struct Transcription {
    /// The transcribed text.
    pub text: String,
    /// Whether this is a final transcription (vs partial/streaming).
    pub is_final: bool,
    /// Optional voiceprint features for best-effort speaker matching.
    ///
    /// This is computed from the original audio and is intended for lightweight
    /// "respond mostly to the primary user" behavior.
    pub voiceprint: Option<Vec<f32>>,
    /// Time the original audio was captured.
    pub audio_captured_at: Instant,
    /// Time the transcription completed.
    pub transcribed_at: Instant,
}

/// A single token emitted by the LLM during streaming generation.
#[derive(Debug, Clone)]
pub struct LlmToken {
    /// The decoded text fragment.
    pub text: String,
    /// Whether this is the final token in the response.
    pub is_end: bool,
}

/// A sentence accumulated from LLM tokens, ready for TTS.
#[derive(Debug, Clone)]
pub struct SentenceChunk {
    /// Complete sentence text.
    pub text: String,
    /// Whether this is the last sentence in the response.
    pub is_final: bool,
}

/// A text message injected directly from the GUI, bypassing STT.
#[derive(Debug, Clone)]
pub struct TextInjection {
    /// The user's typed text.
    pub text: String,
    /// If `Some`, truncate LLM history to keep only this many entries
    /// (system prompt + N user/assistant pairs) before injecting.
    pub fork_at_keep_count: Option<usize>,
}

/// Synthesized audio from TTS, ready for playback.
#[derive(Debug, Clone)]
pub struct SynthesizedAudio {
    /// f32 audio samples.
    pub samples: Vec<f32>,
    /// Sample rate in Hz.
    pub sample_rate: u32,
    /// Whether this is the last chunk of the current response.
    pub is_final: bool,
}
