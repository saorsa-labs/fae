//! `PiperTtsAdapter` — Piper neural TTS via a SHA-pinned sidecar (P5/D2-V5).
//!
//! The Linux TTS lane (ADR-010): macOS keeps Kokoro/`voice-tts` (mlx-rs); every
//! non-macOS target runs the `piper` prebuilt binary (bundled ONNX Runtime +
//! espeak-ng) as a child process — text in on stdin, a 22.05 kHz WAV out. This
//! adapter resamples that to the project's 24 kHz `TtsAudio` contract.
//!
//! The binary + voice model are integrity-gated (confinement + existence + SHA)
//! by the daemon BEFORE this adapter is constructed, exactly as the llama-server
//! runtime is gated before the llama.cpp engine. This adapter is the executor:
//! it never silently emits silence — a missing binary, a non-zero exit, or an
//! unreadable WAV is a loud `EngineError::Inference`.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use async_trait::async_trait;
use tokio::io::AsyncWriteExt;

use crate::provider::{AdapterInfo, EngineError};
use crate::tts::{encode_wav_pcm16, TtsAdapter, TtsAudio};

/// The 24 kHz mono PCM16 contract the rest of the pipeline expects (matches
/// Kokoro on macOS, so playback + `audio.level` behave identically on Linux).
const TARGET_SAMPLE_RATE: u32 = 24_000;

/// Piper's `--length_scale` default. Lower = faster speech, higher = slower, so
/// the pipeline `speed` factor maps inversely. Clamp to a sane band so an
/// out-of-range speed can't produce garbage or a hung synth.
const MIN_SPEED: f32 = 0.5;
const MAX_SPEED: f32 = 2.0;

/// A Piper voice + binary behind the [`TtsAdapter`] contract.
///
/// All paths are resolved + integrity-verified by the daemon before this is
/// built. `espeak_data` is the `espeak-ng-data` dir shipped alongside the
/// binary; passing it explicitly avoids depending on the process CWD.
pub struct PiperTtsAdapter {
    binary: PathBuf,
    model_onnx: PathBuf,
    model_config: PathBuf,
    espeak_data: Option<PathBuf>,
    model_id: String,
}

impl PiperTtsAdapter {
    /// Build an adapter over already-verified paths. `model_id` is for status +
    /// audit only (e.g. the voice name).
    #[must_use]
    pub fn new(
        binary: PathBuf,
        model_onnx: PathBuf,
        model_config: PathBuf,
        espeak_data: Option<PathBuf>,
        model_id: impl Into<String>,
    ) -> PiperTtsAdapter {
        PiperTtsAdapter {
            binary,
            model_onnx,
            model_config,
            espeak_data,
            model_id: model_id.into(),
        }
    }
}

#[async_trait]
impl TtsAdapter for PiperTtsAdapter {
    fn describe(&self) -> AdapterInfo {
        AdapterInfo {
            backend: "piper".to_owned(),
            model_id: self.model_id.clone(),
            // TTS has no text context window.
            context_window: 0,
        }
    }

    async fn synthesize(
        &self,
        text: &str,
        _voice: &str,
        speed: f32,
    ) -> Result<TtsAudio, EngineError> {
        if text.trim().is_empty() {
            return Err(EngineError::Inference("empty text".to_owned()));
        }

        // Piper writes a WAV to --output_file. Use a process-unique temp path so
        // concurrent synths don't collide; clean it up on the way out.
        let out_path = unique_temp_wav();
        // `--length_scale` is inverse speed: 0.8x speed → 1.25 length.
        let length_scale = 1.0 / speed.clamp(MIN_SPEED, MAX_SPEED);

        let mut command = tokio::process::Command::new(&self.binary);
        command
            .arg("--model")
            .arg(&self.model_onnx)
            .arg("--config")
            .arg(&self.model_config)
            .arg("--output_file")
            .arg(&out_path)
            .arg("--length_scale")
            .arg(format!("{length_scale:.4}"))
            .arg("--quiet")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        if let Some(dir) = &self.espeak_data {
            command.arg("--espeak_data").arg(dir);
        }
        // Keep the shipped shared libs (libonnxruntime, libespeak-ng) loadable
        // even if the host's loader path is bare: point it at the binary's dir.
        if let Some(parent) = self.binary.parent() {
            command.env("LD_LIBRARY_PATH", ld_library_path(parent));
        }

        let mut child = command.spawn().map_err(|error| {
            EngineError::Inference(format!("spawn piper {}: {error}", self.binary.display()))
        })?;

        // Pipe the text in, then close stdin so Piper flushes + exits.
        {
            let mut stdin = child
                .stdin
                .take()
                .ok_or_else(|| EngineError::Inference("piper stdin unavailable".to_owned()))?;
            stdin
                .write_all(text.as_bytes())
                .await
                .map_err(|error| EngineError::Inference(format!("write piper stdin: {error}")))?;
            stdin
                .write_all(b"\n")
                .await
                .map_err(|error| EngineError::Inference(format!("write piper stdin: {error}")))?;
        } // stdin dropped here → EOF

        let output = child.wait_with_output().await.map_err(|error| {
            cleanup(&out_path);
            EngineError::Inference(format!("await piper: {error}"))
        })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            cleanup(&out_path);
            return Err(EngineError::Inference(format!(
                "piper exited with {}: {}",
                output.status,
                stderr.trim()
            )));
        }

