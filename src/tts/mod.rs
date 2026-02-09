//! Text-to-speech synthesis using Kokoro-82M.
//!
//! Uses the Kokoro-82M ONNX model with espeak-ng phonemization for
//! high-quality TTS at 24 kHz. Voice selection via pre-trained style
//! tensors (`.bin` files).

mod kokoro;

pub use kokoro::KokoroTts;
