//! Simple, model-free voiceprint extraction for best-effort speaker matching.
//!
//! This is not "secure" speaker verification. It's a lightweight heuristic that
//! helps Fae respond primarily to an enrolled voice, without shipping an extra
//! ML model. Expect false positives/negatives in noisy environments.

use crate::error::{Result, SpeechError};
use rustfft::FftPlanner;
use rustfft::num_complex::Complex32;

/// Voiceprint feature vector size.
///
/// Keep this small since it can be cloned into pipeline messages and persisted
/// in markdown memory files.
pub const VOICEPRINT_DIMS: usize = 64;

/// Compute a normalized voiceprint feature vector (length [`VOICEPRINT_DIMS`]).
///
/// - Resamples to 16kHz (naive linear interpolation) for stable bin mapping.
/// - Computes averaged log-magnitude spectrum in ~300-3400Hz range.
/// - Groups bins into [`VOICEPRINT_DIMS`] buckets and L2-normalizes.
pub fn compute_voiceprint(samples: &[f32], sample_rate: u32) -> Result<Vec<f32>> {
    if samples.is_empty() {
        return Err(SpeechError::Memory(
            "cannot compute voiceprint from empty audio".into(),
        ));
    }

    let mono = if sample_rate == 16_000 {
        samples.to_owned()
    } else {
        resample_linear(samples, sample_rate, 16_000)
            .map_err(|e| SpeechError::Memory(format!("voiceprint resample failed: {e}")))?
    };

    let frame_len: usize = 400; // 25ms @ 16k
    let hop: usize = 160; // 10ms @ 16k
    let fft_len: usize = 512;
    let nyquist_bins = fft_len / 2;

    let min_hz = 300.0f32;
    let max_hz = 3400.0f32;

    let hz_per_bin = 16_000.0f32 / fft_len as f32;
    let mut min_bin = (min_hz / hz_per_bin).floor() as usize;
    let mut max_bin = (max_hz / hz_per_bin).ceil() as usize;
    if min_bin >= nyquist_bins {
        min_bin = nyquist_bins.saturating_sub(1);
    }
    if max_bin > nyquist_bins {
        max_bin = nyquist_bins;
    }
    if max_bin <= min_bin + 1 {
        return Err(SpeechError::Memory(
            "voiceprint frequency range is too small".into(),
        ));
    }

    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(fft_len);

    let window = hamming_window(frame_len);
    let mut acc = vec![0.0f32; VOICEPRINT_DIMS];
    let mut frames: usize = 0;

    let mut buf = vec![Complex32::new(0.0, 0.0); fft_len];

    let mut pos = 0usize;
    while pos + frame_len <= mono.len() {
        for (i, w) in window.iter().enumerate() {
            buf[i] = Complex32::new(mono[pos + i] * *w, 0.0);
        }
        for c in buf.iter_mut().skip(frame_len) {
            *c = Complex32::new(0.0, 0.0);
        }

        fft.process(&mut buf);

        // Accumulate grouped log magnitudes.
        let band_bins = max_bin - min_bin;
        for (b, acc_b) in acc.iter_mut().enumerate() {
            let start = min_bin + (b * band_bins) / VOICEPRINT_DIMS;
            let end = min_bin + ((b + 1) * band_bins) / VOICEPRINT_DIMS;
            if end <= start {
                continue;
            }
            let mut sum = 0.0f32;
            let mut n = 0usize;
            for c in buf.iter().take(end).skip(start) {
                let mag = (c.re * c.re + c.im * c.im).sqrt();
                sum += (1.0f32 + mag).ln();
                n = n.saturating_add(1);
            }
            if n > 0 {
                *acc_b += sum / n as f32;
            }
        }

        frames = frames.saturating_add(1);
        pos = pos.saturating_add(hop);
    }

    if frames == 0 {
        return Err(SpeechError::Memory(
            "not enough audio to compute voiceprint".into(),
        ));
    }

    for v in &mut acc {
        *v /= frames as f32;
    }

    l2_normalize(&mut acc);
    Ok(acc)
}

/// Cosine similarity for normalized voiceprints (range ~[-1, 1]).
#[must_use]
pub fn similarity(a: &[f32], b: &[f32]) -> Option<f32> {
    if a.len() != b.len() || a.is_empty() {
        return None;
    }
    let mut dot = 0.0f32;
    for (x, y) in a.iter().zip(b.iter()) {
        dot += *x * *y;
    }
    Some(dot)
}

fn resample_linear(samples: &[f32], in_rate: u32, out_rate: u32) -> Result<Vec<f32>> {
    if in_rate == 0 || out_rate == 0 {
        return Err(SpeechError::Memory("invalid sample rate".into()));
    }
    if samples.is_empty() {
        return Ok(Vec::new());
    }

    let ratio = out_rate as f64 / in_rate as f64;
    let out_len = ((samples.len() as f64) * ratio).round() as usize;
    if out_len == 0 {
        return Ok(Vec::new());
    }

    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = (i as f64) / ratio;
        let idx0 = src.floor() as isize;
        let idx1 = idx0 + 1;
        let frac = (src - src.floor()) as f32;

        let s0 = if idx0 < 0 {
            samples[0]
        } else {
            let u = idx0 as usize;
            samples
                .get(u)
                .copied()
                .unwrap_or_else(|| samples[samples.len() - 1])
        };
        let s1 = if idx1 < 0 {
            samples[0]
        } else {
            let u = idx1 as usize;
            samples
                .get(u)
                .copied()
                .unwrap_or_else(|| samples[samples.len() - 1])
        };

        out.push(s0 + (s1 - s0) * frac);
    }
    Ok(out)
}

fn hamming_window(n: usize) -> Vec<f32> {
    if n == 0 {
        return Vec::new();
    }
    let mut w = Vec::with_capacity(n);
    let denom = (n - 1).max(1) as f32;
    for i in 0..n {
        let x = i as f32 / denom;
        // 0.54 - 0.46*cos(2*pi*x)
        w.push(0.54 - 0.46 * (2.0 * std::f32::consts::PI * x).cos());
    }
    w
}

fn l2_normalize(v: &mut [f32]) {
    let mut sum = 0.0f32;
    for x in v.iter() {
        sum += *x * *x;
    }
    let norm = sum.sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
}
