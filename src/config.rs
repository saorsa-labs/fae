//! Configuration types for the speech-to-speech pipeline.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Top-level configuration for the speech pipeline.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SpeechConfig {
    /// Audio capture/playback settings.
    pub audio: AudioConfig,
    /// Voice activity detection settings.
    pub vad: VadConfig,
    /// Speech-to-text settings.
    pub stt: SttConfig,
    /// Language model settings.
    pub llm: LlmConfig,
    /// Text-to-speech settings.
    pub tts: TtsConfig,
    /// Model management settings.
    pub models: ModelConfig,
    /// Conversation gate settings (wake word / stop phrase).
    pub conversation: ConversationConfig,
}

/// Audio I/O configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioConfig {
    /// Input sample rate in Hz.
    pub input_sample_rate: u32,
    /// Output sample rate in Hz.
    pub output_sample_rate: u32,
    /// Number of input channels (1 = mono).
    pub input_channels: u16,
    /// Audio buffer size in frames.
    pub buffer_size: u32,
    /// Input device name (None = system default).
    pub input_device: Option<String>,
    /// Output device name (None = system default).
    pub output_device: Option<String>,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            input_sample_rate: 16_000,
            output_sample_rate: 24_000,
            input_channels: 1,
            buffer_size: 512,
            input_device: None,
            output_device: None,
        }
    }
}

/// Voice activity detection configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VadConfig {
    /// Detection threshold (0.0 - 1.0).
    pub threshold: f32,
    /// Minimum silence duration in ms to end a speech segment.
    pub min_silence_duration_ms: u32,
    /// Padding added around detected speech in ms.
    pub speech_pad_ms: u32,
    /// Minimum speech duration in ms to consider valid.
    pub min_speech_duration_ms: u32,
}

impl Default for VadConfig {
    fn default() -> Self {
        Self {
            threshold: 0.5,
            min_silence_duration_ms: 700,
            speech_pad_ms: 30,
            min_speech_duration_ms: 500,
        }
    }
}

/// Speech-to-text configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SttConfig {
    /// HuggingFace model ID for the STT model.
    pub model_id: String,
    /// Chunk size in samples for streaming transcription.
    pub chunk_size: usize,
}

impl Default for SttConfig {
    fn default() -> Self {
        Self {
            // The ONNX-converted repo — the original NVIDIA repo only has .nemo format.
            model_id: "istupakov/parakeet-tdt-0.6b-v3-onnx".to_owned(),
            chunk_size: 2560, // 160ms at 16kHz
        }
    }
}

/// Which LLM inference backend to use.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LlmBackend {
    /// Local inference via mistral.rs (GGUF models with Metal GPU support).
    #[default]
    #[serde(alias = "candle")]
    Local,
    /// Remote inference via OpenAI-compatible API (Ollama, MLX, etc.).
    Api,
}

/// Language model configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmConfig {
    /// Which backend to use for inference.
    pub backend: LlmBackend,
    /// HuggingFace model repo ID containing the GGUF file (local backend only).
    pub model_id: String,
    /// GGUF filename within the model repo (local backend only).
    pub gguf_file: String,
    /// HuggingFace repo ID for the tokenizer (local backend only).
    /// Leave empty to use the tokenizer bundled with the GGUF repo.
    pub tokenizer_id: String,
    /// Base URL for the API server (API backend only).
    pub api_url: String,
    /// Model name to request from the API (API backend only).
    pub api_model: String,
    /// Maximum tokens to generate per response.
    pub max_tokens: usize,
    /// Sampling temperature (0.0 = greedy, higher = more random).
    pub temperature: f64,
    /// Top-p (nucleus) sampling threshold.
    pub top_p: f64,
    /// Repeat penalty for generated tokens.
    pub repeat_penalty: f32,
    /// System prompt for the conversation.
    pub system_prompt: String,
}

impl Default for LlmConfig {
    fn default() -> Self {
        Self {
            backend: LlmBackend::default(),
            // Qwen3-4B-Instruct-2507: instruction-tuned, no thinking mode, ungated.
            model_id: "unsloth/Qwen3-4B-Instruct-2507-GGUF".to_owned(),
            gguf_file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf".to_owned(),
            // GGUF repo doesn't include a tokenizer — pull from the original repo.
            tokenizer_id: "Qwen/Qwen3-4B-Instruct-2507".to_owned(),
            // Ollama default endpoint.
            api_url: "http://localhost:11434".to_owned(),
            api_model: "smollm3:3b".to_owned(),
            max_tokens: 80,
            temperature: 0.7,
            top_p: 0.9,
            repeat_penalty: 1.1,
            system_prompt: "You are Fae, a voice assistant. Rules:\n\
                - Maximum 1-2 sentences per response\n\
                - Be direct and concise, never ramble\n\
                - Never narrate your actions or thoughts\n\
                - Only ask follow-up questions if truly essential"
                .to_owned(),
        }
    }
}

/// Text-to-speech configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TtsConfig {
    /// Path to a reference voice WAV file for voice cloning.
    /// If empty, a default voice is downloaded automatically.
    pub voice_reference: String,
    /// ONNX model precision variant: "fp16", "q4f16", "fp32", "q4", "quantized".
    pub model_dtype: String,
    /// Maximum number of speech tokens to generate per utterance.
    pub max_new_tokens: usize,
    /// Repetition penalty for speech token generation (1.0 = no penalty).
    pub repetition_penalty: f32,
    /// Output sample rate in Hz.
    pub sample_rate: u32,
}

impl Default for TtsConfig {
    fn default() -> Self {
        Self {
            voice_reference: String::new(),
            model_dtype: "q4f16".to_owned(),
            max_new_tokens: 500,
            repetition_penalty: 1.2,
            sample_rate: 24_000,
        }
    }
}

/// Conversation gate configuration (wake word and stop phrase).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationConfig {
    /// Wake word to activate the assistant (case-insensitive).
    pub wake_word: String,
    /// Phrase to stop the assistant and return to idle (case-insensitive).
    pub stop_phrase: String,
    /// Whether the conversation gate is enabled.
    pub enabled: bool,
}

impl Default for ConversationConfig {
    fn default() -> Self {
        Self {
            wake_word: "fae".to_owned(),
            stop_phrase: "that will do".to_owned(),
            enabled: true,
        }
    }
}

/// Model management configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelConfig {
    /// Directory for caching downloaded models.
    pub cache_dir: PathBuf,
}

impl Default for ModelConfig {
    fn default() -> Self {
        Self {
            cache_dir: dirs_cache_dir(),
        }
    }
}

/// Returns the default model cache directory.
fn dirs_cache_dir() -> PathBuf {
    if let Some(cache) = std::env::var_os("XDG_CACHE_HOME") {
        PathBuf::from(cache).join("fae")
    } else if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".cache").join("fae")
    } else {
        PathBuf::from("/tmp/fae-cache")
    }
}

impl SpeechConfig {
    /// Load configuration from a TOML file, falling back to defaults for missing fields.
    ///
    /// # Errors
    ///
    /// Returns an error if the file cannot be read or parsed.
    pub fn from_file(path: &std::path::Path) -> crate::error::Result<Self> {
        let content = std::fs::read_to_string(path)?;
        toml::from_str(&content).map_err(|e| crate::error::SpeechError::Config(e.to_string()))
    }
}
