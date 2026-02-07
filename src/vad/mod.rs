//! Voice Activity Detection using energy-based analysis.
//!
//! Uses RMS energy thresholding to detect speech boundaries.
//! Silero ONNX model integration is planned for a future version.

use crate::config::{ModelConfig, VadConfig};
use crate::error::Result;
use crate::pipeline::messages::{AudioChunk, SpeechSegment};
use std::time::Instant;
use tracing::info;

/// Voice activity detector using RMS energy thresholding.
pub struct SileroVad {
    /// Accumulated samples for the current speech segment.
    speech_buffer: Vec<f32>,
    /// Whether we are currently in a speech segment.
    in_speech: bool,
    /// Number of consecutive silent chunks.
    silence_count: u32,
    /// Threshold for the number of silence chunks to end a segment.
    silence_threshold: u32,
    /// When the current speech segment started.
    speech_start: Option<Instant>,
    /// Configured sample rate.
    sample_rate: u32,
    /// VAD threshold.
    threshold: f32,
    /// Minimum speech duration in samples.
    min_speech_samples: usize,
}

impl SileroVad {
    /// Create a new VAD instance.
    ///
    /// # Errors
    ///
    /// Returns an error if the model cannot be loaded.
    pub fn new(config: &VadConfig, _model_config: &ModelConfig) -> Result<Self> {
        let chunk_duration_ms: u32 = 32; // 512 samples at 16kHz
        let silence_threshold = config.min_silence_duration_ms / chunk_duration_ms;

        let sample_rate: u32 = 16_000;
        let min_speech_samples =
            (config.min_speech_duration_ms as usize * sample_rate as usize) / 1000;

        info!(
            "VAD initialized: threshold={}, silence_threshold={} chunks, min_speech={}ms",
            config.threshold, silence_threshold, config.min_speech_duration_ms
        );

        Ok(Self {
            speech_buffer: Vec::new(),
            in_speech: false,
            silence_count: 0,
            silence_threshold,
            speech_start: None,
            sample_rate,
            threshold: config.threshold,
            min_speech_samples,
        })
    }

    /// Process an audio chunk and return a speech segment if a complete
    /// utterance has been detected.
    ///
    /// # Errors
    ///
    /// Returns an error if audio processing fails.
    pub fn process_chunk(&mut self, chunk: &AudioChunk) -> Result<Option<SpeechSegment>> {
        let energy = compute_rms_energy(&chunk.samples);
        let is_speech = energy > self.threshold * 0.01; // Energy-based threshold

        if is_speech {
            if !self.in_speech {
                self.in_speech = true;
                self.speech_start = Some(chunk.captured_at);
                self.speech_buffer.clear();
            }
            self.silence_count = 0;
            self.speech_buffer.extend_from_slice(&chunk.samples);
        } else if self.in_speech {
            self.silence_count += 1;
            // Still append silence within tolerance
            self.speech_buffer.extend_from_slice(&chunk.samples);

            if self.silence_count >= self.silence_threshold {
                // Speech segment ended
                self.in_speech = false;
                self.silence_count = 0;

                if self.speech_buffer.len() >= self.min_speech_samples {
                    let segment = SpeechSegment {
                        samples: std::mem::take(&mut self.speech_buffer),
                        sample_rate: self.sample_rate,
                        started_at: self.speech_start.unwrap_or_else(Instant::now),
                    };
                    return Ok(Some(segment));
                }
                self.speech_buffer.clear();
            }
        }

        Ok(None)
    }

    /// Reset the VAD state.
    pub fn reset(&mut self) {
        self.speech_buffer.clear();
        self.in_speech = false;
        self.silence_count = 0;
        self.speech_start = None;
    }
}

/// Compute RMS energy of audio samples.
fn compute_rms_energy(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}