        let wav_bytes = match std::fs::read(&out_path) {
            Ok(bytes) => bytes,
            Err(error) => {
                cleanup(&out_path);
                return Err(EngineError::Inference(format!(
                    "read piper output {}: {error}",
                    out_path.display()
                )));
            }
        };
        cleanup(&out_path);

        let decoded = decode_wav_pcm16_mono(&wav_bytes)
            .map_err(|reason| EngineError::Inference(format!("decode piper wav: {reason}")))?;
        if decoded.samples.is_empty() {
            return Err(EngineError::Inference(
                "piper produced empty audio".to_owned(),
            ));
        }

        let samples = resample_linear(&decoded.samples, decoded.sample_rate, TARGET_SAMPLE_RATE);
        Ok(TtsAudio {
            wav: encode_wav_pcm16(&samples, TARGET_SAMPLE_RATE),
            sample_rate: TARGET_SAMPLE_RATE,
        })
    }
}

/// Prepend `dir` to any existing `LD_LIBRARY_PATH` so the sidecar's bundled
/// shared libraries resolve without touching the host's loader config.
fn ld_library_path(dir: &Path) -> std::ffi::OsString {
    let mut value = dir.as_os_str().to_owned();
    if let Some(existing) = std::env::var_os("LD_LIBRARY_PATH") {
        if !existing.is_empty() {
            value.push(":");
            value.push(existing);
        }
    }
    value
}

fn unique_temp_wav() -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id();
    std::env::temp_dir().join(format!("fae-piper-{pid}-{nanos}-{seq}.wav"))
}

fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
}

struct DecodedWav {
    samples: Vec<f32>,
    sample_rate: u32,
}

/// Minimal 16-bit PCM mono WAV decoder for Piper's output. Piper emits a
/// canonical RIFF/WAVE PCM16 mono file; anything else is a loud error (we never
/// guess at unknown formats). Self-contained so fae-engine needn't depend on the
/// fae-audio playback layer.
fn decode_wav_pcm16_mono(wav: &[u8]) -> Result<DecodedWav, String> {
    if wav.len() < 44 || &wav[0..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return Err("missing RIFF/WAVE header".to_owned());
    }
    let mut offset = 12_usize;
    let mut fmt: Option<(u16, u16, u32, u16)> = None;
    let mut data: Option<&[u8]> = None;
    while offset.saturating_add(8) <= wav.len() {
        let id = &wav[offset..offset + 4];
        let size = u32::from_le_bytes([
            wav[offset + 4],
            wav[offset + 5],
            wav[offset + 6],
            wav[offset + 7],
        ]) as usize;
        offset = offset.saturating_add(8);
        if offset.saturating_add(size) > wav.len() {
            return Err("chunk exceeds file length".to_owned());
        }
        let chunk = &wav[offset..offset + size];
        if id == b"fmt " {
            if chunk.len() < 16 {
                return Err("short fmt chunk".to_owned());
            }
            let format = u16::from_le_bytes([chunk[0], chunk[1]]);
            let channels = u16::from_le_bytes([chunk[2], chunk[3]]);
            let sample_rate = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
            let bits = u16::from_le_bytes([chunk[14], chunk[15]]);
            fmt = Some((format, channels, sample_rate, bits));
        } else if id == b"data" {
            data = Some(chunk);
        }
        // Chunks are word-aligned: skip a pad byte after odd-sized chunks.
        offset = offset.saturating_add(size + (size % 2));
    }
    let (format, channels, sample_rate, bits) = fmt.ok_or("missing fmt chunk")?;
    let data = data.ok_or("missing data chunk")?;
    if format != 1 || bits != 16 {
        return Err(format!(
            "unsupported wav format (format={format}, bits={bits}); expected PCM16"
        ));
    }
    if channels == 0 {
        return Err("zero channels".to_owned());
    }
    let channels = usize::from(channels);
    let frame_bytes = channels.saturating_mul(2);
    if frame_bytes == 0 || data.len() % frame_bytes != 0 {
        return Err("misaligned pcm data".to_owned());
    }
    // Downmix to mono by averaging channels (Piper is mono, but be defensive).
    let mut samples = Vec::with_capacity(data.len() / frame_bytes);
    for frame in data.chunks_exact(frame_bytes) {
        let mut acc = 0.0_f32;
        for ch in 0..channels {
            let lo = frame[ch * 2];
            let hi = frame[ch * 2 + 1];
            acc += f32::from(i16::from_le_bytes([lo, hi])) / 32768.0;
        }
        samples.push(acc / channels as f32);
    }
    Ok(DecodedWav {
        samples,
        sample_rate,
    })
}

