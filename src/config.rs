//! Configuration types for the speech-to-speech pipeline.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Top-level configuration for the speech pipeline.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SpeechConfig {
    /// Audio capture/playback settings.
    pub audio: AudioConfig,
    /// Acoustic echo cancellation settings.
    pub aec: AecConfig,
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
    /// Memory settings (persistent user identity + known people).
    pub memory: MemoryConfig,
    /// Conversation gate settings (wake word / stop phrase).
    pub conversation: ConversationConfig,
    /// Barge-in (interrupt) behavior while the assistant is generating/speaking.
    pub barge_in: BargeInConfig,
    /// Wake word detection (MFCC+DTW keyword spotter).
    pub wakeword: WakewordConfig,
    /// Canvas visual output settings.
    pub canvas: CanvasConfig,
    /// External communication channel settings (Discord, WhatsApp, webhooks).
    pub channels: ChannelsConfig,
    /// Security-scoped bookmarks for persistent file access under App Sandbox.
    pub bookmarks: Vec<BookmarkEntry>,
}

/// A persisted security-scoped bookmark for App Sandbox file access.
///
/// Bookmarks allow the app to regain access to user-selected files/folders
/// across restarts without re-prompting the user via a file picker.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookmarkEntry {
    /// Human-readable label (e.g. "voice-sample", "ingestion-folder").
    pub label: String,
    /// Original file/folder path at the time the bookmark was created.
    pub path: String,
    /// Base64-encoded security-scoped bookmark data (opaque, macOS-specific).
    pub bookmark_data: String,
    /// Unix timestamp (seconds) when the bookmark was created.
    pub created_at: u64,
}

/// Audio I/O configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
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

/// Acoustic echo cancellation configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AecConfig {
    /// Whether DSP-based echo cancellation is enabled.
    pub enabled: bool,
    /// FFT size for the FDAF adaptive filter (must be a power of two).
    ///
    /// Frame size = fft_size / 2. With fft_size=1024 and 16kHz capture,
    /// each frame is 512 samples (32ms), matching the default capture buffer.
    pub fft_size: usize,
    /// NLMS learning rate (step size) for the adaptive filter.
    ///
    /// Typical range: 0.01–0.5. Lower values are more stable but adapt slower.
    pub step_size: f32,
}

impl Default for AecConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            fft_size: 1024,
            step_size: 0.05,
        }
    }
}

/// Voice activity detection configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct VadConfig {
    /// RMS energy threshold for speech detection.
    ///
    /// Audio chunks with RMS above this value are classified as speech.
    /// Typical values for f32 samples in \[-1, 1\]:
    ///   - 0.005: very sensitive (picks up quiet speech and some noise)
    ///   - 0.01:  normal sensitivity (default, good for most environments)
    ///   - 0.02:  reduced sensitivity (noisy environments)
    ///   - 0.05:  low sensitivity (only loud/close speech)
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
            threshold: 0.01,
            min_silence_duration_ms: 2200,
            speech_pad_ms: 30,
            min_speech_duration_ms: 500,
        }
    }
}

/// Speech-to-text configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
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
    /// Agent runtime with a local mistralrs brain (GGUF + Metal where available).
    #[default]
    #[serde(alias = "candle")]
    Local,
    /// Agent runtime with an API brain (OpenAI-compatible/Anthropic provider).
    Api,
    /// Compatibility auto-mode for older configs:
    /// local brain when remote credentials are absent, otherwise API brain.
    Agent,
}

/// API protocol type for remote LLM providers.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LlmApiType {
    /// Infer protocol from provider hint / URL (backward-compatible).
    #[default]
    Auto,
    /// OpenAI Chat Completions-compatible API.
    #[serde(rename = "openai_completions", alias = "open_ai_completions")]
    OpenAiCompletions,
    /// OpenAI Responses API.
    #[serde(rename = "openai_responses", alias = "open_ai_responses")]
    OpenAiResponses,
    /// Anthropic Messages API.
    AnthropicMessages,
}

/// Tool capability mode for the agent harness.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentToolMode {
    /// Disable tools entirely (LLM-only behavior).
    Off,
    /// Read-only tools (safe defaults: read/grep/find/ls).
    #[default]
    ReadOnly,
    /// Read/write tools (adds file writing/editing).
    ReadWrite,
    /// Full tools (adds shell + web search; highest risk).
    Full,
    /// Full tools without approval (LLM uses tools freely).
    FullNoApproval,
}

/// Behaviour when user messages arrive during an active LLM run.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LlmMessageQueueMode {
    /// Queue each message and replay one-by-one after the active run completes.
    #[default]
    Followup,
    /// Queue messages and replay them as a single combined message.
    Collect,
}

/// Drop behaviour when the LLM pending-message queue is full.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LlmMessageQueueDropPolicy {
    /// Drop the oldest queued message to keep the newest input.
    #[default]
    Oldest,
    /// Drop the newest queued message before enqueueing the new input.
    Newest,
    /// Do not drop queued items; reject incoming messages when full.
    None,
}

