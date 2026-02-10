//! Fish Speech voice cloning TTS backend.
//!
//! Uses a reference audio file to clone a voice for synthesis.
//! This module requires the `fish-speech` Cargo feature.

use crate::config::TtsConfig;
use crate::error::{Result, SpeechError};
use tracing::info;

/// Output sample rate for Fish Speech (matches Kokoro for pipeline compatibility).
const SAMPLE_RATE: u32 = 24_000;

/// Fish Speech TTS engine with voice cloning.
///
/// Synthesises speech using a cloned voice derived from a reference audio file.
/// Currently a scaffold — full integration pending the `fish-speech.rs` crate.
#[derive(Debug)]
pub struct FishSpeechTts {
    /// Retained configuration (used for logging / diagnostics).
    _config: TtsConfig,
}

impl FishSpeechTts {
    /// Create a new Fish Speech TTS instance.
    ///
    /// # Arguments
    ///
    /// * `config` - TTS configuration including the `voice_reference` path.
    ///
    /// # Errors
    ///
    /// Returns an error if `voice_reference` is not set or the file does not exist.
    pub fn new(config: &TtsConfig) -> Result<Self> {
        let reference_path = config.voice_reference.as_ref().ok_or_else(|| {
            SpeechError::Tts("voice_reference path required for Fish Speech backend".into())
        })?;

        if !reference_path.exists() {
            return Err(SpeechError::Tts(format!(
                "voice reference file not found: {}",
                reference_path.display()
            )));
        }

        info!("loading Fish Speech model");
        info!(
            "extracting voice embedding from: {}",
            reference_path.display()
        );

        // TODO: Initialise fish-speech model and extract speaker embedding.
        // Blocked on fish-speech.rs crate availability.

        info!("Fish Speech TTS ready (scaffold mode)");

        Ok(Self {
            _config: config.clone(),
        })
    }

    /// Synthesise text to 24 kHz mono f32 audio using the cloned voice.
    ///
    /// # Errors
    ///
    /// Returns an error if synthesis fails.
    pub async fn synthesize(&mut self, text: &str) -> Result<Vec<f32>> {
        if text.is_empty() {
            return Ok(Vec::new());
        }

        info!("Fish Speech synthesize (scaffold): \"{text}\"");

        // Scaffold: return silence proportional to text length.
        // Real implementation will call fish-speech inference.
        let duration_samples = (text.len() as f32 * 0.1 * SAMPLE_RATE as f32) as usize;
        Ok(vec![0.0f32; duration_samples])
    }

    /// Output sample rate in Hz.
    pub fn sample_rate(&self) -> u32 {
        SAMPLE_RATE
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use std::path::PathBuf;

    /// Helper: create a temporary WAV file and return a `TtsConfig` with `voice_reference` set.
    fn config_with_test_wav(name: &str) -> TtsConfig {
        let dir = std::env::temp_dir().join("fae-test-fish-speech");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("{name}.wav"));
        // Minimal WAV header (44 bytes, zero data length — enough for existence check).
        let header: [u8; 44] = [
            b'R', b'I', b'F', b'F', 0x24, 0, 0, 0, b'W', b'A', b'V', b'E', b'f', b'm', b't', b' ',
            16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0, b'd', b'a',
            b't', b'a', 0, 0, 0, 0,
        ];
        std::fs::write(&path, header).unwrap();
        TtsConfig {
            voice_reference: Some(path),
            ..TtsConfig::default()
        }
    }

    #[test]
    fn requires_voice_reference() {
        let config = TtsConfig::default();
        let result = FishSpeechTts::new(&config);
        assert!(result.is_err());
        let err = format!("{}", result.unwrap_err());
        assert!(err.contains("voice_reference"));
    }

    #[test]
    fn rejects_nonexistent_reference() {
        let config = TtsConfig {
            voice_reference: Some(PathBuf::from("/nonexistent/voice.wav")),
            ..TtsConfig::default()
        };
        let result = FishSpeechTts::new(&config);
        assert!(result.is_err());
        let err = format!("{}", result.unwrap_err());
        assert!(err.contains("not found"));
    }

    #[test]
    fn loads_with_valid_reference() {
        let config = config_with_test_wav("loads_valid");
        let result = FishSpeechTts::new(&config);
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn empty_text_returns_empty_audio() {
        let config = config_with_test_wav("empty_text");
        let mut tts = FishSpeechTts::new(&config).unwrap();
        let audio = tts.synthesize("").await.unwrap();
        assert!(audio.is_empty());
    }

    #[tokio::test]
    async fn scaffold_returns_proportional_silence() {
        let config = config_with_test_wav("proportional");
        let mut tts = FishSpeechTts::new(&config).unwrap();
        let audio = tts.synthesize("hello").await.unwrap();
        // 5 chars * 0.1 * 24000 = 12000 samples
        assert_eq!(audio.len(), 12_000);
        assert!(audio.iter().all(|&s| s == 0.0));
    }

    #[test]
    fn sample_rate_is_24khz() {
        let config = config_with_test_wav("sample_rate");
        let tts = FishSpeechTts::new(&config).unwrap();
        assert_eq!(tts.sample_rate(), 24_000);
    }
}
