//! Vendored Chatterbox TTS engine (from github.com/srv1n/cbx).
//!
//! Adapted for ort 2.0.0-rc.11 compatibility (parakeet-rs pins this version).
//! Original source: <https://github.com/srv1n/cbx>

pub mod audio;
pub mod download;
pub mod engine;
pub mod voice;

pub use download::{ModelVariant, download_chatterbox_assets};
pub use engine::{Chatterbox, SessionConfig};
pub use voice::VoiceProfile;
