//! Kokoro-82M ONNX inference engine.
//!
//! Single-model TTS: phonemize → tokenize → ONNX inference → 24 kHz audio.

use super::download::download_kokoro_assets;
use super::phonemize::Phonemizer;
use crate::config::TtsConfig;
use crate::error::{Result, SpeechError};
use ort::session::Session;
use ort::value::Tensor;
use std::collections::HashMap;
use tracing::info;

/// Maximum context length for Kokoro (including pad tokens).
const MAX_CONTEXT: usize = 512;

/// Output sample rate in Hz.
const SAMPLE_RATE: u32 = 24_000;

/// Kokoro TTS engine.
///
/// Wraps a single ONNX session, the tokenizer, phonemizer, and a voice
/// style embedding. Synthesizes text to 24 kHz f32 mono audio.
pub struct KokoroTts {
    session: Session,
    tokenizer: tokenizers::Tokenizer,
    phonemizer: Phonemizer,
    /// Raw voice style tensor: shape `(N, 1, 256)` stored flat.
    /// Index by `[token_count]` to get the context-appropriate 256-dim slice.
    voice_styles: Vec<f32>,
    speed: f32,
}

impl KokoroTts {
    /// Load the Kokoro engine from pre-downloaded paths.
    ///
    /// This skips all download logic and loads directly from disk.
    /// Use when files have already been downloaded via
    /// [`download_kokoro_assets_with_progress`](super::download::download_kokoro_assets_with_progress).
    ///
    /// # Errors
    ///
    /// Returns an error if model loading or phonemizer init fails.
    pub fn from_paths(paths: super::download::KokoroPaths, config: &TtsConfig) -> Result<Self> {
        info!("loading Kokoro ONNX model");
        let session = Session::builder()
            .and_then(|b| b.with_intra_threads(4))
            .and_then(|b| b.commit_from_file(&paths.model_onnx))
            .map_err(|e| SpeechError::Tts(format!("failed to load Kokoro ONNX model: {e}")))?;

        info!("loading tokenizer");
        let tokenizer = load_tokenizer(&paths.tokenizer_json)?;

        let resolved = super::download::resolve_voice_alias(&config.voice);
        let is_british = resolved.starts_with("bf_") || resolved.starts_with("bm_");
        info!("initialising misaki phonemizer (british={is_british})");
        let phonemizer = Phonemizer::new(is_british);

        info!("loading voice style: {}", paths.voice_bin.display());
        let voice_styles = load_voice_styles(&paths.voice_bin)?;

        let speed = config.speed.clamp(0.5, 2.0);

        info!(
            "Kokoro TTS ready (voice={}, variant={})",
            config.voice, config.model_variant
        );

        Ok(Self {
            session,
            tokenizer,
            phonemizer,
            voice_styles,
            speed,
        })
    }

    /// Load the Kokoro engine.
    ///
    /// Downloads model files on first use (cached by HuggingFace Hub),
    /// then loads them. For pre-downloaded files, use [`Self::from_paths`].
    ///
    /// # Errors
    ///
    /// Returns an error if model download, loading, or phonemizer init fails.
    pub fn new(config: &TtsConfig) -> Result<Self> {
        let paths = download_kokoro_assets(&config.model_variant, &config.voice)?;
        Self::from_paths(paths, config)
    }

    /// Synthesize text to audio samples.
    ///
    /// Returns f32 audio samples at 24 kHz mono.
    /// Uses `block_in_place` since ONNX inference is synchronous.
    ///
    /// # Errors
    ///
    /// Returns an error if phonemization, tokenization, or inference fails.
    pub async fn synthesize(&mut self, text: &str) -> Result<Vec<f32>> {
        if text.is_empty() {
            return Ok(Vec::new());
        }

        info!("synthesizing: \"{text}\"");
        let start = std::time::Instant::now();

        // 1. Phonemize
        let ipa = self.phonemizer.phonemize(text)?;
        if ipa.is_empty() {
            return Ok(Vec::new());
        }
        info!("phonemized: \"{ipa}\" ({} chars)", ipa.len());

        // 2. Tokenize — we stripped the post-processor (tokenizers v0.22 compat)
        //    so we manually wrap with pad token (id=0) at start and end.
        let encoding = self
            .tokenizer
            .encode(ipa.as_str(), false)
            .map_err(|e| SpeechError::Tts(format!("tokenization failed: {e}")))?;

        let raw_ids = encoding.get_ids();
        info!(
            "tokenized: {} raw tokens, first 20: {:?}",
            raw_ids.len(),
            &raw_ids[..raw_ids.len().min(20)]
        );

        let mut token_ids: Vec<i64> = Vec::with_capacity(raw_ids.len() + 2);
        token_ids.push(0); // pad token at start
        token_ids.extend(raw_ids.iter().map(|&id| id as i64));
        token_ids.push(0); // pad token at end

        if token_ids.len() > MAX_CONTEXT {
            return Err(SpeechError::Tts(format!(
                "input too long: {} tokens (max {})",
                token_ids.len(),
                MAX_CONTEXT,
            )));
        }

        if token_ids.is_empty() {
            return Ok(Vec::new());
        }

        // 3. Select voice style vector based on token count.
        //    voice_styles is shape (N, 1, 256). We index by token count (without pads).
        //    The number of content tokens = total - 2 (for the two pad tokens).
        let content_len = token_ids.len().saturating_sub(2).max(1);
        let num_entries = self.voice_styles.len() / 256;
        let style_index = content_len.min(num_entries.saturating_sub(1));
        let style_offset = style_index * 256;
        let style_slice = &self.voice_styles[style_offset..style_offset + 256];

        // 4. Build input tensors and run inference (synchronous).
        let speed = self.speed;
        let token_ids_owned = token_ids;
        let style_vec: Vec<f32> = style_slice.to_vec();

        let samples = tokio::task::block_in_place(|| {
            self.run_inference(&token_ids_owned, &style_vec, speed)
        })?;

        let elapsed = start.elapsed();
        let max_amp = samples.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
        let has_nan = samples.iter().any(|s| s.is_nan());
        info!(
            "synthesized {} samples ({:.1}s audio) in {:.0}ms — max_amp={:.4}, nan={}",
            samples.len(),
            samples.len() as f32 / SAMPLE_RATE as f32,
            elapsed.as_millis(),
            max_amp,
            has_nan,
        );

        Ok(samples)
    }