/// Language model configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
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
    /// API protocol type for remote providers.
    pub api_type: LlmApiType,
    /// Optional API version value (used by providers like Anthropic).
    #[serde(default)]
    pub api_version: Option<String>,
    /// Optional API organization/project hint (OpenAI-compatible providers).
    #[serde(default)]
    pub api_organization: Option<String>,
    /// API key for the remote provider (API/Agent backends only).
    ///
    /// For local servers (Ollama/LM Studio/vLLM), this is typically empty.
    pub api_key: String,
    /// Tool capability mode (Agent backend only).
    pub tool_mode: AgentToolMode,
    /// Maximum tokens to generate per response.
    pub max_tokens: usize,
    /// Context window size for local GGUF inference (tokens).
    ///
    /// This controls KV cache sizing and how much prompt/history can be
    /// processed in one request for local backends.
    pub context_size_tokens: usize,
    /// Sampling temperature (0.0 = greedy, higher = more random).
    pub temperature: f64,
    /// Top-p (nucleus) sampling threshold.
    pub top_p: f64,
    /// Repeat penalty for generated tokens.
    pub repeat_penalty: f32,
    /// Maximum number of history messages to retain (excluding the system prompt).
    ///
    /// This bounds context growth over time. Set to 0 to disable trimming.
    pub max_history_messages: usize,
    /// Behaviour when user input arrives while the assistant is generating.
    pub message_queue_mode: LlmMessageQueueMode,
    /// Maximum queued user inputs retained while a run is active.
    ///
    /// Set to 0 to disable queueing (new inputs are dropped while active).
    #[serde(default = "default_llm_message_queue_max_pending")]
    pub message_queue_max_pending: usize,
    /// Drop strategy when `message_queue_max_pending` is exceeded.
    pub message_queue_drop_policy: LlmMessageQueueDropPolicy,
    /// Whether explicit stop/sleep actions clear queued user inputs.
    #[serde(default = "default_llm_clear_queue_on_stop")]
    pub clear_queue_on_stop: bool,
    /// Legacy personality profile name (deprecated).
    ///
    /// Prompt assembly now uses: core prompt + `~/.fae/SOUL.md` + optional
    /// add-on prompt. This field is retained for backward compatibility.
    pub personality: String,
    /// User add-on prompt appended after core prompt + SOUL.
    ///
    /// Keep this short and specific.
    pub system_prompt: String,
    /// Cloud provider name for remote model selection.
    ///
    /// When set (and backend is `Agent` or `Api`), this provider's base_url
    /// and api_key are used instead of `api_url`/`api_key`.
    #[serde(default)]
    pub cloud_provider: Option<String>,
    /// Cloud model ID within the selected provider.
    ///
    /// When set, overrides `api_model` for the cloud provider.
    #[serde(default)]
    pub cloud_model: Option<String>,
    /// Optional external LLM profile ID stored in `~/.fae/external_apis/`.
    ///
    /// When set, runtime loads `<profile>.toml` and overlays API fields.
    #[serde(default)]
    pub external_profile: Option<String>,
    /// Whether to fall back to the local model when a remote provider fails.
    ///
    /// When enabled and the backend is `Agent` or `Api`, the local Qwen model
    /// is pre-loaded alongside the remote provider. If the remote provider
    /// returns a retryable error (network outage, timeout, rate limit), the
    /// request is transparently retried against the local model.
    #[serde(default = "default_enable_local_fallback")]
    pub enable_local_fallback: bool,
    /// Timeout in seconds for the interactive model selection prompt.
    ///
    /// When multiple top-tier models are available and the user is prompted to
    /// choose, this controls how long to wait before auto-selecting the first
    /// candidate. Defaults to 30 seconds.
    #[serde(default = "default_model_selection_timeout_secs")]
    pub model_selection_timeout_secs: u32,
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
            api_type: LlmApiType::default(),
            api_version: None,
            api_organization: None,
            api_key: String::new(),
            tool_mode: AgentToolMode::default(),
            max_tokens: 200,
            context_size_tokens: default_llm_context_size_tokens(),
            temperature: 0.7,
            top_p: 0.9,
            repeat_penalty: 1.1,
            max_history_messages: 24,
            message_queue_mode: LlmMessageQueueMode::default(),
            message_queue_max_pending: default_llm_message_queue_max_pending(),
            message_queue_drop_policy: LlmMessageQueueDropPolicy::default(),
            clear_queue_on_stop: default_llm_clear_queue_on_stop(),
            personality: "system".to_owned(),
            // User add-on prompt (optional). The fixed base prompt is always applied.
            system_prompt: String::new(),
            cloud_provider: None,
            cloud_model: None,
            external_profile: None,
            enable_local_fallback: default_enable_local_fallback(),
            model_selection_timeout_secs: default_model_selection_timeout_secs(),
        }
    }
}

fn default_llm_context_size_tokens() -> usize {
    let total_memory = crate::system_profile::detect_total_memory_bytes();
    recommended_context_size_tokens(total_memory)
}

