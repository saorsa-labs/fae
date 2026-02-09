//! Lightweight MFCC-based wake word spotter.
//!
//! Detects a keyword (e.g. "Fae") in a live audio stream by comparing
//! MFCC features of incoming audio against stored reference recordings.
//! Uses DTW (Dynamic Time Warping) for robust time-invariant comparison.
//!
//! No external ML dependencies — built on `rustfft` which is already in
//! the project for AEC.

use crate::config::WakewordConfig;
use crate::error::{Result, SpeechError};
use rustfft::FftPlanner;
use rustfft::num_complex::Complex;
use std::path::{Path, PathBuf};
use tracing::info;

/// Number of MFCC coefficients to extract per frame.
const DEFAULT_NUM_MFCC: usize = 13;
/// FFT window size in samples (25ms at 16kHz).
const FRAME_SIZE: usize = 400;
/// Hop size in samples (10ms at 16kHz).
const HOP_SIZE: usize = 160;
/// Number of mel filter banks.
const NUM_MEL_FILTERS: usize = 26;
/// Expected sample rate. Audio is NOT resampled — caller must provide 16kHz.
const EXPECTED_SAMPLE_RATE: u32 = 16_000;

/// A single wake word reference: a sequence of MFCC frames extracted from
/// a recording of the keyword.
#[derive(Clone)]
struct Reference {
    /// MFCC frames: `[num_frames][num_mfcc]`.
    mfccs: Vec<Vec<f32>>,
}

/// Wake word spotter that compares live audio against reference recordings.
pub struct WakewordSpotter {
    references: Vec<Reference>,
    mel_filterbank: Vec<Vec<f32>>,
    num_mfcc: usize,
    threshold: f32,
    /// Rolling audio buffer: accumulates samples until we have enough for
    /// a detection window (~1 second), then slides forward by `HOP_SIZE`.
    audio_buffer: Vec<f32>,
    /// Number of samples that constitute one detection window.
    /// Typically ~1s of audio (16000 samples).
    window_samples: usize,
}

impl WakewordSpotter {
    /// Create a new spotter and load reference recordings from disk.
    ///
    /// Reference files are WAV files (16kHz mono) in `references_dir`.
    /// At least one reference is required for detection to work.
    ///
    /// # Errors
    ///
    /// Returns an error if no references can be loaded or the config is invalid.
    pub fn new(config: &WakewordConfig, sample_rate: u32) -> Result<Self> {
        if sample_rate != EXPECTED_SAMPLE_RATE {
            return Err(SpeechError::Config(format!(
                "wakeword spotter requires {EXPECTED_SAMPLE_RATE}Hz audio, got {sample_rate}Hz"
            )));
        }

        let num_mfcc = if config.num_mfcc > 0 {
            config.num_mfcc
        } else {
            DEFAULT_NUM_MFCC
        };

        let mel_filterbank = build_mel_filterbank(NUM_MEL_FILTERS, FRAME_SIZE, sample_rate);
        let references = load_references(&config.references_dir, num_mfcc, &mel_filterbank)?;

        if references.is_empty() {
            return Err(SpeechError::Config(
                "no wake word reference recordings found".into(),
            ));
        }

        info!(
            "wakeword spotter loaded {} references, threshold={}",
            references.len(),
            config.threshold,
        );

        // Detection window: ~1 second of audio. The reference recordings are
        // typically 0.3-0.8s, so 1s gives enough context.
        let window_samples = sample_rate as usize;

        Ok(Self {
            references,
            mel_filterbank,
            num_mfcc,
            threshold: config.threshold,
            audio_buffer: Vec::with_capacity(window_samples + FRAME_SIZE),
            window_samples,
        })
    }