/// Linear-interpolation resampler (same shape as `fae-audio::resample_linear`).
fn resample_linear(input: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if input.is_empty() || from_rate == 0 || to_rate == 0 {
        return Vec::new();
    }
    if from_rate == to_rate {
        return input.to_vec();
    }
    let out_len_u64 = (input.len() as u64)
        .saturating_mul(u64::from(to_rate))
        .div_ceil(u64::from(from_rate));
    let out_len = usize::try_from(out_len_u64)
        .unwrap_or(usize::MAX)
        .min(usize::MAX / 2);
    let ratio = from_rate as f64 / to_rate as f64;
    let mut output = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = i as f64 * ratio;
        let left = src.floor() as usize;
        let frac = (src - left as f64) as f32;
        let a = input.get(left).copied().unwrap_or(0.0);
        let b = input.get(left.saturating_add(1)).copied().unwrap_or(a);
        output.push(a.mul_add(1.0 - frac, b * frac));
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a canonical PCM16 mono WAV from samples for decode tests.
    fn pcm16_mono_wav(samples: &[f32], sample_rate: u32) -> Vec<u8> {
        encode_wav_pcm16(samples, sample_rate)
    }

    #[test]
    fn decodes_pcm16_mono_roundtrip() -> Result<(), String> {
        let input = [0.0_f32, 0.5, -0.5, 0.25];
        let wav = pcm16_mono_wav(&input, 22_050);
        let decoded = decode_wav_pcm16_mono(&wav)?;
        assert_eq!(decoded.sample_rate, 22_050);
        assert_eq!(decoded.samples.len(), input.len());
        // 16-bit quantisation: within ~1/32768.
        for (got, want) in decoded.samples.iter().zip(input.iter()) {
            assert!((got - want).abs() < 1e-3, "got {got}, want {want}");
        }
        Ok(())
    }

    #[test]
    fn decode_rejects_non_pcm16_and_garbage() {
        // Float32 WAV (format=3) is rejected — we only accept Piper's PCM16.
        let mut wav = pcm16_mono_wav(&[0.1, 0.2], 22_050);
        wav[20] = 3; // format tag → IEEE float
        assert!(decode_wav_pcm16_mono(&wav).is_err());
        // Not a RIFF file at all.
        assert!(decode_wav_pcm16_mono(b"not a wav").is_err());
        // Header only, no data chunk.
        assert!(decode_wav_pcm16_mono(&wav[0..12]).is_err());
    }

    #[test]
    fn resample_22050_to_24000_grows_length_and_preserves_endpoints() {
        let input: Vec<f32> = (0..2205).map(|i| (i as f32 / 100.0).sin()).collect();
        let out = resample_linear(&input, 22_050, 24_000);
        // 22050 → 24000 over 0.1s ≈ 2400 samples.
        assert!(
            (out.len() as i64 - 2400).abs() <= 2,
            "resampled len {} not ≈2400",
            out.len()
        );
        assert!((out[0] - input[0]).abs() < 1e-4);
    }

    #[test]
    fn length_scale_is_inverse_speed_and_clamped() {
        // The mapping the adapter uses: length_scale = 1 / clamp(speed).
        let ls = |speed: f32| 1.0 / speed.clamp(MIN_SPEED, MAX_SPEED);
        assert!((ls(1.0) - 1.0).abs() < 1e-6);
        assert!(ls(2.0) < ls(1.0)); // faster speech = shorter phonemes
        assert!(ls(0.5) > ls(1.0)); // slower speech = longer phonemes
                                    // Out-of-band speeds are clamped, not propagated raw.
        assert!((ls(10.0) - ls(MAX_SPEED)).abs() < 1e-6);
        assert!((ls(0.01) - ls(MIN_SPEED)).abs() < 1e-6);
    }

    #[tokio::test]
    async fn synthesize_rejects_empty_text_without_spawning() {
        // A non-existent binary path proves we error on empty text BEFORE spawn.
        let adapter = PiperTtsAdapter::new(
            PathBuf::from("/nonexistent/piper"),
            PathBuf::from("/nonexistent/voice.onnx"),
            PathBuf::from("/nonexistent/voice.onnx.json"),
            None,
            "en_US-lessac-medium",
        );
        let err = adapter.synthesize("   ", "lessac", 1.0).await.unwrap_err();
        assert!(matches!(err, EngineError::Inference(_)));
    }

    #[tokio::test]
    async fn synthesize_fails_loud_when_binary_missing() {
        // The integrity gate runs in the daemon; if a bad path still reaches the
        // adapter, it must error loudly — never return silence.
        let adapter = PiperTtsAdapter::new(
            PathBuf::from("/nonexistent/piper-binary"),
            PathBuf::from("/nonexistent/voice.onnx"),
            PathBuf::from("/nonexistent/voice.onnx.json"),
            None,
            "en_US-lessac-medium",
        );
        let err = adapter
            .synthesize("hello", "lessac", 1.0)
            .await
            .unwrap_err();
        match err {
            EngineError::Inference(msg) => assert!(
                msg.contains("spawn piper"),
                "unexpected error message: {msg}"
            ),
            other => panic!("expected Inference error, got {other:?}"),
        }
    }
}
