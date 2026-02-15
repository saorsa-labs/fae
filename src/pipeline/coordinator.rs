//! Main pipeline orchestrator that wires all stages together.

use crate::approval::ToolApprovalRequest;
use crate::audio::aec::{AecProcessor, ReferenceBuffer, ReferenceHandle};
use crate::canvas::registry::CanvasSessionRegistry;
use crate::config::{LlmMessageQueueDropPolicy, LlmMessageQueueMode, SpeechConfig};
use crate::error::Result;
use crate::memory::{MemoryOrchestrator, MemoryStore};
use crate::pipeline::messages::{
    AudioChunk, ControlEvent, GateCommand, SentenceChunk, SpeechSegment, SynthesizedAudio,
    TextInjection, Transcription,
};
use crate::runtime::{ConversationSnapshotEntry, ConversationSnapshotEntryRole, RuntimeEvent};
use crate::startup::InitializedModels;
use std::collections::VecDeque;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::broadcast;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};

/// Channel buffer sizes.
const AUDIO_CHANNEL_SIZE: usize = 64;
const SPEECH_CHANNEL_SIZE: usize = 8;
const TRANSCRIPTION_CHANNEL_SIZE: usize = 8;
const SENTENCE_CHANNEL_SIZE: usize = 8;
const SYNTH_CHANNEL_SIZE: usize = 16;

/// Commands sent to the playback stage (e.g., barge-in stop).
enum PlaybackCommand {
    Stop,
}

/// Commands sent to the LLM stage for queue control.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LlmQueueCommand {
    ClearQueuedInputs,
}

/// A user input item pending for the LLM stage.
#[derive(Debug, Clone)]
enum QueuedLlmInput {
    Transcription(Transcription),
    TextInjection(TextInjection),
}

impl QueuedLlmInput {
    fn text(&self) -> &str {
        match self {
            Self::Transcription(t) => &t.text,
            Self::TextInjection(i) => &i.text,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum QueueEnqueueAction {
    Enqueued,
    DroppedOldest,
    DroppedNewest,
    DroppedIncoming,
}

/// Bounded queue for user inputs received while an LLM run is active.
struct LlmInputQueue {
    mode: LlmMessageQueueMode,
    max_pending: usize,
    drop_policy: LlmMessageQueueDropPolicy,
    pending: VecDeque<QueuedLlmInput>,
}

impl LlmInputQueue {
    fn new(config: &crate::config::LlmConfig) -> Self {
        Self {
            mode: config.message_queue_mode,
            max_pending: config.message_queue_max_pending,
            drop_policy: config.message_queue_drop_policy,
            pending: VecDeque::new(),
        }
    }

    fn len(&self) -> usize {
        self.pending.len()
    }

    fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    fn clear(&mut self) -> usize {
        let cleared = self.pending.len();
        self.pending.clear();
        cleared
    }

    fn enqueue(&mut self, input: QueuedLlmInput) -> QueueEnqueueAction {
        if input.text().trim().is_empty() {
            return QueueEnqueueAction::DroppedIncoming;
        }

        if self.max_pending == 0 {
            return QueueEnqueueAction::DroppedIncoming;
        }

        if self.pending.len() < self.max_pending {
            self.pending.push_back(input);
            return QueueEnqueueAction::Enqueued;
        }

        match self.drop_policy {
            LlmMessageQueueDropPolicy::Oldest => {
                let _ = self.pending.pop_front();
                self.pending.push_back(input);
                QueueEnqueueAction::DroppedOldest
            }
            LlmMessageQueueDropPolicy::Newest => {
                let _ = self.pending.pop_back();
                self.pending.push_back(input);
                QueueEnqueueAction::DroppedNewest
            }
            LlmMessageQueueDropPolicy::None => QueueEnqueueAction::DroppedIncoming,
        }
    }

    fn dequeue_next(&mut self) -> Option<QueuedLlmInput> {
        match self.mode {
            LlmMessageQueueMode::Followup => self.pending.pop_front(),
            LlmMessageQueueMode::Collect => self.dequeue_collect_mode(),
        }
    }

    fn dequeue_collect_mode(&mut self) -> Option<QueuedLlmInput> {
        let first = self.pending.pop_front()?;
        match first {
            QueuedLlmInput::Transcription(mut merged) => {
                while let Some(QueuedLlmInput::Transcription(next)) = self.pending.front() {
                    if next.text.trim().is_empty() {
                        let _ = self.pending.pop_front();
                        continue;
                    }
                    let Some(QueuedLlmInput::Transcription(next)) = self.pending.pop_front() else {
                        break;
                    };
                    append_collected_text(&mut merged.text, &next.text);
                    merged.is_final = merged.is_final || next.is_final;
                    merged.transcribed_at = next.transcribed_at;
                }
                Some(QueuedLlmInput::Transcription(merged))
            }
            QueuedLlmInput::TextInjection(mut merged) => {
                if merged.fork_at_keep_count.is_some() {
                    return Some(QueuedLlmInput::TextInjection(merged));
                }
                while let Some(QueuedLlmInput::TextInjection(next)) = self.pending.front() {
                    if next.fork_at_keep_count.is_some() {
                        break;
                    }
                    if next.text.trim().is_empty() {
                        let _ = self.pending.pop_front();
                        continue;
                    }
                    let Some(QueuedLlmInput::TextInjection(next)) = self.pending.pop_front() else {
                        break;
                    };
                    append_collected_text(&mut merged.text, &next.text);
                }
                Some(QueuedLlmInput::TextInjection(merged))
            }
        }
    }
}

fn append_collected_text(base: &mut String, next: &str) {
    let next = next.trim();
    if next.is_empty() {
        return;
    }
    if !base.trim().is_empty() {
        base.push_str("\n\n");
    } else {
        base.clear();
    }
    base.push_str(next);
}

/// Source of a conversation turn for attribution and telemetry.
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)] // ScheduledTask variant will be used when scheduler integration completes
enum ConversationSource {
    /// User spoke via microphone (STT).
    Voice,
    /// User typed text via GUI.
    TextInput,
    /// Scheduled task triggered conversation.
    ScheduledTask { task_id: String },
}

#[derive(Debug, Clone)]
struct ConversationTurn {
    user_text: String,
    assistant_text: String,
    /// Source of this turn (voice, text, or scheduled task).
    #[allow(dead_code)] // Will be used for telemetry/analytics in future phases
    source: ConversationSource,
}

fn append_conversation_turn(
    turns: &mut Vec<ConversationTurn>,
    user_text: String,
    assistant_text: String,
    source: ConversationSource,
) {
    turns.push(ConversationTurn {
        user_text,
        assistant_text,
        source,
    });
}

fn build_conversation_snapshot_entries(
    turns: &[ConversationTurn],
) -> Vec<ConversationSnapshotEntry> {
    let mut entries = Vec::with_capacity(turns.len().saturating_mul(2));
    for turn in turns {
        if !turn.user_text.trim().is_empty() {
            entries.push(ConversationSnapshotEntry {
                role: ConversationSnapshotEntryRole::User,
                text: turn.user_text.clone(),
            });
        }
        if !turn.assistant_text.trim().is_empty() {
            entries.push(ConversationSnapshotEntry {
                role: ConversationSnapshotEntryRole::Assistant,
                text: turn.assistant_text.clone(),
            });
        }
    }
    entries
}

/// Pipeline operating mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipelineMode {
    /// Full conversation: capture → VAD → STT → LLM → TTS → playback.
    Conversation,
    /// Transcription only: capture → VAD → STT → print.
    TranscribeOnly,
}

/// Orchestrates the full speech-to-speech pipeline.
pub struct PipelineCoordinator {
    config: SpeechConfig,
    cancel: CancellationToken,
    mode: PipelineMode,
    models: Option<InitializedModels>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
    text_injection_rx: Option<mpsc::UnboundedReceiver<TextInjection>>,
    canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
    gate_cmd_rx: Option<mpsc::UnboundedReceiver<GateCommand>>,
    gate_active: Arc<AtomicBool>,
    console_output: bool,
    /// Sender for voice commands detected by the pipeline filter.
    ///
    /// Created during `run()` and passed to the LLM stage (Phase 2.2)
    voice_command_tx: Option<mpsc::UnboundedSender<crate::voice_command::VoiceCommand>>,
}

impl PipelineCoordinator {
    /// Create a new pipeline coordinator with the given configuration.
    pub fn new(config: SpeechConfig) -> Self {
        Self {
            config,
            cancel: CancellationToken::new(),
            mode: PipelineMode::Conversation,
            models: None,
            runtime_tx: None,
            tool_approval_tx: None,
            text_injection_rx: None,
            canvas_registry: None,
            gate_cmd_rx: None,
            gate_active: Arc::new(AtomicBool::new(false)),
            console_output: true,
            voice_command_tx: None,
        }
    }

    /// Create a coordinator with pre-loaded models from startup initialization.
    ///
    /// This skips lazy loading inside each stage, avoiding mid-conversation delays.
    pub fn with_models(config: SpeechConfig, models: InitializedModels) -> Self {
        Self {
            config,
            cancel: CancellationToken::new(),
            mode: PipelineMode::Conversation,
            models: Some(models),
            runtime_tx: None,
            tool_approval_tx: None,
            text_injection_rx: None,
            canvas_registry: None,
            gate_cmd_rx: None,
            gate_active: Arc::new(AtomicBool::new(false)),
            console_output: true,
            voice_command_tx: None,
        }
    }

    /// Set the pipeline operating mode.
    pub fn with_mode(mut self, mode: PipelineMode) -> Self {
        self.mode = mode;
        self
    }

    /// Attach a runtime event broadcaster for UI/observability.
    pub fn with_runtime_events(mut self, tx: broadcast::Sender<RuntimeEvent>) -> Self {
        self.runtime_tx = Some(tx);
        self
    }

    /// Attach a tool approval sender for interactive frontends.
    ///
    /// When set, high-risk tools (write/edit/bash/web) can be gated behind explicit approval.
    pub fn with_tool_approvals(mut self, tx: mpsc::UnboundedSender<ToolApprovalRequest>) -> Self {
        self.tool_approval_tx = Some(tx);
        self
    }

    /// Attach a canvas session registry for canvas tool integration.
    ///
    /// When set, the agent's canvas tools (`canvas_render`, `canvas_interact`,
    /// `canvas_export`) can look up and modify active canvas sessions.
    pub fn with_canvas_registry(mut self, registry: Arc<Mutex<CanvasSessionRegistry>>) -> Self {
        self.canvas_registry = Some(registry);
        self
    }

    /// Attach a text injection channel for typed input from the GUI.
    ///
    /// Messages received on this channel bypass STT and are fed directly
    /// into the LLM stage.
    pub fn with_text_injection(mut self, rx: mpsc::UnboundedReceiver<TextInjection>) -> Self {
        self.text_injection_rx = Some(rx);
        self
    }

    /// Attach a conversation gate command channel.
    ///
    /// The GUI sends [`GateCommand::Wake`] / [`GateCommand::Sleep`] to toggle
    /// the conversation gate between active and idle — equivalent to the wake
    /// word and stop phrase.
    pub fn with_gate_commands(mut self, rx: mpsc::UnboundedReceiver<GateCommand>) -> Self {
        self.gate_cmd_rx = Some(rx);
        self
    }

