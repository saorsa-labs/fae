//! Voice Activity Detection using energy-based analysis.
//!
//! Uses RMS energy thresholding to detect speech boundaries.
//! Silero ONNX model integration is planned for a future version.

use crate::config::{ModelConfig, VadConfig};
use crate::error::Result;
use crate::pipeline::messages::{AudioChunk, SpeechSegment};
use std::collections::VecDeque;
use std::time::Instant;
use tracing::info;

/// VAD processing output.
pub struct VadOutput {
    /// Whether this chunk started a new speech segment.
    pub speech_started: bool,
    /// Whether this chunk is classified as speech.
    pub is_speech: bool,
    /// Completed speech segment, if one ended on this chunk.
    pub segment: Option<SpeechSegment>,
    /// RMS energy of the processed chunk.
    pub rms: f32,
}

/// Voice activity detector using RMS energy thresholding.
pub struct SileroVad {
    /// Pre-roll audio buffer for `speech_pad_ms`.
    pre_roll: VecDeque<f32>,
    /// Maximum number of samples to keep in pre-roll.
    pre_roll_max: usize,
    /// Accumulated samples for the current speech segment.
    speech_buffer: Vec<f32>,
    /// Whether we are currently in a speech segment.
    in_speech: bool,
    /// Number of consecutive silent samples.
    silence_samples: usize,
    /// Threshold for the number of silence samples to end a segment.
    silence_samples_threshold: usize,
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
    pub fn new(config: &VadConfig, _model_config: &ModelConfig, sample_rate: u32) -> Result<Self> {
        let silence_samples_threshold =
            (config.min_silence_duration_ms as usize * sample_rate as usize) / 1000;
        let pre_roll_max = (config.speech_pad_ms as usize * sample_rate as usize) / 1000;
        let min_speech_samples =
            (config.min_speech_duration_ms as usize * sample_rate as usize) / 1000;

        info!(
            "VAD initialized: threshold={}, silence_threshold={}ms, pad={}ms, min_speech={}ms",
            config.threshold,
            config.min_silence_duration_ms,
            config.speech_pad_ms,
            config.min_speech_duration_ms
        );

        Ok(Self {
            pre_roll: VecDeque::with_capacity(
                pre_roll_max.saturating_add(sample_rate as usize / 2),
            ),
            pre_roll_max,
            speech_buffer: Vec::new(),
            in_speech: false,
            silence_samples: 0,
            silence_samples_threshold,
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
    pub fn process_chunk(&mut self, chunk: &AudioChunk) -> Result<VadOutput> {
        let rms = compute_rms_energy(&chunk.samples);
        let is_speech = rms > self.threshold;

        // Update pre-roll buffer (for future speech starts)
        if self.pre_roll_max > 0 {
            self.pre_roll.extend(chunk.samples.iter().copied());
            while self.pre_roll.len() > self.pre_roll_max {
                let _ = self.pre_roll.pop_front();
            }
        }

        let mut speech_started = false;
        let mut completed: Option<SpeechSegment> = None;

        if is_speech {
            if !self.in_speech {
                self.in_speech = true;
                speech_started = true;
                self.speech_start = Some(chunk.captured_at);
                self.speech_buffer.clear();

                // Prepend pre-roll so we don't clip the initial phoneme.
                if !self.pre_roll.is_empty() {
                    self.speech_buffer.extend(self.pre_roll.iter().copied());
                }
            }
            self.silence_samples = 0;
            self.speech_buffer.extend_from_slice(&chunk.samples);
        } else if self.in_speech {
            self.silence_samples = self.silence_samples.saturating_add(chunk.samples.len());
            // Still append silence within tolerance
            self.speech_buffer.extend_from_slice(&chunk.samples);

            if self.silence_samples >= self.silence_samples_threshold {
                // Speech segment ended
                self.in_speech = false;
                self.silence_samples = 0;

                if self.speech_buffer.len() >= self.min_speech_samples {
                    let started_at = match self.speech_start {
                        Some(t) => t,
                        None => Instant::now(),
                    };
                    let segment = SpeechSegment {
                        samples: std::mem::take(&mut self.speech_buffer),
                        sample_rate: self.sample_rate,
                        started_at,
                    };
                    completed = Some(segment);
                } else {
                    self.speech_buffer.clear();
                }
            }
        }

        Ok(VadOutput {
            speech_started,
            is_speech,
            segment: completed,
            rms,
        })
    }

    /// Update the silence duration threshold at runtime.
    ///
    /// This allows the coordinator to use a shorter threshold during assistant
    /// speech (for faster barge-in segment delivery) and revert to the normal
    /// threshold when the assistant is idle.
    pub fn set_silence_threshold_ms(&mut self, ms: u32) {
        self.silence_samples_threshold = (ms as usize * self.sample_rate as usize) / 1000;
    }

    /// Reset the VAD state.
    pub fn reset(&mut self) {
        self.pre_roll.clear();
        self.speech_buffer.clear();
        self.in_speech = false;
        self.silence_samples = 0;
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
