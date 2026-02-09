//! Acoustic Echo Cancellation (AEC) using FDAF adaptive filtering.
//!
//! Removes speaker output (echo) from the microphone signal so the VAD/STT
//! pipeline only sees the user's voice. This enables proper barge-in without
//! flag-based echo suppression.
//!
//! # Architecture
//!
//! ```text
//! Capture (16kHz) → [AecProcessor] → VAD → STT → LLM → TTS → Playback (24kHz)
//!                        ↑                                         │
//!                        └── ReferenceBuffer (24kHz→16kHz) ────────┘
//! ```

use crate::config::AecConfig;
use crate::pipeline::messages::AudioChunk;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

/// Shared ring buffer holding resampled reference audio from the playback stage.
///
/// The playback stage pushes 24kHz samples via [`ReferenceHandle::push`],
/// which are downsampled to the capture rate (16kHz) on the fly. The AEC stage
/// drains frames of the same size as the microphone chunks.
pub struct ReferenceBuffer {
    inner: Arc<Mutex<VecDeque<f32>>>,
    playback_rate: u32,
    capture_rate: u32,
}

impl ReferenceBuffer {
    /// Create a new reference buffer.
    ///
    /// `playback_rate` is the speaker output rate (e.g. 24kHz).
    /// `capture_rate` is the microphone input rate (e.g. 16kHz).
    /// The internal ring buffer holds up to 2 seconds at the capture rate.
    pub fn new(playback_rate: u32, capture_rate: u32) -> Self {
        let capacity = (capture_rate as usize) * 2; // 2s
        Self {
            inner: Arc::new(Mutex::new(VecDeque::with_capacity(capacity))),
            playback_rate,
            capture_rate,
        }
    }

    /// Clone the shared `Arc` handle for passing to another stage.
    pub fn handle(&self) -> ReferenceHandle {
        ReferenceHandle {
            inner: Arc::clone(&self.inner),
            playback_rate: self.playback_rate,
            capture_rate: self.capture_rate,
        }
    }

    /// Drain exactly `n` samples from the buffer.
    ///
    /// If fewer than `n` samples are available, the remainder is zero-filled.
    pub fn drain_frame(&self, n: usize) -> Vec<f32> {
        let Ok(mut buf) = self.inner.lock() else {
            return vec![0.0; n];
        };
        let mut out = Vec::with_capacity(n);
        for _ in 0..n {
            out.push(buf.pop_front().unwrap_or(0.0));
        }
        out
    }

    /// Clear all buffered reference audio (e.g. on barge-in stop).
    pub fn clear(&self) {
        if let Ok(mut buf) = self.inner.lock() {
            buf.clear();
        }
    }
}

/// A clonable handle to the reference buffer, used by the playback stage.
pub struct ReferenceHandle {
    inner: Arc<Mutex<VecDeque<f32>>>,
    playback_rate: u32,
    capture_rate: u32,
}

impl ReferenceHandle {
    /// Push playback samples into the reference buffer.
    ///
    /// Samples are downsampled from the playback rate to the capture rate
    /// via linear interpolation before being appended.
    pub fn push(&self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        let resampled = if self.playback_rate != self.capture_rate {
            downsample_linear(samples, self.playback_rate, self.capture_rate)
        } else {
            samples.to_vec()
        };
        let Ok(mut buf) = self.inner.lock() else {
            return;
        };
        // Cap at 2 seconds of capture-rate audio to prevent unbounded growth.
        let cap = (self.capture_rate as usize) * 2;

        // If the new data alone exceeds the cap, keep only the tail.
        let data = if resampled.len() > cap {
            &resampled[resampled.len() - cap..]
        } else {
            &resampled
        };

        let needed = data.len().saturating_sub(cap.saturating_sub(buf.len()));
        for _ in 0..needed {
            buf.pop_front();
        }
        buf.extend(data.iter());
    }

    /// Clear all buffered reference audio.
    pub fn clear(&self) {
        if let Ok(mut buf) = self.inner.lock() {
            buf.clear();
        }
    }
}

