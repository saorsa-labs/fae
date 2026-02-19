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

// C ABI surface for embedding in native shells (Swift, Obj-C, etc.).
pub mod canvas;
pub mod channels;
pub mod config;
pub mod credentials;
pub mod diagnostics;
pub mod doctor;
pub mod error;
pub mod external_llm;
pub mod fae_dirs;
pub mod fae_llm;
pub mod ffi;
pub mod host;
pub mod huggingface;
pub mod intelligence;
pub mod linker_anchor;
pub mod llm;
pub mod memory;
pub mod memory_pressure;
pub mod model_integrity;
pub mod model_picker;
pub mod model_selection;
pub mod model_tier;
pub mod models;
pub mod onboarding;
pub mod permissions;
pub mod personality;
pub mod pipeline;
pub mod platform;
pub mod progress;
pub mod runtime;
pub mod scheduler;
pub mod sentiment;
pub mod skills;
pub mod soul_version;
pub mod startup;
pub mod stt;
pub mod system_profile;
pub mod theme;
pub mod tts;
pub mod ui;
pub mod update;
pub mod vad;
pub mod viseme;
pub mod voice_clone;
pub mod voice_command;
pub mod voiceprint;

#[cfg(test)]
pub(crate) mod test_utils;

pub use approval::ToolApprovalRequest;
pub use config::SpeechConfig;
pub use error::{Result, SpeechError};
pub use permissions::{PermissionKind, PermissionStore};
pub use pipeline::coordinator::{PipelineCoordinator, PipelineMode};
pub use pipeline::messages::GateCommand;
pub use progress::{ProgressCallback, ProgressEvent};
pub use runtime::RuntimeEvent;
pub use startup::InitializedModels;