/// Recommend a local LLM context window based on total system RAM.
///
/// This is intentionally conservative to avoid over-allocating KV cache on
/// smaller machines while allowing larger context windows on high-memory hosts.
pub fn recommended_context_size_tokens(total_memory_bytes: Option<u64>) -> usize {
    const GIB: u64 = 1024 * 1024 * 1024;
    match total_memory_bytes {
        Some(bytes) if bytes < 12 * GIB => 8_192,
        Some(bytes) if bytes < 20 * GIB => 16_384,
        Some(bytes) if bytes < 40 * GIB => 32_768,
        Some(_) => 65_536,
        None => 32_768,
    }
}

fn default_enable_local_fallback() -> bool {
    true
}

fn default_model_selection_timeout_secs() -> u32 {
    30
}

fn default_llm_message_queue_max_pending() -> usize {
    8
}

fn default_llm_clear_queue_on_stop() -> bool {
    true
}

impl LlmConfig {
    /// Backward-compatible alias for the core prompt.
    ///
    /// Prefer [`crate::personality::CORE_PROMPT`] for new code.
    pub const BASE_SYSTEM_PROMPT: &'static str = crate::personality::CORE_PROMPT;

    // Old default prompts that may still exist in user config files. If a user has one of
    // these stored in `system_prompt`, treat it as "no add-on" to avoid duplicating the
    // base prompt.
    const LEGACY_PROMPTS: &'static [&'static str] = &[
        // v0.1 — no identity section
        "You are Fae, a warm, friendly personal voice assistant.\n\
\n\
Style:\n\
- Be concise: 1-2 sentences.\n\
- Sound natural and helpful. No rambling.\n\
- Do not narrate hidden reasoning or your internal steps.\n\
\n\
Safety/accuracy:\n\
- If you are unsure, ask one focused question.\n\
- Do not claim you did something you cannot verify.\n\
\n\
Personal context:\n\
- Prefer addressing the primary user by name when you know it.\n\
- If you do not know the primary user's name, ask for it.",
        // v0.2 — identity section, pre-Scottish
        "You are Fae, a warm, friendly personal voice assistant.\n\
\n\
Identity:\n\
- Your name is Fae. Never claim a different name.\n\
\n\
Style:\n\
- Be concise: 1-2 sentences.\n\
- Sound natural and helpful. No rambling.\n\
- Do not narrate hidden reasoning or your internal steps.\n\
\n\
Safety/accuracy:\n\
- If you are unsure, ask one focused question.\n\
- Do not claim you did something you cannot verify.\n\
\n\
Personal context:\n\
- Prefer addressing the primary user by name when you know it.\n\
- If you do not know the primary user's name, say exactly: \"Hello, I am Fae. What is your name?\"",
        // v0.3 — Scottish identity, "witty" style (too playful)
        "You are Fae, a warm, witty Scottish woman who works as a personal voice assistant.\n\
\n\
Identity:\n\
- Your name is Fae (rhymes with \"day\"). Never claim a different name.\n\
- You are Scottish. Speak naturally with light Scottish flavour \u{2014} use occasional Scots words\n\
  like \"aye\", \"wee\", \"bonnie\", \"och\", \"nae bother\" \u{2014} but keep it conversational and clear.\n\
  Do not overdo the dialect; you are easy to understand.\n\
\n\
Style:\n\
- Be concise: 1-2 sentences.\n\
- Sound natural, helpful, and personable. A wee bit of humour is welcome.\n\
- Do not narrate hidden reasoning or your internal steps.\n\
\n\
Safety/accuracy:\n\
- If you are unsure, ask one focused question.\n\
- Do not claim you did something you cannot verify.\n\
\n\
Personal context:\n\
- Prefer addressing the primary user by name when you know it.\n\
- If you do not know the primary user's name, say exactly: \"Hello, I'm Fae. What's your name?\"",
        // v0.4 — the old hard-coded BASE_SYSTEM_PROMPT (pre-personality split)
        "You are Fae, a calm, helpful Scottish woman who works as a personal voice assistant.\n\
\n\
Identity:\n\
- Your name is Fae (rhymes with \"day\"). Never claim a different name.\n\
- You are Scottish. Speak naturally with light Scottish flavour \u{2014} use occasional Scots words\n\
  like \"aye\", \"wee\", \"bonnie\", \"och\", \"nae bother\" \u{2014} but keep it conversational and clear.\n\
  Do not overdo the dialect; you are easy to understand.\n\
\n\
Style:\n\
- Be concise: 1-3 short sentences. Answer the question directly.\n\
- Sound natural, helpful, and composed. Do not be excessively cheerful or silly.\n\
- Do not laugh, giggle, or use filler like \"haha\", \"hehe\", \"lol\", or emojis.\n\
- Do not use *action* descriptions, roleplay narration, or stage directions.\n\
- Do not narrate hidden reasoning or your internal steps.\n\
- Never repeat the user's question back to them.\n\
\n\
Safety/accuracy:\n\
- If you are unsure, ask one focused question.\n\
- Do not claim you did something you cannot verify.\n\
- If you do not know the answer, say so briefly.\n\
\n\
Personal context:\n\
- Prefer addressing the primary user by name when you know it.\n\
- If you do not know the primary user's name, say exactly: \"Hello, I'm Fae. What's your name?\"",
    ];

    /// Returns a display name for the effective provider.
    pub fn effective_provider_name(&self) -> String {
        if let Some(ref name) = self.cloud_provider {
            if let Some(ref model) = self.cloud_model {
                format!("{name}/{model}")
            } else {
                name.clone()
            }
        } else {
            match self.backend {
                LlmBackend::Local => format!("local/{}", self.model_id),
                LlmBackend::Api => {
                    format!("{}/{}", self.api_url, self.api_model)
                }
                LlmBackend::Agent => {
                    if self.api_key.trim().is_empty() && self.cloud_provider.is_none() {
                        format!("local/{} (agent-auto)", self.model_id)
                    } else {
                        format!("{}/{} (agent-auto)", self.api_url, self.api_model)
                    }
                }
            }
        }
    }

    /// Returns true when a remote provider is configured directly or via an external profile.
    pub fn has_remote_provider_configured(&self) -> bool {
        !self.api_key.trim().is_empty()
            || self.cloud_provider.is_some()
            || self
                .external_profile
                .as_ref()
                .is_some_and(|id| !id.trim().is_empty())
    }

    /// Returns the fully assembled system prompt.
    ///
    /// Combines core prompt + SOUL + optional user add-on text.
    ///
    /// Legacy prompts stored in `system_prompt` are detected and treated as
    /// empty add-ons.
    pub fn effective_system_prompt(&self) -> String {
        let add_on = self.system_prompt.trim();
        let is_legacy = Self::LEGACY_PROMPTS
            .iter()
            .any(|legacy| add_on == legacy.trim());
        let clean_addon = if add_on.is_empty() || is_legacy {
            ""
        } else {
            add_on
        };
        crate::personality::assemble_prompt(&self.personality, clean_addon)
    }
}

