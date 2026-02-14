//! Runtime events emitted by the pipeline for UI and observability.
//!
//! This is intentionally lightweight (no heavy payloads) so the pipeline
//! can emit events without blocking critical audio paths.

use crate::pipeline::messages::{ControlEvent, SentenceChunk, Transcription};

/// Role used in conversation snapshot entries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConversationSnapshotEntryRole {
    User,
    Assistant,
}

/// A single message entry in a conversation snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationSnapshotEntry {
    pub role: ConversationSnapshotEntryRole,
    pub text: String,
}

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
    /// Viseme events for lip-sync animation.
    ///
    /// Contains the mouth shape to display and timing information.
    /// This provides accurate lip-sync compared to RMS-based animation.
    AssistantViseme {
        /// The viseme/mouth shape to display.
        mouth_png: String,
    },
    /// Memory recall summary for the current turn.
    MemoryRecall { query: String, hits: usize },
    /// Memory write/edit operation summary.
    MemoryWrite {
        op: String,
        target_id: Option<String>,
    },
    /// Memory conflict/supersession summary.
    MemoryConflict {
        existing_id: String,
        replacement_id: Option<String>,
    },
    /// Memory schema migration progress/event.
    MemoryMigration { from: u32, to: u32, success: bool },
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
    /// A voice command was detected in a transcription.
    ///
    /// Emitted when the voice command filter intercepts a command phrase
    /// (e.g. "switch to Claude") before it reaches the LLM.
    VoiceCommandDetected {
        /// Human-readable description of the detected command.
        command: String,
    },
    /// Permissions were changed (granted or revoked).
    PermissionsChanged {
        /// Whether permissions are now granted.
        granted: bool,
    },
    /// A model switch was requested via voice command.
    ///
    /// Emitted after a `SwitchModel` voice command is parsed and before
    /// the actual switch is executed. The GUI can use this to show a
    /// transitional state.
    ModelSwitchRequested {
        /// Target model description (e.g. "anthropic" or "local").
        target: String,
    },
    /// Full conversation transcript snapshot for canvas rendering.
    ///
    /// This event is emitted when the user asks to view the conversation.
    /// The GUI canvas should display these entries as a chat transcript.
    ConversationSnapshot {
        entries: Vec<ConversationSnapshotEntry>,
    },
    /// Microphone status update.
    ///
    /// Emitted by the audio capture stage to indicate whether the microphone
    /// is actively providing audio data. The GUI uses this to display a mic
    /// health indicator (green = audio flowing, red = capture failed or no
    /// audio detected).
    MicStatus {
        /// Whether audio data is being received from the microphone.
        active: bool,
    },
    /// Explicit canvas panel visibility command for conversation UX.
    ///
    /// This is emitted when the user asks to show/hide conversation canvas.
    ConversationCanvasVisibility { visible: bool },
    /// The primary LLM provider failed and the request was retried against the
    /// local fallback model.
    ///
    /// Emitted by the fallback provider adapter so the GUI can show a
    /// non-intrusive notification (e.g. "Using local model — network issue").
    ProviderFallback {
        /// Name of the primary provider that failed.
        primary: String,
        /// Error message from the primary provider.
        error: String,
    },
}
