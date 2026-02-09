//! Text-to-speech synthesis using Chatterbox Turbo.
//!
//! Uses ResembleAI's Chatterbox Turbo ONNX models for high-quality
//! voice-cloning TTS at 24kHz. The bundled default voice ("Fae") is a
//! Scottish female voice embedded at compile time.

mod chatterbox;

use std::io::Read as _;
use std::path::PathBuf;

use crate::config::TtsConfig;
use crate::error::{Result, SpeechError};
use chatterbox::{
    Chatterbox, ModelVariant, SessionConfig, VoiceProfile, download_chatterbox_assets,
};
use tracing::info;

/// Default HuggingFace repo for Chatterbox Turbo ONNX models.
const DEFAULT_REPO_ID: &str = "ResembleAI/chatterbox-turbo-ONNX";

/// Default revision (branch) for the model repo.
const DEFAULT_REVISION: &str = "main";

/// URL for the fallback voice profile from cbx GitHub releases (used only if the
/// bundled Fae voice cannot be written to disk).
const CBX_DEFAULT_VOICE_URL: &str =
    "https://github.com/srv1n/cbx/releases/latest/download/cbx-voice-default-fp16.cbxvoice";

/// Bundled Fae voice WAV (Scottish female, 24kHz mono, ~30s).
/// Embedded at compile time so it's always available without network access.
const FAE_VOICE_WAV: &[u8] = include_bytes!("../../assets/voices/fae.wav");

/// Well-known filename for the bundled Fae voice on disk.
const FAE_VOICE_FILENAME: &str = "fae.wav";

/// Text-to-speech engine using Chatterbox Turbo.
///
/// Synthesizes text to 24kHz f32 mono audio using ONNX Runtime with
/// voice cloning from a reference WAV file.
pub struct ChatterboxTts {
    engine: Chatterbox,
    voice_profile: VoiceProfile,
    repo_id: String,
    revision: String,
    dtype_label: String,
    config: TtsConfig,
}

impl ChatterboxTts {
    /// Load the Chatterbox engine and encode a voice profile from a WAV file.
    ///
    /// Downloads model files on first use (cached by HuggingFace Hub).
    /// The `voice_wav` path points to a reference WAV for voice cloning.
    ///
    /// # Errors
    ///
    /// Returns an error if model download, loading, or voice encoding fails.
    pub fn new(config: &TtsConfig, voice_wav: &std::path::Path) -> Result<Self> {
        let repo_id = DEFAULT_REPO_ID.to_owned();
        let revision = DEFAULT_REVISION.to_owned();
        let variant = parse_model_variant(&config.model_dtype);
        let dtype_label = config.model_dtype.clone();

        info!("downloading Chatterbox models ({repo_id}@{revision} dtype={dtype_label})");
        let paths = download_chatterbox_assets(&repo_id, &revision, variant)
            .map_err(|e| SpeechError::Tts(format!("failed to download Chatterbox models: {e}")))?;

        info!("loading Chatterbox engine");
        let session_cfg = SessionConfig::default();
        let mut engine = Chatterbox::load_with(&paths, &session_cfg)
            .map_err(|e| SpeechError::Tts(format!("failed to load Chatterbox engine: {e}")))?;

        info!("encoding voice profile from {}", voice_wav.display());
        let voice_profile = engine
            .encode_voice_profile(voice_wav, &repo_id, &revision, &dtype_label)
            .map_err(|e| SpeechError::Tts(format!("failed to encode voice profile: {e}")))?;

        info!("Chatterbox TTS ready");

        Ok(Self {
            engine,
            voice_profile,
            repo_id,
            revision,
            dtype_label,
            config: config.clone(),
        })
    }