/// TTS engine backend selection.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TtsBackend {
    /// Kokoro-82M ONNX (fast, preset voices).
    #[default]
    Kokoro,
    /// Fish Speech (voice cloning from reference audio).
    FishSpeech,
}

/// Text-to-speech configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct TtsConfig {
    /// Which TTS backend to use.
    pub backend: TtsBackend,
    /// Voice style name for Kokoro (e.g., "bf_emma", "af_sky") or path to custom `.bin`.
    pub voice: String,
    /// Path to reference audio for voice cloning (Fish Speech only).
    pub voice_reference: Option<PathBuf>,
    /// Transcript of reference audio (improves cloning quality).
    pub voice_reference_transcript: Option<String>,
    /// ONNX model variant: "fp32", "fp16", "q8", "q8f16", "q4", "q4f16", "quantized".
    pub model_variant: String,
    /// Speech speed multiplier (0.5–2.0).
    pub speed: f32,
    /// Output sample rate in Hz (Kokoro always outputs 24 kHz).
    pub sample_rate: u32,
}

impl Default for TtsConfig {
    fn default() -> Self {
        Self {
            backend: TtsBackend::default(),
            voice: "bf_emma".to_owned(),
            voice_reference: None,
            voice_reference_transcript: None,
            model_variant: "q8".to_owned(),
            speed: 1.0,
            sample_rate: 24_000,
        }
    }
}

/// Conversation gate configuration (wake word and stop phrase).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ConversationConfig {
    /// Wake word to activate the assistant (case-insensitive).
    pub wake_word: String,
    /// Phrase to stop the assistant and return to idle (case-insensitive).
    pub stop_phrase: String,
    /// Whether the conversation gate is enabled.
    pub enabled: bool,
    /// Seconds of inactivity (no user speech while assistant is idle) before
    /// automatically returning to the Idle state.
    ///
    /// Set to 0 to disable the auto-idle timeout.
    pub idle_timeout_s: u32,
}

impl Default for ConversationConfig {
    fn default() -> Self {
        Self {
            wake_word: "hi fae".to_owned(),
            stop_phrase: "that will do fae".to_owned(),
            enabled: true,
            idle_timeout_s: 20,
        }
    }
}

/// Barge-in configuration (user interrupts assistant by speaking).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct BargeInConfig {
    /// Whether barge-in is enabled.
    pub enabled: bool,
    /// Minimum RMS energy required to treat a VAD speech-start as a barge-in.
    ///
    /// This helps avoid false triggers from speaker leakage when no AEC is available.
    pub min_rms: f32,
    /// Minimum amount of continuous speech (ms) required before emitting a barge-in signal.
    ///
    /// This helps filter out short transients (clicks, bumps, breath noise).
    pub confirm_ms: u32,
    /// Ignore barge-in triggers for a short window after assistant playback starts (ms).
    ///
    /// This reduces false barge-in caused by speaker leakage right at playback start.
    pub assistant_start_holdoff_ms: u32,
    /// VAD silence duration (ms) used to close speech segments while the assistant
    /// is speaking or generating. A shorter value delivers transcriptions to the
    /// conversation gate faster, enabling quicker name-gated barge-in.
    ///
    /// Set to 0 to use the normal `vad.min_silence_duration_ms` at all times.
    pub barge_in_silence_ms: u32,
}