    /// Feed audio samples and check for wake word detection.
    ///
    /// Returns `true` if the wake word was detected in the current window.
    /// The internal buffer slides forward automatically.
    pub fn process(&mut self, samples: &[f32]) -> bool {
        self.audio_buffer.extend_from_slice(samples);

        // Need at least one full window to compare.
        if self.audio_buffer.len() < self.window_samples {
            return false;
        }

        // Extract MFCCs from the current window.
        let window = &self.audio_buffer[self.audio_buffer.len() - self.window_samples..];
        let mfccs = extract_mfccs(window, self.num_mfcc, &self.mel_filterbank);

        if mfccs.is_empty() {
            // Slide buffer forward.
            let drain = self.audio_buffer.len().saturating_sub(self.window_samples);
            if drain > 0 {
                self.audio_buffer.drain(..drain);
            }
            return false;
        }

        // Compare against each reference using DTW. Take the best (lowest) distance.
        let mut best_score: f32 = 0.0;
        for reference in &self.references {
            let dist = dtw_distance(&mfccs, &reference.mfccs);
            // Convert distance to a 0-1 score: score = 1 / (1 + dist).
            let score = 1.0 / (1.0 + dist);
            if score > best_score {
                best_score = score;
            }
        }

        // Slide buffer forward by half a window so we overlap.
        let drain_amount = self.window_samples / 2;
        if self.audio_buffer.len() > drain_amount {
            self.audio_buffer.drain(..drain_amount);
        }

        best_score >= self.threshold
    }

    /// Clear the internal audio buffer (e.g. after a detection or on reset).
    pub fn clear(&mut self) {
        self.audio_buffer.clear();
    }

    /// Returns the number of loaded references.
    #[must_use]
    pub fn reference_count(&self) -> usize {
        self.references.len()
    }
}

/// Load reference WAV files from a directory and extract MFCC features.
fn load_references(
    dir: &Path,
    num_mfcc: usize,
    mel_filterbank: &[Vec<f32>],
) -> Result<Vec<Reference>> {
    if !dir.exists() {
        return Ok(Vec::new());
    }

    let mut refs = Vec::new();
    let entries = std::fs::read_dir(dir)
        .map_err(|e| SpeechError::Config(format!("cannot read references dir: {e}")))?;

    for entry in entries {
        let entry =
            entry.map_err(|e| SpeechError::Config(format!("cannot read dir entry: {e}")))?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("wav") {
            continue;
        }

        match load_wav_mono_16k(&path) {
            Ok(samples) => {
                let mfccs = extract_mfccs(&samples, num_mfcc, mel_filterbank);
                if !mfccs.is_empty() {
                    info!("loaded wakeword reference: {}", path.display());
                    refs.push(Reference { mfccs });
                }
            }
            Err(e) => {
                info!("skipping invalid reference {}: {e}", path.display());
            }
        }
    }

    Ok(refs)
}

/// Load a WAV file as mono f32 samples at 16kHz.
fn load_wav_mono_16k(path: &Path) -> Result<Vec<f32>> {
    let mut reader = hound::WavReader::open(path)
        .map_err(|e| SpeechError::Config(format!("cannot open WAV {}: {e}", path.display())))?;

    let spec = reader.spec();
    if spec.sample_rate != EXPECTED_SAMPLE_RATE {
        return Err(SpeechError::Config(format!(
            "reference WAV must be {}Hz, got {}Hz: {}",
            EXPECTED_SAMPLE_RATE,
            spec.sample_rate,
            path.display()
        )));
    }

    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Int => {
            let max = (1i64 << (spec.bits_per_sample - 1)) as f32;
            reader
                .samples::<i32>()
                .map(|s| {
                    s.map_err(|e| SpeechError::Config(format!("WAV read error: {e}")))
                        .map(|v| v as f32 / max)
                })
                .collect::<Result<Vec<f32>>>()?
        }
        hound::SampleFormat::Float => reader
            .samples::<f32>()
            .map(|s| s.map_err(|e| SpeechError::Config(format!("WAV read error: {e}"))))
            .collect::<Result<Vec<f32>>>()?,
    };

    // Mix to mono if stereo.
    if spec.channels > 1 {
        let ch = spec.channels as usize;
        let mono: Vec<f32> = samples
            .chunks(ch)
            .map(|frame| frame.iter().sum::<f32>() / ch as f32)
            .collect();
        Ok(mono)
    } else {
        Ok(samples)
    }
}

// ── MFCC extraction ─────────────────────────────────────────────────