    /// Returns a shared flag that tracks whether the conversation gate is
    /// currently active (listening).  The GUI reads this to show the correct
    /// button label.
    pub fn gate_active(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.gate_active)
    }

    /// Enable or disable console (stdout) output from the pipeline.
    ///
    /// UI frontends should set this to `false` to avoid corrupting rendering.
    pub fn with_console_output(mut self, enabled: bool) -> Self {
        self.console_output = enabled;
        self
    }

    /// Run the full pipeline until cancelled.
    ///
    /// # Errors
    ///
    /// Returns an error if any pipeline stage fails to initialize.
    pub async fn run(mut self) -> Result<()> {
        info!("initializing speech pipeline (mode: {:?})", self.mode);

        // Ensure persistent memory roots exist early.
        let memory_root = self.config.memory.root_dir.clone();
        let store = MemoryStore::new(&memory_root);
        let _ = store.ensure_dirs();
        let _ = MemoryStore::ensure_voice_dirs(&memory_root);
        let onboarding_seg_tx: Option<mpsc::Sender<SpeechSegment>> = None;
        let onboarding_seg_rx: Option<mpsc::Receiver<SpeechSegment>> = None;

        // Split pre-loaded models (if any) into per-stage pieces.
        let (preloaded_stt, preloaded_llm, preloaded_tts) = match self.models.take() {
            Some(m) => (Some(m.stt), m.llm, m.tts),
            None => (None, None, None),
        };

        let text_injection_rx = self.text_injection_rx.take();

        // Create channels between stages
        let (audio_tx, audio_rx) = mpsc::channel::<AudioChunk>(AUDIO_CHANNEL_SIZE);
        let (speech_tx, speech_rx) = mpsc::channel::<SpeechSegment>(SPEECH_CHANNEL_SIZE);
        let (transcription_tx, transcription_rx) =
            mpsc::channel::<Transcription>(TRANSCRIPTION_CHANNEL_SIZE);
        let (control_tx, control_rx) = mpsc::unbounded_channel::<ControlEvent>();

        let cancel = self.cancel.clone();
        let runtime_tx = self.runtime_tx.clone();
        let tool_approval_tx = self.tool_approval_tx.clone();
        let canvas_registry = self.canvas_registry.clone();
        let console_output = self.console_output;
        let assistant_speaking = Arc::new(AtomicBool::new(false));
        let assistant_generating = Arc::new(AtomicBool::new(false));

        // AEC reference buffer: playback pushes speaker audio here so the AEC
        // stage can subtract it from the microphone signal.
        let ref_buf = ReferenceBuffer::new(
            self.config.audio.output_sample_rate,
            self.config.audio.input_sample_rate,
        );
        let ref_handle_playback = ref_buf.handle();
        let aec_enabled = self.config.aec.enabled;

        // Stage 1: Audio capture (always)
        let capture_handle = {
            let config = self.config.audio.clone();
            let cancel = cancel.clone();
            let rt_tx = runtime_tx.clone();
            tokio::spawn(async move {
                run_capture_stage(config, audio_tx, rt_tx, cancel).await;
            })
        };

        // AEC stage: sits between capture and VAD when enabled.
        let (vad_audio_rx, aec_handle) = if aec_enabled {
            let (aec_out_tx, aec_out_rx) = mpsc::channel::<AudioChunk>(AUDIO_CHANNEL_SIZE);
            let aec_config = self.config.aec.clone();
            let cancel = cancel.clone();
            let handle = tokio::spawn(async move {
                run_aec_stage(aec_config, ref_buf, audio_rx, aec_out_tx, cancel).await;
            });
            (aec_out_rx, Some(handle))
        } else {
            // Bypass: raw capture audio goes directly to VAD.
            drop(ref_buf);
            (audio_rx, None)
        };

        // Wakeword spotter: when enabled, tee audio to a second channel so the
        // MFCC+DTW spotter runs in parallel with VAD.
        let wakeword_enabled = self.config.wakeword.enabled;
        let (final_vad_rx, wakeword_handle, wakeword_gate_rx) = if wakeword_enabled {
            let (wakeword_audio_tx, wakeword_audio_rx) =
                mpsc::channel::<AudioChunk>(AUDIO_CHANNEL_SIZE);
            let (tee_out_tx, tee_out_rx) = mpsc::channel::<AudioChunk>(AUDIO_CHANNEL_SIZE);
            let (wakeword_signal_tx, wakeword_signal_rx) = mpsc::unbounded_channel::<()>();
            let cancel_tee = cancel.clone();

            // Tee task: sends each audio chunk to both VAD and wakeword spotter.
            tokio::spawn(async move {
                let mut rx = vad_audio_rx;
                loop {
                    tokio::select! {
                        () = cancel_tee.cancelled() => break,
                        chunk = rx.recv() => {
                            match chunk {
                                Some(c) => {
                                    // Best-effort send to wakeword: don't block VAD.
                                    let _ = wakeword_audio_tx.try_send(c.clone());
                                    if tee_out_tx.send(c).await.is_err() {
                                        break;
                                    }
                                }
                                None => break,
                            }
                        }
                    }
                }
            });

            // Wakeword spotter: maps detections to signals for the conversation gate.
            let ww_config = self.config.clone();
            let ww_control_tx = control_tx.clone();
            let ww_cancel = cancel.clone();
            let ww_signal_tx = wakeword_signal_tx;
            let handle = Some(tokio::spawn(async move {
                // The stage sends ControlEvent::WakewordDetected AND a () signal.
                run_wakeword_stage_with_signal(
                    ww_config,
                    wakeword_audio_rx,
                    ww_control_tx,
                    ww_signal_tx,
                    ww_cancel,
                )
                .await;
            }));

            (tee_out_rx, handle, Some(wakeword_signal_rx))
        } else {
            (vad_audio_rx, None, None)
        };

        // Stage 2: VAD (always)
        let vad_handle = {
            let config = self.config.clone();
            let cancel = cancel.clone();
            let control_tx = control_tx.clone();
            let onboarding_seg_tx = onboarding_seg_tx.clone();
            let vad_state = VadStageState {
                assistant_speaking: Arc::clone(&assistant_speaking),
                assistant_generating: Arc::clone(&assistant_generating),
                aec_enabled,
                runtime_tx: runtime_tx.clone(),
            };
            tokio::spawn(async move {
                run_vad_stage(
                    config,
                    final_vad_rx,
                    speech_tx,
                    onboarding_seg_tx,
                    control_tx,
                    vad_state,
                    cancel,
                )
                .await;
            })
        };

        // Stage 3: STT (always)
        let stt_handle = {
            let config = self.config.clone();
            let cancel = cancel.clone();
            let runtime_tx = runtime_tx.clone();
            tokio::spawn(async move {
                run_stt_stage(
                    config,
                    preloaded_stt,
                    speech_rx,
                    transcription_tx,
                    runtime_tx,
                    cancel,
                )
                .await;
            })
        };

        // Build remaining handles depending on mode
        match self.mode {
            PipelineMode::Conversation => {
                let mut control_rx = control_rx;
                // Tee assistant sentences so UI can observe them without interfering with TTS.
                let (llm_sentence_tx, llm_sentence_rx) =
                    mpsc::channel::<SentenceChunk>(SENTENCE_CHANNEL_SIZE);
                let (tts_sentence_tx, tts_sentence_rx) =
                    mpsc::channel::<SentenceChunk>(SENTENCE_CHANNEL_SIZE);
                let (synth_tx, synth_rx) = mpsc::channel::<SynthesizedAudio>(SYNTH_CHANNEL_SIZE);

                // Shared interrupt flag between gate and LLM
                let interrupt = Arc::new(AtomicBool::new(false));

                // Playback stop command channel (barge-in).
                let (playback_cmd_tx, playback_cmd_rx) =
                    mpsc::unbounded_channel::<PlaybackCommand>();

                // Queue-control channel for explicit queued-input cancellation.
                let (llm_queue_cmd_tx, llm_queue_cmd_rx) =
                    mpsc::unbounded_channel::<LlmQueueCommand>();

                // Identity gate before wake-word gating.
                // Onboarding now happens conversationally via prompt + memory.
                let (ident_tx, ident_rx) =
                    mpsc::channel::<Transcription>(TRANSCRIPTION_CHANNEL_SIZE);
                let identity_handle = {
                    let config = self.config.clone();
                    let cancel = cancel.clone();
                    let tts_tx = tts_sentence_tx.clone();
                    let memory_root = memory_root.clone();
                    tokio::spawn(async move {
                        run_identity_gate(
                            config,
                            transcription_rx,
                            ident_tx,
                            tts_tx,
                            memory_root,
                            onboarding_seg_rx,
                            cancel,
                        )
                        .await;
                    })
                };

                // Insert conversation gate between STT and LLM when enabled
                let (llm_rx, gate_handle) = if self.config.conversation.enabled {
                    let (gated_tx, gated_rx) =
                        mpsc::channel::<Transcription>(TRANSCRIPTION_CHANNEL_SIZE);
                    let config = self.config.clone();
                    let gate_ctl = ConversationGateControl {
                        interrupt: Arc::clone(&interrupt),
                        assistant_speaking: Arc::clone(&assistant_speaking),
                        assistant_generating: Arc::clone(&assistant_generating),
                        playback_cmd_tx: playback_cmd_tx.clone(),
                        llm_queue_cmd_tx: Some(llm_queue_cmd_tx.clone()),
                        clear_queue_on_stop: self.config.llm.clear_queue_on_stop,
                        console_output,
                        cancel: cancel.clone(),
                        wakeword_rx: wakeword_gate_rx,
                        gate_cmd_rx: self.gate_cmd_rx.take(),
                        gate_active: Arc::clone(&self.gate_active),
                    };
                    let handle = Some(tokio::spawn(async move {
                        run_conversation_gate(config, ident_rx, gated_tx, gate_ctl).await;
                    }));
                    (gated_rx, handle)
                } else {
                    (ident_rx, None)
                };

                // Voice command filter: intercepts model-switch phrases
                // before they reach the LLM. Non-command transcriptions pass through.
                let (voice_cmd_tx, voice_cmd_rx) =
                    mpsc::unbounded_channel::<crate::voice_command::VoiceCommand>();
                self.voice_command_tx = Some(voice_cmd_tx.clone());
                let (filtered_tx, filtered_rx) =
                    mpsc::channel::<Transcription>(TRANSCRIPTION_CHANNEL_SIZE);
                let vcf_handle = {
                    let runtime_tx = runtime_tx.clone();
                    let cancel = cancel.clone();
                    tokio::spawn(async move {
                        run_voice_command_filter(
                            llm_rx,
                            filtered_tx,
                            voice_cmd_tx,
                            runtime_tx,
                            cancel,
                        )
                        .await;
                    })
                };
                let llm_rx = filtered_rx;

                // Forward LLM sentences to both TTS and runtime event stream.
                // Also intercepts JSON canvas output from local models.
                let sentence_forward_handle = {
                    let runtime_tx = runtime_tx.clone();
                    let canvas_reg = canvas_registry.clone();
                    tokio::spawn(async move {
                        forward_sentences(
                            llm_sentence_rx,
                            tts_sentence_tx,
                            runtime_tx,
                            canvas_reg,
                            console_output,
                        )
                        .await;
                    })
                };

                // Stage 4: LLM
                let llm_handle = {
                    let config = self.config.clone();
                    let cancel = cancel.clone();
                    let interrupt = Arc::clone(&interrupt);
                    let assistant_speaking = Arc::clone(&assistant_speaking);
                    let assistant_generating = Arc::clone(&assistant_generating);
                    let playback_cmd_tx = playback_cmd_tx.clone();
                    let runtime_tx = runtime_tx.clone();
                    let tool_approval_tx = tool_approval_tx.clone();
                    let canvas_registry = canvas_registry.clone();
                    tokio::task::spawn_blocking(move || {
                        let runtime = match tokio::runtime::Builder::new_current_thread()
                            .enable_all()
                            .build()
                        {
                            Ok(runtime) => runtime,
                            Err(e) => {
                                error!("failed to create LLM stage runtime: {e}");
                                return;
                            }
                        };

                        runtime.block_on(async move {
                            let ctl = LlmStageControl {
                                interrupt,
                                assistant_speaking,
                                assistant_generating,
                                playback_cmd_tx,
                                runtime_tx,
                                tool_approval_tx,
                                canvas_registry,
                                console_output,
                                cancel,
                                voice_command_rx: Some(voice_cmd_rx),
                                queue_cmd_rx: Some(llm_queue_cmd_rx),
                            };
                            run_llm_stage(
                                config,
                                preloaded_llm,
                                llm_rx,
                                llm_sentence_tx,
                                ctl,
                                text_injection_rx,
                            )
                            .await;
                        });
                    })
                };

                // Stage 5: TTS
                let tts_handle = {
                    let config = self.config.clone();
                    let cancel = cancel.clone();
                    let interrupt = Arc::clone(&interrupt);
                    let runtime_tx = runtime_tx.clone();
                    tokio::spawn(async move {
                        run_tts_stage(
                            config,
                            preloaded_tts,
                            tts_sentence_rx,
                            synth_tx,
                            interrupt,
                            cancel,
                            runtime_tx,
                        )
                        .await;
                    })
                };

                // Stage 6: Playback
                let playback_handle = {
                    let config = self.config.audio.clone();
                    let ctl = PlaybackStageControl {
                        assistant_speaking: Arc::clone(&assistant_speaking),
                        control_tx: control_tx.clone(),
                        runtime_tx: runtime_tx.clone(),
                        aec_ref: if aec_enabled {
                            Some(ref_handle_playback)
                        } else {
                            None
                        },
                        cancel: cancel.clone(),
                    };
                    tokio::spawn(async move {
                        run_playback_stage(config, synth_rx, playback_cmd_rx, ctl).await;
                    })
                };

                // Control handler: on user speech start during assistant activity, interrupt and
                // stop playback (barge-in).
                //
                // When AEC + conversation gate are both enabled, the gate handles
                // barge-in based on transcription content (name-gated). The energy-based
                // path here is only used as a fallback when either is disabled.
                {
                    let cancel = cancel.clone();
                    let interrupt = Arc::clone(&interrupt);
                    let assistant_speaking = Arc::clone(&assistant_speaking);
                    let assistant_generating = Arc::clone(&assistant_generating);
                    let playback_cmd_tx = playback_cmd_tx.clone();
                    let barge_in = self.config.barge_in.clone();
                    let runtime_tx = runtime_tx.clone();
                    let name_gated = aec_enabled && self.config.conversation.enabled;
                    tokio::spawn(async move {
                        let mut last_assistant_speech_start: Option<Instant> = None;
                        loop {
                            tokio::select! {
                                () = cancel.cancelled() => break,
                                ev = control_rx.recv() => {
                                    let Some(ev) = ev else { break };
                                    if let Some(rt) = &runtime_tx {
                                        let _ = rt.send(RuntimeEvent::Control(ev.clone()));
                                    }
                                    if matches!(ev, ControlEvent::AssistantSpeechStart) {
                                        last_assistant_speech_start = Some(Instant::now());
                                    }
                                    // Skip energy-based barge-in when name-gated: the
                                    // conversation gate will interrupt only when the user
                                    // says "Fae" in the transcription.
                                    if let ControlEvent::UserSpeechStart { rms, .. } = ev
                                        && !name_gated
                                        && (assistant_speaking.load(Ordering::Relaxed)
                                            || assistant_generating.load(Ordering::Relaxed))
                                        && barge_in.enabled
                                        && rms >= barge_in.min_rms
                                        && !within_assistant_holdoff(
                                            &last_assistant_speech_start,
                                            barge_in.assistant_start_holdoff_ms,
                                        )
                                    {
                                        interrupt.store(true, Ordering::Relaxed);
                                        let _ = playback_cmd_tx.send(PlaybackCommand::Stop);
                                    }
                                }
                            }
                        }
                    });
                }

                // Wait for cancellation
                cancel.cancelled().await;
                info!("pipeline shutting down");

                // Join optional stage handles.
                if let Some(aec) = aec_handle {
                    let _ = aec.await;
                }
                if let Some(ww) = wakeword_handle {
                    let _ = ww.await;
                }

                if let Some(gate) = gate_handle {
                    let _ = tokio::join!(
                        capture_handle,
                        vad_handle,
                        stt_handle,
                        identity_handle,
                        gate,
                        vcf_handle,
                        llm_handle,
                        sentence_forward_handle,
                        tts_handle,
                        playback_handle,
                    );
                } else {
                    let _ = tokio::join!(
                        capture_handle,
                        vad_handle,
                        stt_handle,
                        identity_handle,
                        vcf_handle,
                        llm_handle,
                        sentence_forward_handle,
                        tts_handle,
                        playback_handle,
                    );
                }
            }
            PipelineMode::TranscribeOnly => {
                // Drop control events and unused reference handle (not used in this mode).
                let _control_rx = control_rx;
                drop(ref_handle_playback);
                // Just print transcriptions to stdout
                let print_handle = {
                    let cancel = cancel.clone();
                    let runtime_tx = runtime_tx.clone();
                    tokio::spawn(async move {
                        run_print_stage(transcription_rx, runtime_tx, console_output, cancel).await;
                    })
                };

                cancel.cancelled().await;
                info!("pipeline shutting down");

                if let Some(aec) = aec_handle {
                    let _ = aec.await;
                }

                let _ = tokio::join!(capture_handle, vad_handle, stt_handle, print_handle,);
            }
        }

        info!("pipeline shutdown complete");
        Ok(())
    }

    /// Request graceful shutdown of the pipeline.
    pub fn shutdown(&self) {
        self.cancel.cancel();
    }

    /// Get a clone of the cancellation token for external use.
    pub fn cancel_token(&self) -> CancellationToken {
        self.cancel.clone()
    }
}

// -- Stage runner functions --

async fn run_capture_stage(
    config: crate::config::AudioConfig,
    tx: mpsc::Sender<AudioChunk>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    cancel: CancellationToken,
) {
    use crate::audio::capture::CpalCapture;

    match CpalCapture::new(&config) {
        Ok(capture) => {
            // NOTE: MicStatus { active: true } is NOT emitted here.
            // The VAD stage validates actual audio flow before confirming
            // mic health (macOS TCC can silently provide zero-amplitude audio).
            if let Err(e) = capture.run(tx, cancel).await {
                error!("capture stage error: {e}");
                if let Some(ref rt) = runtime_tx {
                    let _ = rt.send(RuntimeEvent::MicStatus { active: false });
                }
            }
        }
        Err(e) => {
            error!("failed to init capture: {e}");
            if let Some(ref rt) = runtime_tx {
                let _ = rt.send(RuntimeEvent::MicStatus { active: false });
            }
        }
    }
}

