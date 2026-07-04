//! Daemon-side TTS (S19) — the backend-agnostic synthesis contract.
//!
//! Mirrors [`crate::ProviderAdapter`]: the daemon holds a `dyn TtsAdapter` so
//! the backend is swappable (voice-tts/mlx-rs on Apple Silicon today, a
//! candle port for other platforms later). [`MockTtsAdapter`] keeps the
//! protocol path fully testable without weights.

use async_trait::async_trait;

use crate::provider::{AdapterInfo, EngineError};

/// One synthesis result: a complete WAV file (16-bit PCM mono) plus its rate.
/// WAV (not raw PCM) so the Swift client can reuse its existing parser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TtsAudio {
    pub wav: Vec<u8>,
    pub sample_rate: u32,
}

/// What every TTS backend implements. `Send + Sync` so one adapter is shared
/// (`Arc<dyn TtsAdapter>`) across connection tasks.
#[async_trait]
pub trait TtsAdapter: Send + Sync {
    /// Backend + model identity, for status and audit.
    fn describe(&self) -> AdapterInfo;

    /// Synthesize speech for `text` with the named voice and speed factor.
    async fn synthesize(
        &self,
        text: &str,
        voice: &str,
        speed: f32,
    ) -> Result<TtsAudio, EngineError>;
}

/// Encode mono f32 samples as a 16-bit PCM little-endian WAV file. Samples
/// are clamped to [-1, 1]; scaling matches libsndfile (full signed range).
#[must_use]
pub fn encode_wav_pcm16(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let mut wav = Vec::with_capacity(44 + samples.len() * 2);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1u16.to_le_bytes()); // mono
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&(sample_rate * 2).to_le_bytes()); // byte rate
    wav.extend_from_slice(&2u16.to_le_bytes()); // block align
    wav.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    for &sample in samples {
        let clamped = sample.clamp(-1.0, 1.0);
        #[allow(clippy::cast_possible_truncation)]
        let value = (clamped * 32768.0).round().clamp(-32768.0, 32767.0) as i16;
        wav.extend_from_slice(&value.to_le_bytes());
    }
    wav
}

/// Deterministic TTS for tests and non-macOS builds: 240 samples of silence
/// (10 ms at 24 kHz), so protocol plumbing is exercised without weights.
pub struct MockTtsAdapter {
    model_id: String,
}

impl MockTtsAdapter {
    #[must_use]
    pub fn new(model_id: impl Into<String>) -> MockTtsAdapter {
        MockTtsAdapter {
            model_id: model_id.into(),
        }
    }
}

#[async_trait]
impl TtsAdapter for MockTtsAdapter {
    fn describe(&self) -> AdapterInfo {
        AdapterInfo {
            backend: "mock".to_owned(),
            model_id: self.model_id.clone(),
            // TTS has no text context window.
            context_window: 0,
        }
    }

    async fn synthesize(
        &self,
        text: &str,
        _voice: &str,
        _speed: f32,
    ) -> Result<TtsAudio, EngineError> {
        if text.trim().is_empty() {
            return Err(EngineError::Inference("empty text".to_owned()));
        }
        Ok(TtsAudio {
            wav: encode_wav_pcm16(&[0.0; 240], 24_000),
            sample_rate: 24_000,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_header_shape() {
        let wav = encode_wav_pcm16(&[0.0, 0.5, -0.5], 24_000);
        assert_eq!(wav.len(), 44 + 6);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[36..40], b"data");
        // Sample rate field at offset 24.
        assert_eq!(
            u32::from_le_bytes([wav[24], wav[25], wav[26], wav[27]]),
            24_000
        );
    }

    #[tokio::test]
    async fn mock_synthesizes_valid_wav_and_rejects_empty_text(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let tts = MockTtsAdapter::new("mock-tts");
        let audio = tts.synthesize("hello", "af_heart", 1.0).await?;
        assert_eq!(audio.sample_rate, 24_000);
        assert_eq!(&audio.wav[0..4], b"RIFF");
        assert!(tts.synthesize("   ", "af_heart", 1.0).await.is_err());
        Ok(())
    }
}
