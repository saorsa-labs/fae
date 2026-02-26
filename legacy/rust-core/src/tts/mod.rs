//! Text-to-speech synthesis.
//!
//! Uses the Kokoro-82M ONNX engine with pre-trained voice styles.

pub mod kokoro;

pub use kokoro::KokoroTts;