    /// Load the Chatterbox engine using the built-in default voice.
    ///
    /// Downloads a pre-encoded default voice profile from cbx GitHub releases
    /// and caches it locally. Subsequent calls use the cached profile directly.
    ///
    /// # Errors
    ///
    /// Returns an error if model download, loading, or voice profile download fails.
    pub fn new_with_default_voice(config: &TtsConfig) -> Result<Self> {
        let repo_id = DEFAULT_REPO_ID.to_owned();
        let revision = DEFAULT_REVISION.to_owned();
        let variant = parse_model_variant(&config.model_dtype);
        let dtype_label = config.model_dtype.clone();

        info!("downloading Chatterbox models ({repo_id}@{revision} dtype={dtype_label})");
        let paths = download_chatterbox_assets(&repo_id, &revision, variant)
            .map_err(|e| SpeechError::Tts(format!("failed to download Chatterbox models: {e}")))?;

        info!("loading Chatterbox engine");
        let session_cfg = SessionConfig::default();
        let engine = Chatterbox::load_with(&paths, &session_cfg)
            .map_err(|e| SpeechError::Tts(format!("failed to load Chatterbox engine: {e}")))?;

        let voice_profile = get_or_download_default_profile(&repo_id, &revision, &dtype_label)?;

        info!("Chatterbox TTS ready (default voice)");

        Ok(Self {
            engine,
            voice_profile,
            repo_id,
            revision,
            dtype_label,
            config: config.clone(),
        })
    }

    /// Synthesize text to audio samples.
    ///
    /// Returns f32 audio samples at 24kHz mono.
    /// Uses `block_in_place` since ONNX inference is synchronous.
    ///
    /// # Errors
    ///
    /// Returns an error if synthesis fails.
    pub async fn synthesize(&mut self, text: &str) -> Result<Vec<f32>> {
        if text.is_empty() {
            return Ok(Vec::new());
        }

        info!("synthesizing: \"{text}\"");

        let start = std::time::Instant::now();

        // ONNX inference is synchronous; signal tokio that we're blocking.
        let samples = tokio::task::block_in_place(|| {
            self.engine.synthesize_with_voice_profile(
                text,
                &self.repo_id,
                &self.revision,
                &self.dtype_label,
                &self.voice_profile,
                self.config.max_new_tokens,
                self.config.repetition_penalty,
            )
        })
        .map_err(|e| SpeechError::Tts(format!("synthesis failed: {e}")))?;

        let elapsed = start.elapsed();
        info!(
            "synthesized {} samples ({:.1}s audio) in {:.0}ms",
            samples.len(),
            samples.len() as f32 / self.config.sample_rate as f32,
            elapsed.as_millis()
        );

        Ok(samples)
    }

    /// Get the output sample rate.
    pub fn sample_rate(&self) -> u32 {
        self.config.sample_rate
    }
}

/// Parse config model_dtype string to a `ModelVariant`.
fn parse_model_variant(dtype: &str) -> ModelVariant {
    match dtype {
        "fp32" => ModelVariant::Fp32,
        "fp16" => ModelVariant::Fp16,
        "quantized" => ModelVariant::Quantized,
        "q4" => ModelVariant::Q4,
        "q4f16" => ModelVariant::Q4f16,
        "q8" => ModelVariant::Q8,
        "q8f16" => ModelVariant::Q8f16,
        _ => {
            info!("unknown model dtype '{dtype}', falling back to q4f16");
            ModelVariant::Q4f16
        }
    }
}

/// Resolve the voice reference WAV path.
///
/// Priority order:
/// 1. Explicit `voice_reference` in config (user-selected voice)
/// 2. Bundled Fae voice (Scottish female, written to `~/.fae/voices/fae.wav`)
/// 3. `None` — caller falls back to downloading the cbx default voice profile
pub fn resolve_voice_wav(config: &TtsConfig) -> Option<PathBuf> {
    if !config.voice_reference.is_empty() {
        return Some(PathBuf::from(&config.voice_reference));
    }

    // Try to ensure the bundled Fae voice is available on disk.
    match ensure_bundled_fae_voice() {
        Ok(path) => {
            info!("using bundled Fae voice: {}", path.display());
            Some(path)
        }
        Err(e) => {
            info!("could not write bundled Fae voice to disk: {e}; falling back to cbx default");
            None
        }
    }
}

