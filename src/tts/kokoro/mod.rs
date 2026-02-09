//! Kokoro-82M TTS engine — single-model ONNX inference with espeak-ng phonemization.

mod download;
mod engine;
mod phonemize;

pub use engine::KokoroTts;
