//! Error types for the fae pipeline.

/// Top-level error type for the speech-to-speech system.
#[derive(Debug, thiserror::Error)]
pub enum SpeechError {
    /// Audio device or stream error.
    #[error("audio error: {0}")]
    Audio(String),

    /// Voice activity detection error.
    #[error("VAD error: {0}")]
    Vad(String),

    /// Speech-to-text transcription error.
    #[error("STT error: {0}")]
    Stt(String),

    /// Language model inference error.
    #[error("LLM error: {0}")]
    Llm(String),

    /// Text-to-speech synthesis error.
    #[error("TTS error: {0}")]
    Tts(String),

    /// Model download or loading error.
    #[error("model error: {0}")]
    Model(String),

    /// Configuration error.
    #[error("config error: {0}")]
    Config(String),

    /// Memory / identity storage error.
    #[error("memory error: {0}")]
    Memory(String),

    /// Pipeline coordination error.
    #[error("pipeline error: {0}")]
    Pipeline(String),

    /// I/O error.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// Channel send/receive error.
    #[error("channel error: {0}")]
    Channel(String),

    /// Self-update error (version check, download, apply).
    #[error("update error: {0}")]
    Update(String),

    /// Scheduler error (task execution, state persistence).
    #[error("scheduler error: {0}")]
    Scheduler(String),
}

/// Convenience result type.
pub type Result<T> = std::result::Result<T, SpeechError>;
