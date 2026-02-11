//! Runtime events emitted by the pipeline for UI and observability.
//!
//! This is intentionally lightweight (no heavy payloads) so the pipeline
//! can emit events without blocking critical audio paths.

use crate::pipeline::messages::{ControlEvent, SentenceChunk, Transcription};

/// Events that describe what the pipeline is doing "right now".
#[derive(Debug, Clone)]
pub enum RuntimeEvent {
    /// Low-latency control/state events (barge-in, playback start/end).
    Control(ControlEvent),
    /// User transcription produced by STT.
    Transcription(Transcription),
    /// Assistant sentence produced by the LLM (sentence-chunked stream).
    AssistantSentence(SentenceChunk),
    /// Whether the assistant is currently generating a response.
    AssistantGenerating { active: bool },
    /// Agent tool call request (for UI/telemetry).
    ToolCall {
        /// Tool call identifier (stable across start/update/end).
        id: String,
        name: String,
        input_json: String,
    },
    /// Agent tool result (for UI/telemetry).
    ToolResult {
        /// Tool call identifier this result corresponds to.
        id: String,
        name: String,
        success: bool,
        /// Best-effort textual output for display (may be truncated).
        output_text: Option<String>,
    },
    /// Best-effort assistant audio level (RMS) while playing back speech.
    ///
    /// Intended for driving simple avatar animation (mouth open/close).
    AssistantAudioLevel { rms: f32 },
    /// Model selection prompt for GUI (when multiple top-tier models available).
    ///
    /// The GUI should display a picker UI with the candidate models and
    /// allow the user to select one. If no selection is made within the
    /// timeout period, the first candidate will be auto-selected.
    ModelSelectionPrompt {
        /// List of "provider/model" strings to display in picker.
        candidates: Vec<String>,
        /// Timeout in seconds before auto-selecting first candidate.
        timeout_secs: u32,
    },
    /// Model selection confirmed (either by user or auto-selected).
    ///
    /// Emitted after model selection completes, for UI feedback.
    ModelSelected {
        /// Selected model in "provider/model" format.
        provider_model: String,
    },
}
