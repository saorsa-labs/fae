//! Fae: Real-time speech-to-speech AI conversation system.
//!
//! This crate provides a cascaded pipeline for voice conversations:
//! Microphone → VAD → STT → LLM → TTS → Speaker
//!
//! # Architecture
//!
//! The pipeline is built from independent stages connected by async channels:
//! - **Audio capture**: Records from the microphone via `cpal`
//! - **VAD**: Detects speech boundaries using energy-based analysis
//! - **STT**: Transcribes speech using NVIDIA Parakeet
//! - **LLM**: Generates responses using GGUF models via `mistralrs`
//! - **TTS**: Synthesizes speech using Kokoro-82M (ONNX)
//! - **Audio playback**: Plays synthesized audio via `cpal`

// Fail early with a clear message when the metal feature is enabled but the
// Metal Toolchain is not installed. Without this, mistralrs panics deep in a
// build script with an opaque error.
#[cfg(missing_metal_toolchain)]
compile_error!(
    "The `metal` feature requires Apple's Metal Toolchain. Install it with:\n\n    \
     xcodebuild -downloadComponent MetalToolchain\n\n\
     This is a one-time ~700 MB download."
);

pub mod agent;
pub mod approval;
pub mod audio;
pub mod canvas;
pub mod config;
pub mod error;
pub mod huggingface;
pub mod llm;
pub mod memory;
pub mod model_picker;
pub mod models;
pub mod personality;
pub mod pi;
pub mod pipeline;
pub mod progress;
pub mod runtime;
pub mod scheduler;
pub mod skills;
pub mod startup;
pub mod stt;
pub mod system_profile;
pub mod tts;
pub mod update;
pub mod vad;
pub mod voice_clone;
pub mod voiceprint;
pub mod wakeword;

pub use approval::ToolApprovalRequest;
pub use config::SpeechConfig;
pub use error::{Result, SpeechError};
pub use pipeline::coordinator::{PipelineCoordinator, PipelineMode};
pub use progress::{ProgressCallback, ProgressEvent};
pub use runtime::RuntimeEvent;
pub use startup::InitializedModels;
