//! Text-to-speech synthesis.
//!
//! Supports multiple backends:
//! - **Kokoro** (default) — Kokoro-82M ONNX with pre-trained voice styles.
//! - **Fish Speech** (optional, `fish-speech` feature) — voice cloning from reference audio.

pub mod kokoro;

#[cfg(feature = "fish-speech")]
pub mod fish_speech;

pub use kokoro::KokoroTts;

#[cfg(feature = "fish-speech")]
pub use fish_speech::FishSpeechTts;