/// AEC stage: runs the adaptive filter on each microphone chunk.
async fn run_aec_stage(
    config: crate::config::AecConfig,
    ref_buf: ReferenceBuffer,
    mut rx: mpsc::Receiver<AudioChunk>,
    tx: mpsc::Sender<AudioChunk>,
    cancel: CancellationToken,
) {
    let mut processor = match AecProcessor::new(&config, ref_buf) {
        Ok(p) => p,
        Err(e) => {
            error!("failed to init AEC: {e}");
            // Fall through: forward raw audio so the pipeline still works.
            loop {
                tokio::select! {
                    () = cancel.cancelled() => return,
                    chunk = rx.recv() => {
                        match chunk {
                            Some(c) => { if tx.send(c).await.is_err() { return; } }
                            None => return,
                        }
                    }
                }
            }
        }
    };

    info!(
        "AEC stage started (fft_size={}, step_size={})",
        config.fft_size, config.step_size
    );

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            chunk = rx.recv() => {
                match chunk {
                    Some(chunk) => {
                        let cleaned = processor.process(chunk);
                        if tx.send(cleaned).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

/// Wakeword spotter stage: runs MFCC+DTW detection on raw audio in parallel
/// with the VAD stage. Emits a `ControlEvent::WakewordDetected` for UI
/// observability and a dedicated `()` signal to the conversation gate.
async fn run_wakeword_stage_with_signal(
    config: SpeechConfig,
    mut rx: mpsc::Receiver<AudioChunk>,
    control_tx: mpsc::UnboundedSender<ControlEvent>,
    signal_tx: mpsc::UnboundedSender<()>,
    cancel: CancellationToken,
) {
    use crate::wakeword::WakewordSpotter;

    let mut spotter = match WakewordSpotter::new(&config.wakeword, config.audio.input_sample_rate) {
        Ok(s) => s,
        Err(e) => {
            error!("failed to init wakeword spotter: {e}");
            loop {
                tokio::select! {
                    () = cancel.cancelled() => return,
                    chunk = rx.recv() => {
                        if chunk.is_none() { return; }
                    }
                }
            }
        }
    };

    info!(
        "wakeword spotter started ({} references)",
        spotter.reference_count()
    );

    let cooldown = Duration::from_secs(2);
    let mut last_detection: Option<Instant> = None;

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            chunk = rx.recv() => {
                match chunk {
                    Some(chunk) => {
                        if spotter.process(&chunk.samples) {
                            let in_cooldown = last_detection
                                .is_some_and(|t| t.elapsed() < cooldown);
                            if !in_cooldown {
                                info!("wakeword detected by MFCC+DTW spotter");
                                let _ = control_tx.send(ControlEvent::WakewordDetected);
                                let _ = signal_tx.send(());
                                last_detection = Some(Instant::now());
                                spotter.clear();
                            }
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

/// Shared state for echo suppression and mic validation in the VAD stage.
struct VadStageState {
    assistant_speaking: Arc<AtomicBool>,
    assistant_generating: Arc<AtomicBool>,
    /// When true, DSP-based AEC is active and echo suppression can be relaxed.
    aec_enabled: bool,
    /// Runtime event sender for mic status updates.
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
}

async fn run_vad_stage(
    config: SpeechConfig,
    mut rx: mpsc::Receiver<AudioChunk>,
    tx: mpsc::Sender<SpeechSegment>,
    onboarding_tx: Option<mpsc::Sender<SpeechSegment>>,
    control_tx: mpsc::UnboundedSender<ControlEvent>,
    state: VadStageState,
    cancel: CancellationToken,
) {
    use crate::vad::SileroVad;

    let mut vad = match SileroVad::new(&config.vad, &config.models, config.audio.input_sample_rate)
    {
        Ok(v) => v,
        Err(e) => {
            error!("failed to init VAD: {e}");
            return;
        }
    };

    let confirm_samples = ms_to_samples(config.audio.input_sample_rate, config.barge_in.confirm_ms);
    let mut pending: Option<PendingBargeIn> = None;

    // Mic audio flow validation:
    // - Confirm active once we observe non-zero audio.
    // - Emit a watchdog warning if startup stays silent for too long.
    // - Keep checking after watchdog so the indicator can recover to green
    //   when audio starts later (e.g. user was quiet during startup).
    let mut mic_active_reported = false;
    let mut mic_watchdog_reported = false;
    let mic_start_time = Instant::now();
    /// RMS threshold used for "non-zero audio" detection.
    ///
    /// Keep this low so normal room noise and very quiet speech count as
    /// active audio, while permission-denied all-zero streams stay below it.
    const MIC_RMS_THRESHOLD: f32 = 0.000_01;
    /// Seconds to wait for non-zero audio before declaring mic failed.
    const MIC_WATCHDOG_SECS: u64 = 5;

    // Dynamic silence threshold: use a shorter silence gap during assistant
    // speech so segments reach the conversation gate faster for barge-in.
    let normal_silence_ms = config.vad.min_silence_duration_ms;
    let barge_in_silence_ms = config.barge_in.barge_in_silence_ms;
    let use_fast_silence = barge_in_silence_ms > 0 && barge_in_silence_ms < normal_silence_ms;
    let mut in_fast_mode = false;

    // Echo suppression tail: after assistant stops speaking, keep suppressing
    // for a brief window so residual echo/reverb doesn't leak through.
    // When AEC is active, the DSP filter handles most echo removal, so only a
    // short tail is needed to catch residual reverb.
    let echo_tail_ms: u64 = if state.aec_enabled { 300 } else { 1500 };
    let echo_tail = std::time::Duration::from_millis(echo_tail_ms);

    let mut was_suppressing = false;
    let mut suppress_until: Option<std::time::Instant> = None;

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            chunk = rx.recv() => {
                match chunk {
                    Some(chunk) => {
                        match vad.process_chunk(&chunk) {
                            Ok(out) => {
                                // Mic audio flow validation: confirm mic is
                                // delivering real audio, or time out.
                                if out.rms > MIC_RMS_THRESHOLD {
                                    if !mic_active_reported {
                                        info!("mic audio confirmed (rms={:.5})", out.rms);
                                        if let Some(ref rt) = state.runtime_tx {
                                            let _ = rt.send(RuntimeEvent::MicStatus { active: true });
                                        }
                                        mic_active_reported = true;
                                    }
                                    if mic_watchdog_reported {
                                        info!("mic audio detected after watchdog warning");
                                        mic_watchdog_reported = false;
                                    }
                                } else if !mic_active_reported
                                    && !mic_watchdog_reported
                                    && mic_start_time.elapsed()
                                        > Duration::from_secs(MIC_WATCHDOG_SECS)
                                {
                                    warn!("mic watchdog: no audio detected after {MIC_WATCHDOG_SECS}s");
                                    if let Some(ref rt) = state.runtime_tx {
                                        let _ = rt.send(RuntimeEvent::MicStatus { active: false });
                                    }
                                    mic_watchdog_reported = true;
                                }

                                // Update echo tail: detect the transition from suppressing→not.
                                let actively_suppressing =
                                    state.assistant_speaking.load(Ordering::Relaxed)
                                    || state.assistant_generating.load(Ordering::Relaxed);
                                if was_suppressing && !actively_suppressing {
                                    suppress_until = Some(std::time::Instant::now() + echo_tail);
                                }
                                was_suppressing = actively_suppressing;

                                // Switch silence threshold: shorter during assistant speech
                                // for faster barge-in delivery.
                                if use_fast_silence {
                                    if actively_suppressing && !in_fast_mode {
                                        vad.set_silence_threshold_ms(barge_in_silence_ms);
                                        in_fast_mode = true;
                                    } else if !actively_suppressing && in_fast_mode {
                                        vad.set_silence_threshold_ms(normal_silence_ms);
                                        in_fast_mode = false;
                                    }
                                }

                                let in_echo_tail = suppress_until
                                    .is_some_and(|t| std::time::Instant::now() < t);

                                if out.speech_started {
                                    pending = Some(PendingBargeIn {
                                        captured_at: chunk.captured_at,
                                        speech_samples: 0,
                                        last_rms: out.rms,
                                    });
                                }

                                let mut emit: Option<(Instant, f32)> = None;
                                if let Some(mut p) = pending.take()
                                    && out.is_speech
                                {
                                    p.speech_samples = p.speech_samples.saturating_add(chunk.samples.len());
                                    p.last_rms = out.rms;
                                    if p.speech_samples >= confirm_samples {
                                        emit = Some((p.captured_at, p.last_rms));
                                    } else {
                                        pending = Some(p);
                                    }
                                }

                                // Suppress barge-in events during echo suppression +
                                // tail so echoed speech doesn't trigger false
                                // interruptions.  Even with AEC active, residual
                                // echo can leak through (especially on laptop
                                // speakers), so always suppress during active
                                // playback and the echo tail.  The wakeword
                                // spotter provides fast barge-in detection on
                                // raw audio, bypassing VAD entirely.
                                let allow_event =
                                    !actively_suppressing && !in_echo_tail;
                                if let Some((captured_at, rms)) = emit
                                    && allow_event
                                {
                                    let _ = control_tx.send(ControlEvent::UserSpeechStart {
                                        captured_at,
                                        rms,
                                    });
                                }
                                if let Some(segment) = out.segment {
                                    let duration_s =
                                        segment.samples.len() as f32 / segment.sample_rate as f32;

                                    // Echo suppression: when the assistant is speaking,
                                    // generating, or within the echo tail, the mic is
                                    // likely picking up playback audio.  Even with AEC
                                    // active, residual echo leaks through on laptop
                                    // speakers, so always drop segments during active
                                    // playback and the echo tail.  Barge-in still works
                                    // via the wakeword spotter which runs on raw audio.
                                    let should_drop =
                                        actively_suppressing || in_echo_tail;
                                    if should_drop {
                                        info!(
                                            "dropping {duration_s:.1}s speech segment (echo suppression)"
                                        );
                                        continue;
                                    }

                                    // Clear the tail once we accept a real segment.
                                    suppress_until = None;

                                    info!("speech segment detected: {duration_s:.1}s");

                                    if let Some(tap) = &onboarding_tx {
                                        // Best-effort: don't block the pipeline if the tap is slow.
                                        let _ = tap.try_send(segment.clone());
                                    }

                                    if tx.send(segment).await.is_err() {
                                        break;
                                    }
                                }
                            }
                            Err(e) => error!("VAD error: {e}"),
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

async fn run_stt_stage(
    config: SpeechConfig,
    preloaded: Option<crate::stt::ParakeetStt>,
    mut rx: mpsc::Receiver<SpeechSegment>,
    tx: mpsc::Sender<Transcription>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    cancel: CancellationToken,
) {
    use crate::stt::ParakeetStt;

    let mut stt = match preloaded {
        Some(s) => s,
        None => match ParakeetStt::new(&config.stt, &config.models) {
            Ok(s) => s,
            Err(e) => {
                error!("failed to init STT: {e}");
                return;
            }
        },
    };

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            segment = rx.recv() => {
                match segment {
                    Some(segment) => {
                        match stt.transcribe(&segment) {
                            Ok(transcription) => {
                                let mut transcription = transcription;
                                if let Some(fixed) = canonicalize_wake_word_transcription(
                                    &config.conversation.wake_word,
                                    &transcription.text,
                                ) {
                                    transcription.text = fixed;
                                }

                                if let Some(rt) = &runtime_tx {
                                    let _ = rt.send(RuntimeEvent::Transcription(transcription.clone()));
                                }
                                if tx.send(transcription).await.is_err() {
                                    break;
                                }
                            }
                            Err(e) => error!("STT error: {e}"),
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

async fn run_identity_gate(
    _config: SpeechConfig,
    mut rx: mpsc::Receiver<Transcription>,
    tx: mpsc::Sender<Transcription>,
    tts_tx: mpsc::Sender<SentenceChunk>,
    memory_root: std::path::PathBuf,
    _onboarding_seg_rx: Option<mpsc::Receiver<SpeechSegment>>,
    cancel: CancellationToken,
) {
    let store = MemoryStore::new(&memory_root);
    if let Err(e) = store.ensure_dirs() {
        error!("memory init failed: {e}");
    }
    if let Err(e) = MemoryStore::ensure_voice_dirs(&memory_root) {
        error!("voice dir init failed: {e}");
    }

    let has_primary = match store.load_primary_user() {
        Ok(v) => v.is_some(),
        Err(e) => {
            error!("failed to load primary user memory: {e}");
            false
        }
    };

    if !has_primary {
        let _ = speak(
            &tts_tx,
            "Hello, I am Fae. We can get to know each other naturally as we chat.",
            cancel.clone(),
        )
        .await;
    }

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            msg = rx.recv() => {
                let Some(t) = msg else { break };

                // TODO: Speaker detection disabled — respond to all speech.
                // Re-enable voiceprint gating once embeddings are more stable.

                if tx.send(t).await.is_err() {
                    break;
                }
            }
        }
    }
}

/// Filter transcriptions for voice commands before they reach the LLM.
///
/// Final transcriptions are checked against `parse_voice_command()`. If a command
/// is detected, it is sent to `cmd_tx` and a `VoiceCommandDetected` runtime event
/// is emitted. Non-command (and partial) transcriptions pass through to `tx`.
async fn run_voice_command_filter(
    mut rx: mpsc::Receiver<Transcription>,
    tx: mpsc::Sender<Transcription>,
    cmd_tx: mpsc::UnboundedSender<crate::voice_command::VoiceCommand>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    cancel: CancellationToken,
) {
    use crate::voice_command::parse_voice_command;

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            msg = rx.recv() => {
                let Some(t) = msg else { break };

                // Only inspect final transcriptions for commands.
                if t.is_final
                    && let Some(cmd) = parse_voice_command(&t.text)
                {
                    let description = format!("{cmd:?}");
                    if let Some(ref tx) = runtime_tx {
                        let _ = tx.send(RuntimeEvent::VoiceCommandDetected {
                            command: description,
                        });
                    }
                    let _ = cmd_tx.send(cmd);
                    continue; // Do not forward to LLM.
                }

                // Not a command — pass through.
                if tx.send(t).await.is_err() {
                    break;
                }
            }
        }
    }
}

async fn speak(
    tts_tx: &mpsc::Sender<SentenceChunk>,
    text: &str,
    cancel: CancellationToken,
) -> bool {
    let chunk = SentenceChunk {
        text: text.to_owned(),
        is_final: true,
    };
    tokio::select! {
        () = cancel.cancelled() => false,
        res = tts_tx.send(chunk) => res.is_ok(),
    }
}

#[cfg(test)]
fn parse_name(text: &str) -> Option<String> {
    let raw = text.trim();
    if raw.is_empty() {
        return None;
    }
    let lower = raw.to_ascii_lowercase();

    // Search for name-introducing patterns anywhere in the text, not just at the start.
    // This handles "Hello, I'm David" where a greeting precedes the name pattern.
    let patterns = [
        "my name is ",
        "i am ",
        "i'm ",
        "im ",
        "this is ",
        "call me ",
        "it's ",
        "its ",
        "name's ",
        "names ",
    ];
    for pat in patterns {
        if let Some(idx) = lower.find(pat) {
            let rest = &lower[idx + pat.len()..];
            let token = rest.split_whitespace().next().unwrap_or("");
            let cleaned = clean_name_token(token);
            if !cleaned.is_empty() && !is_filler_word(&cleaned) {
                return Some(capitalize_first(&cleaned));
            }
        }
    }

    // Single-token fallback: take the last non-filler word.
    // Greetings like "Hello" or "Hi" are filtered out.
    let tokens: Vec<&str> = lower.split_whitespace().collect();
    for token in tokens.iter().rev() {
        let cleaned = clean_name_token(token);
        if !cleaned.is_empty() && !is_filler_word(&cleaned) {
            return Some(capitalize_first(&cleaned));
        }
    }

    None
}

/// Returns `true` for common greetings, filler words, articles, nationalities,
/// and identity words that are not plausible names.
#[cfg(test)]
fn is_filler_word(token: &str) -> bool {
    matches!(
        token,
        // Greetings / filler
        "hello"
            | "hi"
            | "hey"
            | "yo"
            | "hiya"
            | "howdy"
            | "greetings"
            | "morning"
            | "evening"
            | "afternoon"
            | "the"
            | "a"
            | "an"
            | "um"
            | "uh"
            | "er"
            | "erm"
            | "so"
            | "well"
            | "okay"
            | "ok"
            | "yeah"
            | "yes"
            | "no"
            | "just"
            | "like"
            | "actually"
            | "basically"
            | "you"
            | "your"
            | "can"
            | "fae"
            | "fay"
            | "faye"
            | "fee"
            | "fey"
            // Feelings / states
            | "tired"
            | "happy"
            | "sad"
            | "glad"
            | "ready"
            | "busy"
            | "hungry"
            | "fine"
            | "good"
            | "great"
            | "here"
            | "there"
            | "back"
            | "sorry"
            | "excited"
            // Gender / identity
            | "male"
            | "female"
            | "nonbinary"
            // Nationalities (common ones that follow "I'm")
            | "scottish"
            | "english"
            | "irish"
            | "welsh"
            | "british"
            | "american"
            | "canadian"
            | "australian"
            | "french"
            | "german"
            | "italian"
            | "spanish"
            | "dutch"
            | "swedish"
            | "norwegian"
            | "danish"
            | "finnish"
            | "polish"
            | "russian"
            | "chinese"
            | "japanese"
            | "korean"
            | "indian"
            | "brazilian"
            | "mexican"
            | "african"
            | "european"
            | "asian"
            // Common professions
            | "developer"
            | "engineer"
            | "teacher"
            | "student"
            | "doctor"
            | "programmer"
            | "retired"
    )
}

#[cfg(test)]
fn clean_name_token(token: &str) -> String {
    token
        .trim_matches(|c: char| !c.is_ascii_alphabetic() && c != '-' && c != '\'')
        .chars()
        .filter(|c| c.is_ascii_alphabetic() || *c == '-' || *c == '\'')
        .take(24)
        .collect()
}

#[derive(Debug, Clone, Copy)]
struct LocalCodingAssistants {
    codex_installed: bool,
    claude_installed: bool,
}

impl LocalCodingAssistants {
    fn detect() -> Self {
        Self {
            codex_installed: is_command_available("codex"),
            claude_installed: is_command_available("claude"),
        }
    }

    fn any(self) -> bool {
        self.codex_installed || self.claude_installed
    }
}

fn is_command_available(command: &str) -> bool {
    let Some(path_os) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path_os) {
        let candidate = dir.join(command);
        if !candidate.is_file() {
            continue;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(meta) = std::fs::metadata(&candidate)
                && meta.permissions().mode() & 0o111 != 0
            {
                return true;
            }
        }
        #[cfg(not(unix))]
        {
            return true;
        }
    }
    false
}

fn build_local_coding_assistants_context(
    assistants: LocalCodingAssistants,
    permission: Option<bool>,
) -> String {
    let permission_status = match permission {
        Some(true) => "allowed",
        Some(false) => "denied",
        None => "unknown",
    };

    format!(
        "<local_coding_assistants>\n\
- claude_cli_installed: {}\n\
- codex_cli_installed: {}\n\
- user_permission_for_coding_tasks: {}\n\
- policy: If coding help is needed and local Claude/Codex is installed, ask once when permission is unknown, remember the answer, and follow it.\n\
</local_coding_assistants>",
        assistants.claude_installed, assistants.codex_installed, permission_status
    )
}

/// Internal engine wrapper for the agent LLM.
enum LlmEngine {
    Agent(Box<crate::agent::FaeAgentLlm>),
}

struct LlmStageControl {
    interrupt: Arc<AtomicBool>,
    assistant_speaking: Arc<AtomicBool>,
    assistant_generating: Arc<AtomicBool>,
    playback_cmd_tx: mpsc::UnboundedSender<PlaybackCommand>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
    canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
    console_output: bool,
    cancel: CancellationToken,
    voice_command_rx: Option<mpsc::UnboundedReceiver<crate::voice_command::VoiceCommand>>,
    queue_cmd_rx: Option<mpsc::UnboundedReceiver<LlmQueueCommand>>,
}

impl LlmEngine {
    /// Generate a response using whichever backend is active.
    async fn generate_response(
        &mut self,
        user_input: String,
        tx: mpsc::Sender<SentenceChunk>,
        interrupt: Arc<AtomicBool>,
    ) -> crate::error::Result<bool> {
        match self {
            Self::Agent(llm) => llm.generate_response(user_input, tx, interrupt).await,
        }
    }

    /// Truncate the conversation history to keep only the system prompt and
    /// the first `keep_count` messages after it. Used for conversation forking.
    fn truncate_history(&mut self, keep_count: usize) {
        match self {
            Self::Agent(llm) => llm.truncate_history(keep_count),
        }
    }
}

async fn run_llm_stage(
    config: SpeechConfig,
    preloaded: Option<crate::llm::LocalLlm>,
    mut rx: mpsc::Receiver<Transcription>,
    tx: mpsc::Sender<SentenceChunk>,
    ctl: LlmStageControl,
    mut text_injection_rx: Option<mpsc::UnboundedReceiver<TextInjection>>,
) {
    use crate::agent::FaeAgentLlm;

    if let Err(e) = crate::personality::ensure_prompt_assets() {
        warn!("failed to ensure prompt assets: {e}");
    }

    let mut config = config;
    match crate::external_llm::apply_external_profile(&mut config.llm) {
        Ok(Some(applied)) => info!(
            "LLM stage applied external profile '{}' (provider={}, model={})",
            applied.profile_id, applied.provider, applied.api_model
        ),
        Ok(None) => {}
        Err(e) => warn!("failed to apply external LLM profile in LLM stage: {e}"),
    }

    let credential_manager = crate::credentials::create_manager();
    let mut engine = match FaeAgentLlm::new(
        &config.llm,
        preloaded,
        ctl.runtime_tx.clone(),
        ctl.tool_approval_tx.clone(),
        ctl.canvas_registry.clone(),
        credential_manager.as_ref(),
    )
    .await
    {
        Ok(l) => LlmEngine::Agent(Box::new(l)),
        Err(e) => {
            error!("failed to init agent LLM: {e}");
            return;
        }
    };

    let local_coding_assistants = LocalCodingAssistants::detect();

    let name = "Fae".to_owned();
    let memory_orchestrator = if config.memory.enabled {
        let orchestrator = MemoryOrchestrator::new(&config.memory);
        let migration_from = if config.memory.schema_auto_migrate {
            orchestrator.schema_version().ok()
        } else {
            None
        };

        match orchestrator.ensure_ready_with_migration() {
            Ok(Some((from, to))) => {
                if let Some(rt) = &ctl.runtime_tx {
                    let _ = rt.send(RuntimeEvent::MemoryMigration {
                        from,
                        to,
                        success: true,
                    });
                }
            }
            Ok(None) => {}
            Err(e) => {
                warn!("memory orchestrator init failed: {e}");
                if let Some(from) = migration_from {
                    let to = orchestrator.target_schema_version();
                    if from < to
                        && let Some(rt) = &ctl.runtime_tx
                    {
                        let _ = rt.send(RuntimeEvent::MemoryMigration {
                            from,
                            to,
                            success: false,
                        });
                    }
                }
            }
        }
        Some(orchestrator)
    } else {
        None
    };

    let LlmStageControl {
        interrupt,
        assistant_speaking,
        assistant_generating,
        playback_cmd_tx,
        runtime_tx,
        tool_approval_tx: _,
        canvas_registry: _,
        console_output,
        cancel,
        voice_command_rx,
        queue_cmd_rx,
    } = ctl;

    // Voice command receiver (currently unused — was Pi-specific).
    let mut voice_cmd_rx = voice_command_rx;
    let mut queue_cmd_rx = queue_cmd_rx;
    let mut pending_inputs = LlmInputQueue::new(&config.llm);
    let mut transcription_channel_closed = false;
    let mut conversation_turns: Vec<ConversationTurn> = Vec::new();

    let cancel = cancel;
    let mut turn_counter: u64 = 0;
    'outer: loop {
        if cancel.is_cancelled() {
            let cleared = pending_inputs.clear();
            if cleared > 0 {
                info!(
                    cleared,
                    "dropping queued LLM inputs during pipeline cancellation"
                );
            }
            break;
        }

        let next_input = if let Some(queued) = pending_inputs.dequeue_next() {
            queued
        } else {
            loop {
                let recv_injection = async {
                    match text_injection_rx.as_mut() {
                        Some(rx) => rx.recv().await,
                        None => std::future::pending().await,
                    }
                };
                let recv_voice_cmd = async {
                    match voice_cmd_rx.as_mut() {
                        Some(rx) => rx.recv().await,
                        None => std::future::pending().await,
                    }
                };
                let recv_queue_cmd = async {
                    match queue_cmd_rx.as_mut() {
                        Some(rx) => rx.recv().await,
                        None => std::future::pending().await,
                    }
                };

                enum Input {
                    Transcription(Option<Transcription>),
                    TextInjection(Option<TextInjection>),
                    VoiceCommand(Option<crate::voice_command::VoiceCommand>),
                    QueueCommand(Option<LlmQueueCommand>),
                }

                let input = tokio::select! {
                    () = cancel.cancelled() => break 'outer,
                    t = rx.recv() => Input::Transcription(t),
                    inj = recv_injection => Input::TextInjection(inj),
                    cmd = recv_voice_cmd => Input::VoiceCommand(cmd),
                    cmd = recv_queue_cmd => Input::QueueCommand(cmd),
                };

                match input {
                    Input::Transcription(Some(transcription)) => {
                        if transcription.text.trim().is_empty() {
                            continue;
                        }
                        break QueuedLlmInput::Transcription(transcription);
                    }
                    Input::TextInjection(Some(injection)) => {
                        if injection.text.trim().is_empty() {
                            continue;
                        }
                        break QueuedLlmInput::TextInjection(injection);
                    }
                    Input::VoiceCommand(Some(cmd)) => {
                        let response = handle_voice_command(&cmd);
                        // Emit permissions changed event for GUI
                        use crate::voice_command::VoiceCommand;
                        match &cmd {
                            VoiceCommand::GrantPermissions => {
                                if let Some(ref rt) = runtime_tx {
                                    let _ =
                                        rt.send(RuntimeEvent::PermissionsChanged { granted: true });
                                }
                            }
                            VoiceCommand::RevokePermissions => {
                                if let Some(ref rt) = runtime_tx {
                                    let _ = rt
                                        .send(RuntimeEvent::PermissionsChanged { granted: false });
                                }
                            }
                            _ => {}
                        }
                        if !response.is_empty() {
                            let _ = tx
                                .send(SentenceChunk {
                                    text: response,
                                    is_final: true,
                                })
                                .await;
                        }
                    }
                    Input::VoiceCommand(None) => {
                        voice_cmd_rx = None;
                    }
                    Input::QueueCommand(Some(LlmQueueCommand::ClearQueuedInputs)) => {
                        let cleared = clear_pending_inputs(
                            &mut pending_inputs,
                            &mut rx,
                            &mut text_injection_rx,
                            &mut transcription_channel_closed,
                        );
                        if cleared > 0 {
                            info!(cleared, "cleared queued LLM inputs");
                        }
                    }
                    Input::QueueCommand(None) => {
                        queue_cmd_rx = None;
                    }
                    Input::Transcription(None) => {
                        transcription_channel_closed = true;
                        if pending_inputs.is_empty() {
                            break 'outer;
                        }
                    }
                    Input::TextInjection(None) => {
                        // Text injection channel closed (GUI dropped sender).
                        // Continue with voice-only mode rather than killing the LLM stage.
                        text_injection_rx = None;
                    }
                }
            }
        };

        // Determine source of this turn for attribution
        let conversation_source = match &next_input {
            QueuedLlmInput::Transcription(_) => ConversationSource::Voice,
            QueuedLlmInput::TextInjection(_) => ConversationSource::TextInput,
        };

        let user_ctx = UserInputContext {
            config: &config,
            name: &name,
            interrupt: &interrupt,
            assistant_speaking: &assistant_speaking,
            assistant_generating: &assistant_generating,
            playback_cmd_tx: &playback_cmd_tx,
            runtime_tx: runtime_tx.as_ref(),
            console_output,
        };
        let Some(user_text) = prepare_user_text(next_input, &mut engine, &user_ctx) else {
            continue;
        };

        turn_counter += 1;
        let turn_id = format!(
            "{}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis(),
            turn_counter
        );

        if is_hide_conversation_request(&user_text) {
            let assistant_text = "Okay, I've hidden the conversation canvas.".to_owned();
            append_conversation_turn(
                &mut conversation_turns,
                user_text.clone(),
                assistant_text.clone(),
                conversation_source.clone(),
            );

            if let Some(rt) = &runtime_tx {
                let _ = rt.send(RuntimeEvent::ConversationCanvasVisibility { visible: false });
            }

            if tx
                .send(SentenceChunk {
                    text: assistant_text.clone(),
                    is_final: true,
                })
                .await
                .is_err()
            {
                break;
            }

            capture_memory_turn(
                memory_orchestrator.as_ref(),
                runtime_tx.as_ref(),
                &turn_id,
                &user_text,
                &assistant_text,
            );
            continue;
        }

        if is_show_conversation_request(&user_text) {
            let assistant_text = "I've opened the canvas with our full conversation.".to_owned();
            append_conversation_turn(
                &mut conversation_turns,
                user_text.clone(),
                assistant_text.clone(),
                conversation_source.clone(),
            );

            if let Some(rt) = &runtime_tx {
                let _ = rt.send(RuntimeEvent::ConversationCanvasVisibility { visible: true });
                let entries = build_conversation_snapshot_entries(&conversation_turns);
                let _ = rt.send(RuntimeEvent::ConversationSnapshot { entries });
            }

            if tx
                .send(SentenceChunk {
                    text: assistant_text.clone(),
                    is_final: true,
                })
                .await
                .is_err()
            {
                break;
            }

            capture_memory_turn(
                memory_orchestrator.as_ref(),
                runtime_tx.as_ref(),
                &turn_id,
                &user_text,
                &assistant_text,
            );
            continue;
        }

        let mut llm_input = format!("User message:\n{user_text}");
        if let Some(memory) = &memory_orchestrator {
            if let Ok(Some(memory_ctx)) = memory.recall_context(&user_text) {
                if let Some(rt) = &runtime_tx {
                    let hits = memory_ctx.matches("\n- [").count();
                    let _ = rt.send(RuntimeEvent::MemoryRecall {
                        query: user_text.clone(),
                        hits,
                    });
                }
                llm_input = format!("{memory_ctx}\n\n{llm_input}");
            }

            if let Ok(Some(onboarding_ctx)) = memory.onboarding_context() {
                llm_input = format!("{onboarding_ctx}\n\n{llm_input}");
            }
        }

        if local_coding_assistants.any() {
            let permission = memory_orchestrator
                .as_ref()
                .and_then(|memory| memory.coding_assistant_permission().ok().flatten());
            let local_coding_ctx =
                build_local_coding_assistants_context(local_coding_assistants, permission);
            llm_input = format!("{local_coding_ctx}\n\n{llm_input}");
        }

        assistant_generating.store(true, Ordering::Relaxed);
        if let Some(rt) = &runtime_tx {
            let _ = rt.send(RuntimeEvent::AssistantGenerating { active: true });
        }
        // Proxy channel captures assistant text for memory while forwarding to TTS.
        let (proxy_tx, mut proxy_rx) = mpsc::channel::<SentenceChunk>(SENTENCE_CHANNEL_SIZE);
        let final_tx = tx.clone();
        let forward_handle = tokio::spawn(async move {
            let mut assistant_text = String::new();
            while let Some(chunk) = proxy_rx.recv().await {
                let is_final = chunk.is_final;
                let text = chunk.text.trim();
                if !text.is_empty() {
                    if !assistant_text.is_empty() {
                        assistant_text.push(' ');
                    }
                    assistant_text.push_str(text);
                }
                final_tx.send(chunk).await.map_err(|e| {
                    crate::error::SpeechError::Channel(format!("LLM output channel closed: {e}"))
                })?;
                if is_final {
                    break;
                }
            }
            Ok::<String, crate::error::SpeechError>(assistant_text)
        });

        let mut generation = Box::pin(engine.generate_response(
            llm_input.clone(),
            proxy_tx.clone(),
            Arc::clone(&interrupt),
        ));
        let gen_result = loop {
            let recv_voice_during_gen = async {
                match voice_cmd_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            };
            let recv_injection_during_gen = async {
                match text_injection_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            };
            let recv_queue_cmd_during_gen = async {
                match queue_cmd_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            };

            tokio::select! {
                () = cancel.cancelled() => {
                    drop(proxy_tx);
                    let _ = forward_handle.await;
                    let cleared = clear_pending_inputs(
                        &mut pending_inputs,
                        &mut rx,
                        &mut text_injection_rx,
                        &mut transcription_channel_closed,
                    );
                    if cleared > 0 {
                        info!(cleared, "dropping queued LLM inputs during pipeline cancellation");
                    }
                    assistant_generating.store(false, Ordering::Relaxed);
                    if let Some(rt) = &runtime_tx {
                        let _ = rt.send(RuntimeEvent::AssistantGenerating { active: false });
                    }
                    break 'outer;
                }
                result = &mut generation => {
                    drop(proxy_tx);
                    break result;
                }
                cmd = recv_voice_during_gen => {
                    // Voice command arrived mid-generation - interrupt.
                    drop(proxy_tx);
                    interrupt.store(true, Ordering::Relaxed);
                    let _ = playback_cmd_tx.send(PlaybackCommand::Stop);
                    info!("voice command interrupted active generation");

                    if let Some(cmd) = cmd {
                        let response = handle_voice_command(&cmd);
                        if !response.is_empty() {
                            let _ = tx.send(SentenceChunk { text: response, is_final: true }).await;
                        }
                    } else {
                        voice_cmd_rx = None;
                    }

                    assistant_generating.store(false, Ordering::Relaxed);
                    if let Some(rt) = &runtime_tx {
                        let _ = rt.send(RuntimeEvent::AssistantGenerating { active: false });
                    }
                    let _ = forward_handle.await;
                    continue 'outer;
                }
                input = rx.recv() => {
                    match input {
                        Some(transcription) => {
                            enqueue_pending_input(
                                &mut pending_inputs,
                                QueuedLlmInput::Transcription(transcription),
                            );
                        }
                        None => {
                            transcription_channel_closed = true;
                        }
                    }
                }
                input = recv_injection_during_gen => {
                    match input {
                        Some(injection) => {
                            enqueue_pending_input(
                                &mut pending_inputs,
                                QueuedLlmInput::TextInjection(injection),
                            );
                        }
                        None => {
                            text_injection_rx = None;
                        }
                    }
                }
                queue_cmd = recv_queue_cmd_during_gen => {
                    match queue_cmd {
                        Some(LlmQueueCommand::ClearQueuedInputs) => {
                            let cleared = clear_pending_inputs(
                                &mut pending_inputs,
                                &mut rx,
                                &mut text_injection_rx,
                                &mut transcription_channel_closed,
                            );
                            if cleared > 0 {
                                info!(cleared, "cleared queued LLM inputs");
                            }
                        }
                        None => {
                            queue_cmd_rx = None;
                        }
                    }
                }
            }
        };

        let assistant_text = match forward_handle.await {
            Ok(Ok(text)) => text,
            Ok(Err(e)) => {
                error!("failed to forward LLM chunks: {e}");
                String::new()
            }
            Err(e) => {
                error!("failed to join LLM forwarding task: {e}");
                String::new()
            }
        };

        match gen_result {
            Ok(interrupted) => {
                if console_output {
                    println!();
                }
                if interrupted {
                    info!("LLM generation was interrupted");
                }
                assistant_generating.store(false, Ordering::Relaxed);
                if let Some(rt) = &runtime_tx {
                    let _ = rt.send(RuntimeEvent::AssistantGenerating { active: false });
                }
            }
            Err(e) => {
                if console_output {
                    println!();
                }
                error!("LLM error: {e}");
                // Report the error to the user via TTS instead of silently dropping it.
                let _ = tx
                    .send(SentenceChunk {
                        text: "Sorry, something went wrong with that request.".to_owned(),
                        is_final: true,
                    })
                    .await;
                assistant_generating.store(false, Ordering::Relaxed);
                if let Some(rt) = &runtime_tx {
                    let _ = rt.send(RuntimeEvent::AssistantGenerating { active: false });
                }
            }
        }

        append_conversation_turn(
            &mut conversation_turns,
            user_text.clone(),
            assistant_text.clone(),
            conversation_source,
        );
        capture_memory_turn(
            memory_orchestrator.as_ref(),
            runtime_tx.as_ref(),
            &turn_id,
            &user_text,
            &assistant_text,
        );

        if transcription_channel_closed && pending_inputs.is_empty() {
            break;
        }
    }
}

struct UserInputContext<'a> {
    config: &'a SpeechConfig,
    name: &'a str,
    interrupt: &'a Arc<AtomicBool>,
    assistant_speaking: &'a Arc<AtomicBool>,
    assistant_generating: &'a Arc<AtomicBool>,
    playback_cmd_tx: &'a mpsc::UnboundedSender<PlaybackCommand>,
    runtime_tx: Option<&'a broadcast::Sender<RuntimeEvent>>,
    console_output: bool,
}

fn prepare_user_text(
    input: QueuedLlmInput,
    engine: &mut LlmEngine,
    ctx: &UserInputContext<'_>,
) -> Option<String> {
    match input {
        QueuedLlmInput::Transcription(transcription) => {
            if transcription.text.trim().is_empty() {
                return None;
            }
            if ctx.console_output {
                if !ctx.config.conversation.enabled {
                    let latency = transcription
                        .transcribed_at
                        .duration_since(transcription.audio_captured_at);
                    println!(
                        "\n[You] {} (STT: {:.0}ms)",
                        transcription.text,
                        latency.as_millis()
                    );
                    print!("[AI] ");
                } else {
                    print!("[{}] ", ctx.name);
                }
                let _ = std::io::stdout().flush();
            }
            Some(transcription.text)
        }
        QueuedLlmInput::TextInjection(injection) => {
            if injection.text.trim().is_empty() {
                return None;
            }

            // Typed input should interrupt any active generation/playback,
            // just like voice barge-in.
            let assistant_active = ctx.assistant_speaking.load(Ordering::Relaxed)
                || ctx.assistant_generating.load(Ordering::Relaxed);
            if assistant_active {
                ctx.interrupt.store(true, Ordering::Relaxed);
                let _ = ctx.playback_cmd_tx.send(PlaybackCommand::Stop);
            }

            if let Some(keep) = injection.fork_at_keep_count {
                engine.truncate_history(keep);
                info!("forked conversation history, keeping {keep} entries");
            }

            if let Some(rt) = ctx.runtime_tx {
                let now = std::time::Instant::now();
                let _ = rt.send(RuntimeEvent::Transcription(Transcription {
                    text: injection.text.clone(),
                    is_final: true,
                    voiceprint: None,
                    audio_captured_at: now,
                    transcribed_at: now,
                }));
            }

            if ctx.console_output {
                println!("\n[You] {} (typed)", injection.text);
                print!("[{}] ", ctx.name);
                let _ = std::io::stdout().flush();
            }
            Some(injection.text)
        }
    }
}

fn enqueue_pending_input(queue: &mut LlmInputQueue, input: QueuedLlmInput) {
    let action = queue.enqueue(input);
    match action {
        QueueEnqueueAction::Enqueued => {}
        QueueEnqueueAction::DroppedOldest => {
            warn!(
                pending = queue.len(),
                "LLM pending-input queue full, dropped oldest entry"
            );
        }
        QueueEnqueueAction::DroppedNewest => {
            warn!(
                pending = queue.len(),
                "LLM pending-input queue full, dropped newest queued entry"
            );
        }
        QueueEnqueueAction::DroppedIncoming => {
            warn!(
                pending = queue.len(),
                "LLM pending-input queue full, dropped incoming entry"
            );
        }
    }
}

fn clear_pending_inputs(
    queue: &mut LlmInputQueue,
    rx: &mut mpsc::Receiver<Transcription>,
    text_injection_rx: &mut Option<mpsc::UnboundedReceiver<TextInjection>>,
    transcription_channel_closed: &mut bool,
) -> usize {
    let mut cleared = queue.clear();

    loop {
        match rx.try_recv() {
            Ok(t) => {
                if !t.text.trim().is_empty() {
                    cleared += 1;
                }
            }
            Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
            Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                *transcription_channel_closed = true;
                break;
            }
        }
    }

    if let Some(injection_rx) = text_injection_rx.as_mut() {
        loop {
            match injection_rx.try_recv() {
                Ok(injection) => {
                    if !injection.text.trim().is_empty() {
                        cleared += 1;
                    }
                }
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                    *text_injection_rx = None;
                    break;
                }
            }
        }
    }

    cleared
}

fn capture_memory_turn(
    memory_orchestrator: Option<&MemoryOrchestrator>,
    runtime_tx: Option<&broadcast::Sender<RuntimeEvent>>,
    turn_id: &str,
    user_text: &str,
    assistant_text: &str,
) {
    if let Some(memory) = memory_orchestrator {
        match memory.capture_turn(turn_id, user_text, assistant_text) {
            Ok(report) => {
                if let Some(rt) = runtime_tx {
                    for write in &report.writes {
                        let _ = rt.send(RuntimeEvent::MemoryWrite {
                            op: write.op.clone(),
                            target_id: write.target_id.clone(),
                        });
                    }
                    for conflict in &report.conflicts {
                        let _ = rt.send(RuntimeEvent::MemoryConflict {
                            existing_id: conflict.existing_id.clone(),
                            replacement_id: conflict.replacement_id.clone(),
                        });
                    }
                }
            }
            Err(e) => warn!("memory capture failed: {e}"),
        }
    }
}

/// Handle a voice command.
///
/// Returns a human-readable response string for TTS.
fn handle_voice_command(cmd: &crate::voice_command::VoiceCommand) -> String {
    use crate::voice_command::VoiceCommand;

    match cmd {
        VoiceCommand::SwitchModel { .. } => {
            "Voice model switching is not currently available.".to_owned()
        }
        VoiceCommand::ListModels | VoiceCommand::CurrentModel => {
            "Voice model info is not currently available.".to_owned()
        }
        VoiceCommand::Help => crate::voice_command::help_response(),
        VoiceCommand::GrantPermissions => {
            "Permissions granted. I can now use tools without asking.".to_owned()
        }
        VoiceCommand::RevokePermissions => {
            "Permissions revoked. I'll ask before using any tools.".to_owned()
        }
    }
}

/// Internal TTS engine wrapper for backend dispatch.
enum TtsEngine {
    /// Kokoro-82M ONNX backend (boxed to reduce enum size).
    Kokoro(Box<crate::tts::KokoroTts>),
    /// Fish Speech voice-cloning backend (requires `fish-speech` feature).
    #[cfg(feature = "fish-speech")]
    FishSpeech(crate::tts::FishSpeechTts),
}

impl TtsEngine {
    /// Synthesise text to f32 audio samples.
    async fn synthesize(&mut self, text: &str) -> crate::error::Result<Vec<f32>> {
        match self {
            Self::Kokoro(k) => k.synthesize(text).await,
            #[cfg(feature = "fish-speech")]
            Self::FishSpeech(f) => f.synthesize(text).await,
        }
    }
}

async fn run_tts_stage(
    config: SpeechConfig,
    preloaded: Option<crate::tts::KokoroTts>,
    mut rx: mpsc::Receiver<SentenceChunk>,
    tx: mpsc::Sender<SynthesizedAudio>,
    interrupt: Arc<AtomicBool>,
    cancel: CancellationToken,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
) {
    let mut engine = match config.tts.backend {
        crate::config::TtsBackend::Kokoro => {
            let tts = match preloaded {
                Some(t) => t,
                None => match crate::tts::KokoroTts::new(&config.tts) {
                    Ok(t) => t,
                    Err(e) => {
                        error!("failed to init Kokoro TTS: {e}");
                        return;
                    }
                },
            };
            TtsEngine::Kokoro(Box::new(tts))
        }
        crate::config::TtsBackend::FishSpeech => {
            #[cfg(feature = "fish-speech")]
            {
                match crate::tts::FishSpeechTts::new(&config.tts) {
                    Ok(t) => TtsEngine::FishSpeech(t),
                    Err(e) => {
                        error!("failed to init Fish Speech TTS: {e}");
                        return;
                    }
                }
            }
            #[cfg(not(feature = "fish-speech"))]
            {
                error!("Fish Speech backend selected but `fish-speech` feature is not enabled");
                return;
            }
        }
    };

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            sentence = rx.recv() => {
                match sentence {
                    Some(sentence) => {
                        // Generate visemes for lip-sync animation
                        if let Some(ref rt_tx) = runtime_tx {
                            let visemes = crate::viseme::text_to_visemes(&sentence.text, 1.0);
                            // Send first viseme as a "preview" - the GUI will advance through them
                            if let Some((viseme, _, _)) = visemes.first() {
                                let mouth_png = crate::viseme::viseme_to_mouth_png(*viseme);
                                let _ = rt_tx.send(RuntimeEvent::AssistantViseme {
                                    mouth_png: mouth_png.to_owned(),
                                });
                            }
                        }

                        // If an interrupt was requested (barge-in), drop any pending synthesis
                        // and only forward a final marker to unblock downstream state.
                        if interrupt.load(Ordering::Relaxed) {
                            if sentence.is_final {
                                let synth = SynthesizedAudio {
                                    samples: Vec::new(),
                                    sample_rate: config.tts.sample_rate,
                                    is_final: true,
                                };
                                if tx.send(synth).await.is_err() {
                                    break;
                                }
                            }
                            continue;
                        }
                        if sentence.text.is_empty() {
                            // End-of-response marker, forward it
                            let synth = SynthesizedAudio {
                                samples: Vec::new(),
                                sample_rate: config.tts.sample_rate,
                                is_final: true,
                            };
                            if tx.send(synth).await.is_err() {
                                break;
                            }
                            continue;
                        }
                        match engine.synthesize(&sentence.text).await {
                            Ok(audio) => {
                                if interrupt.load(Ordering::Relaxed) {
                                    // Interrupted while synthesizing; drop audio.
                                    if sentence.is_final {
                                        let synth = SynthesizedAudio {
                                            samples: Vec::new(),
                                            sample_rate: config.tts.sample_rate,
                                            is_final: true,
                                        };
                                        let _ = tx.send(synth).await;
                                    }
                                    continue;
                                }
                                let synth = SynthesizedAudio {
                                    samples: audio,
                                    sample_rate: config.tts.sample_rate,
                                    is_final: sentence.is_final,
                                };
                                if tx.send(synth).await.is_err() {
                                    break;
                                }
                            }
                            Err(e) => error!("TTS error: {e}"),
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

/// Bundled control state for the playback stage.
struct PlaybackStageControl {
    assistant_speaking: Arc<AtomicBool>,
    control_tx: mpsc::UnboundedSender<ControlEvent>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    aec_ref: Option<ReferenceHandle>,
    cancel: CancellationToken,
}

async fn run_playback_stage(
    config: crate::config::AudioConfig,
    mut rx: mpsc::Receiver<SynthesizedAudio>,
    mut cmd_rx: mpsc::UnboundedReceiver<PlaybackCommand>,
    ctl: PlaybackStageControl,
) {
    let assistant_speaking = ctl.assistant_speaking;
    let control_tx = ctl.control_tx;
    let runtime_tx = ctl.runtime_tx;
    let aec_ref = ctl.aec_ref;
    let cancel = ctl.cancel;
    use crate::audio::playback::CpalPlayback;
    use crate::audio::playback::PlaybackEvent;

    let (event_tx, mut event_rx) = mpsc::unbounded_channel::<PlaybackEvent>();

    let mut playback = match CpalPlayback::new(&config, event_tx) {
        Ok(p) => p,
        Err(e) => {
            error!("failed to init playback: {e}");
            return;
        }
    };

    // Track whether we have received the final TTS chunk for this response.
    // While false, PlaybackEvent::Finished means an intermediate chunk ended —
    // keep assistant_speaking=true so the VAD echo suppression covers the gap
    // between TTS chunks.
    let mut received_final_chunk = true;

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(PlaybackCommand::Stop) => {
                        playback.stop();
                        received_final_chunk = true;
                        assistant_speaking.store(false, Ordering::Relaxed);
                        if let Some(ref r) = aec_ref {
                            r.clear();
                        }
                        let _ = control_tx.send(ControlEvent::AssistantSpeechEnd { interrupted: true });
                    }
                    None => break,
                }
            }
            ev = event_rx.recv() => {
                match ev {
                    Some(PlaybackEvent::Finished) => {
                        if received_final_chunk {
                            // Last chunk of the response finished playing — safe to
                            // clear the speaking flag now.
                            assistant_speaking.store(false, Ordering::Relaxed);
                            let _ = control_tx.send(ControlEvent::AssistantSpeechEnd { interrupted: false });
                        } else {
                            // Intermediate chunk finished; more TTS audio is coming.
                            // Keep assistant_speaking=true to suppress echo in the gap.
                            info!("intermediate chunk finished, keeping echo suppression active");
                        }
                    }
                    Some(PlaybackEvent::Stopped) => {
                        received_final_chunk = true;
                        assistant_speaking.store(false, Ordering::Relaxed);
                        let _ = control_tx.send(ControlEvent::AssistantSpeechEnd { interrupted: true });
                    }
                    Some(PlaybackEvent::Level { rms }) => {
                        if let Some(rt) = &runtime_tx {
                            let _ = rt.send(RuntimeEvent::AssistantAudioLevel { rms });
                        }
                    }
                    None => break,
                }
            }
            audio = rx.recv() => {
                match audio {
                    Some(audio) => {
                        if audio.samples.is_empty() && audio.is_final {
                            // End-of-response marker from TTS. Use mark_end() so
                            // Finished fires only after the queue actually drains
                            // (not immediately while audio is still playing).
                            received_final_chunk = true;
                            playback.mark_end();
                        } else if !audio.samples.is_empty() {
                            if !assistant_speaking.load(Ordering::Relaxed) {
                                assistant_speaking.store(true, Ordering::Relaxed);
                                let _ = control_tx.send(ControlEvent::AssistantSpeechStart);
                            }
                            received_final_chunk = audio.is_final;
                            // Push audio to the AEC reference buffer so the
                            // adaptive filter can subtract it from the mic signal.
                            if let Some(ref r) = aec_ref {
                                r.push(&audio.samples);
                            }
                            if let Err(e) = playback.enqueue(&audio.samples, audio.sample_rate, audio.is_final) {
                                error!("playback error: {e}");
                            }
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

/// Conversation gate state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GateState {
    /// Waiting for wake word. All transcriptions silently discarded.
    Idle,
    /// Actively forwarding transcriptions to LLM.
    Active,
}

/// Strip punctuation that STT inserts (commas, periods, etc.) so that
/// phrase matching is resilient to transcription formatting differences.
/// For example, "that will do, fae" → "that will do fae".
fn strip_punctuation(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Expand common English contractions so STT output like "that'll" matches
/// the configured stop phrase "that will".
fn expand_contractions(text: &str) -> String {
    text.replace("that'll", "that will")
        .replace("i'll", "i will")
        .replace("i'm", "i am")
        .replace("i've", "i have")
        .replace("i'd", "i would")
        .replace("you'll", "you will")
        .replace("you're", "you are")
        .replace("you've", "you have")
        .replace("you'd", "you would")
        .replace("we'll", "we will")
        .replace("we're", "we are")
        .replace("we've", "we have")
        .replace("they'll", "they will")
        .replace("they're", "they are")
        .replace("they've", "they have")
        .replace("he'll", "he will")
        .replace("she'll", "she will")
        .replace("it'll", "it will")
        .replace("it's", "it is")
        .replace("can't", "cannot")
        .replace("won't", "will not")
        .replace("don't", "do not")
        .replace("doesn't", "does not")
        .replace("didn't", "did not")
        .replace("isn't", "is not")
        .replace("wasn't", "was not")
        .replace("weren't", "were not")
        .replace("wouldn't", "would not")
        .replace("couldn't", "could not")
        .replace("shouldn't", "should not")
}

/// Whether the user is asking to open the full conversation in canvas.
fn is_show_conversation_request(text: &str) -> bool {
    let normalized = strip_punctuation(&text.to_lowercase());
    let has_show_verb = normalized.contains("show")
        || normalized.contains("open")
        || normalized.contains("bring up");
    let asks_for_conversation = normalized.contains("conversation")
        || normalized.contains("chat history")
        || normalized.contains("chat log")
        || normalized.contains("conversation history");
    has_show_verb && asks_for_conversation
}

/// Whether the user is asking to hide/close the conversation canvas.
fn is_hide_conversation_request(text: &str) -> bool {
    let normalized = strip_punctuation(&text.to_lowercase());
    let has_hide_verb = normalized.contains("hide") || normalized.contains("close");
    let asks_for_conversation = normalized.contains("conversation")
        || normalized.contains("chat history")
        || normalized.contains("chat log")
        || normalized.contains("conversation history")
        || normalized.contains("canvas");
    has_hide_verb && asks_for_conversation
}

/// Bundled control state for the conversation gate.
struct ConversationGateControl {
    interrupt: Arc<AtomicBool>,
    assistant_speaking: Arc<AtomicBool>,
    assistant_generating: Arc<AtomicBool>,
    playback_cmd_tx: mpsc::UnboundedSender<PlaybackCommand>,
    llm_queue_cmd_tx: Option<mpsc::UnboundedSender<LlmQueueCommand>>,
    clear_queue_on_stop: bool,
    console_output: bool,
    cancel: CancellationToken,
    /// Optional channel for MFCC+DTW wake word detections from the spotter stage.
    /// When received in Idle state, transitions to Active immediately.
    wakeword_rx: Option<mpsc::UnboundedReceiver<()>>,
    /// Optional channel for GUI-driven gate commands (wake/sleep button).
    gate_cmd_rx: Option<mpsc::UnboundedReceiver<GateCommand>>,
    /// Shared flag indicating whether the gate is currently active.
    /// Written by the gate, read by the GUI for button state.
    gate_active: Arc<AtomicBool>,
}

/// Conversation gate: filters transcriptions based on wake word / stop phrase.
///
/// In `Idle` state, listens for the wake word and discards everything else.
/// In `Active` state:
///   - If the assistant is speaking/generating, only interrupt on wake word
///     (name-gated barge-in) or stop phrase.
///   - If the assistant is silent, forward any speech and check for stop phrase.
///   - Auto-returns to Idle after a configurable inactivity timeout.
async fn run_conversation_gate(
    config: SpeechConfig,
    mut stt_rx: mpsc::Receiver<Transcription>,
    llm_tx: mpsc::Sender<Transcription>,
    mut ctl: ConversationGateControl,
) {
    let wake_word = config.conversation.wake_word.to_lowercase();
    let stop_phrase = config.conversation.stop_phrase.to_lowercase();
    let idle_timeout_s = config.conversation.idle_timeout_s;
    let mut state = GateState::Idle;

    let display_name = "Fae".to_owned();

    // Take the wakeword receiver out of ctl so we can use it in the select loop
    // without a mutable borrow conflict.
    let mut wakeword_rx = ctl.wakeword_rx.take();
    let mut gate_cmd_rx = ctl.gate_cmd_rx.take();
    let gate_active = ctl.gate_active.clone();

    // Auto-idle: track when the last conversational activity happened.
    let mut last_activity = Instant::now();
    let mut idle_check = tokio::time::interval(Duration::from_secs(5));

    info!("conversation gate active, wake word: \"{wake_word}\"");

    loop {
        // Create a future for the wakeword channel that resolves to None when
        // the channel is absent (effectively disabled).
        let wakeword_fut = async {
            match &mut wakeword_rx {
                Some(rx) => rx.recv().await,
                None => std::future::pending().await,
            }
        };

        // Create a future for the GUI gate command channel.
        let gate_cmd_fut = async {
            match &mut gate_cmd_rx {
                Some(rx) => rx.recv().await,
                None => std::future::pending().await,
            }
        };

        tokio::select! {
            () = ctl.cancel.cancelled() => break,
            // GUI-driven gate command (start/stop listening button).
            Some(cmd) = gate_cmd_fut => {
                match cmd {
                    GateCommand::Wake if state == GateState::Idle => {
                        state = GateState::Active;
                        gate_active.store(true, Ordering::Relaxed);
                        last_activity = Instant::now();
                        if ctl.console_output {
                            println!("\n[{display_name}] Listening...");
                        }
                        info!("gate wake command received, transitioning to active");
                    }
                    GateCommand::Sleep if state == GateState::Active => {
                        ctl.interrupt.store(true, Ordering::Relaxed);
                        let _ = ctl.playback_cmd_tx.send(PlaybackCommand::Stop);
                        if ctl.clear_queue_on_stop
                            && let Some(tx) = &ctl.llm_queue_cmd_tx
                        {
                            let _ = tx.send(LlmQueueCommand::ClearQueuedInputs);
                        }
                        state = GateState::Idle;
                        gate_active.store(false, Ordering::Relaxed);
                        if ctl.console_output {
                            println!("\n[{display_name}] Standing by.\n");
                        }
                        info!("gate sleep command received, returning to idle");
                    }
                    _ => {} // Already in requested state, ignore.
                }
            }
            // MFCC+DTW wake word detection from the spotter stage.
            Some(()) = wakeword_fut, if state == GateState::Idle => {
                state = GateState::Active;
                gate_active.store(true, Ordering::Relaxed);
                last_activity = Instant::now();
                if ctl.console_output {
                    println!("\n[{display_name}] Listening...");
                }
                info!("wakeword spotter triggered, transitioning to active");
            }
            // Periodic auto-idle check.
            _ = idle_check.tick(), if state == GateState::Active && idle_timeout_s > 0 => {
                let assistant_active =
                    ctl.assistant_speaking.load(Ordering::Relaxed)
                    || ctl.assistant_generating.load(Ordering::Relaxed);
                if assistant_active {
                    // Keep the idle timer fresh while the assistant is speaking or
                    // generating — the conversation is still alive. This ensures the
                    // timeout counts from when the assistant FINISHES, not from when
                    // the user last spoke.
                    last_activity = Instant::now();
                } else if last_activity.elapsed() >= Duration::from_secs(idle_timeout_s as u64) {
                    state = GateState::Idle;
                    gate_active.store(false, Ordering::Relaxed);
                    if ctl.console_output {
                        println!("\n[{display_name}] Standing by.\n");
                    }
                    info!("conversation idle timeout, returning to idle");
                }
            }
            transcription = stt_rx.recv() => {
                match transcription {
                    Some(t) => {
                        if t.text.is_empty() {
                            continue;
                        }

                        // Use the raw lowercase string for any operations that need stable
                        // byte offsets back into `t.text`. Contraction expansion can change
                        // string length, which would invalidate indices.
                        let lower_raw = t.text.to_lowercase();
                        let lower_expanded = expand_contractions(&lower_raw);

                        match state {
                            GateState::Idle => {
                                if let Some((pos, matched_len)) =
                                    find_wake_word(&lower_raw, &wake_word)
                                {
                                    // Wake word detected — transition to Active
                                    state = GateState::Active;
                                    gate_active.store(true, Ordering::Relaxed);
                                    last_activity = Instant::now();
                                    if ctl.console_output {
                                        println!("\n[{display_name}] Listening...");
                                    }

                                    let query = extract_query_around_wake_word(
                                        &t.text, pos, matched_len,
                                    );

                                    let latency =
                                        t.transcribed_at.duration_since(t.audio_captured_at);
                                    if ctl.console_output {
                                        println!(
                                            "[You] {query} (STT: {:.0}ms)",
                                            latency.as_millis()
                                        );
                                    }

                                    let forwarded = Transcription {
                                        text: query,
                                        ..t
                                    };
                                    if llm_tx.send(forwarded).await.is_err() {
                                        break;
                                    }
                                }
                                // If no wake word, silently discard
                            }
                            GateState::Active => {
                                // Strip punctuation for phrase matching so STT
                                // formatting (commas, periods) doesn't break
                                // comparisons. E.g. "that will do, fae" matches
                                // stop phrase "that will do fae".
                                let clean = strip_punctuation(&lower_expanded);

                                // Check for stop phrase (always, even during
                                // assistant speech — "that'll do Fae" should work
                                // mid-sentence when AEC is active).
                                if clean.contains(&stop_phrase) {
                                    ctl.interrupt.store(true, Ordering::Relaxed);
                                    let _ = ctl.playback_cmd_tx.send(PlaybackCommand::Stop);
                                    if ctl.clear_queue_on_stop
                                        && let Some(tx) = &ctl.llm_queue_cmd_tx
                                    {
                                        let _ = tx.send(LlmQueueCommand::ClearQueuedInputs);
                                    }
                                    state = GateState::Idle;
                                    gate_active.store(false, Ordering::Relaxed);
                                    if ctl.console_output {
                                        println!("\n[{display_name}] Standing by.\n");
                                    }
                                    info!("stop phrase detected, returning to idle");
                                    continue;
                                }

                                let assistant_active =
                                    ctl.assistant_speaking.load(Ordering::Relaxed)
                                    || ctl.assistant_generating.load(Ordering::Relaxed);

                                // Check for full wake phrase first ("hi fae", "hey fae").
                                // Then fall back to standalone name mention ("fae") for
                                // name-gated barge-in — the user shouldn't need the full
                                // phrase when already in an active conversation.
                                let name_match = find_wake_word(&lower_raw, &wake_word)
                                    .or_else(|| find_name_mention(&lower_raw));

                                if let Some((pos, matched_len)) = name_match {
                                    ctl.interrupt.store(true, Ordering::Relaxed);
                                    if assistant_active {
                                        let _ = ctl.playback_cmd_tx.send(PlaybackCommand::Stop);
                                    }

                                    let query = extract_query_around_wake_word(
                                        &t.text, pos, matched_len,
                                    );

                                    let latency = t.transcribed_at
                                        .duration_since(t.audio_captured_at);
                                    if ctl.console_output {
                                        println!(
                                            "\n[You] {query} (STT: {:.0}ms)",
                                            latency.as_millis()
                                        );
                                    }

                                    let forwarded = Transcription {
                                        text: query,
                                        ..t
                                    };
                                    if llm_tx.send(forwarded).await.is_err() {
                                        break;
                                    }
                                    last_activity = Instant::now();
                                    continue;
                                }

                                // No name found.
                                if assistant_active {
                                    // During assistant speech without name: ignore.
                                    // Background conversation doesn't interrupt.
                                    continue;
                                }

                                // Normal active transcription (assistant not active).
                                // Interrupt any stale generation and forward.
                                ctl.interrupt.store(true, Ordering::Relaxed);

                                let latency = t.transcribed_at
                                    .duration_since(t.audio_captured_at);
                                if ctl.console_output {
                                    println!(
                                        "\n[You] {} (STT: {:.0}ms)",
                                        t.text,
                                        latency.as_millis()
                                    );
                                }

                                if llm_tx.send(t).await.is_err() {
                                    break;
                                }
                                last_activity = Instant::now();
                            }
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

/// Extract the user's query from text surrounding a wake word match.
///
/// Prefers text after the wake word ("Fae, how are you?" → "how are you?"),
/// falls back to text before it ("Hello Fae" → "Hello"), then defaults to
/// "Hello" if the wake word was the entire utterance.
fn extract_query_around_wake_word(text: &str, pos: usize, matched_len: usize) -> String {
    let after = &text[pos + matched_len..];
    let after = after.trim_start_matches([',', ':', '.', '!', '?', ' ']);
    let after = after.trim();

    if !after.is_empty() {
        return after.to_owned();
    }

    let before = &text[..pos];
    let before = before.trim_end_matches([',', ':', '.', '!', '?', ' ']);
    let before = before.trim();
    if before.is_empty() {
        "Hello".to_owned()
    } else {
        before.to_owned()
    }
}

fn find_wake_word(lower_raw: &str, wake_word: &str) -> Option<(usize, usize)> {
    if wake_word.is_empty() {
        return None;
    }

    let mut variants: Vec<String> = Vec::new();
    variants.push(wake_word.to_owned());

    // Common STT confusions for "fae" — add variants for both standalone and
    // multi-word wake phrases containing "fae".
    let fae_variants = ["faye", "fae", "fea", "fee", "fay", "fey", "fah", "feh"];

    if wake_word == "hi fae" {
        // Multi-word wake phrase: generate all "hi X" and "high X" variants.
        for v in fae_variants {
            variants.push(format!("hi {v}"));
            variants.push(format!("high {v}"));
            // STT may insert comma: "hi, fae"
            variants.push(format!("hi, {v}"));
            variants.push(format!("high, {v}"));
        }
        // Also match "hey fae" as a close variant of "hi fae"
        for v in fae_variants {
            variants.push(format!("hey {v}"));
            variants.push(format!("hey, {v}"));
        }
    } else if wake_word == "fae" {
        for v in fae_variants {
            variants.push(v.to_owned());
        }
    }

    // Sort longest-first so longer matches are preferred.
    variants.sort_by_key(|v| std::cmp::Reverse(v.len()));
    variants.dedup();

    let mut best: Option<(usize, usize)> = None;
    for v in &variants {
        let mut search_from = 0;
        while search_from < lower_raw.len() {
            let haystack = &lower_raw[search_from..];
            let Some(rel_pos) = haystack.find(v.as_str()) else {
                break;
            };
            let pos = search_from + rel_pos;
            let end = pos + v.len();

            // Word boundary check: avoid false positives like "coffee" matching "fee"
            // or "buffet" matching "fey". A boundary is start-of-string, end-of-string,
            // or a non-alphanumeric character.
            let start_ok = pos == 0 || !lower_raw.as_bytes()[pos - 1].is_ascii_alphanumeric();
            let end_ok =
                end >= lower_raw.len() || !lower_raw.as_bytes()[end].is_ascii_alphanumeric();

            if start_ok && end_ok {
                let candidate = (pos, v.len());
                best = match best {
                    None => Some(candidate),
                    Some(prev) if candidate.0 < prev.0 => Some(candidate),
                    Some(prev) => Some(prev),
                };
                break; // found a valid match for this variant
            }
            search_from = pos + 1;
        }
    }
    best
}

/// Check if the assistant's name ("fae") appears in text as a standalone word.
///
/// This is used during Active state for name-gated barge-in: saying just "Fae,
/// stop that" should interrupt even though the full wake phrase is "hi fae".
/// Returns `(byte_pos, matched_len)` of the first standalone name match, or
/// `None` if the name doesn't appear.
fn find_name_mention(lower_raw: &str) -> Option<(usize, usize)> {
    let variants = ["faye", "fae", "fea", "fay", "fey", "fah", "feh", "fee"];

    let mut best: Option<(usize, usize)> = None;
    for v in variants {
        let mut search_from = 0;
        while search_from < lower_raw.len() {
            let haystack = &lower_raw[search_from..];
            let Some(rel_pos) = haystack.find(v) else {
                break;
            };
            let pos = search_from + rel_pos;
            let end = pos + v.len();

            // Word boundary check to avoid false positives ("coffee" matching "fee").
            let start_ok = pos == 0 || !lower_raw.as_bytes()[pos - 1].is_ascii_alphanumeric();
            let end_ok =
                end >= lower_raw.len() || !lower_raw.as_bytes()[end].is_ascii_alphanumeric();

            if start_ok && end_ok {
                let candidate = (pos, v.len());
                best = match best {
                    None => Some(candidate),
                    Some(prev) if candidate.0 < prev.0 => Some(candidate),
                    Some(prev) => Some(prev),
                };
                break;
            }
            search_from = pos + 1;
        }
    }
    best
}

fn canonicalize_wake_word_transcription(wake_word: &str, text: &str) -> Option<String> {
    // Conservative fix-up for common STT confusions when users address Fae.
    // We only rewrite the first "wake-like" token near the start of the utterance.
    let wake = wake_word.trim().to_ascii_lowercase();

    // Only perform canonicalization for wake words containing "fae".
    if !wake.contains("fae") {
        return None;
    }

    let original = text;
    let trimmed = original.trim_start();
    let base_off = original.len().saturating_sub(trimmed.len());
    if trimmed.is_empty() {
        return None;
    }

    let lower = trimmed.to_ascii_lowercase();
    let canonical = "Fae";
    let fae_variants = ["faye", "fae", "fea", "fee", "fay", "fey", "fah", "feh"];

    fn boundary_ok(s: &str, at: usize) -> bool {
        if at >= s.len() {
            return true;
        }
        matches!(
            s.as_bytes()[at],
            b' ' | b'\t' | b'\n' | b'\r' | b',' | b'.' | b'!' | b'?' | b':' | b';'
        )
    }

    // Direct: "fee, ...", "fay ..."
    for v in fae_variants {
        if lower.starts_with(v) && boundary_ok(&lower, v.len()) {
            let start = base_off;
            let end = start + v.len();
            if end <= original.len() && end > start {
                let mut out = original.to_owned();
                out.replace_range(start..end, canonical);
                return Some(out);
            }
        }
    }

    // Common prefixed forms: "hey fee", "hi fee", "hello fee", "hello, fee", etc.
    // Include comma-separated variants since STT often inserts punctuation.
    let prefixes = [
        "hey ", "hey, ", "hi ", "hi, ", "high ", "high, ", "hello ", "hello, ", "ok ", "ok, ",
        "okay ", "okay, ",
    ];
    for prefix in prefixes.iter().copied() {
        if let Some(after) = lower.strip_prefix(prefix) {
            for v in fae_variants {
                if after.starts_with(v) && boundary_ok(after, v.len()) {
                    let start = base_off + prefix.len();
                    let end = start + v.len();
                    if end <= original.len() && end > start {
                        let mut out = original.to_owned();
                        out.replace_range(start..end, canonical);
                        return Some(out);
                    }
                }
            }
        }
    }

    None
}

/// Print transcriptions to stdout (for transcribe-only mode).
async fn run_print_stage(
    mut rx: mpsc::Receiver<Transcription>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    console_output: bool,
    cancel: CancellationToken,
) {
    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            transcription = rx.recv() => {
                match transcription {
                    Some(t) => {
                        if let Some(rt) = &runtime_tx {
                            let _ = rt.send(RuntimeEvent::Transcription(t.clone()));
                        }
                        if console_output && !t.text.is_empty() {
                            let latency = t.transcribed_at.duration_since(t.audio_captured_at);
                            println!("[{:.0}ms] {}", latency.as_millis(), t.text);
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct PendingBargeIn {
    captured_at: Instant,
    speech_samples: usize,
    last_rms: f32,
}

fn ms_to_samples(sample_rate: u32, ms: u32) -> usize {
    ((ms as u64 * sample_rate as u64) / 1000) as usize
}

fn within_assistant_holdoff(last_start: &Option<Instant>, holdoff_ms: u32) -> bool {
    let Some(t0) = *last_start else { return false };
    if holdoff_ms == 0 {
        return false;
    }
    Instant::now().duration_since(t0) < Duration::from_millis(holdoff_ms as u64)
}

#[cfg(test)]
fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => {
            let mut result = c.to_uppercase().to_string();
            result.push_str(chars.as_str());
            result
        }
        None => String::new(),
    }
}

/// Forward LLM sentence chunks to TTS and the runtime event stream.
///
/// When a local model outputs raw JSON that matches the `canvas_render`
/// content schema (`{ "type": "Chart"|"Image"|"Text", "data": {...} }`),
/// the JSON is intercepted and rendered directly to the canvas session
/// instead of being sent to TTS. A brief spoken description is sent in
/// its place so Fae doesn't try to speak JSON.
///
/// JSON detection uses a three-phase approach:
/// 1. **Deciding** — initial chunks are buffered (up to ~120 chars) to
///    detect JSON preambles like "aaa json ```json {..."
/// 2. **JSON mode** — once `{` is seen, everything from `{` onward is
///    accumulated and rendered to canvas on `is_final`.
/// 3. **Speech mode** — if enough text accumulates without `{`, all
///    buffered text is flushed and subsequent chunks stream normally.
async fn forward_sentences(
    mut rx: mpsc::Receiver<SentenceChunk>,
    tx: mpsc::Sender<SentenceChunk>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
    console_output: bool,
) {
    /// Send a chunk to both the runtime event stream and TTS.
    async fn emit(
        chunk: &SentenceChunk,
        runtime_tx: &Option<broadcast::Sender<RuntimeEvent>>,
        tx: &mpsc::Sender<SentenceChunk>,
        console_output: bool,
    ) {
        if let Some(rt) = runtime_tx {
            let _ = rt.send(RuntimeEvent::AssistantSentence(chunk.clone()));
        }
        if console_output && !chunk.text.is_empty() {
            print!("{}", chunk.text);
            let _ = std::io::stdout().flush();
        }
        let _ = tx.send(chunk.clone()).await;
    }

    /// How many characters of preamble to buffer before deciding this is
    /// normal speech (not JSON). Covers "aaa json ```json" and similar.
    const DECIDE_THRESHOLD: usize = 120;

    #[derive(PartialEq)]
    enum Mode {
        /// Buffering initial text to detect JSON.
        Deciding,
        /// Accumulating `{...}` for canvas rendering.
        Json,
        /// Normal speech — forward chunks immediately.
        Speech,
    }

    let mut mode = Mode::Deciding;
    let mut pending = String::new(); // buffered text while Deciding
    let mut json_buf = String::new(); // JSON accumulator in Json mode

    while let Some(chunk) = rx.recv().await {
        match mode {
            Mode::Json => {
                json_buf.push_str(&chunk.text);
            }
            Mode::Speech => {
                emit(&chunk, &runtime_tx, &tx, console_output).await;
            }
            Mode::Deciding => {
                pending.push_str(&chunk.text);

                // Check the combined pending text for a `{`.
                if let Some(brace_pos) = pending.find('{') {
                    // Found JSON start — everything from `{` onward goes
                    // to json_buf. Everything before is preamble (discarded).
                    mode = Mode::Json;
                    json_buf.push_str(&pending[brace_pos..]);
                } else if pending.len() >= DECIDE_THRESHOLD {
                    // Enough text without `{` — this is normal speech.
                    mode = Mode::Speech;
                    emit(
                        &SentenceChunk {
                            text: std::mem::take(&mut pending),
                            is_final: false,
                        },
                        &runtime_tx,
                        &tx,
                        console_output,
                    )
                    .await;
                }
                // else: keep buffering
            }
        }

        if chunk.is_final {
            match mode {
                Mode::Json => {
                    // Strip markdown code fences (```json ... ```) that
                    // some models wrap around the JSON output.
                    let stripped = strip_markdown_fences(&json_buf);
                    let cleaned = clean_model_json(stripped.trim());
                    let json_str = extract_json_object(&cleaned);

                    let spoken = json_str
                        .and_then(|js| try_render_canvas_json(js, &canvas_registry, &runtime_tx));

                    let output_text = if let Some(description) = spoken {
                        description
                    } else {
                        warn!(
                            "JSON canvas output detected but parsing failed: {}",
                            &cleaned[..cleaned.len().min(200)]
                        );
                        "I tried to create a chart but had trouble with the data format.".to_owned()
                    };

                    emit(
                        &SentenceChunk {
                            text: output_text,
                            is_final: true,
                        },
                        &runtime_tx,
                        &tx,
                        console_output,
                    )
                    .await;
                }
                Mode::Deciding => {
                    // Response ended while still buffering — check one
                    // last time for JSON, otherwise emit as speech.
                    if pending.contains('{') {
                        let stripped = strip_markdown_fences(&pending);
                        let cleaned = clean_model_json(stripped.trim());
                        let json_str = extract_json_object(&cleaned);

                        let spoken = json_str.and_then(|js| {
                            try_render_canvas_json(js, &canvas_registry, &runtime_tx)
                        });

                        let output_text = spoken.unwrap_or_else(|| pending.clone());
                        emit(
                            &SentenceChunk {
                                text: output_text,
                                is_final: true,
                            },
                            &runtime_tx,
                            &tx,
                            console_output,
                        )
                        .await;
                    } else if !pending.is_empty() {
                        emit(
                            &SentenceChunk {
                                text: std::mem::take(&mut pending),
                                is_final: true,
                            },
                            &runtime_tx,
                            &tx,
                            console_output,
                        )
                        .await;
                    }
                }
                Mode::Speech => {
                    // Final chunk already emitted above.
                }
            }

            // Reset for the next response.
            mode = Mode::Deciding;
            pending.clear();
            json_buf.clear();
        }
    }
}

/// Strip markdown code fences from text. Removes leading/trailing
/// ` ```json ` / ` ``` ` markers that models sometimes wrap JSON in.
fn strip_markdown_fences(text: &str) -> String {
    let mut s = text.to_owned();
    // Remove opening fence: ```json or ```
    if let Some(start) = s.find("```") {
        let fence_end = s[start + 3..]
            .find('\n')
            .map(|i| start + 3 + i + 1)
            .unwrap_or(start + 3);
        s.replace_range(start..fence_end, "");
    }
    // Remove closing fence
    if let Some(end) = s.rfind("```") {
        s.replace_range(end..end + 3, "");
    }
    s
}

/// Extract the outermost `{...}` JSON object from `text`, accounting
/// for nested braces and quoted strings. Returns the slice if balanced
/// braces are found, `None` otherwise.
fn extract_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let mut depth: i32 = 0;
    let mut in_string = false;
    let mut escape_next = false;

    for (i, ch) in text[start..].char_indices() {
        if escape_next {
            escape_next = false;
            continue;
        }
        match ch {
            '\\' if in_string => escape_next = true,
            '"' => in_string = !in_string,
            '{' if !in_string => depth += 1,
            '}' if !in_string => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[start..start + i + 1]);
                }
            }
            _ => {}
        }
    }
    None
}

/// Clean up common JSON formatting issues from local LLM output.
///
/// Local models sometimes output values like `1 billion` or `1.25 billion`
/// instead of proper numeric literals. This function normalizes those
/// patterns so the JSON can be parsed by serde.
fn clean_model_json(text: &str) -> String {
    let mut result = text.to_owned();

    // Process multiplier words from largest to smallest.
    for (word, multiplier) in [
        (" trillion", 1_000_000_000_000_f64),
        (" billion", 1_000_000_000_f64),
        (" million", 1_000_000_f64),
    ] {
        while let Some(word_pos) = result.find(word) {
            // Walk backward from the space before the word to find the number.
            let before = &result[..word_pos];
            let num_start = before
                .rfind(|c: char| !c.is_ascii_digit() && c != '.')
                .map_or(0, |i| i + 1);
            let num_str = &result[num_start..word_pos];

            if let Ok(n) = num_str.parse::<f64>() {
                let expanded = format!("{}", (n * multiplier) as i64);
                result.replace_range(num_start..word_pos + word.len(), &expanded);
            } else {
                // Can't parse the preceding text as a number; leave it and
                // break to avoid an infinite loop.
                break;
            }
        }
    }

    result
}

/// Attempt to parse `text` as a canvas `RenderContent` JSON blob and
/// render it to the `"gui"` canvas session.
///
/// On success, emits `ToolCall` + `ToolResult` runtime events (so the GUI
/// opens the canvas window) and returns a brief spoken description.
///
/// Returns `None` if the text doesn't parse as valid canvas content.
fn try_render_canvas_json(
    text: &str,
    canvas_registry: &Option<Arc<Mutex<CanvasSessionRegistry>>>,
    runtime_tx: &Option<broadcast::Sender<RuntimeEvent>>,
) -> Option<String> {
    use canvas_mcp::tools::{RenderContent, RenderParams};

    let registry = canvas_registry.as_ref()?;

    // The local model outputs the `content` part directly — a JSON object
    // with `"type"` and `"data"` fields matching `RenderContent`.
    let content: RenderContent = serde_json::from_str(text).ok()?;

    // Build full render params with a reasonable default size for chart/image
    // rendering (Transform::default() gives only 100x100 which is too small).
    use canvas_mcp::tools::Position;
    let params = RenderParams {
        session_id: "gui".to_owned(),
        content,
        position: Some(Position {
            x: 0.0,
            y: 0.0,
            width: Some(600.0),
            height: Some(400.0),
        }),
    };

    // Render the element into the canvas session.
    let element = crate::canvas::tools::render::render_content_to_element(&params);
    let reg = registry.lock().ok()?;
    let session_arc = reg.get("gui")?;
    let mut session = session_arc.lock().ok()?;
    session.add_element(element);
    drop(session);
    drop(reg);

    // Emit ToolCall/ToolResult so the GUI opens the canvas window.
    if let Some(rt) = runtime_tx {
        let input_json = serde_json::to_string(&params).unwrap_or_default();
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let id = format!("canvas_render:{ts}");
        let _ = rt.send(RuntimeEvent::ToolCall {
            id: id.clone(),
            name: "canvas_render".to_owned(),
            input_json,
        });
        let _ = rt.send(RuntimeEvent::ToolResult {
            id,
            name: "canvas_render".to_owned(),
            success: true,
            output_text: None,
        });
    }

    // Generate a brief spoken description for TTS.
    let description = match &params.content {
        RenderContent::Chart {
            title, chart_type, ..
        } => {
            if let Some(title) = title {
                format!("I've put that on the canvas. {title}.")
            } else {
                format!("Here's the {chart_type} chart on the canvas.")
            }
        }
        RenderContent::Image { alt, .. } => {
            if let Some(alt) = alt {
                format!("I've shown the image on the canvas. {alt}.")
            } else {
                "I've shown the image on the canvas.".to_owned()
            }
        }
        RenderContent::Text { .. } => "I've put that text on the canvas.".to_owned(),
        _ => "I've rendered that on the canvas.".to_owned(),
    };

    info!("intercepted JSON canvas output → rendered to canvas session");
    Some(description)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use crate::config::LlmBackend;
    use crate::memory::{MemoryKind, MemoryOrchestrator, MemoryRepository};
    use axum::{Json, Router, extract::State, routing::post};
    use std::collections::VecDeque;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex as StdMutex;
    use std::time::Duration;
    use tokio::sync::broadcast::error::TryRecvError;

    // ── clean_model_json ─────────────────────────────────────────────

    #[test]
    fn clean_json_billion() {
        let input = r#"[500000000, 1 billion, 1.25 billion]"#;
        let cleaned = clean_model_json(input);
        assert_eq!(cleaned, "[500000000, 1000000000, 1250000000]");
    }

    #[test]
    fn clean_json_million() {
        let input = r#"[900 million, 2.5 million]"#;
        let cleaned = clean_model_json(input);
        assert_eq!(cleaned, "[900000000, 2500000]");
    }

    #[test]
    fn clean_json_no_change_needed() {
        let input = r#"{"values": [100, 200, 300]}"#;
        let cleaned = clean_model_json(input);
        assert_eq!(cleaned, input);
    }

    #[test]
    fn clean_json_mixed() {
        let input = r#"[500000000, 550000000, 1 billion, 6.7 billion]"#;
        let cleaned = clean_model_json(input);
        assert_eq!(cleaned, "[500000000, 550000000, 1000000000, 6700000000]");
    }

    // ── extract_json_object ───────────────────────────────────────

    #[test]
    fn extract_json_pure_object() {
        let text = r#"{"type":"Chart","data":{"chart_type":"bar"}}"#;
        assert_eq!(extract_json_object(text), Some(text));
    }

    #[test]
    fn extract_json_with_preamble() {
        let text = r#"Here is a chart: {"type":"Chart","data":{"chart_type":"bar"}}"#;
        assert_eq!(
            extract_json_object(text),
            Some(r#"{"type":"Chart","data":{"chart_type":"bar"}}"#)
        );
    }

    #[test]
    fn extract_json_with_trailing_text() {
        let text = r#"{"type":"Chart","data":{}} I hope this helps!"#;
        assert_eq!(
            extract_json_object(text),
            Some(r#"{"type":"Chart","data":{}}"#)
        );
    }

    #[test]
    fn extract_json_nested_braces() {
        let text = r#"{"a":{"b":{"c":1}}}"#;
        assert_eq!(extract_json_object(text), Some(text));
    }

    #[test]
    fn extract_json_braces_in_strings() {
        let text = r#"{"label":"value {x}"}"#;
        assert_eq!(extract_json_object(text), Some(text));
    }

    #[test]
    fn extract_json_escaped_quotes() {
        let text = r#"{"label":"say \"hello\""}"#;
        assert_eq!(extract_json_object(text), Some(text));
    }

    #[test]
    fn extract_json_no_json() {
        assert_eq!(extract_json_object("no json here"), None);
    }

    #[test]
    fn extract_json_unbalanced() {
        assert_eq!(extract_json_object("{unclosed"), None);
    }

    // ── strip_markdown_fences ─────────────────────────────────────

    #[test]
    fn strip_fences_json_block() {
        let input = "```json\n{\"type\":\"Chart\"}\n```";
        let result = strip_markdown_fences(input);
        assert!(result.contains("{\"type\":\"Chart\"}"));
        assert!(!result.contains("```"));
    }

    #[test]
    fn strip_fences_plain_backticks() {
        let input = "```\n{\"key\":\"val\"}\n```";
        let result = strip_markdown_fences(input);
        assert!(result.contains("{\"key\":\"val\"}"));
        assert!(!result.contains("```"));
    }

    #[test]
    fn strip_fences_no_fences() {
        let input = "{\"key\":\"val\"}";
        let result = strip_markdown_fences(input);
        assert_eq!(result, input);
    }

    #[test]
    fn strip_fences_with_preamble() {
        let input = "here is the json ```json\n{\"a\":1}\n```";
        let result = strip_markdown_fences(input);
        assert!(result.contains("{\"a\":1}"));
        assert!(!result.contains("```"));
    }

    // ── find_wake_word ──────────────────────────────────────────────

    #[test]
    fn wake_word_exact_match() {
        assert_eq!(find_wake_word("fae tell me a joke", "fae"), Some((0, 3)));
    }

    #[test]
    fn wake_word_fee_variant() {
        // "fee" is the most common STT confusion for "fae"
        assert_eq!(find_wake_word("fee what time is it", "fae"), Some((0, 3)));
    }

    #[test]
    fn wake_word_fay_variant() {
        assert_eq!(find_wake_word("hey fay how are you", "fae"), Some((4, 3)));
    }

    #[test]
    fn wake_word_fey_variant() {
        assert_eq!(
            find_wake_word("fey, what is the weather", "fae"),
            Some((0, 3))
        );
    }

    #[test]
    fn wake_word_faye_variant() {
        assert_eq!(find_wake_word("faye tell me a story", "fae"), Some((0, 4)));
    }

    #[test]
    fn wake_word_fah_variant() {
        assert_eq!(find_wake_word("fah what is that", "fae"), Some((0, 3)));
    }

    #[test]
    fn wake_word_boundary_rejects_coffee() {
        // "coffee" contains "fee" but should NOT trigger the wake word
        assert_eq!(find_wake_word("i love coffee", "fae"), None);
    }

    #[test]
    fn wake_word_boundary_rejects_buffet() {
        // "buffet" contains "fey" substring — should not match
        assert_eq!(find_wake_word("we went to the buffet", "fae"), None);
    }

    #[test]
    fn wake_word_boundary_rejects_fayette() {
        // "fayette" starts with "fay" but is not at a word boundary on the right
        assert_eq!(find_wake_word("welcome to fayette", "fae"), None);
    }

    #[test]
    fn wake_word_with_punctuation() {
        // Punctuation counts as a word boundary
        assert_eq!(find_wake_word("fae, play some music", "fae"), Some((0, 3)));
        assert_eq!(find_wake_word("hey fee! what's up", "fae"), Some((4, 3)));
    }

    #[test]
    fn wake_word_mid_sentence() {
        assert_eq!(find_wake_word("hello fae how are you", "fae"), Some((6, 3)));
    }

    #[test]
    fn wake_word_empty_wake_word() {
        assert_eq!(find_wake_word("anything", ""), None);
    }

    #[test]
    fn wake_word_not_found() {
        assert_eq!(find_wake_word("tell me a joke", "fae"), None);
    }

    // ── canonicalize_wake_word_transcription ─────────────────────────

    #[test]
    fn canonicalize_fee_to_fae() {
        let result = canonicalize_wake_word_transcription("fae", "Fee what time is it");
        assert_eq!(result, Some("Fae what time is it".to_owned()));
    }

    #[test]
    fn canonicalize_fay_to_fae() {
        let result = canonicalize_wake_word_transcription("fae", "Fay, tell me a joke");
        assert_eq!(result, Some("Fae, tell me a joke".to_owned()));
    }

    #[test]
    fn canonicalize_faye_to_fae() {
        let result = canonicalize_wake_word_transcription("fae", "Faye how are you");
        assert_eq!(result, Some("Fae how are you".to_owned()));
    }

    #[test]
    fn canonicalize_hey_fee_to_hey_fae() {
        let result = canonicalize_wake_word_transcription("fae", "Hey fee, play music");
        assert_eq!(result, Some("Hey Fae, play music".to_owned()));
    }

    #[test]
    fn canonicalize_no_match() {
        let result = canonicalize_wake_word_transcription("fae", "tell me a joke");
        assert_eq!(result, None);
    }

    #[test]
    fn canonicalize_non_fae_wake_word_noop() {
        let result = canonicalize_wake_word_transcription("alexa", "alexa play music");
        assert_eq!(result, None);
    }

    #[test]
    fn canonicalize_hello_comma_fee() {
        // STT often produces "Hello, Fee." — the comma variant must be handled
        let result = canonicalize_wake_word_transcription("fae", "Hello, Fee.");
        assert_eq!(result, Some("Hello, Fae.".to_owned()));
    }

    #[test]
    fn canonicalize_hi_comma_fay() {
        let result = canonicalize_wake_word_transcription("fae", "Hi, Fay!");
        assert_eq!(result, Some("Hi, Fae!".to_owned()));
    }

    #[test]
    fn canonicalize_hey_comma_fee() {
        let result = canonicalize_wake_word_transcription("fae", "Hey, Fee how are you");
        assert_eq!(result, Some("Hey, Fae how are you".to_owned()));
    }

    #[test]
    fn canonicalize_okay_comma_fae() {
        let result = canonicalize_wake_word_transcription("fae", "Okay, Fae stop");
        assert_eq!(result, Some("Okay, Fae stop".to_owned()));
    }

    // ── wake word extraction helpers ────────────────────────────────

    /// Helper: given an input like "Hello, Fee.", simulate what the
    /// conversation gate extracts as the query to send to the LLM.
    fn extract_query(input: &str, wake_word: &str) -> Option<String> {
        let lower_raw = input.to_lowercase();
        let (pos, matched_len) = find_wake_word(&lower_raw, wake_word)?;

        let after = &input[pos + matched_len..];
        let after = after.trim_start_matches([',', ':', '.', '!', '?', ' ']);
        let after = after.trim();

        if !after.is_empty() {
            return Some(after.to_owned());
        }

        // Nothing after wake word — check for text before it
        let before = &input[..pos];
        let before = before.trim_end_matches([',', ':', '.', '!', '?', ' ']);
        let before = before.trim();

        if before.is_empty() {
            Some("Hello".to_owned())
        } else {
            Some(before.to_owned())
        }
    }

    #[test]
    fn extract_query_after_wake_word() {
        // "Fee what time is it" → query is "what time is it"
        assert_eq!(
            extract_query("fee what time is it", "fae"),
            Some("what time is it".to_owned())
        );
    }

    #[test]
    fn extract_query_hello_fee_dot() {
        // "Hello, Fee." → nothing after wake word → use "Hello" before it
        assert_eq!(
            extract_query("Hello, Fee.", "fae"),
            Some("Hello".to_owned())
        );
    }

    #[test]
    fn extract_query_hello_fee_no_punct() {
        // "Hello Fee" → nothing after → use "Hello"
        assert_eq!(extract_query("Hello Fee", "fae"), Some("Hello".to_owned()));
    }

    #[test]
    fn extract_query_hey_fae_how_are_you() {
        // "Hey Fae how are you" → query is "how are you"
        assert_eq!(
            extract_query("Hey Fae how are you", "fae"),
            Some("how are you".to_owned())
        );
    }

    #[test]
    fn extract_query_just_fae() {
        // Just "Fae" alone → default greeting "Hello"
        assert_eq!(extract_query("fae", "fae"), Some("Hello".to_owned()));
    }

    #[test]
    fn extract_query_fae_comma() {
        // "Fae," → nothing meaningful after → default "Hello"
        assert_eq!(extract_query("Fae,", "fae"), Some("Hello".to_owned()));
    }

    #[test]
    fn extract_query_hi_fae_excl() {
        // "Hi Fae!" → nothing after → "Hi" from before
        assert_eq!(extract_query("Hi Fae!", "fae"), Some("Hi".to_owned()));
    }

    // ── "hi fae" multi-word wake phrase ─────────────────────────────

    #[test]
    fn hi_fae_exact_match() {
        assert_eq!(find_wake_word("hi fae how are you", "hi fae"), Some((0, 6)));
    }

    #[test]
    fn hi_fae_with_comma() {
        assert_eq!(
            find_wake_word("hi, fae how are you", "hi fae"),
            Some((0, 7))
        );
    }

    #[test]
    fn hi_fee_variant() {
        assert_eq!(
            find_wake_word("hi fee what time is it", "hi fae"),
            Some((0, 6))
        );
    }

    #[test]
    fn hi_fea_variant() {
        assert_eq!(
            find_wake_word("hi fea tell me a joke", "hi fae"),
            Some((0, 6))
        );
    }

    #[test]
    fn high_fae_variant() {
        // STT may hear "high" instead of "hi"
        assert_eq!(
            find_wake_word("high fae how are you", "hi fae"),
            Some((0, 8))
        );
    }

    #[test]
    fn hey_fae_variant() {
        // "hey fae" is a close variant of "hi fae"
        assert_eq!(
            find_wake_word("hey fae how are you", "hi fae"),
            Some((0, 7))
        );
    }

    #[test]
    fn hi_fae_not_found() {
        assert_eq!(find_wake_word("tell me a joke", "hi fae"), None);
    }

    #[test]
    fn hi_fae_query_extraction() {
        // "Hi Fae, how are you" → "how are you"
        assert_eq!(
            extract_query("hi fae, how are you", "hi fae"),
            Some("how are you".to_owned())
        );
    }

    #[test]
    fn hi_fae_alone_gives_greeting() {
        // Just "Hi Fae" → default greeting
        assert_eq!(extract_query("hi fae", "hi fae"), Some("Hello".to_owned()));
    }

    #[test]
    fn hi_fea_query_extraction() {
        assert_eq!(
            extract_query("hi fea tell me a story", "hi fae"),
            Some("tell me a story".to_owned())
        );
    }

    #[test]
    fn canonicalize_hi_fae_variants() {
        // canonicalize should work with "hi fae" as wake word too
        let result = canonicalize_wake_word_transcription("hi fae", "Hi Fee, tell me a joke");
        assert_eq!(result, Some("Hi Fae, tell me a joke".to_owned()));
    }

    // ── find_name_mention (standalone name for barge-in) ────────────

    #[test]
    fn name_mention_standalone_fae() {
        assert_eq!(find_name_mention("fae stop talking"), Some((0, 3)));
    }

    #[test]
    fn name_mention_standalone_faye() {
        assert_eq!(find_name_mention("faye, what about this"), Some((0, 4)));
    }

    #[test]
    fn name_mention_mid_sentence() {
        assert_eq!(find_name_mention("hey fae how are you"), Some((4, 3)));
    }

    #[test]
    fn name_mention_end_of_sentence() {
        assert_eq!(find_name_mention("that will do fae"), Some((13, 3)));
    }

    #[test]
    fn name_mention_with_punctuation() {
        assert_eq!(find_name_mention("fae, stop!"), Some((0, 3)));
    }

    #[test]
    fn name_mention_rejects_coffee() {
        // "coffee" contains "fee" but should NOT match
        assert_eq!(find_name_mention("i love coffee"), None);
    }

    #[test]
    fn name_mention_rejects_fayette() {
        assert_eq!(find_name_mention("welcome to fayette"), None);
    }

    #[test]
    fn name_mention_not_found() {
        assert_eq!(find_name_mention("tell me a joke"), None);
    }

    // ── strip_punctuation ───────────────────────────────────────────

    #[test]
    fn strip_punct_removes_commas() {
        assert_eq!(strip_punctuation("that will do, fae"), "that will do fae");
    }

    #[test]
    fn strip_punct_removes_periods_and_exclamation() {
        assert_eq!(
            strip_punctuation("hello. how are you!"),
            "hello how are you"
        );
    }

    #[test]
    fn strip_punct_normalizes_whitespace() {
        assert_eq!(strip_punctuation("  hello   world  "), "hello world");
    }

    #[test]
    fn strip_punct_preserves_alphanumeric() {
        assert_eq!(strip_punctuation("hello fae 123"), "hello fae 123");
    }

    #[test]
    fn stop_phrase_with_comma_matches_after_strip() {
        // The actual scenario: STT produces "that will do, fae"
        // and the stop phrase is "that will do fae"
        let stt_output = "that will do, fae";
        let stop_phrase = "that will do fae";
        let expanded = expand_contractions(&stt_output.to_lowercase());
        let clean = strip_punctuation(&expanded);
        assert!(clean.contains(stop_phrase));
    }

    #[test]
    fn stop_phrase_contraction_with_comma() {
        // STT: "that'll do, Fae" → expand → "that will do, fae" → strip → "that will do fae"
        let stt_output = "that'll do, fae";
        let stop_phrase = "that will do fae";
        let expanded = expand_contractions(&stt_output.to_lowercase());
        let clean = strip_punctuation(&expanded);
        assert!(clean.contains(stop_phrase));
    }

    #[test]
    fn show_conversation_request_detected() {
        assert!(is_show_conversation_request("Fae show me the conversation"));
        assert!(is_show_conversation_request("open conversation history"));
        assert!(is_show_conversation_request("bring up chat history"));
    }

    #[test]
    fn show_conversation_request_rejects_unrelated_history() {
        assert!(!is_show_conversation_request(
            "show me the history of scotland"
        ));
        assert!(!is_show_conversation_request(
            "what is our conversation about"
        ));
    }

    #[test]
    fn hide_conversation_request_detected() {
        assert!(is_hide_conversation_request("hide the conversation"));
        assert!(is_hide_conversation_request("close chat history"));
        assert!(is_hide_conversation_request("close the canvas"));
    }

    #[test]
    fn hide_conversation_request_rejects_unrelated_close() {
        assert!(!is_hide_conversation_request("close the door"));
        assert!(!is_hide_conversation_request(
            "hide the history of scotland"
        ));
    }

    // ── parse_name ──────────────────────────────────────────────────

    #[test]
    fn parse_name_my_name_is() {
        assert_eq!(parse_name("my name is David"), Some("David".to_owned()));
    }

    #[test]
    fn parse_name_i_am() {
        assert_eq!(parse_name("I am Sarah"), Some("Sarah".to_owned()));
    }

    #[test]
    fn parse_name_im_contraction() {
        assert_eq!(parse_name("I'm Alice"), Some("Alice".to_owned()));
    }

    #[test]
    fn parse_name_call_me() {
        assert_eq!(parse_name("call me Bob"), Some("Bob".to_owned()));
    }

    #[test]
    fn parse_name_greeting_then_pattern() {
        // "Hello, I'm David" — pattern found mid-string, not at start
        assert_eq!(parse_name("Hello, I'm David"), Some("David".to_owned()));
    }

    #[test]
    fn parse_name_hi_im() {
        assert_eq!(parse_name("Hi, I'm Sarah"), Some("Sarah".to_owned()));
    }

    #[test]
    fn parse_name_hey_my_name_is() {
        assert_eq!(parse_name("Hey, my name is Alex"), Some("Alex".to_owned()));
    }

    #[test]
    fn parse_name_hello_alone_rejected() {
        // "Hello" is a greeting, not a name
        assert_eq!(parse_name("Hello"), None);
    }

    #[test]
    fn parse_name_hi_alone_rejected() {
        assert_eq!(parse_name("Hi"), None);
    }

    #[test]
    fn parse_name_hey_alone_rejected() {
        assert_eq!(parse_name("Hey"), None);
    }

    #[test]
    fn parse_name_hello_fae_rejected() {
        // Both "hello" and "fae" are filler words
        assert_eq!(parse_name("Hello Fae"), None);
    }

    #[test]
    fn parse_name_single_word_name() {
        // Just a name with no pattern prefix
        assert_eq!(parse_name("David"), Some("David".to_owned()));
    }

    #[test]
    fn parse_name_greeting_then_name_no_pattern() {
        // "Hello David" — no "I'm"/"my name is" pattern, fallback picks last non-filler
        assert_eq!(parse_name("Hello David"), Some("David".to_owned()));
    }

    #[test]
    fn parse_name_empty_string() {
        assert_eq!(parse_name(""), None);
    }

    #[test]
    fn parse_name_whitespace_only() {
        assert_eq!(parse_name("   "), None);
    }

    #[test]
    fn parse_name_with_punctuation() {
        assert_eq!(parse_name("I'm David."), Some("David".to_owned()));
    }

    #[test]
    fn parse_name_its_pattern() {
        assert_eq!(parse_name("it's James"), Some("James".to_owned()));
    }

    // ── is_filler_word ──────────────────────────────────────────────

    #[test]
    fn filler_rejects_greetings() {
        assert!(is_filler_word("hello"));
        assert!(is_filler_word("hi"));
        assert!(is_filler_word("hey"));
        assert!(is_filler_word("morning"));
    }

    #[test]
    fn filler_rejects_fae_variants() {
        assert!(is_filler_word("fae"));
        assert!(is_filler_word("faye"));
        assert!(is_filler_word("fee"));
    }

    #[test]
    fn filler_accepts_real_names() {
        assert!(!is_filler_word("david"));
        assert!(!is_filler_word("sarah"));
        assert!(!is_filler_word("alex"));
    }

    #[derive(Clone)]
    struct MockApiState {
        requests: Arc<StdMutex<Vec<serde_json::Value>>>,
        responses: Arc<StdMutex<VecDeque<String>>>,
        response_delays_ms: Arc<StdMutex<VecDeque<u64>>>,
    }

    struct MockApiServer {
        url: String,
        requests: Arc<StdMutex<Vec<serde_json::Value>>>,
        handle: tokio::task::JoinHandle<()>,
    }

    async fn mock_chat_completions(
        State(state): State<MockApiState>,
        Json(payload): Json<serde_json::Value>,
    ) -> impl axum::response::IntoResponse {
        state.requests.lock().expect("lock requests").push(payload);
        let delay_ms = state
            .response_delays_ms
            .lock()
            .expect("lock response delays")
            .pop_front()
            .unwrap_or(0);
        if delay_ms > 0 {
            tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        }
        let text = state
            .responses
            .lock()
            .expect("lock responses")
            .pop_front()
            .unwrap_or_else(|| "Noted.".to_owned());

        let chunk = serde_json::json!({
            "choices": [{
                "delta": { "content": text },
                "finish_reason": serde_json::Value::Null
            }]
        });
        let done = serde_json::json!({
            "choices": [{
                "delta": {},
                "finish_reason": "stop"
            }]
        });
        let body = format!("data: {chunk}\n\ndata: {done}\n\ndata: [DONE]\n\n");

        (
            [(axum::http::header::CONTENT_TYPE, "text/event-stream")],
            body,
        )
    }

    async fn start_mock_api_server_with_delays(
        responses: &[&str],
        delays_ms: &[u64],
    ) -> MockApiServer {
        let requests = Arc::new(StdMutex::new(Vec::new()));
        let responses = Arc::new(StdMutex::new(
            responses
                .iter()
                .map(|s| (*s).to_owned())
                .collect::<VecDeque<_>>(),
        ));
        let response_delays_ms = Arc::new(StdMutex::new(
            delays_ms.iter().copied().collect::<VecDeque<_>>(),
        ));
        let state = MockApiState {
            requests: Arc::clone(&requests),
            responses,
            response_delays_ms,
        };

        let app = Router::new()
            .route("/v1/chat/completions", post(mock_chat_completions))
            .with_state(state);

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind mock API listener");
        let addr = listener.local_addr().expect("mock API local addr");
        let handle = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("mock API server run");
        });

        MockApiServer {
            url: format!("http://{addr}"),
            requests,
            handle,
        }
    }

    async fn start_mock_api_server(responses: &[&str]) -> MockApiServer {
        let delays = vec![0_u64; responses.len()];
        start_mock_api_server_with_delays(responses, &delays).await
    }

    impl MockApiServer {
        fn request_count(&self) -> usize {
            self.requests.lock().expect("lock requests").len()
        }

        fn request_user_inputs(&self) -> Vec<String> {
            let requests = self.requests.lock().expect("lock requests");
            requests
                .iter()
                .filter_map(extract_last_user_message)
                .collect()
        }

        /// Returns the full (enriched) user message content from each API request,
        /// including any prepended context (memory, onboarding, coding assistants).
        fn request_raw_user_inputs(&self) -> Vec<String> {
            let requests = self.requests.lock().expect("lock requests");
            requests
                .iter()
                .filter_map(extract_raw_last_user_message)
                .collect()
        }

        async fn shutdown(self) {
            self.handle.abort();
            let _ = self.handle.await;
        }
    }

    async fn wait_for_mock_requests(server: &MockApiServer, min_count: usize) {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if server.request_count() >= min_count {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("wait for mock API requests");
    }

    fn extract_last_user_message(payload: &serde_json::Value) -> Option<String> {
        let messages = payload.get("messages")?.as_array()?;
        messages.iter().rev().find_map(|m| {
            if m.get("role")?.as_str()? == "user" {
                let content = m.get("content")?.as_str()?;
                // Strip enrichment context (local_coding_assistants, onboarding_context)
                // that gets prepended to user messages. The original user text follows
                // the "User message:\n" marker.
                if let Some(idx) = content.rfind("User message:\n") {
                    Some(content[idx + "User message:\n".len()..].to_owned())
                } else {
                    Some(content.to_owned())
                }
            } else {
                None
            }
        })
    }

    /// Returns the full raw content of the last user message without stripping
    /// enrichment context. Used to verify memory/onboarding context injection.
    fn extract_raw_last_user_message(payload: &serde_json::Value) -> Option<String> {
        let messages = payload.get("messages")?.as_array()?;
        messages.iter().rev().find_map(|m| {
            if m.get("role")?.as_str()? == "user" {
                m.get("content")?.as_str().map(str::to_owned)
            } else {
                None
            }
        })
    }

    fn temp_root(name: &str) -> PathBuf {
        crate::test_utils::temp_test_root("coordinator-memory", name)
    }

    fn api_test_config(root: &Path, api_url: String) -> SpeechConfig {
        let mut config = SpeechConfig::default();
        config.llm.backend = LlmBackend::Api;
        config.llm.api_url = api_url;
        config.llm.api_model = "fae-test".to_owned();
        config.llm.api_key = crate::credentials::CredentialRef::None;
        config.llm.max_tokens = 64;
        config.memory.root_dir = root.to_path_buf();
        config.memory.enabled = true;
        config.memory.auto_recall = true;
        config.memory.auto_capture = true;
        config
    }

    use crate::test_utils::seed_manifest_v0;

    fn make_transcription(text: &str) -> Transcription {
        let now = Instant::now();
        Transcription {
            text: text.to_owned(),
            is_final: true,
            voiceprint: None,
            audio_captured_at: now,
            transcribed_at: now,
        }
    }

    fn make_llm_stage_control(
        runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    ) -> LlmStageControl {
        make_llm_stage_control_with_queue(runtime_tx, None)
    }

    fn make_llm_stage_control_with_queue(
        runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
        queue_cmd_rx: Option<mpsc::UnboundedReceiver<LlmQueueCommand>>,
    ) -> LlmStageControl {
        let (playback_cmd_tx, _playback_cmd_rx) = mpsc::unbounded_channel();
        LlmStageControl {
            interrupt: Arc::new(AtomicBool::new(false)),
            assistant_speaking: Arc::new(AtomicBool::new(false)),
            assistant_generating: Arc::new(AtomicBool::new(false)),
            playback_cmd_tx,
            runtime_tx,
            tool_approval_tx: None,
            canvas_registry: None,
            console_output: false,
            cancel: CancellationToken::new(),
            voice_command_rx: None,
            queue_cmd_rx,
        }
    }

    fn spawn_llm_stage_for_test(
        config: SpeechConfig,
        input_rx: mpsc::Receiver<Transcription>,
        sentence_tx: mpsc::Sender<SentenceChunk>,
        ctl: LlmStageControl,
    ) -> tokio::task::JoinHandle<()> {
        tokio::task::spawn_blocking(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build test runtime for llm stage");
            runtime.block_on(async move {
                run_llm_stage(config, None, input_rx, sentence_tx, ctl, None).await;
            });
        })
    }

    fn collect_runtime_events(rx: &mut broadcast::Receiver<RuntimeEvent>) -> Vec<RuntimeEvent> {
        let mut events = Vec::new();
        loop {
            match rx.try_recv() {
                Ok(event) => events.push(event),
                Err(TryRecvError::Empty) | Err(TryRecvError::Closed) => break,
                Err(TryRecvError::Lagged(_)) => {}
            }
        }
        events
    }

    #[tokio::test]
    async fn llm_stage_recall_injects_memory_context_and_emits_runtime_event() {
        let root = temp_root("recall-context");
        let server = start_mock_api_server(&["Your name is Alice."]).await;
        let config = api_test_config(&root, server.url.clone());

        let seed = MemoryOrchestrator::new(&config.memory);
        seed.capture_turn("seed-turn", "My name is Alice.", "Noted.")
            .expect("seed memory with name");

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, _sentence_rx) = mpsc::channel(32);
        let (runtime_tx, mut runtime_rx) = broadcast::channel(64);
        let ctl = make_llm_stage_control(Some(runtime_tx.clone()));

        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        input_tx
            .send(make_transcription("What is my name?"))
            .await
            .expect("send transcription");
        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(5), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        let user_inputs = server.request_raw_user_inputs();
        assert_eq!(user_inputs.len(), 1);
        assert!(user_inputs[0].contains("<memory_context>"));
        assert!(user_inputs[0].contains("Primary user name is Alice."));
        assert!(user_inputs[0].contains("User message:\nWhat is my name?"));

        let events = collect_runtime_events(&mut runtime_rx);
        assert!(events.iter().any(|event| matches!(
            event,
            RuntimeEvent::MemoryRecall { query, hits }
            if query == "What is my name?" && *hits >= 1
        )));

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_captures_turn_memories_after_generation() {
        let root = temp_root("capture-turn");
        let server = start_mock_api_server(&["Noted."]).await;
        let config = api_test_config(&root, server.url.clone());

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, _sentence_rx) = mpsc::channel(32);
        let ctl = make_llm_stage_control(None);

        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        input_tx
            .send(make_transcription("I prefer tea."))
            .await
            .expect("send transcription");
        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(5), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        let repo = MemoryRepository::new(&root);
        let records = repo.list_records().expect("list memory records");
        assert!(records.iter().any(|record| {
            record.kind == MemoryKind::Episode && record.text.contains("User: I prefer tea.")
        }));

        let preferences = repo
            .find_active_by_tag("preference")
            .expect("find active preferences");
        assert_eq!(preferences.len(), 1);
        assert!(preferences[0].text.to_ascii_lowercase().contains("tea"));

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_emits_memory_write_and_conflict_events() {
        let root = temp_root("event-emission");
        let server = start_mock_api_server(&["Noted.", "Updated."]).await;
        let config = api_test_config(&root, server.url.clone());

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, _sentence_rx) = mpsc::channel(32);
        let (runtime_tx, mut runtime_rx) = broadcast::channel(128);
        let ctl = make_llm_stage_control(Some(runtime_tx.clone()));

        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        input_tx
            .send(make_transcription("My name is Alice."))
            .await
            .expect("send first transcription");
        input_tx
            .send(make_transcription("Actually my name is Bob."))
            .await
            .expect("send second transcription");
        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(5), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        let events = collect_runtime_events(&mut runtime_rx);
        assert!(events.iter().any(|event| matches!(
            event,
            RuntimeEvent::MemoryWrite { op, target_id: Some(id) }
            if op == "insert_episode" && !id.is_empty()
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            RuntimeEvent::MemoryWrite { op, target_id: Some(id) }
            if op == "update_profile" && !id.is_empty()
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            RuntimeEvent::MemoryConflict {
                existing_id,
                replacement_id: Some(replacement_id)
            } if existing_id != "conflict" && !existing_id.is_empty() && !replacement_id.is_empty()
        )));

        let repo = MemoryRepository::new(&root);
        let active_name = repo
            .find_active_by_tag("name")
            .expect("find active names")
            .into_iter()
            .next()
            .expect("active name record");
        assert!(active_name.text.contains("Bob"));

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_emits_memory_migration_success_event_on_startup() {
        let root = temp_root("migration-success-event");
        seed_manifest_v0(&root);
        let server = start_mock_api_server(&["Noted."]).await;
        let config = api_test_config(&root, server.url.clone());

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, _sentence_rx) = mpsc::channel(8);
        let (runtime_tx, mut runtime_rx) = broadcast::channel(64);
        let ctl = make_llm_stage_control(Some(runtime_tx.clone()));

        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(5), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        let events = collect_runtime_events(&mut runtime_rx);
        assert!(events.iter().any(|event| matches!(
            event,
            RuntimeEvent::MemoryMigration { from, to, success }
            if *from == 0 && *to == 1 && *success
        )));

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_emits_memory_migration_failure_event_on_startup() {
        let root = temp_root("migration-failure-event");
        seed_manifest_v0(&root);
        std::fs::write(root.join("memory").join(".fail_migration"), "1").expect("write failpoint");
        let server = start_mock_api_server(&["Noted."]).await;
        let config = api_test_config(&root, server.url.clone());

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, _sentence_rx) = mpsc::channel(8);
        let (runtime_tx, mut runtime_rx) = broadcast::channel(64);
        let ctl = make_llm_stage_control(Some(runtime_tx.clone()));

        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(5), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        let events = collect_runtime_events(&mut runtime_rx);
        assert!(events.iter().any(|event| matches!(
            event,
            RuntimeEvent::MemoryMigration { from, to, success }
            if *from == 0 && *to == 1 && !*success
        )));

        let repo = MemoryRepository::new(&root);
        let schema = repo.schema_version().expect("schema version");
        assert_eq!(schema, 0);

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_queue_followup_replays_each_pending_message() {
        let root = temp_root("queue-followup");
        let server = start_mock_api_server_with_delays(
            &["First reply.", "Second reply.", "Third reply."],
            &[300, 0, 0],
        )
        .await;
        let mut config = api_test_config(&root, server.url.clone());
        config.llm.message_queue_mode = LlmMessageQueueMode::Followup;
        config.llm.message_queue_max_pending = 8;
        config.llm.message_queue_drop_policy = LlmMessageQueueDropPolicy::Oldest;

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, _sentence_rx) = mpsc::channel(32);
        let ctl = make_llm_stage_control(None);
        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        input_tx
            .send(make_transcription("first"))
            .await
            .expect("send first transcription");
        wait_for_mock_requests(&server, 1).await;
        input_tx
            .send(make_transcription("second"))
            .await
            .expect("send second transcription");
        input_tx
            .send(make_transcription("third"))
            .await
            .expect("send third transcription");
        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(8), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        let user_inputs = server.request_user_inputs();
        assert_eq!(
            user_inputs,
            vec!["first".to_owned(), "second".to_owned(), "third".to_owned(),]
        );

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_queue_collect_merges_pending_messages() {
        let root = temp_root("queue-collect");
        let server =
            start_mock_api_server_with_delays(&["First reply.", "Collected reply."], &[300, 0])
                .await;
        let mut config = api_test_config(&root, server.url.clone());
        config.llm.message_queue_mode = LlmMessageQueueMode::Collect;
        config.llm.message_queue_max_pending = 8;
        config.llm.message_queue_drop_policy = LlmMessageQueueDropPolicy::Oldest;

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, _sentence_rx) = mpsc::channel(32);
        let ctl = make_llm_stage_control(None);
        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        input_tx
            .send(make_transcription("first"))
            .await
            .expect("send first transcription");
        wait_for_mock_requests(&server, 1).await;
        input_tx
            .send(make_transcription("second"))
            .await
            .expect("send second transcription");
        input_tx
            .send(make_transcription("third"))
            .await
            .expect("send third transcription");
        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(8), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        let user_inputs = server.request_user_inputs();
        assert_eq!(user_inputs.len(), 2);
        assert_eq!(user_inputs[0], "first");
        assert_eq!(user_inputs[1], "second\n\nthird");

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_queue_drop_oldest_keeps_latest_when_full() {
        let root = temp_root("queue-drop-oldest");
        let server =
            start_mock_api_server_with_delays(&["First reply.", "Latest reply."], &[300, 0]).await;
        let mut config = api_test_config(&root, server.url.clone());
        config.llm.message_queue_mode = LlmMessageQueueMode::Followup;
        config.llm.message_queue_max_pending = 1;
        config.llm.message_queue_drop_policy = LlmMessageQueueDropPolicy::Oldest;

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, _sentence_rx) = mpsc::channel(32);
        let ctl = make_llm_stage_control(None);
        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        input_tx
            .send(make_transcription("first"))
            .await
            .expect("send first transcription");
        wait_for_mock_requests(&server, 1).await;
        input_tx
            .send(make_transcription("second"))
            .await
            .expect("send second transcription");
        input_tx
            .send(make_transcription("third"))
            .await
            .expect("send third transcription");
        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(8), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        let user_inputs = server.request_user_inputs();
        assert_eq!(user_inputs, vec!["first".to_owned(), "third".to_owned()]);

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_clear_queued_command_drops_pending_inputs() {
        let root = temp_root("queue-clear-command");
        let server =
            start_mock_api_server_with_delays(&["First reply.", "Should not run."], &[300, 0])
                .await;
        let mut config = api_test_config(&root, server.url.clone());
        config.llm.message_queue_mode = LlmMessageQueueMode::Followup;
        config.llm.message_queue_max_pending = 8;
        config.llm.message_queue_drop_policy = LlmMessageQueueDropPolicy::Oldest;

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, _sentence_rx) = mpsc::channel(32);
        let (queue_cmd_tx, queue_cmd_rx) = mpsc::unbounded_channel::<LlmQueueCommand>();
        let ctl = make_llm_stage_control_with_queue(None, Some(queue_cmd_rx));
        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        input_tx
            .send(make_transcription("first"))
            .await
            .expect("send first transcription");
        wait_for_mock_requests(&server, 1).await;
        input_tx
            .send(make_transcription("second"))
            .await
            .expect("send second transcription");
        queue_cmd_tx
            .send(LlmQueueCommand::ClearQueuedInputs)
            .expect("send clear queued command");
        drop(input_tx);
        drop(queue_cmd_tx);

        tokio::time::timeout(Duration::from_secs(8), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        let user_inputs = server.request_user_inputs();
        assert_eq!(user_inputs, vec!["first".to_owned()]);

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_show_conversation_command_emits_snapshot_and_uses_full_history() {
        let root = temp_root("show-conversation-canvas");
        let server = start_mock_api_server(&["Hello there."]).await;
        let mut config = api_test_config(&root, server.url.clone());
        config.llm.message_queue_mode = LlmMessageQueueMode::Followup;

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, mut sentence_rx) = mpsc::channel(32);
        let (runtime_tx, mut runtime_rx) = broadcast::channel(128);
        let ctl = make_llm_stage_control(Some(runtime_tx));
        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        input_tx
            .send(make_transcription("hello fae"))
            .await
            .expect("send first transcription");
        wait_for_mock_requests(&server, 1).await;
        input_tx
            .send(make_transcription("show me the conversation"))
            .await
            .expect("send show conversation command");
        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(8), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        // Only the first user message should hit the model.
        assert_eq!(server.request_count(), 1);

        let events = collect_runtime_events(&mut runtime_rx);
        let snapshot = events.iter().find_map(|event| match event {
            RuntimeEvent::ConversationSnapshot { entries } => Some(entries),
            _ => None,
        });
        let Some(snapshot) = snapshot else {
            unreachable!("expected conversation snapshot runtime event");
        };
        assert!(snapshot.iter().any(|entry| {
            entry.role == ConversationSnapshotEntryRole::User && entry.text == "hello fae"
        }));
        assert!(snapshot.iter().any(|entry| {
            entry.role == ConversationSnapshotEntryRole::Assistant
                && entry.text.contains("Hello there.")
        }));
        assert!(snapshot.iter().any(|entry| {
            entry.role == ConversationSnapshotEntryRole::User
                && entry.text.contains("show me the conversation")
        }));
        assert!(snapshot.iter().any(|entry| {
            entry.role == ConversationSnapshotEntryRole::Assistant
                && entry
                    .text
                    .contains("opened the canvas with our full conversation")
        }));

        // Assistant should acknowledge opening canvas from the command path.
        let mut saw_canvas_ack = false;
        while let Ok(chunk) = sentence_rx.try_recv() {
            if chunk
                .text
                .to_ascii_lowercase()
                .contains("opened the canvas with our full conversation")
            {
                saw_canvas_ack = true;
                break;
            }
        }
        assert!(saw_canvas_ack);

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn llm_stage_hide_conversation_command_emits_visibility_and_skips_model() {
        let root = temp_root("hide-conversation-canvas");
        let server = start_mock_api_server(&["Hello there."]).await;
        let mut config = api_test_config(&root, server.url.clone());
        config.llm.message_queue_mode = LlmMessageQueueMode::Followup;

        let (input_tx, input_rx) = mpsc::channel(8);
        let (sentence_tx, mut sentence_rx) = mpsc::channel(32);
        let (runtime_tx, mut runtime_rx) = broadcast::channel(128);
        let ctl = make_llm_stage_control(Some(runtime_tx));
        let stage = spawn_llm_stage_for_test(config, input_rx, sentence_tx, ctl);

        input_tx
            .send(make_transcription("hello fae"))
            .await
            .expect("send first transcription");
        wait_for_mock_requests(&server, 1).await;
        input_tx
            .send(make_transcription("hide the conversation"))
            .await
            .expect("send hide conversation command");
        drop(input_tx);

        tokio::time::timeout(Duration::from_secs(8), stage)
            .await
            .expect("llm stage timeout")
            .expect("llm stage join");

        // Only the first user message should hit the model.
        assert_eq!(server.request_count(), 1);

        let events = collect_runtime_events(&mut runtime_rx);
        assert!(events.iter().any(|event| matches!(
            event,
            RuntimeEvent::ConversationCanvasVisibility { visible } if !visible
        )));
        assert!(
            !events
                .iter()
                .any(|event| matches!(event, RuntimeEvent::ConversationSnapshot { .. }))
        );

        // Assistant should acknowledge hiding the canvas from the command path.
        let mut saw_canvas_ack = false;
        while let Ok(chunk) = sentence_rx.try_recv() {
            if chunk
                .text
                .to_ascii_lowercase()
                .contains("hidden the conversation canvas")
            {
                saw_canvas_ack = true;
                break;
            }
        }
        assert!(saw_canvas_ack);

        server.shutdown().await;
        let _ = std::fs::remove_dir_all(root);
    }

    #[tokio::test]
    async fn conversation_gate_sleep_emits_clear_queued_command() {
        let config = SpeechConfig::default();
        let (stt_tx, stt_rx) = mpsc::channel(8);
        let (llm_tx, _llm_rx) = mpsc::channel(8);
        let (playback_cmd_tx, _playback_cmd_rx) = mpsc::unbounded_channel();
        let (gate_cmd_tx, gate_cmd_rx) = mpsc::unbounded_channel();
        let (llm_queue_cmd_tx, mut llm_queue_cmd_rx) = mpsc::unbounded_channel::<LlmQueueCommand>();
        let cancel = CancellationToken::new();

        let ctl = ConversationGateControl {
            interrupt: Arc::new(AtomicBool::new(false)),
            assistant_speaking: Arc::new(AtomicBool::new(false)),
            assistant_generating: Arc::new(AtomicBool::new(false)),
            playback_cmd_tx,
            llm_queue_cmd_tx: Some(llm_queue_cmd_tx),
            clear_queue_on_stop: true,
            console_output: false,
            cancel: cancel.clone(),
            wakeword_rx: None,
            gate_cmd_rx: Some(gate_cmd_rx),
            gate_active: Arc::new(AtomicBool::new(false)),
        };

        let handle = tokio::spawn(async move {
            run_conversation_gate(config, stt_rx, llm_tx, ctl).await;
        });

        gate_cmd_tx
            .send(GateCommand::Wake)
            .expect("send wake command");
        gate_cmd_tx
            .send(GateCommand::Sleep)
            .expect("send sleep command");

        let cmd = tokio::time::timeout(Duration::from_secs(2), llm_queue_cmd_rx.recv())
            .await
            .expect("wait for queue clear command");
        assert_eq!(cmd, Some(LlmQueueCommand::ClearQueuedInputs));

        cancel.cancel();
        drop(stt_tx);
        let _ = handle.await;
    }
}
