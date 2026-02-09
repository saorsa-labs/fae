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
    ToolCall { name: String, input_json: String },
    /// Agent tool result (for UI/telemetry).
    ToolResult { name: String, success: bool },
    /// Best-effort assistant audio level (RMS) while playing back speech.
    ///
    /// Intended for driving simple avatar animation (mouth open/close).
    AssistantAudioLevel { rms: f32 },
}