/// Extract MFCC features from audio samples.
///
/// Returns a sequence of MFCC vectors, one per frame (10ms hop).
fn extract_mfccs(samples: &[f32], num_mfcc: usize, mel_filterbank: &[Vec<f32>]) -> Vec<Vec<f32>> {
    if samples.len() < FRAME_SIZE {
        return Vec::new();
    }

    let num_frames = (samples.len() - FRAME_SIZE) / HOP_SIZE + 1;
    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(FRAME_SIZE);

    let mut frames = Vec::with_capacity(num_frames);

    for i in 0..num_frames {
        let start = i * HOP_SIZE;
        let end = start + FRAME_SIZE;
        if end > samples.len() {
            break;
        }

        // Apply Hann window.
        let mut windowed: Vec<Complex<f32>> = samples[start..end]
            .iter()
            .enumerate()
            .map(|(n, &s)| {
                let w = 0.5
                    * (1.0
                        - (2.0 * std::f32::consts::PI * n as f32 / (FRAME_SIZE - 1) as f32).cos());
                Complex::new(s * w, 0.0)
            })
            .collect();

        // FFT.
        fft.process(&mut windowed);

        // Power spectrum (only first half + DC).
        let power_len = FRAME_SIZE / 2 + 1;
        let power: Vec<f32> = windowed[..power_len]
            .iter()
            .map(|c| (c.re * c.re + c.im * c.im) / FRAME_SIZE as f32)
            .collect();

        // Apply mel filterbank.
        let mel_energies: Vec<f32> = mel_filterbank
            .iter()
            .map(|filter| {
                let energy: f32 = filter.iter().zip(power.iter()).map(|(&f, &p)| f * p).sum();
                // Log energy (with floor to avoid log(0)).
                (energy.max(1e-10)).ln()
            })
            .collect();

        // DCT-II to get MFCCs.
        let mfcc = dct_ii(&mel_energies, num_mfcc);
        frames.push(mfcc);
    }

    frames
}

/// Build mel-spaced triangular filterbank.
fn build_mel_filterbank(num_filters: usize, fft_size: usize, sample_rate: u32) -> Vec<Vec<f32>> {
    let power_len = fft_size / 2 + 1;
    let low_freq_mel = hz_to_mel(0.0);
    let high_freq_mel = hz_to_mel(sample_rate as f32 / 2.0);

    // Equally spaced mel points.
    let num_points = num_filters + 2;
    let mel_points: Vec<f32> = (0..num_points)
        .map(|i| low_freq_mel + (high_freq_mel - low_freq_mel) * i as f32 / (num_points - 1) as f32)
        .collect();

    let hz_points: Vec<f32> = mel_points.iter().map(|&m| mel_to_hz(m)).collect();

    // Convert Hz to FFT bin indices.
    let bin_points: Vec<usize> = hz_points
        .iter()
        .map(|&hz| ((fft_size as f32 + 1.0) * hz / sample_rate as f32).floor() as usize)
        .collect();

    let mut filterbank = Vec::with_capacity(num_filters);
    for m in 0..num_filters {
        let mut filter = vec![0.0f32; power_len];
        let left = bin_points[m];
        let center = bin_points[m + 1];
        let right = bin_points[m + 2];

        // Rising slope.
        if center > left {
            let denom = (center - left) as f32;
            for (i, val) in filter.iter_mut().enumerate().take(center).skip(left) {
                if i < power_len {
                    *val = (i - left) as f32 / denom;
                }
            }
        }
        // Falling slope.
        if right > center {
            let denom = (right - center) as f32;
            for (i, val) in filter.iter_mut().enumerate().take(right + 1).skip(center) {
                if i < power_len {
                    *val = (right - i) as f32 / denom;
                }
            }
        }

        filterbank.push(filter);
    }

    filterbank
}

/// DCT-II: extract `num_coeffs` coefficients from `input`.
fn dct_ii(input: &[f32], num_coeffs: usize) -> Vec<f32> {
    let n = input.len();
    let mut result = Vec::with_capacity(num_coeffs);
    for k in 0..num_coeffs {
        let mut sum = 0.0f32;
        for (i, &val) in input.iter().enumerate() {
            sum +=
                val * (std::f32::consts::PI * k as f32 * (2 * i + 1) as f32 / (2 * n) as f32).cos();
        }
        result.push(sum);
    }
    result
}

/// Convert frequency in Hz to mel scale.
fn hz_to_mel(hz: f32) -> f32 {
    2595.0 * (1.0 + hz / 700.0).log10()
}

/// Convert mel scale to Hz.
fn mel_to_hz(mel: f32) -> f32 {
    700.0 * (10.0_f32.powf(mel / 2595.0) - 1.0)
}

// ── DTW (Dynamic Time Warping) ──────────────────────────────────────