/// Wraps [`fdaf_aec::FdafAec`] for frame-by-frame echo cancellation.
pub struct AecProcessor {
    filter: fdaf_aec::FdafAec,
    reference: ReferenceBuffer,
    frame_size: usize,
}

impl AecProcessor {
    /// Create a new AEC processor.
    ///
    /// # Errors
    ///
    /// Returns an error if `fft_size` is not a power of two or is zero.
    pub fn new(config: &AecConfig, reference: ReferenceBuffer) -> crate::error::Result<Self> {
        if config.fft_size == 0 || !config.fft_size.is_power_of_two() {
            return Err(crate::error::SpeechError::Audio(format!(
                "AEC fft_size must be a non-zero power of two, got {}",
                config.fft_size
            )));
        }
        let filter = fdaf_aec::FdafAec::new(config.fft_size, config.step_size);
        let frame_size = config.fft_size / 2;
        Ok(Self {
            filter,
            reference,
            frame_size,
        })
    }

    /// Process a microphone audio chunk through the adaptive filter.
    ///
    /// Drains a matching reference frame and returns the echo-cancelled chunk.
    /// Sub-frame remainders (when the chunk length is not a multiple of
    /// `frame_size`) are passed through unprocessed.
    pub fn process(&mut self, chunk: AudioChunk) -> AudioChunk {
        let mic = &chunk.samples;
        if mic.is_empty() {
            return chunk;
        }

        let mut output = Vec::with_capacity(mic.len());
        let mut offset = 0;

        while offset + self.frame_size <= mic.len() {
            let mic_frame = &mic[offset..offset + self.frame_size];
            let ref_frame = self.reference.drain_frame(self.frame_size);
            let cleaned = self.filter.process(&ref_frame, mic_frame);
            output.extend_from_slice(&cleaned);
            offset += self.frame_size;
        }

        // Pass through any remaining samples that don't fill a complete frame.
        if offset < mic.len() {
            output.extend_from_slice(&mic[offset..]);
        }

        AudioChunk {
            samples: output,
            sample_rate: chunk.sample_rate,
            captured_at: chunk.captured_at,
        }
    }
}