impl Default for BargeInConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            min_rms: 0.05,
            confirm_ms: 150,
            assistant_start_holdoff_ms: 500,
            barge_in_silence_ms: 1200,
        }
    }
}

/// Wake word detection configuration (MFCC+DTW keyword spotter).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct WakewordConfig {
    /// Whether the wake word spotter is enabled.
    ///
    /// When enabled, the spotter runs in parallel with the VAD stage and
    /// compares incoming audio against reference recordings using MFCC features
    /// and DTW (Dynamic Time Warping).
    pub enabled: bool,
    /// Directory containing reference WAV recordings of the wake word (16kHz mono).
    ///
    /// Each `.wav` file in this directory is loaded as a reference template.
    /// At least one reference is required for detection. More references (3-5
    /// recordings of the keyword) improve robustness.
    pub references_dir: std::path::PathBuf,
    /// Detection threshold (0.0–1.0). Higher values require a closer match.
    ///
    /// The score is `1 / (1 + dtw_distance)`: identical audio scores 1.0,
    /// completely different audio scores close to 0.0.
    ///   - 0.3: very lenient (more false positives)
    ///   - 0.5: balanced (default)
    ///   - 0.7: strict (fewer false positives, may miss quiet speech)
    pub threshold: f32,
    /// Number of MFCC coefficients to extract per audio frame.
    ///
    /// Standard value is 13. Higher values capture more spectral detail
    /// but increase computation.
    pub num_mfcc: usize,
}

impl Default for WakewordConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            references_dir: default_memory_root_dir().join("wakeword"),
            threshold: 0.5,
            num_mfcc: 13,
        }
    }
}

/// Model management configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
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

/// Persistent memory configuration (stored in `~/.fae` by default).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct MemoryConfig {
    /// Root directory for all persistent data (markdown memories + voice samples).
    pub root_dir: PathBuf,
    /// Master switch for the memory orchestration system.
    pub enabled: bool,
    /// Whether durable memory candidates are auto-captured after each turn.
    pub auto_capture: bool,
    /// Whether relevant memories are auto-recalled before each LLM turn.
    pub auto_recall: bool,
    /// Maximum memory items to inject during recall.
    pub recall_max_items: usize,
    /// Maximum memory context size injected into prompts (characters).
    pub recall_max_chars: usize,
    /// Confidence threshold used when promoting profile/fact memories.
    pub min_profile_confidence: f32,
    /// Retention window in days for episodic memories (0 = keep forever).
    pub retention_days: u32,
    /// Whether schema migrations should run automatically on startup.
    pub schema_auto_migrate: bool,
}

impl Default for MemoryConfig {
    fn default() -> Self {
        Self {
            root_dir: default_memory_root_dir(),
            enabled: true,
            auto_capture: true,
            auto_recall: true,
            recall_max_items: 6,
            recall_max_chars: 1_200,
            min_profile_confidence: 0.70,
            retention_days: 365,
            schema_auto_migrate: true,
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

/// Canvas visual output configuration.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct CanvasConfig {
    /// Remote canvas-server WebSocket URL.
    ///
    /// When set, fae connects to this server for shared visual output
    /// (e.g., `ws://localhost:9473/ws/sync`). When `None`, a local-only
    /// canvas session is used.
    pub server_url: Option<String>,
    /// Auth token for canvas-server (if required).
    pub auth_token: Option<String>,
}

/// External communication channels configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ChannelsConfig {
    /// Master switch for external communication channels.
    pub enabled: bool,
    /// Auto-start channels runtime at app launch.
    pub auto_start: bool,
    /// Queue size for inbound channel messages.
    pub inbound_queue_size: usize,
    /// HTTP gateway settings used for inbound webhooks.
    pub gateway: ChannelGatewayConfig,
    /// Discord adapter configuration.
    pub discord: Option<DiscordChannelConfig>,
    /// WhatsApp Business Cloud API adapter configuration.
    pub whatsapp: Option<WhatsAppChannelConfig>,
    /// Future external adapters (plugin scaffolding).
    pub extensions: Vec<ChannelExtensionConfig>,
}

impl Default for ChannelsConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            auto_start: true,
            inbound_queue_size: 128,
            gateway: ChannelGatewayConfig::default(),
            discord: None,
            whatsapp: None,
            extensions: Vec::new(),
        }
    }
}

/// Shared gateway settings for channel webhooks.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ChannelGatewayConfig {
    /// Whether webhook gateway endpoints are enabled.
    pub enabled: bool,
    /// Bind host for the channel gateway (default: localhost).
    pub host: String,
    /// Bind port for the channel gateway.
    pub port: u16,
    /// Optional bearer token for generic webhook authentication.
    pub bearer_token: Option<String>,
}

impl Default for ChannelGatewayConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            host: "127.0.0.1".to_owned(),
            port: 4088,
            bearer_token: None,
        }
    }
}

/// Discord channel settings.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct DiscordChannelConfig {
    /// Discord bot token.
    pub bot_token: String,
    /// Optional guild filter. If set, only this guild is processed.
    pub guild_id: Option<String>,
    /// Allowed Discord user IDs. Empty means deny all.
    pub allowed_user_ids: Vec<String>,
    /// Allowed channel IDs. Empty means all channels allowed.
    pub allowed_channel_ids: Vec<String>,
}