/// Write the bundled Fae voice WAV to `~/.fae/voices/fae.wav` if it doesn't
/// already exist (or if it has a different size). Returns the path.
fn ensure_bundled_fae_voice() -> Result<PathBuf> {
    let voices_dir = crate::config::MemoryConfig::default()
        .root_dir
        .join("voices");
    std::fs::create_dir_all(&voices_dir)?;

    let path = voices_dir.join(FAE_VOICE_FILENAME);

    // Only write if the file is missing or has a different size (stale/corrupt).
    let needs_write = match std::fs::metadata(&path) {
        Ok(meta) => meta.len() != FAE_VOICE_WAV.len() as u64,
        Err(_) => true,
    };

    if needs_write {
        info!(
            "writing bundled Fae voice ({} bytes) to {}",
            FAE_VOICE_WAV.len(),
            path.display()
        );
        std::fs::write(&path, FAE_VOICE_WAV)?;
    }

    Ok(path)
}

/// Return the path where the bundled Fae voice is (or would be) stored.
/// Use this for "Reset to Fae's voice" in the GUI.
pub fn bundled_fae_voice_path() -> PathBuf {
    crate::config::MemoryConfig::default()
        .root_dir
        .join("voices")
        .join(FAE_VOICE_FILENAME)
}

/// Check the cbx voice cache for a matching profile, or download the default.
fn get_or_download_default_profile(
    repo_id: &str,
    revision: &str,
    dtype: &str,
) -> Result<VoiceProfile> {
    let cache_dir = chatterbox::voice::voice_cache_dir()
        .map_err(|e| SpeechError::Tts(format!("failed to resolve voice cache dir: {e}")))?;

    // Check for an existing cached profile matching the model tuple.
    if let Ok(Some(name)) =
        chatterbox::voice::pick_voice_for_model(&cache_dir, repo_id, revision, dtype)
    {
        info!("found cached voice profile: {name}");
        return chatterbox::voice::load_voice_profile(&cache_dir, &name)
            .map_err(|e| SpeechError::Tts(format!("failed to load cached voice profile: {e}")));
    }

    // Download the default voice profile from cbx GitHub releases.
    info!("downloading default voice profile from cbx releases...");
    let profile = download_default_voice_profile(repo_id, revision, dtype)?;

    // Cache the profile for future use.
    let profile_name = format!("saorsa-default-{dtype}");
    match chatterbox::voice::save_voice_profile(&cache_dir, &profile_name, &profile) {
        Ok(()) => info!("cached voice profile as {profile_name}"),
        Err(e) => info!("could not cache voice profile: {e}"),
    }

    Ok(profile)
}

/// Download the default `.cbxvoice` from cbx GitHub releases and adapt its metadata.
fn download_default_voice_profile(
    repo_id: &str,
    revision: &str,
    dtype: &str,
) -> Result<VoiceProfile> {
    let response = ureq::get(CBX_DEFAULT_VOICE_URL)
        .call()
        .map_err(|e| SpeechError::Tts(format!("failed to download default voice profile: {e}")))?;

    let mut bytes = Vec::new();
    response
        .into_reader()
        .read_to_end(&mut bytes)
        .map_err(|e| SpeechError::Tts(format!("failed to read voice profile data: {e}")))?;

    info!("downloaded {} bytes", bytes.len());

    let mut profile: VoiceProfile = bincode::deserialize(&bytes)
        .map_err(|e| SpeechError::Tts(format!("failed to decode voice profile: {e}")))?;

    // Adapt the profile metadata to match our model tuple.
    // The tensor data is always stored in f32/i64 regardless of the model variant,
    // so the voice characteristics are preserved across dtype variants.
    profile.repo_id = repo_id.to_string();
    profile.revision = revision.to_string();
    profile.dtype = dtype.to_string();

    Ok(profile)
}
