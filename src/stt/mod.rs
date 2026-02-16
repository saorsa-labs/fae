//! Speech-to-text using NVIDIA Parakeet TDT.
//!
//! Uses `parakeet-rs` with the `ParakeetTDT` model for multilingual
//! batch transcription with punctuation support.

use crate::config::{ModelConfig, SttConfig};
use crate::error::{Result, SpeechError};
use crate::models::ModelManager;
use crate::pipeline::messages::{SpeechSegment, Transcription};
use crate::voiceprint;
use parakeet_rs::{ParakeetTDT, TimestampMode, Transcriber};
use std::time::Instant;
use tracing::info;

/// Speech-to-text engine using Parakeet TDT (multilingual, 25 languages).
pub struct ParakeetStt {
    model: Option<ParakeetTDT>,
    model_id: String,
    model_manager: ModelManager,
}

/// Model files required by Parakeet TDT.
const ENCODER_ONNX: &str = "encoder-model.onnx";
const ENCODER_DATA: &str = "encoder-model.onnx.data";
const DECODER_ONNX: &str = "decoder_joint-model.onnx";
const VOCAB_TXT: &str = "vocab.txt";

impl ParakeetStt {
    /// Create a new STT engine instance.
    ///
    /// Models are loaded lazily on first use via `ModelManager`.
    ///
    /// # Errors
    ///
    /// Returns an error if configuration is invalid.
    pub fn new(config: &SttConfig, model_config: &ModelConfig) -> Result<Self> {
        let model_manager = ModelManager::new(model_config)?;
        info!("STT configured with model: {}", config.model_id);

        Ok(Self {
            model: None,
            model_id: config.model_id.clone(),
            model_manager,
        })
    }

    /// Transcribe a speech segment to text.
    ///
    /// # Errors
    ///
    /// Returns an error if model loading or transcription fails.
    pub fn transcribe(&mut self, segment: &SpeechSegment) -> Result<Transcription> {
        if self.model.is_none() {
            self.initialize()?;
        }

        let transcribed_start = Instant::now();
        let duration_s = segment.samples.len() as f32 / segment.sample_rate as f32;

        // Diagnostic: log segment audio characteristics to debug empty transcriptions.
        let rms: f32 = if segment.samples.is_empty() {
            0.0
        } else {
            (segment.samples.iter().map(|s| s * s).sum::<f32>() / segment.samples.len() as f32)
                .sqrt()
        };
        let peak = segment
            .samples
            .iter()
            .map(|s| s.abs())
            .fold(0.0f32, f32::max);
        let non_zero = segment
            .samples
            .iter()
            .filter(|&&s| s.abs() > 0.0001)
            .count();
        info!(
            "transcribing {duration_s:.1}s audio segment (rms={rms:.6}, peak={peak:.6}, non_zero={non_zero}/{})",
            segment.samples.len()
        );

        let model = self
            .model
            .as_mut()
            .ok_or_else(|| SpeechError::Stt("model not initialized".into()))?;

        let result = model
            .transcribe_samples(
                segment.samples.clone(),
                segment.sample_rate,
                1, // mono
                Some(TimestampMode::Sentences),
            )
            .map_err(|e| SpeechError::Stt(format!("transcription failed: {e}")))?;

        let transcribed_at = Instant::now();
        let latency = transcribed_at.duration_since(transcribed_start);
        info!(
            "transcribed in {:.0}ms: \"{}\"",
            latency.as_millis(),
            result.text
        );

        let voiceprint = voiceprint::compute_voiceprint(&segment.samples, segment.sample_rate).ok();

        Ok(Transcription {
            text: result.text,
            is_final: true,
            voiceprint,
            audio_captured_at: segment.started_at,
            transcribed_at,
        })
    }

    /// Eagerly load the model so it is ready for transcription.
    ///
    /// This is the same as the lazy init that happens on first `transcribe()`,
    /// but allows callers to trigger loading at a controlled time (e.g. startup).
    ///
    /// # Errors
    ///
    /// Returns an error if model loading fails.
    pub fn ensure_loaded(&mut self) -> Result<()> {
        if self.model.is_none() {
            self.initialize()?;
        }
        Ok(())
    }

    /// Load the Parakeet TDT model from cache (downloading if needed).
    fn initialize(&mut self) -> Result<()> {
        info!("loading STT model: {}", self.model_id);

        // Download all required model files via hf-hub
        let _encoder = self
            .model_manager
            .get_model_path(&self.model_id, ENCODER_ONNX)?;
        let _encoder_data = self
            .model_manager
            .get_model_path(&self.model_id, ENCODER_DATA)?;
        let _decoder = self
            .model_manager
            .get_model_path(&self.model_id, DECODER_ONNX)?;
        let _vocab = self
            .model_manager
            .get_model_path(&self.model_id, VOCAB_TXT)?;

        // hf-hub caches files in a repo-level directory structure.
        // ParakeetTDT::from_pretrained expects a directory containing all files.
        let repo_dir = self.model_manager.get_repo_dir(&self.model_id)?;

        let model = ParakeetTDT::from_pretrained(&repo_dir, None)
            .map_err(|e| SpeechError::Stt(format!("failed to load Parakeet TDT: {e}")))?;

        info!("STT model loaded successfully");
        self.model = Some(model);
        Ok(())
    }
}
