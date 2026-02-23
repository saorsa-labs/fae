//! Kokoro-82M TTS engine — single-model ONNX inference with espeak-ng phonemization.

pub mod download;
mod engine;
pub mod phonemize;

pub use engine::{strip_non_speech_chars, KokoroTts};
