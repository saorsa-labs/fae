//! Kokoro-82M TTS engine — single-model ONNX inference with espeak-ng phonemization.

pub mod download;
mod engine;
mod phonemize;

pub use engine::KokoroTts;