/// Linear-interpolation downsampler (same algorithm as capture.rs).
fn downsample_linear(samples: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
    if src_rate == dst_rate || samples.is_empty() {
        return samples.to_vec();
    }

    let ratio = src_rate as f64 / dst_rate as f64;
    let out_len = (samples.len() as f64 / ratio) as usize;
    let mut output = Vec::with_capacity(out_len);

    for i in 0..out_len {
        let src_pos = i as f64 * ratio;
        let idx = src_pos as usize;
        let frac = src_pos - idx as f64;

        let sample = if idx + 1 < samples.len() {
            samples[idx] as f64 * (1.0 - frac) + samples[idx + 1] as f64 * frac
        } else {
            samples[idx.min(samples.len() - 1)] as f64
        };

        output.push(sample as f32);
    }

    output
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use std::time::Instant;

    fn make_chunk(samples: Vec<f32>, rate: u32) -> AudioChunk {
        AudioChunk {
            samples,
            sample_rate: rate,
            captured_at: Instant::now(),
        }
    }

    fn default_config() -> AecConfig {
        AecConfig {
            enabled: true,
            fft_size: 1024,
            step_size: 0.05,
        }
    }

    // ── AecProcessor ─────────────────────────────────────────────

    #[test]
    fn passthrough_with_no_reference() {
        // When no reference audio is pushed, the AEC should pass through
        // the microphone signal largely unchanged (zero reference = zero echo).
        let ref_buf = ReferenceBuffer::new(24_000, 16_000);
        let config = default_config();
        let mut proc = match AecProcessor::new(&config, ref_buf) {
            Ok(p) => p,
            Err(e) => panic!("failed to create AecProcessor: {e}"),
        };

        // 512-sample frame of a constant tone.
        let mic: Vec<f32> = (0..512).map(|i| (i as f32 * 0.01).sin()).collect();
        let chunk = make_chunk(mic.clone(), 16_000);
        let out = proc.process(chunk);

        assert_eq!(out.samples.len(), 512);
        // With zero reference, output should be close to input.
        let diff_rms = rms_diff(&mic, &out.samples);
        assert!(diff_rms < 0.1, "passthrough diff too large: {diff_rms:.4}");
    }

    #[test]
    fn echo_cancellation_reduces_output() {
        // Feed the same signal as both reference and mic (pure echo).
        // After adaptation, the output should have significantly lower RMS
        // than the input.
        let ref_buf = ReferenceBuffer::new(16_000, 16_000); // same rate for simplicity
        let config = AecConfig {
            enabled: true,
            fft_size: 1024,
            step_size: 0.1, // faster adaptation for test
        };
        let mut proc = match AecProcessor::new(&config, ref_buf.handle().as_ref_buf()) {
            Ok(p) => p,
            Err(e) => panic!("failed to create AecProcessor: {e}"),
        };

        let frame_size = 512;
        // Run several frames to let the filter adapt.
        let mut last_out_rms = f32::MAX;
        for iteration in 0..20 {
            let signal: Vec<f32> = (0..frame_size)
                .map(|i| {
                    let t = (iteration * frame_size + i) as f32 / 16_000.0;
                    (2.0 * std::f32::consts::PI * 440.0 * t).sin() * 0.5
                })
                .collect();

            // Push the signal as reference.
            ref_buf.push_direct(&signal);

            // Process the same signal as mic input (simulating pure echo).
            let chunk = make_chunk(signal, 16_000);
            let out = proc.process(chunk);
            last_out_rms = rms(&out.samples);
        }

        // After 20 frames of adaptation, the echo should be reduced.
        let input_rms = 0.5 / f32::sqrt(2.0); // RMS of 0.5*sin
        assert!(
            last_out_rms < input_rms * 0.8,
            "echo not sufficiently reduced: out_rms={last_out_rms:.4}, in_rms={input_rms:.4}"
        );
    }

    #[test]
    fn disabled_config_still_creates_processor() {
        // The processor itself doesn't care about the `enabled` flag —
        // that's checked at the pipeline level.
        let ref_buf = ReferenceBuffer::new(24_000, 16_000);
        let config = AecConfig {
            enabled: false,
            ..default_config()
        };
        assert!(AecProcessor::new(&config, ref_buf).is_ok());
    }

    #[test]
    fn invalid_fft_size_returns_error() {
        let ref_buf = ReferenceBuffer::new(24_000, 16_000);

        // Not a power of two.
        let config = AecConfig {
            fft_size: 1000,
            ..default_config()
        };
        assert!(AecProcessor::new(&config, ref_buf).is_err());
    }

    #[test]
    fn zero_fft_size_returns_error() {
        let ref_buf = ReferenceBuffer::new(24_000, 16_000);
        let config = AecConfig {
            fft_size: 0,
            ..default_config()
        };
        assert!(AecProcessor::new(&config, ref_buf).is_err());
    }

    #[test]
    fn sub_frame_remainder_passed_through() {
        // Chunk with 600 samples (512 full frame + 88 remainder).
        let ref_buf = ReferenceBuffer::new(24_000, 16_000);
        let config = default_config();
        let mut proc = match AecProcessor::new(&config, ref_buf) {
            Ok(p) => p,
            Err(e) => panic!("failed to create AecProcessor: {e}"),
        };

        let mic: Vec<f32> = (0..600).map(|i| i as f32 * 0.001).collect();
        let chunk = make_chunk(mic, 16_000);
        let out = proc.process(chunk);

        assert_eq!(out.samples.len(), 600);
    }

    #[test]
    fn empty_chunk_passthrough() {
        let ref_buf = ReferenceBuffer::new(24_000, 16_000);
        let config = default_config();
        let mut proc = match AecProcessor::new(&config, ref_buf) {
            Ok(p) => p,
            Err(e) => panic!("failed to create AecProcessor: {e}"),
        };

        let chunk = make_chunk(Vec::new(), 16_000);
        let out = proc.process(chunk);
        assert!(out.samples.is_empty());
    }

    // ── ReferenceBuffer ──────────────────────────────────────────

    #[test]
    fn reference_buffer_resampling() {
        let buf = ReferenceBuffer::new(24_000, 16_000);
        let handle = buf.handle();

        // Push 2400 samples at 24kHz → should become ~1600 at 16kHz.
        let input: Vec<f32> = (0..2400).map(|i| i as f32 / 2400.0).collect();
        handle.push(&input);

        let drained = buf.drain_frame(1600);
        assert_eq!(drained.len(), 1600);
        // Should have meaningful (non-zero) content.
        let non_zero = drained.iter().filter(|&&s| s.abs() > 1e-6).count();
        assert!(
            non_zero > 1000,
            "expected mostly non-zero samples after resampling"
        );
    }

    #[test]
    fn reference_buffer_zero_fill() {
        let buf = ReferenceBuffer::new(24_000, 16_000);
        // Drain without pushing anything — should get zeros.
        let drained = buf.drain_frame(512);
        assert_eq!(drained.len(), 512);
        assert!(drained.iter().all(|&s| s == 0.0));
    }

    #[test]
    fn reference_buffer_overflow_caps_at_2s() {
        let buf = ReferenceBuffer::new(16_000, 16_000); // same rate for simplicity
        let handle = buf.handle();

        // Push 3 seconds of audio into a 2-second buffer.
        let big: Vec<f32> = vec![1.0; 48_000];
        handle.push(&big);

        let inner = buf.inner.lock().map(|b| b.len()).unwrap_or(0);
        let cap = 16_000 * 2;
        assert!(inner <= cap, "buffer exceeded 2s cap: {inner} > {cap}");
    }

    #[test]
    fn reference_buffer_clear() {
        let buf = ReferenceBuffer::new(16_000, 16_000);
        let handle = buf.handle();
        handle.push(&[1.0; 1000]);
        buf.clear();
        let drained = buf.drain_frame(100);
        assert!(drained.iter().all(|&s| s == 0.0));
    }

    #[test]
    fn reference_handle_clear() {
        let buf = ReferenceBuffer::new(16_000, 16_000);
        let handle = buf.handle();
        handle.push(&[1.0; 1000]);
        handle.clear();
        let drained = buf.drain_frame(100);
        assert!(drained.iter().all(|&s| s == 0.0));
    }

    // ── downsample_linear ────────────────────────────────────────

    #[test]
    fn downsample_same_rate() {
        let input = vec![1.0, 2.0, 3.0];
        let out = downsample_linear(&input, 16_000, 16_000);
        assert_eq!(out, input);
    }

    #[test]
    fn downsample_empty() {
        let out = downsample_linear(&[], 48_000, 16_000);
        assert!(out.is_empty());
    }

    #[test]
    fn downsample_3x_ratio() {
        // 48kHz → 16kHz is a 3:1 ratio.
        let input: Vec<f32> = (0..480).map(|i| i as f32).collect();
        let out = downsample_linear(&input, 48_000, 16_000);
        assert_eq!(out.len(), 160);
    }

    // ── Test helpers ─────────────────────────────────────────────

    fn rms(samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return 0.0;
        }
        let sum: f32 = samples.iter().map(|s| s * s).sum();
        (sum / samples.len() as f32).sqrt()
    }

    fn rms_diff(a: &[f32], b: &[f32]) -> f32 {
        let len = a.len().min(b.len());
        if len == 0 {
            return 0.0;
        }
        let sum: f32 = a[..len]
            .iter()
            .zip(b[..len].iter())
            .map(|(x, y)| (x - y) * (x - y))
            .sum();
        (sum / len as f32).sqrt()
    }

    // Helpers for test convenience.
    impl ReferenceBuffer {
        /// Push samples directly at capture rate (no resampling), for tests.
        fn push_direct(&self, samples: &[f32]) {
            if let Ok(mut buf) = self.inner.lock() {
                buf.extend(samples.iter());
            }
        }
    }

    impl ReferenceHandle {
        /// Convert handle back into a ReferenceBuffer for test convenience.
        fn as_ref_buf(&self) -> ReferenceBuffer {
            ReferenceBuffer {
                inner: Arc::clone(&self.inner),
                playback_rate: self.playback_rate,
                capture_rate: self.capture_rate,
            }
        }
    }
}
