//! Voice command detection for runtime model switching.
//!
//! Detects model-switch phrases in user transcriptions before they reach the LLM,
//! enabling hands-free model switching mid-conversation. Users can say things like
//! "Fae, switch to Claude" or "use the local model" and the command will be
//! intercepted and routed to the model switching logic.
//!
//! # Supported Commands
//!
//! | Phrase Pattern | Command |
//! |----------------|---------|
//! | "switch to {model}" | `SwitchModel` |
//! | "use {model}" | `SwitchModel` |
//! | "list models" | `ListModels` |
//! | "what model are you using" | `CurrentModel` |

/// A voice command detected from user speech.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VoiceCommand {
    /// Switch to a different model.
    SwitchModel {
        /// The target model to switch to.
        target: ModelTarget,
    },
    /// List all available models.
    ListModels,
    /// Query which model is currently active.
    CurrentModel,
}

/// Target specification for a model switch command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelTarget {
    /// Switch to a specific model by name (e.g., "gpt-4o").
    ByName(String),
    /// Switch to a model from a specific provider (e.g., "anthropic").
    ByProvider(String),
    /// Switch to the local on-device model.
    Local,
    /// Switch to the best available model (highest tier).
    Best,
}