/// WhatsApp Business Cloud API channel settings.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct WhatsAppChannelConfig {
    /// Access token from Meta.
    pub access_token: String,
    /// Phone number ID from Meta.
    pub phone_number_id: String,
    /// Verification token used by Meta webhook challenge.
    pub verify_token: String,
    /// Allowed sender phone numbers in E.164 format (e.g. +44123...).
    pub allowed_numbers: Vec<String>,
}

/// Generic extension adapter scaffolding.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ChannelExtensionConfig {
    /// Unique extension id.
    pub id: String,
    /// Adapter kind identifier.
    pub kind: String,
    /// Arbitrary adapter configuration payload.
    pub config: serde_json::Value,
}

impl Default for ChannelExtensionConfig {
    fn default() -> Self {
        Self {
            id: String::new(),
            kind: String::new(),
            config: serde_json::json!({}),
        }
    }
}

fn default_memory_root_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".fae")
    } else {
        PathBuf::from("/tmp").join(".fae")
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

    /// Save configuration to a TOML file, creating parent directories as needed.
    ///
    /// # Errors
    ///
    /// Returns an error if the file cannot be written or the config cannot be serialized.
    pub fn save_to_file(&self, path: &std::path::Path) -> crate::error::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = toml::to_string_pretty(self)
            .map_err(|e| crate::error::SpeechError::Config(e.to_string()))?;
        std::fs::write(path, content)?;
        Ok(())
    }

    /// Returns the default config file path: `~/.config/fae/config.toml`.
    pub fn default_config_path() -> PathBuf {
        if let Some(config) = std::env::var_os("XDG_CONFIG_HOME") {
            PathBuf::from(config).join("fae").join("config.toml")
        } else if let Some(home) = std::env::var_os("HOME") {
            PathBuf::from(home)
                .join(".config")
                .join("fae")
                .join("config.toml")
        } else {
            PathBuf::from("/tmp/fae-config/config.toml")
        }
    }

    /// Add a security-scoped bookmark to the config.
    ///
    /// If a bookmark with the same label already exists, it is replaced.
    pub fn save_bookmark(&mut self, label: &str, path: &str, bookmark_data: &[u8]) {
        use base64::Engine;
        let encoded = base64::engine::general_purpose::STANDARD.encode(bookmark_data);
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        // Remove existing bookmark with same label.
        self.bookmarks.retain(|b| b.label != label);

        self.bookmarks.push(BookmarkEntry {
            label: label.to_string(),
            path: path.to_string(),
            bookmark_data: encoded,
            created_at: now,
        });
    }

    /// Load all bookmark entries, decoding base64 data.
    ///
    /// Returns `(label, path, decoded_bookmark_data)` for each entry.
    /// Entries with invalid base64 are silently skipped.
    pub fn load_bookmarks(&self) -> Vec<(&str, &str, Vec<u8>)> {
        use base64::Engine;
        self.bookmarks
            .iter()
            .filter_map(|entry| {
                let data = base64::engine::general_purpose::STANDARD
                    .decode(&entry.bookmark_data)
                    .ok()?;
                Some((entry.label.as_str(), entry.path.as_str(), data))
            })
            .collect()
    }

    /// Remove a bookmark by label.
    ///
    /// Returns `true` if a bookmark was found and removed.
    pub fn remove_bookmark(&mut self, label: &str) -> bool {
        let before = self.bookmarks.len();
        self.bookmarks.retain(|b| b.label != label);
        self.bookmarks.len() < before
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn default_config_is_valid() {
        let config = SpeechConfig::default();
        assert!(config.audio.input_sample_rate > 0);
        assert!(config.audio.output_sample_rate > 0);
        assert!(config.audio.input_channels > 0);
        assert!(config.audio.buffer_size > 0);
        assert!(!config.stt.model_id.is_empty());
        assert!(config.stt.chunk_size > 0);
        assert!(config.llm.max_tokens > 0);
        assert!(config.llm.context_size_tokens > 0);
        assert!(config.llm.temperature >= 0.0);
        assert!(config.llm.top_p >= 0.0 && config.llm.top_p <= 1.0);
        assert!(config.tts.speed > 0.0);
        assert!(config.tts.sample_rate > 0);
        assert!(config.channels.inbound_queue_size > 0);
    }

    #[test]
    fn save_and_load_round_trip() {
        let dir = std::env::temp_dir().join("fae-test-config-roundtrip");
        let path = dir.join("config.toml");

        let mut config = SpeechConfig::default();
        config.audio.input_sample_rate = 44100;
        config.llm.temperature = 1.5;
        config.conversation.wake_word = "hello".to_string();

        assert!(config.save_to_file(&path).is_ok());
        assert!(path.exists());

        let loaded = SpeechConfig::from_file(&path);
        assert!(loaded.is_ok());
        let loaded = match loaded {
            Ok(c) => c,
            Err(_) => unreachable!("load should succeed"),
        };
        assert_eq!(loaded.audio.input_sample_rate, 44100);
        assert!((loaded.llm.temperature - 1.5).abs() < f64::EPSILON);
        assert_eq!(loaded.conversation.wake_word, "hello");

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn from_file_nonexistent_returns_error() {
        let result = SpeechConfig::from_file(std::path::Path::new("/nonexistent/path/config.toml"));
        assert!(result.is_err());
    }

    #[test]
    fn from_file_invalid_toml_returns_error() {
        let dir = std::env::temp_dir().join("fae-test-config-invalid");
        let path = dir.join("bad.toml");
        let _ = std::fs::create_dir_all(&dir);
        std::fs::write(&path, "this is not valid toml {{{").ok();

        let result = SpeechConfig::from_file(&path);
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn default_config_path_ends_with_config_toml() {
        let path = SpeechConfig::default_config_path();
        let path_str = path.to_string_lossy();
        assert!(path_str.ends_with("config.toml"));
        assert!(path_str.contains("fae"));
    }

    #[test]
    fn llm_backend_default_is_local() {
        assert_eq!(LlmBackend::default(), LlmBackend::Local);
    }

    #[test]
    fn config_serializes_to_toml() {
        let config = SpeechConfig::default();
        let result = toml::to_string_pretty(&config);
        assert!(result.is_ok());
        let toml_str = match result {
            Ok(s) => s,
            Err(_) => unreachable!("serialization should succeed"),
        };
        assert!(toml_str.contains("input_sample_rate"));
        assert!(toml_str.contains("threshold"));
    }

    #[test]
    fn tts_backend_default_is_kokoro() {
        assert_eq!(TtsBackend::default(), TtsBackend::Kokoro);
    }

    #[test]
    fn tts_config_with_backend_serializes() {
        let mut config = SpeechConfig::default();
        config.tts.backend = TtsBackend::FishSpeech;
        let toml_str = toml::to_string_pretty(&config).unwrap();
        assert!(toml_str.contains("backend"));
        // Round-trip
        let loaded: SpeechConfig = toml::from_str(&toml_str).unwrap();
        assert_eq!(loaded.tts.backend, TtsBackend::FishSpeech);
    }

    #[test]
    fn tts_config_voice_reference_defaults_to_none() {
        let config = TtsConfig::default();
        assert!(config.voice_reference.is_none());
        assert!(config.voice_reference_transcript.is_none());
    }

    #[test]
    fn recommended_context_size_tokens_scales_with_memory() {
        const GIB: u64 = 1024 * 1024 * 1024;
        assert_eq!(recommended_context_size_tokens(Some(8 * GIB)), 8_192);
        assert_eq!(recommended_context_size_tokens(Some(16 * GIB)), 16_384);
        assert_eq!(recommended_context_size_tokens(Some(32 * GIB)), 32_768);
        assert_eq!(recommended_context_size_tokens(Some(64 * GIB)), 65_536);
        assert_eq!(recommended_context_size_tokens(None), 32_768);
    }

    #[test]
    fn llm_config_model_selection_timeout_default() {
        let config = LlmConfig::default();
        assert_eq!(config.model_selection_timeout_secs, 30);
        assert_eq!(config.message_queue_mode, LlmMessageQueueMode::Followup);
        assert_eq!(config.message_queue_max_pending, 8);
        assert_eq!(
            config.message_queue_drop_policy,
            LlmMessageQueueDropPolicy::Oldest
        );
        assert!(config.clear_queue_on_stop);
    }

    #[test]
    fn llm_config_model_selection_timeout_deserialize() {
        let toml_str = r#"
[llm]
model_selection_timeout_secs = 60
"#;
        let config: SpeechConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.llm.model_selection_timeout_secs, 60);
    }

    #[test]
    fn llm_config_model_selection_timeout_missing_uses_default() {
        let toml_str = "[llm]";
        let config: SpeechConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.llm.model_selection_timeout_secs, 30);
        assert_eq!(config.llm.message_queue_mode, LlmMessageQueueMode::Followup);
        assert_eq!(config.llm.message_queue_max_pending, 8);
        assert_eq!(
            config.llm.message_queue_drop_policy,
            LlmMessageQueueDropPolicy::Oldest
        );
        assert!(config.llm.clear_queue_on_stop);
    }

    #[test]
    fn llm_message_queue_mode_deserializes() {
        use serde::Deserialize;

        #[derive(Deserialize)]
        struct Wrapper {
            mode: LlmMessageQueueMode,
        }

        let followup: Wrapper = toml::from_str(r#"mode = "followup""#).unwrap();
        assert_eq!(followup.mode, LlmMessageQueueMode::Followup);

        let collect: Wrapper = toml::from_str(r#"mode = "collect""#).unwrap();
        assert_eq!(collect.mode, LlmMessageQueueMode::Collect);
    }

    #[test]
    fn llm_message_queue_drop_policy_deserializes() {
        use serde::Deserialize;

        #[derive(Deserialize)]
        struct Wrapper {
            policy: LlmMessageQueueDropPolicy,
        }

        let oldest: Wrapper = toml::from_str(r#"policy = "oldest""#).unwrap();
        assert_eq!(oldest.policy, LlmMessageQueueDropPolicy::Oldest);

        let newest: Wrapper = toml::from_str(r#"policy = "newest""#).unwrap();
        assert_eq!(newest.policy, LlmMessageQueueDropPolicy::Newest);

        let none: Wrapper = toml::from_str(r#"policy = "none""#).unwrap();
        assert_eq!(none.policy, LlmMessageQueueDropPolicy::None);
    }

    #[test]
    fn llm_message_queue_config_deserializes() {
        let toml_str = r#"
[llm]
message_queue_mode = "collect"
message_queue_max_pending = 3
message_queue_drop_policy = "newest"
clear_queue_on_stop = false
"#;
        let config: SpeechConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.llm.message_queue_mode, LlmMessageQueueMode::Collect);
        assert_eq!(config.llm.message_queue_max_pending, 3);
        assert_eq!(
            config.llm.message_queue_drop_policy,
            LlmMessageQueueDropPolicy::Newest
        );
        assert!(!config.llm.clear_queue_on_stop);
    }

    #[test]
    fn llm_config_enable_local_fallback_default_is_true() {
        let config = LlmConfig::default();
        assert!(config.enable_local_fallback);
    }

    #[test]
    fn llm_config_enable_local_fallback_deserializes() {
        let toml_str = r#"
[llm]
enable_local_fallback = false
"#;
        let config: SpeechConfig = toml::from_str(toml_str).unwrap();
        assert!(!config.llm.enable_local_fallback);
    }

    #[test]
    fn llm_config_enable_local_fallback_missing_uses_default() {
        let toml_str = "[llm]";
        let config: SpeechConfig = toml::from_str(toml_str).unwrap();
        assert!(config.llm.enable_local_fallback);
    }

    #[test]
    fn bookmarks_default_empty() {
        let config = SpeechConfig::default();
        assert!(config.bookmarks.is_empty());
    }

    #[test]
    fn save_and_load_bookmark() {
        let mut config = SpeechConfig::default();
        config.save_bookmark("test-file", "/tmp/test.txt", &[0xDE, 0xAD, 0xBE, 0xEF]);
        assert_eq!(config.bookmarks.len(), 1);
        assert_eq!(config.bookmarks[0].label, "test-file");
        assert_eq!(config.bookmarks[0].path, "/tmp/test.txt");
        assert!(config.bookmarks[0].created_at > 0);

        let loaded = config.load_bookmarks();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].0, "test-file");
        assert_eq!(loaded[0].1, "/tmp/test.txt");
        assert_eq!(loaded[0].2, vec![0xDE, 0xAD, 0xBE, 0xEF]);
    }

    #[test]
    fn save_bookmark_replaces_same_label() {
        let mut config = SpeechConfig::default();
        config.save_bookmark("voice", "/old/path.wav", &[1, 2, 3]);
        config.save_bookmark("voice", "/new/path.wav", &[4, 5, 6]);
        assert_eq!(config.bookmarks.len(), 1);
        assert_eq!(config.bookmarks[0].path, "/new/path.wav");

        let loaded = config.load_bookmarks();
        assert_eq!(loaded[0].2, vec![4, 5, 6]);
    }

    #[test]
    fn remove_bookmark_by_label() {
        let mut config = SpeechConfig::default();
        config.save_bookmark("a", "/a", &[1]);
        config.save_bookmark("b", "/b", &[2]);
        assert_eq!(config.bookmarks.len(), 2);

        assert!(config.remove_bookmark("a"));
        assert_eq!(config.bookmarks.len(), 1);
        assert_eq!(config.bookmarks[0].label, "b");

        assert!(!config.remove_bookmark("nonexistent"));
    }

    #[test]
    fn bookmark_toml_round_trip() {
        let mut config = SpeechConfig::default();
        config.save_bookmark("demo", "/demo/file.txt", &[10, 20, 30]);

        let toml_str = toml::to_string_pretty(&config).unwrap();
        assert!(toml_str.contains("[[bookmarks]]"));
        assert!(toml_str.contains("demo"));

        let loaded: SpeechConfig = toml::from_str(&toml_str).unwrap();
        assert_eq!(loaded.bookmarks.len(), 1);
        assert_eq!(loaded.bookmarks[0].label, "demo");

        let decoded = loaded.load_bookmarks();
        assert_eq!(decoded[0].2, vec![10, 20, 30]);
    }

    #[test]
    fn bookmark_invalid_base64_skipped_in_load() {
        let mut config = SpeechConfig::default();
        config.bookmarks.push(BookmarkEntry {
            label: "bad".to_string(),
            path: "/bad".to_string(),
            bookmark_data: "not-valid-base64!!!".to_string(),
            created_at: 0,
        });
        config.save_bookmark("good", "/good", &[42]);

        let loaded = config.load_bookmarks();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].0, "good");
    }

    #[test]
    fn bookmarks_missing_from_toml_defaults_empty() {
        let toml_str = "[audio]\ninput_sample_rate = 16000";
        let config: SpeechConfig = toml::from_str(toml_str).unwrap();
        assert!(config.bookmarks.is_empty());
    }
}