/// Compute DTW distance between two MFCC sequences.
///
/// Uses standard DTW with Euclidean distance between MFCC vectors.
/// The reference sequence is typically shorter (0.3-0.8s) and the input
/// is longer (~1s window), so DTW handles the time alignment naturally.
fn dtw_distance(input: &[Vec<f32>], reference: &[Vec<f32>]) -> f32 {
    let n = input.len();
    let m = reference.len();

    if n == 0 || m == 0 {
        return f32::MAX;
    }

    // Cost matrix. Using a flat vec for cache-friendliness.
    let mut cost = vec![f32::MAX; (n + 1) * (m + 1)];
    let idx = |i: usize, j: usize| i * (m + 1) + j;

    cost[idx(0, 0)] = 0.0;

    for i in 1..=n {
        for j in 1..=m {
            let d = euclidean_distance(&input[i - 1], &reference[j - 1]);
            let prev = cost[idx(i - 1, j)]
                .min(cost[idx(i, j - 1)])
                .min(cost[idx(i - 1, j - 1)]);
            cost[idx(i, j)] = d + prev;
        }
    }

    // Normalize by path length.
    cost[idx(n, m)] / (n + m) as f32
}

/// Euclidean distance between two MFCC vectors.
fn euclidean_distance(a: &[f32], b: &[f32]) -> f32 {
    a.iter()
        .zip(b.iter())
        .map(|(&x, &y)| (x - y) * (x - y))
        .sum::<f32>()
        .sqrt()
}

// ── Utility: record references ──────────────────────────────────────

/// Save audio samples as a 16kHz mono WAV reference file.
///
/// # Errors
///
/// Returns an error if the file cannot be written.
pub fn save_reference_wav(path: &Path, samples: &[f32], sample_rate: u32) -> Result<()> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec)
        .map_err(|e| SpeechError::Config(format!("cannot create WAV: {e}")))?;

    for &s in samples {
        let sample_i16 = (s * 32767.0).clamp(-32768.0, 32767.0) as i16;
        writer
            .write_sample(sample_i16)
            .map_err(|e| SpeechError::Config(format!("WAV write error: {e}")))?;
    }
    writer
        .finalize()
        .map_err(|e| SpeechError::Config(format!("WAV finalize error: {e}")))?;

    Ok(())
}

