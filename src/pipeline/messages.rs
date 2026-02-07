//! Message types passed between pipeline stages.

use std::time::Instant;

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
