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
    /// Agent tool is currently executing (for "thinking" indicator).
    ToolExecuting { name: String },
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
    /// Legacy viseme event for lip-sync animation.
    ///
    /// Native orb UI paths do not require phoneme/viseme animation, so this
    /// event is retained for compatibility and is not emitted by default.
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
    /// Explicit conversation panel visibility command.
    ///
    /// Emitted when the user asks to show/hide the conversation panel
    /// (distinct from the canvas panel).
    ConversationVisibility { visible: bool },
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
    /// Intelligence extraction completed for a conversation turn.
    ///
    /// Emitted after the background extraction pass finishes.
    IntelligenceExtraction {
        /// Number of intelligence items extracted.
        items_count: usize,
        /// Number of actions triggered.
        actions_count: usize,
    },
    /// A proactive briefing has been prepared and is ready for delivery.
    ///
    /// Emitted when the briefing builder finishes gathering data.
    ProactiveBriefingReady {
        /// Number of briefing items prepared.
        item_count: usize,
    },
    /// A relationship record was updated or created.
    ///
    /// Emitted after a relationship upsert from intelligence actions.
    RelationshipUpdate {
        /// Person's name.
        name: String,
    },
    /// A skill proposal was generated.
    ///
    /// Emitted when a new skill opportunity is detected.
    SkillProposal {
        /// Proposed skill name.
        skill_name: String,
    },
    /// Noise budget status changed.
    ///
    /// Emitted when the daily noise budget is reset or exhausted.
    NoiseBudgetUpdate {
        /// Remaining deliveries allowed today.
        remaining: u32,
    },
    /// Orb mood/feeling update from sentiment analysis.
    ///
    /// Emitted by the background sentiment classifier after each LLM turn.
    /// The orb animation layer uses this to shift emotional colour/palette.
    OrbMoodUpdate {
        /// One of the 8 `OrbFeeling` values (e.g. `"warmth"`, `"delight"`).
        feeling: String,
        /// Optional palette override (e.g. `"autumn-bracken"`).
        palette: Option<String>,
    },
    /// Pipeline stage timing measurement for latency analysis.
    ///
    /// Emitted at each pipeline stage boundary with the stage name and
    /// elapsed duration in milliseconds. Use these events to identify
    /// where the latency bottleneck lives.
    PipelineTiming {
        /// Pipeline stage that completed (e.g. `"vad"`, `"stt"`, `"llm_first_token"`).
        stage: String,
        /// Duration in milliseconds for this stage.
        duration_ms: u64,
    },
    /// A background agent task has been spawned.
    ///
    /// Emitted when the pipeline detects tool intent in a voice turn and
    /// delegates execution to a background agent. The GUI can show a subtle
    /// "working..." indicator on the orb.
    BackgroundTaskStarted {
        /// Unique task identifier.
        task_id: String,
        /// Human-readable description of the task.
        description: String,
    },
    /// A background agent task completed.
    ///
    /// Emitted when a background agent finishes executing. The result text
    /// is simultaneously injected into the TTS pipeline for narration.
    BackgroundTaskCompleted {
        /// Task identifier (matches `BackgroundTaskStarted::task_id`).
        task_id: String,
        /// Whether the task completed successfully.
        success: bool,
        /// Summary text (may be truncated for event payload size).
        summary: String,
    },
    /// A tool approval request was resolved (granted, denied, or timed out).
    ///
    /// Emitted by the pipeline coordinator after a voice or button response
    /// resolves a pending approval. The Swift UI uses this to dismiss the
    /// approval overlay.
    ApprovalResolved {
        /// Numeric request identifier (matches the `approval.requested` event).
        request_id: u64,
        /// Whether the tool execution was approved.
        approved: bool,
        /// How the approval was resolved: `"voice"`, `"button"`, or `"timeout"`.
        source: String,
        /// Whether the resolving voice speaker matched the enrolled identity.
        ///
        /// `None` for non-voice paths (button/timeout).
        speaker_verified: Option<bool>,
    },
    /// Speaker verification decision for an incoming transcription.
    VoiceIdentityDecision {
        /// Whether the utterance passed identity checks.
        accepted: bool,
        /// Decision reason (e.g. `speaker_match`, `speaker_mismatch`).
        reason: String,
        /// Optional cosine similarity score when voiceprint is available.
        similarity: Option<f32>,
    },
    /// Progress updates while collecting onboarding voiceprint samples.
    VoiceprintEnrollmentProgress {
        /// Number of captured samples currently stored.
        sample_count: usize,
        /// Minimum required samples to finalize enrollment.
        required_samples: usize,
        /// Whether enrollment is now complete.
        enrolled: bool,
    },
}