    /// Get the output sample rate (always 24 kHz).
    pub fn sample_rate(&self) -> u32 {
        SAMPLE_RATE
    }

    /// Run a single ONNX inference call.
    fn run_inference(&mut self, token_ids: &[i64], style: &[f32], speed: f32) -> Result<Vec<f32>> {
        use ort::session::{SessionInputValue, SessionInputs};

        let seq_len = token_ids.len();

        // input_ids: shape [1, seq_len]
        let input_ids = Tensor::from_array(([1_usize, seq_len], token_ids.to_vec()))
            .map_err(|e| SpeechError::Tts(format!("failed to create input_ids tensor: {e}")))?;

        // style: shape [1, 256]
        let style_tensor = Tensor::from_array(([1_usize, 256], style.to_vec()))
            .map_err(|e| SpeechError::Tts(format!("failed to create style tensor: {e}")))?;

        // speed: shape [1]
        let speed_tensor = Tensor::from_array(([1_usize], vec![speed]))
            .map_err(|e| SpeechError::Tts(format!("failed to create speed tensor: {e}")))?;

        let mut feed: HashMap<String, SessionInputValue> = HashMap::new();
        feed.insert("input_ids".to_string(), input_ids.into());
        feed.insert("style".to_string(), style_tensor.into());
        feed.insert("speed".to_string(), speed_tensor.into());

        let outputs = self
            .session
            .run(SessionInputs::from(feed))
            .map_err(|e| SpeechError::Tts(format!("ONNX inference failed: {e}")))?;

        // Output: shape [1, num_samples]
        let output_value = &outputs[0_usize];
        let (_shape, data) = output_value
            .try_extract_tensor::<f32>()
            .map_err(|e| SpeechError::Tts(format!("failed to extract output tensor: {e}")))?;

        Ok(data.to_vec())
    }
}

/// Load and patch the Kokoro tokenizer.
///
/// The `tokenizers` crate v0.22 cannot deserialize the `TemplateProcessing`
/// post-processor in Kokoro's `tokenizer.json`. We strip it and handle pad
/// token insertion manually in `synthesize()`.
fn load_tokenizer(path: &std::path::Path) -> Result<tokenizers::Tokenizer> {
    let raw = std::fs::read_to_string(path).map_err(|e| {
        SpeechError::Tts(format!(
            "failed to read tokenizer file {}: {e}",
            path.display()
        ))
    })?;

    let mut json: serde_json::Value = serde_json::from_str(&raw)
        .map_err(|e| SpeechError::Tts(format!("failed to parse tokenizer JSON: {e}")))?;

    // Patch fields that tokenizers v0.22 can't deserialize:
    // 1. Remove TemplateProcessing post_processor (we add pad tokens manually).
    // 2. Add "type": "WordLevel" to the model (char-level vocab lookup).
    if let Some(obj) = json.as_object_mut() {
        obj.remove("post_processor");

        if let Some(model) = obj.get_mut("model").and_then(|m| m.as_object_mut()) {
            if !model.contains_key("type") {
                model.insert(
                    "type".to_string(),
                    serde_json::Value::String("WordLevel".to_string()),
                );
            }
            // WordLevel requires an unk_token field.
            if !model.contains_key("unk_token") {
                model.insert(
                    "unk_token".to_string(),
                    serde_json::Value::String("$".to_string()),
                );
            }
        }
    }

    let patched = serde_json::to_string(&json)
        .map_err(|e| SpeechError::Tts(format!("failed to serialize patched tokenizer: {e}")))?;

    tokenizers::Tokenizer::from_bytes(patched)
        .map_err(|e| SpeechError::Tts(format!("failed to load tokenizer: {e}")))
}

/// Load a voice style `.bin` file as a flat f32 vector.
///
/// The file contains raw f32 values with shape `(N, 1, 256)` where N is
/// typically 511. We store it flat and index by `[i * 256 .. (i+1) * 256]`.
fn load_voice_styles(path: &std::path::Path) -> Result<Vec<f32>> {
    let bytes = std::fs::read(path).map_err(|e| {
        SpeechError::Tts(format!("failed to read voice file {}: {e}", path.display()))
    })?;

    if bytes.len() % 4 != 0 {
        return Err(SpeechError::Tts(format!(
            "voice file size {} is not a multiple of 4 (expected f32 array)",
            bytes.len()
        )));
    }

    let float_count = bytes.len() / 4;
    if float_count % 256 != 0 {
        return Err(SpeechError::Tts(format!(
            "voice file has {} floats, not a multiple of 256",
            float_count
        )));
    }

    let mut floats = vec![0.0f32; float_count];
    for (i, chunk) in bytes.chunks_exact(4).enumerate() {
        floats[i] = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
    }

    info!(
        "loaded voice style: {} entries of 256 dims",
        float_count / 256
    );

    Ok(floats)
}