/// Returns the default directory for wake word reference recordings.
#[must_use]
pub fn default_references_dir(memory_root: &Path) -> PathBuf {
    memory_root.join("wakeword")
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn hz_to_mel_and_back() {
        let hz = 1000.0;
        let mel = hz_to_mel(hz);
        let back = mel_to_hz(mel);
        assert!(
            (hz - back).abs() < 0.1,
            "round-trip failed: {hz} -> {mel} -> {back}"
        );
    }

    #[test]
    fn mel_filterbank_shape() {
        let fb = build_mel_filterbank(NUM_MEL_FILTERS, FRAME_SIZE, EXPECTED_SAMPLE_RATE);
        assert_eq!(fb.len(), NUM_MEL_FILTERS);
        for filter in &fb {
            assert_eq!(filter.len(), FRAME_SIZE / 2 + 1);
        }
    }

    #[test]
    fn mel_filterbank_non_negative() {
        let fb = build_mel_filterbank(NUM_MEL_FILTERS, FRAME_SIZE, EXPECTED_SAMPLE_RATE);
        for filter in &fb {
            for &v in filter {
                assert!(v >= 0.0, "negative filter value: {v}");
            }
        }
    }

    #[test]
    fn dct_ii_basic() {
        let input = vec![1.0, 2.0, 3.0, 4.0];
        let result = dct_ii(&input, 3);
        assert_eq!(result.len(), 3);
        // First coefficient is the sum (DC component).
        let expected_dc: f32 = input.iter().sum();
        assert!(
            (result[0] - expected_dc).abs() < 0.01,
            "DC coeff should be sum: got {} expected {}",
            result[0],
            expected_dc
        );
    }

    #[test]
    fn extract_mfccs_empty_audio() {
        let fb = build_mel_filterbank(NUM_MEL_FILTERS, FRAME_SIZE, EXPECTED_SAMPLE_RATE);
        let result = extract_mfccs(&[], DEFAULT_NUM_MFCC, &fb);
        assert!(result.is_empty());
    }

    #[test]
    fn extract_mfccs_short_audio() {
        let fb = build_mel_filterbank(NUM_MEL_FILTERS, FRAME_SIZE, EXPECTED_SAMPLE_RATE);
        // Shorter than one frame.
        let samples = vec![0.0; FRAME_SIZE - 1];
        let result = extract_mfccs(&samples, DEFAULT_NUM_MFCC, &fb);
        assert!(result.is_empty());
    }

    #[test]
    fn extract_mfccs_one_frame() {
        let fb = build_mel_filterbank(NUM_MEL_FILTERS, FRAME_SIZE, EXPECTED_SAMPLE_RATE);
        // Exactly one frame of silence.
        let samples = vec![0.0; FRAME_SIZE];
        let result = extract_mfccs(&samples, DEFAULT_NUM_MFCC, &fb);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].len(), DEFAULT_NUM_MFCC);
    }

    #[test]
    fn extract_mfccs_multiple_frames() {
        let fb = build_mel_filterbank(NUM_MEL_FILTERS, FRAME_SIZE, EXPECTED_SAMPLE_RATE);
        // 0.5 seconds at 16kHz.
        let samples = vec![0.0; 8000];
        let result = extract_mfccs(&samples, DEFAULT_NUM_MFCC, &fb);
        // Expected frames: (8000 - 400) / 160 + 1 = 48.
        assert_eq!(result.len(), 48);
    }

    #[test]
    fn dtw_identical_sequences() {
        let seq = vec![vec![1.0, 2.0, 3.0], vec![4.0, 5.0, 6.0]];
        let dist = dtw_distance(&seq, &seq);
        assert!(
            dist.abs() < 0.001,
            "identical sequences should have ~0 distance: {dist}"
        );
    }

    #[test]
    fn dtw_different_sequences() {
        let a = vec![vec![0.0, 0.0], vec![0.0, 0.0]];
        let b = vec![vec![10.0, 10.0], vec![10.0, 10.0]];
        let dist = dtw_distance(&a, &b);
        assert!(
            dist > 1.0,
            "different sequences should have large distance: {dist}"
        );
    }

    #[test]
    fn dtw_empty_input() {
        let a: Vec<Vec<f32>> = Vec::new();
        let b = vec![vec![1.0]];
        assert_eq!(dtw_distance(&a, &b), f32::MAX);
        assert_eq!(dtw_distance(&b, &a), f32::MAX);
    }

    #[test]
    fn dtw_different_lengths() {
        // DTW should handle sequences of different lengths.
        let short = vec![vec![1.0, 2.0]];
        let long = vec![vec![1.0, 2.0], vec![1.0, 2.0], vec![1.0, 2.0]];
        let dist = dtw_distance(&long, &short);
        assert!(dist < 0.001, "repeated pattern should match: {dist}");
    }

    #[test]
    fn euclidean_distance_zero() {
        let a = vec![1.0, 2.0, 3.0];
        assert!(euclidean_distance(&a, &a).abs() < f32::EPSILON);
    }

    #[test]
    fn euclidean_distance_known() {
        let a = vec![0.0, 0.0];
        let b = vec![3.0, 4.0];
        assert!((euclidean_distance(&a, &b) - 5.0).abs() < 0.001);
    }

    #[test]
    fn score_conversion() {
        // Score = 1 / (1 + dist). dist=0 → score=1, dist=∞ → score→0.
        let score_zero = 1.0 / (1.0 + 0.0_f32);
        assert!((score_zero - 1.0).abs() < f32::EPSILON);

        let score_large = 1.0 / (1.0 + 100.0_f32);
        assert!(score_large < 0.01);
    }

    #[test]
    fn save_reference_wav_roundtrip() {
        let dir = std::env::temp_dir().join("fae-wakeword-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("test_ref.wav");

        // Generate a short tone.
        let sample_rate = 16_000;
        let samples: Vec<f32> = (0..sample_rate)
            .map(|i| (2.0 * std::f32::consts::PI * 440.0 * i as f32 / sample_rate as f32).sin())
            .collect();

        save_reference_wav(&path, &samples, sample_rate).unwrap();
        assert!(path.exists());

        // Load it back and verify length.
        let loaded = load_wav_mono_16k(&path).unwrap();
        assert_eq!(loaded.len(), samples.len());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
