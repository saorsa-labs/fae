//! Main pipeline orchestrator that wires all stages together.

use crate::approval::ToolApprovalRequest;
use crate::audio::aec::{AecProcessor, ReferenceBuffer, ReferenceHandle};
use crate::canvas::registry::CanvasSessionRegistry;
use crate::config::{SpeechConfig, VoiceIdentityMode};
use crate::error::Result;
use crate::memory::{MemoryOrchestrator, MemoryStore};
use crate::pipeline::conversation::{
    ConversationTurn, append_conversation_turn, build_background_context,
    build_conversation_snapshot_entries, capture_memory_turn,
};
use crate::pipeline::input_queue::{
    LlmInputQueue, QueuedLlmInput, clear_pending_inputs, enqueue_pending_input,
};
use crate::pipeline::messages::{
    AudioChunk, ControlEvent, GateCommand, SentenceChunk, SpeechSegment, SynthesizedAudio,
    TextInjection, Transcription,
};
use crate::pipeline::voice_approval::{
    ApprovalContext, PendingVoiceApproval, resolve_and_advance_approval, start_voice_approval,
};
use crate::pipeline::voice_identity::{
    approval_speaker_verified, build_voice_identity_profile, extract_voiceprint_samples,
    load_approval_voice_profile,
};
use crate::runtime::RuntimeEvent;
use crate::startup::InitializedModels;
use crate::time_util::now_epoch_secs;
use crate::tts::kokoro::strip_non_speech_chars;
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
    /// Play a brief thinking acknowledgment tone so the user knows Fae heard them.
    ThinkingTone,
    /// Play a short ascending two-note chime (C5→E5, ~200ms) to signal that Fae
    /// is listening for a yes/no approval response. Distinct from `ThinkingTone`.
    ListeningTone,
}

/// Commands sent to the LLM stage for queue control.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LlmQueueCommand {
    ClearQueuedInputs,
}

/// Pipeline operating mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipelineMode {
    /// Full conversation: capture → VAD → STT → LLM → TTS → playback.
    Conversation,
    /// Transcription only: capture → VAD → STT → print.
    TranscribeOnly,
    /// Text-only degraded mode: no audio capture/STT stages.
    ///
    /// Activated when audio capture or STT is unavailable. Only
    /// `TextInjection` inputs are accepted. LLM + TTS stages still run.
    TextOnly,
    /// LLM-only degraded mode: no TTS or audio playback.
    ///
    /// Activated when TTS or audio playback is unavailable. STT inputs are
    /// accepted but responses are emitted as text events only (no audio).
    LlmOnly,
}

impl std::fmt::Display for PipelineMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Conversation => write!(f, "conversation"),
            Self::TranscribeOnly => write!(f, "transcribe_only"),
            Self::TextOnly => write!(f, "text_only"),
            Self::LlmOnly => write!(f, "llm_only"),
        }
    }
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
    /// Live shared permission store from the command handler.
    ///
    /// When set via [`with_shared_permissions`], this is threaded into the
    /// LLM stage so JIT grants from `capability.grant` commands are
    /// immediately visible to Apple ecosystem tool gates.
    shared_permissions: Option<crate::permissions::SharedPermissionStore>,
    /// Sender for voice commands detected by the pipeline filter.
    ///
    /// Created during `run()` and passed to the LLM stage (Phase 2.2)
    voice_command_tx: Option<mpsc::UnboundedSender<crate::voice_command::VoiceCommand>>,
    /// Receiver for approval notifications from the handler bridge.
    ///
    /// When a tool requires user consent, the handler sends an
    /// [`ApprovalNotification`] here so the coordinator can speak the prompt
    /// and listen for a voice yes/no.
    approval_notification_rx:
        Option<mpsc::UnboundedReceiver<super::messages::ApprovalNotification>>,
    /// Sender for resolved approval responses back to the handler.
    ///
    /// The coordinator sends `(request_id, approved)` after the user responds
    /// via voice (or after timeout).
    approval_response_tx: Option<mpsc::UnboundedSender<(u64, bool)>>,
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
            shared_permissions: None,
            voice_command_tx: None,
            approval_notification_rx: None,
            approval_response_tx: None,
        }
    }

    /// Create a coordinator with pre-loaded models from startup initialization.
    ///
    /// This skips lazy loading inside each stage, avoiding mid-conversation delays.
    pub fn with_models(config: SpeechConfig, models: InitializedModels) -> Self {
        let mut coord = Self::new(config);
        coord.models = Some(models);
        coord
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

    /// Thread a live [`crate::permissions::SharedPermissionStore`] into the LLM stage.
    ///
    /// When set, the Apple ecosystem tool availability gates use this store to
    /// check permissions at execution time.  Runtime grants (via
    /// `capability.grant` commands from the command handler) are immediately
    /// visible — no pipeline restart is needed.
    pub fn with_shared_permissions(
        mut self,
        permissions: crate::permissions::SharedPermissionStore,
    ) -> Self {
        self.shared_permissions = Some(permissions);
        self
    }

    /// Attach voice-based approval channels.
    ///
    /// The `notification_rx` delivers [`ApprovalNotification`] messages from
    /// the handler bridge when a tool requests consent.  The coordinator
    /// speaks the prompt, listens for a voice yes/no, and sends
    /// `(request_id, approved)` back through `response_tx`.
    pub fn with_approval_voice(
        mut self,
        notification_rx: mpsc::UnboundedReceiver<super::messages::ApprovalNotification>,
        response_tx: mpsc::UnboundedSender<(u64, bool)>,
    ) -> Self {
        self.approval_notification_rx = Some(notification_rx);
        self.approval_response_tx = Some(response_tx);
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
        let awaiting_approval = Arc::new(AtomicBool::new(false));

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

        // Audio goes directly to VAD (no wakeword tee needed in always-on mode).
        let final_vad_rx = vad_audio_rx;

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
                awaiting_approval: Arc::clone(&awaiting_approval),
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
                    let runtime_tx = runtime_tx.clone();
                    tokio::spawn(async move {
                        run_identity_gate(
                            config,
                            transcription_rx,
                            ident_tx,
                            tts_tx,
                            memory_root,
                            onboarding_seg_rx,
                            runtime_tx,
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
                        gate_cmd_rx: self.gate_cmd_rx.take(),
                        gate_active: Arc::clone(&self.gate_active),
                        awaiting_approval: Arc::clone(&awaiting_approval),
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
                    let awaiting_approval_for_llm = Arc::clone(&awaiting_approval);
                    let playback_cmd_tx = playback_cmd_tx.clone();
                    let runtime_tx = runtime_tx.clone();
                    let tool_approval_tx = tool_approval_tx.clone();
                    let canvas_registry = canvas_registry.clone();
                    let shared_permissions = self.shared_permissions.clone();
                    let approval_notification_rx = self.approval_notification_rx.take();
                    let approval_response_tx = self.approval_response_tx.take();
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
                                shared_permissions,
                                console_output,
                                cancel,
                                voice_command_rx: Some(voice_cmd_rx),
                                queue_cmd_rx: Some(llm_queue_cmd_rx),
                                awaiting_approval: awaiting_approval_for_llm,
                                approval_notification_rx,
                                approval_response_tx,
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
                    let awaiting_approval_ctl = Arc::clone(&awaiting_approval);
                    let playback_cmd_tx = playback_cmd_tx.clone();
                    let barge_in = self.config.barge_in.clone();
                    let runtime_tx = runtime_tx.clone();
                    let name_gated = aec_enabled && self.config.conversation.enabled;
                    let echo_tail_for_tone = if aec_enabled {
                        std::time::Duration::from_millis(1500)
                    } else {
                        std::time::Duration::from_millis(3000)
                    };
                    tokio::spawn(async move {
                        let mut last_assistant_speech_start: Option<Instant> = None;
                        // Pending listening tone: scheduled after echo tail when in approval mode.
                        let mut listening_tone_at: Option<Instant> = None;
                        loop {
                            // If a listening tone is scheduled, create a sleep future for it.
                            let tone_sleep = async {
                                match listening_tone_at {
                                    Some(at) => {
                                        let now = Instant::now();
                                        if now >= at {
                                            // Already past the scheduled time.
                                        } else {
                                            tokio::time::sleep(at - now).await;
                                        }
                                    }
                                    None => std::future::pending().await,
                                }
                            };

                            tokio::select! {
                                () = cancel.cancelled() => break,
                                () = tone_sleep => {
                                    // Echo tail expired and we're in approval mode — play listening tone.
                                    listening_tone_at = None;
                                    if awaiting_approval_ctl.load(Ordering::Relaxed) {
                                        let _ = playback_cmd_tx.send(PlaybackCommand::ListeningTone);
                                    }
                                }
                                ev = control_rx.recv() => {
                                    let Some(ev) = ev else { break };
                                    if let Some(rt) = &runtime_tx {
                                        let _ = rt.send(RuntimeEvent::Control(ev.clone()));
                                    }
                                    if matches!(ev, ControlEvent::AssistantSpeechStart) {
                                        last_assistant_speech_start = Some(Instant::now());
                                    }
                                    // When assistant speech ends while awaiting approval,
                                    // schedule a listening tone after the echo tail expires.
                                    if matches!(ev, ControlEvent::AssistantSpeechEnd { .. })
                                        && awaiting_approval_ctl.load(Ordering::Relaxed)
                                    {
                                        listening_tone_at = Some(Instant::now() + echo_tail_for_tone);
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
            PipelineMode::TextOnly => {
                // Degraded mode: audio capture/STT unavailable.
                // Abort audio stages and wait for cancellation.
                drop(ref_handle_playback);
                // Drop the channel receivers so audio stages drain and exit.
                drop(transcription_rx);
                drop(control_rx);
                // Emit degraded_mode event.
                if let Some(ref rt_tx) = runtime_tx {
                    let _ = rt_tx.send(RuntimeEvent::Control(
                        crate::pipeline::messages::ControlEvent::DegradedMode {
                            mode: "text_only".to_owned(),
                        },
                    ));
                }
                info!("pipeline running in text-only degraded mode");

                // Abort the audio stages — they have no work to do.
                capture_handle.abort();
                vad_handle.abort();
                stt_handle.abort();
                if let Some(aec) = aec_handle {
                    aec.abort();
                }

                cancel.cancelled().await;
                info!("pipeline (text-only) shutdown complete");
            }
            PipelineMode::LlmOnly => {
                // Degraded mode: TTS/playback unavailable.
                // Run capture → VAD → STT → print (skip TTS/playback stages).
                drop(ref_handle_playback);
                let _control_rx = control_rx;
                // Emit degraded_mode event.
                if let Some(ref rt_tx) = runtime_tx {
                    let _ = rt_tx.send(RuntimeEvent::Control(
                        crate::pipeline::messages::ControlEvent::DegradedMode {
                            mode: "llm_only".to_owned(),
                        },
                    ));
                }
                info!("pipeline running in LLM-only degraded mode (no TTS/playback)");
                let print_handle = {
                    let cancel = cancel.clone();
                    let runtime_tx = runtime_tx.clone();
                    tokio::spawn(async move {
                        run_print_stage(transcription_rx, runtime_tx, console_output, cancel).await;
                    })
                };

                cancel.cancelled().await;
                info!("pipeline (LLM-only) shutting down");

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

/// Shared state for echo suppression and mic validation in the VAD stage.
struct VadStageState {
    assistant_speaking: Arc<AtomicBool>,
    assistant_generating: Arc<AtomicBool>,
    /// When true, DSP-based AEC is active and echo suppression can be relaxed.
    aec_enabled: bool,
    /// Runtime event sender for mic status updates.
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    /// When true, the coordinator is awaiting a voice approval response.
    ///
    /// In this mode the short-utterance guard is bypassed for segments >= 0.15s
    /// so that short "yes"/"no" responses can pass through after the echo tail.
    awaiting_approval: Arc<AtomicBool>,
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
    // for a window so residual room echo/reverb does not leak through.
    // Reduced from 3000/5000ms: overly aggressive tail was causing Fae to
    // miss user speech that started shortly after her response ended.
    let echo_tail_ms: u64 = if state.aec_enabled { 1500 } else { 3000 };
    let echo_tail = std::time::Duration::from_millis(echo_tail_ms);
    // Additional post-playback guard where very short utterances are rejected.
    // This targets ghost backchannels like "yeah"/"mm-hmm" that can appear
    // right after long playback.  Reduced from 5000/7000ms.
    let short_utterance_guard_ms: u64 = if state.aec_enabled { 3000 } else { 5000 };
    let short_utterance_guard = std::time::Duration::from_millis(short_utterance_guard_ms);
    const MIN_POST_PLAYBACK_SEGMENT_SECS: f32 = 0.4;

    let mut was_suppressing = false;
    let mut suppress_until: Option<std::time::Instant> = None;
    let mut short_utterance_guard_until: Option<std::time::Instant> = None;

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
                                    let now = std::time::Instant::now();
                                    suppress_until = Some(now + echo_tail);
                                    short_utterance_guard_until = Some(now + short_utterance_guard);
                                    // Flush the VAD buffer so audio accumulated
                                    // during assistant playback is discarded.
                                    // Without this, the VAD emits the buffered
                                    // playback as a mega-segment once the echo
                                    // tail expires.
                                    vad.reset();
                                    pending = None;
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
                                let in_short_utterance_guard = short_utterance_guard_until
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
                                    !actively_suppressing && !in_echo_tail && !in_short_utterance_guard;
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

                                    let in_approval_mode =
                                        state.awaiting_approval.load(Ordering::Relaxed);
                                    if in_short_utterance_guard
                                        && duration_s < MIN_POST_PLAYBACK_SEGMENT_SECS
                                    {
                                        if in_approval_mode {
                                            // Approval mode: accept segments down to 0.15s
                                            // (enough for "yes"/"no"). Shorter segments
                                            // are likely noise, not a deliberate response.
                                            const MIN_APPROVAL_SEGMENT_SECS: f32 = 0.15;
                                            if duration_s < MIN_APPROVAL_SEGMENT_SECS {
                                                info!(
                                                    "dropping {duration_s:.1}s speech segment (too short even for approval)"
                                                );
                                                continue;
                                            }
                                            info!(
                                                "passing {duration_s:.1}s segment through (approval mode bypass)"
                                            );
                                            // Fall through to STT — the approval parser
                                            // will validate content.
                                        } else {
                                            info!(
                                                "dropping {duration_s:.1}s speech segment (post-playback short-utterance guard)"
                                            );
                                            continue;
                                        }
                                    }

                                    // Duration guard: very long segments are likely
                                    // accumulated playback that slipped past echo
                                    // suppression.  Natural utterances rarely exceed
                                    // 15s in conversational speech.  This matches
                                    // the VAD's max_speech_duration_ms cap.
                                    const MAX_SEGMENT_SECS: f32 = 15.0;
                                    if duration_s > MAX_SEGMENT_SECS {
                                        info!(
                                            "dropping {duration_s:.1}s speech segment (exceeds {MAX_SEGMENT_SECS}s cap — likely echo)"
                                        );
                                        continue;
                                    }

                                    // Amplitude-based echo guard: even when the speaking
                                    // flag is off, reject segments with abnormally high
                                    // RMS that indicate speaker-to-mic feedback.  Normal
                                    // human speech through a mic produces RMS ~0.005–0.05;
                                    // speaker bleed-through produces RMS >0.1 (often >>1).
                                    let seg_rms: f32 = if segment.samples.is_empty() {
                                        0.0
                                    } else {
                                        (segment.samples.iter().map(|s| s * s).sum::<f32>()
                                            / segment.samples.len() as f32)
                                            .sqrt()
                                    };
                                    const ECHO_RMS_CEILING: f32 = 0.15;
                                    if seg_rms > ECHO_RMS_CEILING {
                                        info!(
                                            "dropping {duration_s:.1}s speech segment (rms={seg_rms:.3} exceeds echo ceiling {ECHO_RMS_CEILING})"
                                        );
                                        continue;
                                    }

                                    // Clear the tail once we accept a real segment.
                                    suppress_until = None;
                                    short_utterance_guard_until = None;

                                    let vad_duration_ms = segment.started_at.elapsed().as_millis() as u64;
                                    info!(
                                        vad_ms = vad_duration_ms,
                                        duration_s,
                                        "pipeline_timing: VAD segment complete ({duration_s:.1}s)"
                                    );
                                    if let Some(rt) = &state.runtime_tx {
                                        let _ = rt.send(RuntimeEvent::PipelineTiming {
                                            stage: "vad".to_owned(),
                                            duration_ms: vad_duration_ms,
                                        });
                                    }

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
                        // Compute audio metrics before transcription for quality filtering.
                        let duration_secs = segment.samples.len() as f32
                            / segment.sample_rate as f32;
                        let seg_rms: f32 = if segment.samples.is_empty() {
                            0.0
                        } else {
                            (segment.samples.iter().map(|s| s * s).sum::<f32>()
                                / segment.samples.len() as f32)
                                .sqrt()
                        };

                        let stt_start = Instant::now();
                        match stt.transcribe(&segment) {
                            Ok(transcription) => {
                                let stt_duration = stt_start.elapsed();
                                let vad_to_stt_ms = segment.started_at.elapsed().as_millis() as u64;
                                info!(
                                    stt_ms = stt_duration.as_millis() as u64,
                                    vad_to_stt_ms,
                                    "pipeline_timing: STT completed"
                                );
                                if let Some(rt) = &runtime_tx {
                                    let _ = rt.send(RuntimeEvent::PipelineTiming {
                                        stage: "stt".to_owned(),
                                        duration_ms: stt_duration.as_millis() as u64,
                                    });
                                }

                                let mut transcription = transcription;
                                // Attach audio metrics for downstream quality filtering.
                                transcription.audio_rms = Some(seg_rms);
                                transcription.audio_duration_secs = Some(duration_secs);

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

#[allow(clippy::too_many_arguments)]
async fn run_identity_gate(
    config: SpeechConfig,
    mut rx: mpsc::Receiver<Transcription>,
    tx: mpsc::Sender<Transcription>,
    tts_tx: mpsc::Sender<SentenceChunk>,
    memory_root: std::path::PathBuf,
    _onboarding_seg_rx: Option<mpsc::Receiver<SpeechSegment>>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    cancel: CancellationToken,
) {
    let voice_cfg = config.voice_identity.clone();
    let min_enroll_samples = voice_cfg.min_enroll_samples.max(1) as usize;

    let store = MemoryStore::new(&memory_root);
    if let Err(e) = store.ensure_dirs() {
        error!("memory init failed: {e}");
    }
    if let Err(e) = MemoryStore::ensure_voice_dirs(&memory_root) {
        error!("voice dir init failed: {e}");
    }

    let mut primary_user = match store.load_primary_user() {
        Ok(v) => v,
        Err(e) => {
            error!("failed to load primary user memory: {e}");
            None
        }
    };
    let mut identity_profile = build_voice_identity_profile(primary_user.as_ref(), &voice_cfg);
    let mut hold_until: Option<Instant> = None;

    let has_primary = primary_user.is_some();

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

                let lower_raw = t.text.to_lowercase();
                let has_direct_address = find_name_mention(&lower_raw).is_some();

                // Voiceprint enrollment capture for onboarding/manual setup.
                if voice_cfg.enabled
                    && !identity_profile.is_enrolled()
                    && has_direct_address
                    && let (Some(vp), Some(dur), Some(rms)) =
                        (t.voiceprint.as_ref(), t.audio_duration_secs, t.audio_rms)
                    && (0.6..=10.0).contains(&dur)
                    && rms >= 0.01
                {
                    let mut user = primary_user.clone().unwrap_or_else(|| {
                        crate::memory::PrimaryUser::with_name(
                            config
                                .user_name
                                .clone()
                                .unwrap_or_else(|| "Primary User".to_owned()),
                        )
                    });

                    let mut samples = extract_voiceprint_samples(&user);
                    let is_duplicate = samples
                        .iter()
                        .filter_map(|existing| crate::voiceprint::similarity(existing, vp))
                        .any(|sim| sim >= 0.995);
                    if !is_duplicate {
                        samples.push(vp.clone());
                        user.voiceprints = samples.clone();
                        let mut enrolled = false;
                        if samples.len() >= min_enroll_samples
                            && let Some(c) = crate::voiceprint::centroid(&samples)
                        {
                            user.voiceprint = Some(c.clone());
                            user.voiceprint_centroid = Some(c);
                            user.voiceprint_threshold = Some(voice_cfg.threshold_accept);
                            user.voiceprint_version = Some("spectral-v1".to_owned());
                            user.voiceprint_updated_at = Some(now_epoch_secs());
                            if !voice_cfg.store_raw_samples {
                                user.voiceprints.clear();
                            }
                            enrolled = true;
                        }
                        if let Err(e) = store.save_primary_user(&user) {
                            warn!("failed to persist voiceprint enrollment sample: {e}");
                        } else {
                            primary_user = Some(user);
                            identity_profile =
                                build_voice_identity_profile(primary_user.as_ref(), &voice_cfg);
                            if let Some(rt) = &runtime_tx {
                                let sample_count = primary_user
                                    .as_ref()
                                    .map(|u| extract_voiceprint_samples(u).len())
                                    .unwrap_or(0);
                                let _ = rt.send(RuntimeEvent::VoiceprintEnrollmentProgress {
                                    sample_count,
                                    required_samples: min_enroll_samples,
                                    enrolled,
                                });
                            }
                        }
                    }
                }

                // Speaker verification gate.
                if voice_cfg.enabled && identity_profile.is_enrolled() {
                    let now = Instant::now();
                    let similarity = identity_profile.similarity(t.voiceprint.as_ref());
                    let in_hold_window = hold_until.is_some_and(|until| now <= until);
                    let matched = similarity.is_some_and(|sim| {
                        sim >= identity_profile.threshold_accept
                            || (in_hold_window && sim >= identity_profile.threshold_hold)
                    });

                    if matched {
                        hold_until = Some(now + identity_profile.hold_window);
                        if let Some(rt) = &runtime_tx {
                            let _ = rt.send(RuntimeEvent::VoiceIdentityDecision {
                                accepted: true,
                                reason: "speaker_match".to_owned(),
                                similarity,
                            });
                        }
                    } else {
                        let assist_fallback =
                            identity_profile.mode == VoiceIdentityMode::Assist && has_direct_address;
                        if !assist_fallback {
                            if let Some(rt) = &runtime_tx {
                                let reason = if similarity.is_some() {
                                    "speaker_mismatch"
                                } else {
                                    "missing_voiceprint"
                                };
                                let _ = rt.send(RuntimeEvent::VoiceIdentityDecision {
                                    accepted: false,
                                    reason: reason.to_owned(),
                                    similarity,
                                });
                            }
                            continue;
                        }

                        if let Some(rt) = &runtime_tx {
                            let _ = rt.send(RuntimeEvent::VoiceIdentityDecision {
                                accepted: true,
                                reason: "assist_direct_address_fallback".to_owned(),
                                similarity,
                            });
                        }
                    }
                }

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

pub(crate) async fn speak(
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

/// Returns `true` when the user's message looks coding-related.
///
/// Used to gate injection of local coding-assistant context (Codex, Claude
/// Code install status) into the LLM prompt — avoids noise on non-coding
/// queries like "what time is it?".
fn should_include_local_coding_assistants_context(user_text: &str) -> bool {
    let lower = user_text.to_ascii_lowercase();
    crate::intent::contains_any(&lower, crate::intent::CODING_CONTEXT_KEYWORDS)
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

struct LlmStageControl {
    interrupt: Arc<AtomicBool>,
    assistant_speaking: Arc<AtomicBool>,
    assistant_generating: Arc<AtomicBool>,
    playback_cmd_tx: mpsc::UnboundedSender<PlaybackCommand>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
    canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
    /// Live shared permission store from the command handler.
    ///
    /// When `Some`, this is passed to `FaeAgentLlm::new_with_permissions` so
    /// that JIT grants from `capability.grant` commands are immediately
    /// visible to Apple ecosystem tool gates without a registry rebuild.
    shared_permissions: Option<crate::permissions::SharedPermissionStore>,
    console_output: bool,
    cancel: CancellationToken,
    voice_command_rx: Option<mpsc::UnboundedReceiver<crate::voice_command::VoiceCommand>>,
    queue_cmd_rx: Option<mpsc::UnboundedReceiver<LlmQueueCommand>>,
    /// Shared flag: when true, the coordinator is awaiting a voice approval response.
    awaiting_approval: Arc<AtomicBool>,
    /// Receiver for approval notifications from the handler bridge.
    approval_notification_rx:
        Option<mpsc::UnboundedReceiver<super::messages::ApprovalNotification>>,
    /// Sender for resolved approval responses back to the handler.
    approval_response_tx: Option<mpsc::UnboundedSender<(u64, bool)>>,
}

async fn run_llm_stage(
    mut config: SpeechConfig,
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

    // Apply RAM-based model selection so config.llm.model_id matches the
    // actually-loaded model (startup may have selected a different model
    // than what was persisted in config.toml).
    crate::config::apply_ram_model_selection(&mut config.llm);

    let credential_manager = crate::credentials::create_manager();
    let mut engine = match FaeAgentLlm::new_with_permissions(
        &config.llm,
        preloaded.as_ref(),
        ctl.runtime_tx.clone(),
        ctl.tool_approval_tx.clone(),
        ctl.canvas_registry.clone(),
        credential_manager.as_ref(),
        ctl.shared_permissions.clone(),
    )
    .await
    {
        Ok(mut agent) => {
            // Voice engine: disable tools. Tool-intent routing is handled
            // at the coordinator level by spawning background agents.
            agent.disable_tools();
            Box::new(agent)
        }
        Err(e) => {
            error!("failed to init agent LLM: {e}");
            return;
        }
    };

    // Stash dependencies for spawning background agents.
    // Background agents share the same model weights via `Arc<Model>`.
    let bg_preloaded = preloaded.as_ref().map(crate::llm::LocalLlm::shallow_clone);
    let bg_config = config.clone();
    let bg_tool_approval_tx = ctl.tool_approval_tx.clone();
    let bg_canvas_registry = ctl.canvas_registry.clone();
    let bg_shared_permissions = ctl.shared_permissions.clone();

    let local_coding_assistants = LocalCodingAssistants::detect();

    let name = "Fae".to_owned();
    let memory_orchestrator = if config.memory.enabled {
        match MemoryOrchestrator::new(&config.memory) {
            Ok(orchestrator) => {
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
            }
            Err(e) => {
                warn!("memory orchestrator creation failed: {e}");
                None
            }
        }
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
        shared_permissions: _,
        console_output,
        cancel,
        voice_command_rx,
        queue_cmd_rx,
        awaiting_approval,
        approval_notification_rx: mut approval_notif_rx,
        approval_response_tx,
    } = ctl;

    // Voice command receiver (currently unused — was Pi-specific).
    let mut voice_cmd_rx = voice_command_rx;
    let mut queue_cmd_rx = queue_cmd_rx;
    let mut pending_inputs = LlmInputQueue::new(&config.llm);
    let mut transcription_channel_closed = false;
    let mut conversation_turns: Vec<ConversationTurn> = Vec::new();

    let cancel = cancel;
    let mut turn_counter: u64 = 0;

    // Acknowledgment counter for rotating through canned phrases.
    // Shared between tool acks and thinking acks for global rotation.
    let mut ack_counter: u64 = 0;

    // Optional enrolled speaker profile for approval response hardening.
    let mut approval_voice_profile = load_approval_voice_profile(&config);

    // Voice approval state machine.
    let mut pending_voice_approval: Option<PendingVoiceApproval> = None;
    let mut approval_queue: Vec<super::messages::ApprovalNotification> = Vec::new();
    // Counter for rotating through approval canned responses.
    let mut approval_ack_counter: u64 = 0;

    // Channel for receiving results from background agent tasks.
    let (bg_result_tx, mut bg_result_rx) = mpsc::channel::<crate::agent::BackgroundAgentResult>(4);

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
                let recv_approval_notif = async {
                    match approval_notif_rx.as_mut() {
                        Some(rx) => rx.recv().await,
                        None => std::future::pending().await,
                    }
                };

                // Approval timeout: if we have a pending approval, compute
                // the time remaining until the 50s reprompt and 58s auto-deny.
                let approval_timeout = async {
                    match &pending_voice_approval {
                        Some(pva) => {
                            let elapsed = pva.created_at.elapsed();
                            if elapsed >= std::time::Duration::from_secs(58) {
                                // Already past auto-deny threshold.
                                return "deny";
                            }
                            if elapsed >= std::time::Duration::from_secs(50) {
                                // Past reprompt threshold — next tick is deny.
                                let remaining = std::time::Duration::from_secs(58) - elapsed;
                                tokio::time::sleep(remaining).await;
                                return "deny";
                            }
                            // Wait until reprompt threshold.
                            let remaining = std::time::Duration::from_secs(50) - elapsed;
                            tokio::time::sleep(remaining).await;
                            "reprompt"
                        }
                        None => std::future::pending::<&str>().await,
                    }
                };

                enum Input {
                    Transcription(Option<Transcription>),
                    TextInjection(Option<TextInjection>),
                    VoiceCommand(Option<crate::voice_command::VoiceCommand>),
                    QueueCommand(Option<LlmQueueCommand>),
                    BackgroundResult(crate::agent::BackgroundAgentResult),
                    ApprovalNotification(Option<super::messages::ApprovalNotification>),
                    ApprovalTimeout(&'static str),
                }

                let input = tokio::select! {
                    () = cancel.cancelled() => break 'outer,
                    t = rx.recv() => Input::Transcription(t),
                    inj = recv_injection => Input::TextInjection(inj),
                    cmd = recv_voice_cmd => Input::VoiceCommand(cmd),
                    cmd = recv_queue_cmd => Input::QueueCommand(cmd),
                    Some(result) = bg_result_rx.recv() => Input::BackgroundResult(result),
                    notif = recv_approval_notif => Input::ApprovalNotification(notif),
                    action = approval_timeout => Input::ApprovalTimeout(action),
                };

                match input {
                    Input::Transcription(Some(transcription)) => {
                        if transcription.text.trim().is_empty() {
                            continue;
                        }
                        // If awaiting approval, intercept the transcription
                        // for the approval parser instead of the LLM.
                        if pending_voice_approval.is_some() {
                            use crate::voice_command::{
                                ApprovalVoiceResponse, parse_approval_response,
                            };
                            let (speaker_verified, speaker_similarity) = approval_speaker_verified(
                                approval_voice_profile.as_ref(),
                                &transcription,
                            );
                            if let Some(rt) = &runtime_tx
                                && approval_voice_profile.is_some()
                            {
                                let reason = if speaker_verified {
                                    "approval_speaker_match"
                                } else {
                                    "approval_speaker_mismatch"
                                };
                                let _ = rt.send(RuntimeEvent::VoiceIdentityDecision {
                                    accepted: speaker_verified,
                                    reason: reason.to_owned(),
                                    similarity: speaker_similarity,
                                });
                            }
                            let speaker_verified_event =
                                approval_voice_profile.as_ref().map(|_| speaker_verified);

                            let response = if speaker_verified {
                                parse_approval_response(&transcription.text)
                            } else {
                                ApprovalVoiceResponse::Ambiguous
                            };
                            match response {
                                ApprovalVoiceResponse::Approved => {
                                    let mut actx = ApprovalContext {
                                        pending: &mut pending_voice_approval,
                                        ack_counter: &mut approval_ack_counter,
                                        awaiting_approval: &awaiting_approval,
                                        approval_response_tx: &approval_response_tx,
                                        runtime_tx: &runtime_tx,
                                        queue: &mut approval_queue,
                                        tx: &tx,
                                        cancel: &cancel,
                                    };
                                    resolve_and_advance_approval(
                                        &mut actx,
                                        crate::personality::APPROVAL_GRANTED,
                                        true,
                                        "voice",
                                        speaker_verified_event,
                                    )
                                    .await;
                                    continue;
                                }
                                ApprovalVoiceResponse::Denied => {
                                    let mut actx = ApprovalContext {
                                        pending: &mut pending_voice_approval,
                                        ack_counter: &mut approval_ack_counter,
                                        awaiting_approval: &awaiting_approval,
                                        approval_response_tx: &approval_response_tx,
                                        runtime_tx: &runtime_tx,
                                        queue: &mut approval_queue,
                                        tx: &tx,
                                        cancel: &cancel,
                                    };
                                    resolve_and_advance_approval(
                                        &mut actx,
                                        crate::personality::APPROVAL_DENIED,
                                        false,
                                        "voice",
                                        speaker_verified_event,
                                    )
                                    .await;
                                    continue;
                                }
                                ApprovalVoiceResponse::Ambiguous => {
                                    if let Some(ref mut pva) = pending_voice_approval {
                                        pva.reprompt_count += 1;
                                        if pva.reprompt_count >= 2 {
                                            // Too many ambiguous responses — deny.
                                            let mut actx = ApprovalContext {
                                                pending: &mut pending_voice_approval,
                                                ack_counter: &mut approval_ack_counter,
                                                awaiting_approval: &awaiting_approval,
                                                approval_response_tx: &approval_response_tx,
                                                runtime_tx: &runtime_tx,
                                                queue: &mut approval_queue,
                                                tx: &tx,
                                                cancel: &cancel,
                                            };
                                            resolve_and_advance_approval(
                                                &mut actx,
                                                crate::personality::APPROVAL_TIMEOUT,
                                                false,
                                                "voice",
                                                speaker_verified_event,
                                            )
                                            .await;
                                        } else {
                                            if !speaker_verified {
                                                info!(
                                                    similarity = speaker_similarity,
                                                    "approval response rejected (speaker mismatch)"
                                                );
                                            }
                                            let reprompt = crate::personality::next_acknowledgment(
                                                crate::personality::APPROVAL_AMBIGUOUS,
                                                approval_ack_counter,
                                            );
                                            approval_ack_counter += 1;
                                            let _ = tx
                                                .send(SentenceChunk {
                                                    text: reprompt.to_owned(),
                                                    is_final: true,
                                                })
                                                .await;
                                        }
                                    }
                                    continue;
                                }
                            }
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
                        emit_panel_visibility_events(&cmd, &runtime_tx);
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
                    Input::BackgroundResult(result) => {
                        // Background agent completed — inject result into voice
                        // engine history and narrate via TTS.
                        info!(
                            task_id = %result.task_id,
                            success = result.success,
                            "background agent task completed"
                        );
                        if let Some(rt) = &runtime_tx {
                            let _ = rt.send(RuntimeEvent::BackgroundTaskCompleted {
                                task_id: result.task_id.clone(),
                                success: result.success,
                                summary: result.spoken_summary.clone(),
                            });
                        }
                        if result.success && !result.spoken_summary.trim().is_empty() {
                            engine.inject_background_result(&result.spoken_summary);
                            let spoken = result.spoken_summary.clone();
                            append_conversation_turn(
                                &mut conversation_turns,
                                format!("[background task {}]", result.task_id),
                                spoken.clone(),
                            );
                            let _ = tx
                                .send(SentenceChunk {
                                    text: spoken,
                                    is_final: true,
                                })
                                .await;
                        }
                        continue;
                    }
                    Input::ApprovalNotification(Some(notif)) => {
                        // Refresh enrolled profile at approval start so newly
                        // completed onboarding enrollment applies immediately.
                        approval_voice_profile = load_approval_voice_profile(&config);
                        // A tool is requesting user approval. If we're already
                        // handling one, queue it; otherwise start immediately.
                        if pending_voice_approval.is_some() {
                            info!(
                                request_id = notif.request_id,
                                "queuing approval (another in progress)"
                            );
                            approval_queue.push(notif);
                        } else {
                            pending_voice_approval = Some(
                                start_voice_approval(&notif, &tx, &awaiting_approval, &cancel)
                                    .await,
                            );
                        }
                        continue;
                    }
                    Input::ApprovalNotification(None) => {
                        approval_notif_rx = None;
                    }
                    Input::ApprovalTimeout(action) => {
                        match action {
                            "reprompt" => {
                                // 50s elapsed — remind the user.
                                let reprompt = "I'm still waiting. Should I go ahead? Yes or no.";
                                let _ = tx
                                    .send(SentenceChunk {
                                        text: reprompt.to_owned(),
                                        is_final: true,
                                    })
                                    .await;
                            }
                            _ => {
                                // 58s elapsed — auto-deny before the 60s tool timeout.
                                let mut actx = ApprovalContext {
                                    pending: &mut pending_voice_approval,
                                    ack_counter: &mut approval_ack_counter,
                                    awaiting_approval: &awaiting_approval,
                                    approval_response_tx: &approval_response_tx,
                                    runtime_tx: &runtime_tx,
                                    queue: &mut approval_queue,
                                    tx: &tx,
                                    cancel: &cancel,
                                };
                                resolve_and_advance_approval(
                                    &mut actx,
                                    crate::personality::APPROVAL_TIMEOUT,
                                    false,
                                    "timeout",
                                    None,
                                )
                                .await;
                            }
                        }
                        continue;
                    }
                }
            }
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

        // ── Multi-channel routing ───────────────────────────────────────
        // Classify intent: if tools are needed, send a canned acknowledgment
        // immediately and spawn a background agent. The voice engine continues
        // to handle the next user turn with zero tool overhead.
        let intent = crate::agent::classify_intent(&user_text);
        if intent.needs_tools {
            info!(
                tools = ?intent.tool_allowlist,
                desc = %intent.task_description,
                "tool intent detected — routing to background agent"
            );

            // 1. Send canned acknowledgment immediately via TTS.
            let ack = crate::personality::next_acknowledgment(
                crate::personality::TOOL_ACKNOWLEDGMENTS,
                ack_counter,
            );
            ack_counter += 1;
            let _ = tx
                .send(SentenceChunk {
                    text: ack.to_owned(),
                    is_final: true,
                })
                .await;

            // 2. Build conversation context (last few turns).
            let context = build_background_context(&conversation_turns, 5);

            // 3. Spawn background agent.
            let task_id = format!("bg-{turn_counter}");
            let task = crate::agent::BackgroundAgentTask {
                id: task_id.clone(),
                description: intent.task_description.clone(),
                user_message: user_text.clone(),
                conversation_context: context,
                tool_allowlist: intent.tool_allowlist,
            };

            if let Some(rt) = &runtime_tx {
                let _ = rt.send(RuntimeEvent::BackgroundTaskStarted {
                    task_id: task_id.clone(),
                    description: intent.task_description,
                });
            }

            let bg_tx = bg_result_tx.clone();
            let bg_cfg = bg_config.clone();
            let bg_model = bg_preloaded
                .as_ref()
                .map(crate::llm::LocalLlm::shallow_clone);
            let bg_approval = bg_tool_approval_tx.clone();
            let bg_canvas = bg_canvas_registry.clone();
            let bg_perms = bg_shared_permissions.clone();
            let bg_runtime = runtime_tx.clone();
            tokio::spawn(async move {
                let result = crate::agent::spawn_background_agent(
                    task,
                    bg_cfg.llm,
                    bg_model.as_ref(),
                    bg_runtime,
                    bg_approval,
                    bg_canvas,
                    bg_perms,
                )
                .await;
                let _ = bg_tx.send(result).await;
            });

            // 4. Record the ack in conversation history.
            append_conversation_turn(&mut conversation_turns, user_text.clone(), ack.to_owned());
            capture_memory_turn(
                memory_orchestrator.as_ref(),
                runtime_tx.as_ref(),
                &turn_id,
                &user_text,
                ack,
            );
            continue;
        }
        // ── Thinking mode for complex conversational queries ─────────────
        // When the classifier detects a complex question (analytical,
        // comparative, planning), temporarily enable reasoning mode on the
        // voice engine so the model can think more deeply. We speak a
        // thinking acknowledgment so the user knows to expect a slight delay.
        if intent.needs_thinking {
            info!("complex query detected — enabling thinking mode for this turn");
            let ack = crate::personality::next_acknowledgment(
                crate::personality::THINKING_ACKNOWLEDGMENTS,
                ack_counter,
            );
            ack_counter += 1;
            let _ = tx
                .send(SentenceChunk {
                    text: ack.to_owned(),
                    is_final: true,
                })
                .await;
            engine.set_reasoning_level(crate::fae_llm::types::ReasoningLevel::Medium);
        }
        // ── End thinking mode routing ────────────────────────────────────

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

            // Only inject onboarding context if the user hasn't completed
            // the onboarding flow. The 1.7B voice model is too small to
            // handle interview-style probing gracefully; once the user
            // finishes onboarding (config.onboarded == true) we rely on
            // memory recall instead of a per-turn checklist prompt.
            if !config.onboarded
                && let Ok(Some(onboarding_ctx)) = memory.onboarding_context()
            {
                llm_input = format!("{onboarding_ctx}\n\n{llm_input}");
            }
        }

        if local_coding_assistants.any()
            && should_include_local_coding_assistants_context(&user_text)
        {
            let permission = memory_orchestrator
                .as_ref()
                .and_then(|memory| memory.coding_assistant_permission().ok().flatten());
            let local_coding_ctx =
                build_local_coding_assistants_context(local_coding_assistants, permission);
            llm_input = format!("{local_coding_ctx}\n\n{llm_input}");
        }

        let llm_start = Instant::now();
        assistant_generating.store(true, Ordering::Relaxed);
        if let Some(rt) = &runtime_tx {
            let _ = rt.send(RuntimeEvent::AssistantGenerating { active: true });
        }
        // Send a brief thinking tone so the user gets audio feedback that Fae
        // heard them and is processing their request.
        let _ = playback_cmd_tx.send(PlaybackCommand::ThinkingTone);
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

        let mut pending_bg_results: Vec<crate::agent::BackgroundAgentResult> = Vec::new();
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
                        // Emit panel visibility events for the GUI.
                        emit_panel_visibility_events(&cmd, &runtime_tx);
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
                Some(bg_result) = bg_result_rx.recv() => {
                    // Background agent completed during voice generation.
                    // Cannot inject into engine here (mutable borrow conflict),
                    // so stash for processing after generation completes.
                    info!(
                        task_id = %bg_result.task_id,
                        success = bg_result.success,
                        "background agent completed during generation (deferred)"
                    );
                    if let Some(rt) = &runtime_tx {
                        let _ = rt.send(RuntimeEvent::BackgroundTaskCompleted {
                            task_id: bg_result.task_id.clone(),
                            success: bg_result.success,
                            summary: bg_result.spoken_summary.clone(),
                        });
                    }
                    if bg_result.success && !bg_result.spoken_summary.trim().is_empty() {
                        // Queue the result text for injection + TTS after generation.
                        pending_bg_results.push(bg_result);
                    }
                }
                notif = async {
                    match approval_notif_rx.as_mut() {
                        Some(rx) => rx.recv().await,
                        None => std::future::pending().await,
                    }
                } => {
                    // Queue approval notifications during generation — will be
                    // processed after the current response finishes.
                    if let Some(notif) = notif {
                        info!(
                            request_id = notif.request_id,
                            "queuing approval notification during generation"
                        );
                        approval_queue.push(notif);
                    } else {
                        approval_notif_rx = None;
                    }
                }
            }
        };
        // Explicitly drop the pinned generation future to release the mutable
        // borrow on `engine`, allowing us to call `inject_background_result`.
        drop(generation);

        // If we temporarily enabled thinking for a complex query, reset to Off
        // so subsequent simple turns don't incur the reasoning overhead.
        if intent.needs_thinking {
            engine.set_reasoning_level(crate::fae_llm::types::ReasoningLevel::Off);
        }

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
                let llm_duration = llm_start.elapsed();
                info!(
                    llm_ms = llm_duration.as_millis() as u64,
                    interrupted, "pipeline_timing: LLM generation completed"
                );
                if let Some(rt) = &runtime_tx {
                    let _ = rt.send(RuntimeEvent::PipelineTiming {
                        stage: "llm".to_owned(),
                        duration_ms: llm_duration.as_millis() as u64,
                    });
                }
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
        );
        capture_memory_turn(
            memory_orchestrator.as_ref(),
            runtime_tx.as_ref(),
            &turn_id,
            &user_text,
            &assistant_text,
        );

        // Process any background agent results that arrived during generation.
        for bg_result in pending_bg_results {
            engine.inject_background_result(&bg_result.spoken_summary);
            append_conversation_turn(
                &mut conversation_turns,
                format!("[background task {}]", bg_result.task_id),
                bg_result.spoken_summary.clone(),
            );
            // Narrate the background result via TTS.
            let _ = tx
                .send(SentenceChunk {
                    text: bg_result.spoken_summary,
                    is_final: true,
                })
                .await;
        }

        // Process any approval notifications that arrived during generation.
        if pending_voice_approval.is_none()
            && let Some(notif) = approval_queue.pop()
        {
            pending_voice_approval =
                Some(start_voice_approval(&notif, &tx, &awaiting_approval, &cancel).await);
        }

        // Concurrent sentiment analysis → orb mood (non-blocking).
        if let Some(rt) = runtime_tx.clone() {
            let text_for_sentiment = assistant_text.clone();
            tokio::spawn(async move {
                let result = crate::sentiment::classify(&text_for_sentiment);
                if result.confidence >= crate::sentiment::CONFIDENCE_THRESHOLD {
                    let _ = rt.send(RuntimeEvent::OrbMoodUpdate {
                        feeling: result.feeling,
                        palette: result.palette,
                    });
                }
            });
        }

        // Background intelligence extraction (non-blocking).
        if config.intelligence.enabled {
            let params = crate::intelligence::ExtractionParams {
                user_text: user_text.clone(),
                assistant_text: assistant_text.clone(),
                memory_context: None,
                extraction_model: config.intelligence.extraction_model.clone(),
                memory_path: config.memory.root_dir.clone(),
                runtime_tx: runtime_tx.clone(),
            };

            tokio::spawn(crate::intelligence::run_background_extraction(params));
        }

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
    engine: &mut Box<crate::agent::FaeAgentLlm>,
    ctx: &UserInputContext<'_>,
) -> Option<String> {
    match input {
        QueuedLlmInput::Transcription(transcription) => {
            if transcription.text.trim().is_empty() {
                return None;
            }

            // ── Quality gate: reject likely background audio ──
            //
            // Background TV/podcast/music produces low-RMS, long-duration
            // segments that the STT transcribes as gibberish.  Feeding these
            // into the LLM pollutes conversation history and causes
            // degenerate (repetitive) responses.
            //
            // Heuristic: segments with RMS < 0.008 that are also longer
            // than 3 seconds are almost certainly ambient, not directed
            // speech.  Short low-RMS segments (< 3s) may still be quiet
            // "yes"/"no" replies and are allowed through.
            const MIN_DIRECTED_SPEECH_RMS: f32 = 0.008;
            const AMBIENT_DURATION_THRESHOLD_SECS: f32 = 3.0;
            if let (Some(rms), Some(dur)) =
                (transcription.audio_rms, transcription.audio_duration_secs)
                && rms < MIN_DIRECTED_SPEECH_RMS
                && dur > AMBIENT_DURATION_THRESHOLD_SECS
            {
                info!(
                    rms,
                    duration_secs = dur,
                    text = %transcription.text,
                    "dropping low-quality transcription (likely background audio)"
                );
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
                    audio_rms: None,
                    audio_duration_secs: None,
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

/// Emit panel visibility runtime events for the given voice command.
///
/// Handles ShowConversation/HideConversation/ShowCanvas/HideCanvas.
/// Called from both the normal and interrupted-generation code paths.
fn emit_panel_visibility_events(
    cmd: &crate::voice_command::VoiceCommand,
    runtime_tx: &Option<broadcast::Sender<RuntimeEvent>>,
) {
    use crate::voice_command::VoiceCommand;
    match cmd {
        VoiceCommand::ShowConversation | VoiceCommand::HideConversation => {
            if let Some(rt) = runtime_tx {
                let visible = matches!(cmd, VoiceCommand::ShowConversation);
                let _ = rt.send(RuntimeEvent::ConversationVisibility { visible });
            }
        }
        VoiceCommand::ShowCanvas | VoiceCommand::HideCanvas => {
            if let Some(rt) = runtime_tx {
                let visible = matches!(cmd, VoiceCommand::ShowCanvas);
                let _ = rt.send(RuntimeEvent::ConversationCanvasVisibility { visible });
            }
        }
        _ => {}
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
        VoiceCommand::ShowConversation => "Opening conversation.".to_owned(),
        VoiceCommand::HideConversation => "Closing conversation.".to_owned(),
        VoiceCommand::ShowCanvas => "Opening canvas.".to_owned(),
        VoiceCommand::HideCanvas => "Closing canvas.".to_owned(),
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
                        // Strip emojis and non-speech chars before TTS so the
                        // phonemizer doesn't produce garbage audio for them.
                        let clean_text = strip_non_speech_chars(&sentence.text);
                        if clean_text.is_empty() {
                            // Text was only emojis / non-speech chars, or the
                            // end-of-response marker.  Forward a final marker
                            // if needed and skip synthesis.
                            if sentence.is_final || sentence.text.is_empty() {
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
                        let tts_start = Instant::now();
                        match engine.synthesize(&clean_text).await {
                            Ok(audio) => {
                                let tts_duration = tts_start.elapsed();
                                info!(
                                    tts_ms = tts_duration.as_millis() as u64,
                                    chars = sentence.text.len(),
                                    "pipeline_timing: TTS synthesis completed"
                                );
                                if let Some(rt) = &runtime_tx {
                                    let _ = rt.send(RuntimeEvent::PipelineTiming {
                                        stage: "tts".to_owned(),
                                        duration_ms: tts_duration.as_millis() as u64,
                                    });
                                }
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
                    Some(PlaybackCommand::ThinkingTone) => {
                        let sr = config.output_sample_rate;
                        let tone = crate::audio::tone::generate_thinking_tone(sr);
                        if let Err(e) = playback.enqueue(&tone, sr, true) {
                            error!("thinking tone playback error: {e}");
                        }
                    }
                    Some(PlaybackCommand::ListeningTone) => {
                        let sr = config.output_sample_rate;
                        let tone = crate::audio::tone::generate_listening_tone(sr);
                        if let Err(e) = playback.enqueue(&tone, sr, true) {
                            error!("listening tone playback error: {e}");
                        }
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
                                if let Some(rt) = &runtime_tx {
                                    let _ = rt.send(RuntimeEvent::PipelineTiming {
                                        stage: "playback_start".to_owned(),
                                        duration_ms: 0,
                                    });
                                }
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
use super::text_processing::strip_punctuation;
#[cfg(test)]
use super::text_processing::{capitalize_first, expand_contractions};

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
    /// Optional channel for GUI-driven gate commands (wake/sleep button).
    gate_cmd_rx: Option<mpsc::UnboundedReceiver<GateCommand>>,
    /// Shared flag indicating whether the gate is currently active.
    /// Written by the gate, read by the GUI for button state.
    gate_active: Arc<AtomicBool>,
    /// Shared flag indicating whether a voice approval yes/no is in progress.
    ///
    /// While true, the gate should not require direct address so short
    /// responses like "yes" / "no" are not dropped.
    awaiting_approval: Arc<AtomicBool>,
}

/// Conversation gate: routes transcriptions based on active/idle state.
///
/// Always starts in `Active` state (always-on companion mode). The gate
/// transitions to `Idle` when a `GateCommand::Sleep` is received
/// (or optional idle timeout if configured). It returns to `Active` on a
/// `GateCommand::Wake`.
///
/// In `Active` state:
///   - If the assistant is speaking/generating, only interrupt on name
///     mention (name-gated barge-in).
///   - If the assistant is silent, forward speech directly.
///   - Optionally auto-returns to Idle after `idle_timeout_s` of inactivity.
///     When `idle_timeout_s == 0` (companion mode), Fae stays present until
///     explicitly paused by `GateCommand::Sleep`.
async fn run_conversation_gate(
    config: SpeechConfig,
    mut stt_rx: mpsc::Receiver<Transcription>,
    llm_tx: mpsc::Sender<Transcription>,
    mut ctl: ConversationGateControl,
) {
    let idle_timeout_s = config.conversation.idle_timeout_s;
    let require_direct_address = config.conversation.require_direct_address;
    let direct_address_followup =
        Duration::from_secs(config.conversation.direct_address_followup_s as u64);
    // Always-on: start in Active state.
    let mut state = GateState::Active;

    let display_name = "Fae".to_owned();

    let mut gate_cmd_rx = ctl.gate_cmd_rx.take();
    let gate_active = ctl.gate_active.clone();
    // Start active immediately.
    gate_active.store(true, Ordering::Relaxed);

    // Auto-idle: track when the last conversational activity happened.
    let mut last_activity = Instant::now();
    let mut idle_check = tokio::time::interval(Duration::from_secs(5));
    // Engaged window: once the user addresses Fae directly, allow follow-up
    // turns without repeating the name for a short period.
    let mut engaged_until: Option<Instant> = None;

    info!("conversation gate active (always-on)");

    loop {
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
                    GateCommand::RestartAudio { ref device_name } => {
                        let name = device_name.as_deref().unwrap_or("<default>");
                        info!(device = name, "gate: audio device changed — cancelling pipeline for restart");
                        // Cancel the pipeline so the handler can restart with the
                        // new default audio device. The restart watcher detects the
                        // unexpected exit and emits the auto_restart event.
                        ctl.cancel.cancel();
                        break;
                    }
                    _ => {} // Already in requested state, ignore.
                }
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

                        // Use lowercase string for stable byte offsets back into `t.text`
                        // when extracting a query around the name mention.
                        let lower_raw = t.text.to_lowercase();

                        match state {
                            GateState::Idle => {
                                // In always-on mode, Idle means the user
                                // explicitly asked to sleep. Discard all
                                // transcriptions until Wake command.
                            }
                            GateState::Active => {
                                let assistant_active =
                                    ctl.assistant_speaking.load(Ordering::Relaxed)
                                    || ctl.assistant_generating.load(Ordering::Relaxed);

                                // Name-gated barge-in: saying "Fae, stop that"
                                // should interrupt even during assistant speech.
                                let name_match = find_name_mention(&lower_raw);

                                if let Some((pos, matched_len)) = name_match {
                                    ctl.interrupt.store(true, Ordering::Relaxed);
                                    if assistant_active {
                                        let _ = ctl.playback_cmd_tx.send(PlaybackCommand::Stop);
                                    }

                                    let query = extract_query_around_name(
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
                                    let now = Instant::now();
                                    if require_direct_address && !direct_address_followup.is_zero() {
                                        engaged_until = Some(now + direct_address_followup);
                                    }
                                    last_activity = now;
                                    continue;
                                }

                                // No name found.
                                if assistant_active {
                                    // During assistant speech without name: ignore.
                                    // Background conversation doesn't interrupt.
                                    continue;
                                }

                                // In direct-address mode, ignore ambient speech
                                // unless the user recently addressed Fae.
                                let in_followup_window = engaged_until
                                    .is_some_and(|until| Instant::now() <= until);
                                let approval_in_progress =
                                    ctl.awaiting_approval.load(Ordering::Relaxed);
                                if require_direct_address
                                    && !in_followup_window
                                    && !approval_in_progress
                                {
                                    info!(
                                        text = %t.text,
                                        "dropping transcription (no direct address outside follow-up window)"
                                    );
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
                                let now = Instant::now();
                                if require_direct_address && !direct_address_followup.is_zero() {
                                    engaged_until = Some(now + direct_address_followup);
                                }
                                last_activity = now;
                            }
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

use super::name_detection::{
    canonicalize_wake_word_transcription, extract_query_around_name, find_name_mention,
};

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
    /// normal speech (not JSON). Lowered from 48 to 16 — if the response
    /// starts with `{` we detect JSON on the first character; otherwise
    /// 16 chars is plenty to tell speech from code/JSON preambles.
    const DECIDE_THRESHOLD: usize = 16;
    /// Maximum time to wait before forwarding normal speech while deciding.
    ///
    /// Kept short (150ms) to minimise dead air before the first sentence
    /// reaches TTS. The previous 700ms caused noticeable "dead zone" between
    /// the user finishing their question and hearing any audio response.
    const DECIDE_MAX_WAIT: Duration = Duration::from_millis(150);

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
    let mut decide_started: Option<Instant> = None;

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
                if !chunk.text.is_empty() && decide_started.is_none() {
                    decide_started = Some(Instant::now());
                }

                // Check the combined pending text for a `{`.
                if let Some(brace_pos) = pending.find('{') {
                    // Found JSON start — everything from `{` onward goes
                    // to json_buf. Everything before is preamble (discarded).
                    mode = Mode::Json;
                    json_buf.push_str(&pending[brace_pos..]);
                    decide_started = None;
                } else {
                    let decide_timed_out =
                        decide_started.is_some_and(|start| start.elapsed() >= DECIDE_MAX_WAIT);
                    if !pending.is_empty()
                        && (pending.len() >= DECIDE_THRESHOLD || decide_timed_out)
                    {
                        // Enough text (or time) without `{` — this is normal speech.
                        // Preserve `is_final` if this chunk ends the response.
                        let is_final = chunk.is_final;
                        mode = Mode::Speech;
                        emit(
                            &SentenceChunk {
                                text: std::mem::take(&mut pending),
                                is_final,
                            },
                            &runtime_tx,
                            &tx,
                            console_output,
                        )
                        .await;
                    }
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
            decide_started = None;
        }
    }
}

use super::text_processing::{clean_model_json, extract_json_object, strip_markdown_fences};

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
    use crate::pipeline::voice_identity::VoiceIdentityProfile;
    use std::time::Duration;

    // ── Test-only name-parsing helpers ────────────────────────────────

    fn parse_name(text: &str) -> Option<String> {
        let raw = text.trim();
        if raw.is_empty() {
            return None;
        }
        let lower = raw.to_ascii_lowercase();

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

        let tokens: Vec<&str> = lower.split_whitespace().collect();
        for token in tokens.iter().rev() {
            let cleaned = clean_name_token(token);
            if !cleaned.is_empty() && !is_filler_word(&cleaned) {
                return Some(capitalize_first(&cleaned));
            }
        }

        None
    }

    fn is_filler_word(token: &str) -> bool {
        matches!(
            token,
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
                | "male"
                | "female"
                | "nonbinary"
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
                | "developer"
                | "engineer"
                | "teacher"
                | "student"
                | "doctor"
                | "programmer"
                | "retired"
        )
    }

    fn clean_name_token(token: &str) -> String {
        token
            .trim_matches(|c: char| !c.is_ascii_alphabetic() && c != '-' && c != '\'')
            .chars()
            .filter(|c| c.is_ascii_alphabetic() || *c == '-' || *c == '\'')
            .take(24)
            .collect()
    }

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

    // ── sleep phrase detection (multi-phrase) ──────────────────────

    /// Helper: simulate the gate's sleep-phrase detection pipeline.
    /// Mirrors the logic in `run_conversation_gate()`.
    fn matches_sleep_phrase(stt_text: &str, phrases: &[String]) -> bool {
        let lower_raw = stt_text.to_lowercase();
        let lower_expanded = expand_contractions(&lower_raw);
        let clean = strip_punctuation(&lower_expanded);
        phrases.iter().any(|phrase| clean.contains(phrase.as_str()))
    }

    #[test]
    fn sleep_phrases_shut_up_detected() {
        let phrases: Vec<String> = crate::config::ConversationConfig::default()
            .effective_sleep_phrases()
            .iter()
            .map(|s| s.to_lowercase())
            .collect();
        assert!(matches_sleep_phrase("Shut up!", &phrases));
        assert!(matches_sleep_phrase("shut up", &phrases));
        assert!(matches_sleep_phrase("Oh just shut up already", &phrases));
    }

    #[test]
    fn sleep_phrases_go_to_sleep_detected() {
        let phrases: Vec<String> = crate::config::ConversationConfig::default()
            .effective_sleep_phrases()
            .iter()
            .map(|s| s.to_lowercase())
            .collect();
        assert!(matches_sleep_phrase("Go to sleep", &phrases));
        assert!(matches_sleep_phrase("go to sleep, Fae", &phrases));
    }

    #[test]
    fn sleep_phrases_thatll_do_fae_with_contraction() {
        let phrases: Vec<String> = crate::config::ConversationConfig::default()
            .effective_sleep_phrases()
            .iter()
            .map(|s| s.to_lowercase())
            .collect();
        // "that'll do fae" is in the default list; STT may produce "that'll" which
        // expand_contractions converts to "that will" — and "that will do fae" is
        // also in the default list.
        assert!(matches_sleep_phrase("That'll do, Fae", &phrases));
        assert!(matches_sleep_phrase("that will do fae", &phrases));
    }

    #[test]
    fn sleep_phrases_quiet_fae_detected() {
        let phrases: Vec<String> = crate::config::ConversationConfig::default()
            .effective_sleep_phrases()
            .iter()
            .map(|s| s.to_lowercase())
            .collect();
        assert!(matches_sleep_phrase("Quiet Fae", &phrases));
        assert!(matches_sleep_phrase("quiet fae!", &phrases));
    }

    #[test]
    fn sleep_phrases_bye_fae_detected() {
        let phrases: Vec<String> = crate::config::ConversationConfig::default()
            .effective_sleep_phrases()
            .iter()
            .map(|s| s.to_lowercase())
            .collect();
        assert!(matches_sleep_phrase("Bye Fae", &phrases));
        assert!(matches_sleep_phrase("goodbye fae", &phrases));
    }

    #[test]
    fn sleep_phrases_unrelated_not_detected() {
        let phrases: Vec<String> = crate::config::ConversationConfig::default()
            .effective_sleep_phrases()
            .iter()
            .map(|s| s.to_lowercase())
            .collect();
        assert!(!matches_sleep_phrase(
            "What is the weather today?",
            &phrases
        ));
        assert!(!matches_sleep_phrase("Tell me a joke", &phrases));
        assert!(!matches_sleep_phrase("Hello Fae", &phrases));
    }

    #[test]
    fn sleep_phrases_legacy_stop_phrase_included() {
        let config = crate::config::ConversationConfig {
            stop_phrase: "hush now fae".to_owned(),
            ..crate::config::ConversationConfig::default()
        };
        let phrases: Vec<String> = config
            .effective_sleep_phrases()
            .iter()
            .map(|s| s.to_lowercase())
            .collect();
        assert!(matches_sleep_phrase("Hush now, Fae!", &phrases));
    }

    #[test]
    fn auto_idle_disabled_when_timeout_zero() {
        // Default config should have idle_timeout_s == 0, meaning the
        // auto-idle timer branch in the gate is never entered.
        let config = crate::config::ConversationConfig::default();
        assert_eq!(config.idle_timeout_s, 0);
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

    /// Verify the conversation gate starts in Active state and processes
    /// transcriptions immediately without needing a wake word.
    #[tokio::test]
    async fn gate_starts_active_and_forwards_transcription() {
        let config = SpeechConfig::default();
        let (stt_tx, stt_rx) = mpsc::channel(8);
        let (llm_tx, mut llm_rx) = mpsc::channel(8);
        let (playback_cmd_tx, _playback_cmd_rx) = mpsc::unbounded_channel();
        let cancel = CancellationToken::new();

        let gate_active = Arc::new(AtomicBool::new(false));
        let ctl = ConversationGateControl {
            interrupt: Arc::new(AtomicBool::new(false)),
            assistant_speaking: Arc::new(AtomicBool::new(false)),
            assistant_generating: Arc::new(AtomicBool::new(false)),
            playback_cmd_tx,
            llm_queue_cmd_tx: None,
            clear_queue_on_stop: false,
            console_output: false,
            cancel: cancel.clone(),
            gate_cmd_rx: None,
            gate_active: Arc::clone(&gate_active),
            awaiting_approval: Arc::new(AtomicBool::new(false)),
        };

        let handle = tokio::spawn(async move {
            run_conversation_gate(config, stt_rx, llm_tx, ctl).await;
        });

        // Gate should be active immediately after spawn.
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            gate_active.load(Ordering::Relaxed),
            "gate should start active"
        );

        // Send a transcription — it should flow through without any wake word.
        stt_tx
            .send(Transcription {
                text: "what is the weather today".to_string(),
                is_final: true,
                voiceprint: None,
                audio_rms: None,
                audio_duration_secs: None,
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send transcription");

        let received = tokio::time::timeout(Duration::from_secs(2), llm_rx.recv())
            .await
            .expect("transcription should reach LLM within timeout");
        assert!(received.is_some(), "transcription should be forwarded");
        assert_eq!(received.unwrap().text, "what is the weather today");

        cancel.cancel();
        drop(stt_tx);
        let _ = handle.await;
    }

    #[tokio::test]
    async fn gate_direct_address_mode_drops_ambient_and_allows_followups() {
        let mut config = SpeechConfig::default();
        config.conversation.require_direct_address = true;
        config.conversation.direct_address_followup_s = 20;

        let (stt_tx, stt_rx) = mpsc::channel(8);
        let (llm_tx, mut llm_rx) = mpsc::channel(8);
        let (playback_cmd_tx, _playback_cmd_rx) = mpsc::unbounded_channel();
        let cancel = CancellationToken::new();

        let gate_active = Arc::new(AtomicBool::new(false));
        let ctl = ConversationGateControl {
            interrupt: Arc::new(AtomicBool::new(false)),
            assistant_speaking: Arc::new(AtomicBool::new(false)),
            assistant_generating: Arc::new(AtomicBool::new(false)),
            playback_cmd_tx,
            llm_queue_cmd_tx: None,
            clear_queue_on_stop: false,
            console_output: false,
            cancel: cancel.clone(),
            gate_cmd_rx: None,
            gate_active: Arc::clone(&gate_active),
            awaiting_approval: Arc::new(AtomicBool::new(false)),
        };

        let handle = tokio::spawn(async move {
            run_conversation_gate(config, stt_rx, llm_tx, ctl).await;
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(gate_active.load(Ordering::Relaxed));

        // No direct address yet — should be ignored as ambient.
        stt_tx
            .send(Transcription {
                text: "what is the weather today".to_string(),
                is_final: true,
                voiceprint: None,
                audio_rms: None,
                audio_duration_secs: None,
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send ambient-like transcription");

        let first = tokio::time::timeout(Duration::from_millis(200), llm_rx.recv()).await;
        assert!(first.is_err(), "non-addressed speech should be dropped");

        // Direct address should pass and start follow-up window.
        stt_tx
            .send(Transcription {
                text: "Fae, what is the weather today?".to_string(),
                is_final: true,
                voiceprint: None,
                audio_rms: None,
                audio_duration_secs: None,
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send direct-address transcription");

        let addressed = tokio::time::timeout(Duration::from_secs(2), llm_rx.recv())
            .await
            .expect("direct-address transcription should be forwarded");
        let addressed = addressed.expect("forwarded transcription");
        assert_eq!(addressed.text, "what is the weather today?");

        // Follow-up without name should pass while engaged window is open.
        stt_tx
            .send(Transcription {
                text: "and tomorrow?".to_string(),
                is_final: true,
                voiceprint: None,
                audio_rms: None,
                audio_duration_secs: None,
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send follow-up transcription");

        let followup = tokio::time::timeout(Duration::from_secs(2), llm_rx.recv())
            .await
            .expect("follow-up should be forwarded");
        let followup = followup.expect("forwarded follow-up");
        assert_eq!(followup.text, "and tomorrow?");

        cancel.cancel();
        drop(stt_tx);
        let _ = handle.await;
    }

    #[tokio::test]
    async fn gate_direct_address_mode_bypasses_filter_during_approval() {
        let mut config = SpeechConfig::default();
        config.conversation.require_direct_address = true;
        config.conversation.direct_address_followup_s = 0;

        let (stt_tx, stt_rx) = mpsc::channel(8);
        let (llm_tx, mut llm_rx) = mpsc::channel(8);
        let (playback_cmd_tx, _playback_cmd_rx) = mpsc::unbounded_channel();
        let cancel = CancellationToken::new();
        let awaiting_approval = Arc::new(AtomicBool::new(true));

        let ctl = ConversationGateControl {
            interrupt: Arc::new(AtomicBool::new(false)),
            assistant_speaking: Arc::new(AtomicBool::new(false)),
            assistant_generating: Arc::new(AtomicBool::new(false)),
            playback_cmd_tx,
            llm_queue_cmd_tx: None,
            clear_queue_on_stop: false,
            console_output: false,
            cancel: cancel.clone(),
            gate_cmd_rx: None,
            gate_active: Arc::new(AtomicBool::new(false)),
            awaiting_approval: Arc::clone(&awaiting_approval),
        };

        let handle = tokio::spawn(async move {
            run_conversation_gate(config, stt_rx, llm_tx, ctl).await;
        });

        stt_tx
            .send(Transcription {
                text: "yes".to_string(),
                is_final: true,
                voiceprint: None,
                audio_rms: None,
                audio_duration_secs: None,
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send approval response");

        let received = tokio::time::timeout(Duration::from_secs(2), llm_rx.recv())
            .await
            .expect("approval response should pass through");
        assert_eq!(received.expect("forwarded").text, "yes");

        cancel.cancel();
        drop(stt_tx);
        let _ = handle.await;
    }

    #[tokio::test]
    async fn identity_gate_enforce_drops_mismatch_and_accepts_match() {
        let mut config = SpeechConfig::default();
        config.voice_identity.enabled = true;
        config.voice_identity.mode = VoiceIdentityMode::Enforce;
        config.voice_identity.threshold_accept = 0.8;
        config.voice_identity.threshold_hold = 0.75;

        let root = tempfile::tempdir().expect("tempdir");
        let memory_root = root.path().to_path_buf();
        let store = MemoryStore::new(&memory_root);
        store.ensure_dirs().expect("memory dirs");
        store
            .save_primary_user(&crate::memory::PrimaryUser {
                name: "Alice".to_owned(),
                voiceprint: Some(vec![1.0, 0.0, 0.0]),
                voiceprints: vec![vec![1.0, 0.0, 0.0]],
                voiceprint_centroid: Some(vec![1.0, 0.0, 0.0]),
                voiceprint_threshold: Some(0.8),
                voiceprint_version: Some("spectral-v1".to_owned()),
                voiceprint_updated_at: Some(1),
                voice_sample_wav: None,
            })
            .expect("save primary user");

        let (stt_tx, stt_rx) = mpsc::channel(8);
        let (llm_tx, mut llm_rx) = mpsc::channel(8);
        let (tts_tx, _tts_rx) = mpsc::channel(8);
        let cancel = CancellationToken::new();

        let handle = tokio::spawn(async move {
            run_identity_gate(
                config,
                stt_rx,
                llm_tx,
                tts_tx,
                memory_root,
                None,
                None,
                cancel.clone(),
            )
            .await;
        });

        stt_tx
            .send(Transcription {
                text: "hello there".to_owned(),
                is_final: true,
                voiceprint: Some(vec![0.0, 1.0, 0.0]),
                audio_rms: Some(0.08),
                audio_duration_secs: Some(1.1),
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send mismatch");
        let mismatch = tokio::time::timeout(Duration::from_millis(200), llm_rx.recv()).await;
        assert!(
            mismatch.is_err(),
            "mismatched speaker should be dropped in enforce mode"
        );

        stt_tx
            .send(Transcription {
                text: "hello there".to_owned(),
                is_final: true,
                voiceprint: Some(vec![1.0, 0.0, 0.0]),
                audio_rms: Some(0.08),
                audio_duration_secs: Some(1.1),
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send match");
        let matched = tokio::time::timeout(Duration::from_secs(2), llm_rx.recv())
            .await
            .expect("match should pass");
        assert_eq!(
            matched.expect("forwarded transcription").text,
            "hello there"
        );

        drop(stt_tx);
        handle.abort();
    }

    #[tokio::test]
    async fn identity_gate_assist_allows_direct_address_fallback() {
        let mut config = SpeechConfig::default();
        config.voice_identity.enabled = true;
        config.voice_identity.mode = VoiceIdentityMode::Assist;
        config.voice_identity.threshold_accept = 0.8;
        config.voice_identity.threshold_hold = 0.75;

        let root = tempfile::tempdir().expect("tempdir");
        let memory_root = root.path().to_path_buf();
        let store = MemoryStore::new(&memory_root);
        store.ensure_dirs().expect("memory dirs");
        store
            .save_primary_user(&crate::memory::PrimaryUser {
                name: "Alice".to_owned(),
                voiceprint: Some(vec![1.0, 0.0, 0.0]),
                voiceprints: vec![vec![1.0, 0.0, 0.0]],
                voiceprint_centroid: Some(vec![1.0, 0.0, 0.0]),
                voiceprint_threshold: Some(0.8),
                voiceprint_version: Some("spectral-v1".to_owned()),
                voiceprint_updated_at: Some(1),
                voice_sample_wav: None,
            })
            .expect("save primary user");

        let (stt_tx, stt_rx) = mpsc::channel(8);
        let (llm_tx, mut llm_rx) = mpsc::channel(8);
        let (tts_tx, _tts_rx) = mpsc::channel(8);
        let cancel = CancellationToken::new();

        let handle = tokio::spawn(async move {
            run_identity_gate(
                config,
                stt_rx,
                llm_tx,
                tts_tx,
                memory_root,
                None,
                None,
                cancel.clone(),
            )
            .await;
        });

        stt_tx
            .send(Transcription {
                text: "what's the weather".to_owned(),
                is_final: true,
                voiceprint: Some(vec![0.0, 1.0, 0.0]),
                audio_rms: Some(0.08),
                audio_duration_secs: Some(1.1),
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send mismatch");
        let dropped = tokio::time::timeout(Duration::from_millis(200), llm_rx.recv()).await;
        assert!(dropped.is_err(), "non-addressed mismatch should be dropped");

        stt_tx
            .send(Transcription {
                text: "Fae, what's the weather".to_owned(),
                is_final: true,
                voiceprint: Some(vec![0.0, 1.0, 0.0]),
                audio_rms: Some(0.08),
                audio_duration_secs: Some(1.1),
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send direct-address mismatch");
        let fallback = tokio::time::timeout(Duration::from_secs(2), llm_rx.recv())
            .await
            .expect("direct-address fallback should pass");
        assert_eq!(
            fallback.expect("forwarded transcription").text,
            "Fae, what's the weather"
        );

        drop(stt_tx);
        handle.abort();
    }

    #[tokio::test]
    async fn identity_gate_collects_enrollment_samples_and_finalizes() {
        let mut config = SpeechConfig::default();
        config.voice_identity.enabled = true;
        config.voice_identity.mode = VoiceIdentityMode::Enforce;
        config.voice_identity.min_enroll_samples = 2;
        config.voice_identity.store_raw_samples = true;

        let root = tempfile::tempdir().expect("tempdir");
        let memory_root = root.path().to_path_buf();
        let store = MemoryStore::new(&memory_root);
        store.ensure_dirs().expect("memory dirs");
        store
            .save_primary_user(&crate::memory::PrimaryUser {
                name: "Alice".to_owned(),
                voiceprint: None,
                voiceprints: Vec::new(),
                voiceprint_centroid: None,
                voiceprint_threshold: None,
                voiceprint_version: None,
                voiceprint_updated_at: None,
                voice_sample_wav: None,
            })
            .expect("save primary user");

        let (stt_tx, stt_rx) = mpsc::channel(8);
        let (llm_tx, mut llm_rx) = mpsc::channel(8);
        let (tts_tx, _tts_rx) = mpsc::channel(8);
        let cancel = CancellationToken::new();

        let handle = tokio::spawn(async move {
            run_identity_gate(
                config,
                stt_rx,
                llm_tx,
                tts_tx,
                memory_root.clone(),
                None,
                None,
                cancel.clone(),
            )
            .await;
        });

        stt_tx
            .send(Transcription {
                text: "Fae, sample one".to_owned(),
                is_final: true,
                voiceprint: Some(vec![1.0, 0.0, 0.0]),
                audio_rms: Some(0.09),
                audio_duration_secs: Some(1.0),
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send sample one");
        let _ = tokio::time::timeout(Duration::from_secs(2), llm_rx.recv())
            .await
            .expect("sample one should still pass");

        stt_tx
            .send(Transcription {
                text: "Fae, sample two".to_owned(),
                is_final: true,
                voiceprint: Some(vec![0.8, 0.6, 0.0]),
                audio_rms: Some(0.09),
                audio_duration_secs: Some(1.0),
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send sample two");
        let _ = tokio::time::timeout(Duration::from_secs(2), llm_rx.recv())
            .await
            .expect("sample two should pass");

        tokio::time::sleep(Duration::from_millis(100)).await;
        let saved = store
            .load_primary_user()
            .expect("load primary")
            .expect("primary exists");
        assert!(
            saved.voiceprint_centroid.is_some(),
            "voiceprint centroid should be finalized after required samples"
        );

        drop(stt_tx);
        handle.abort();
    }

    #[test]
    fn approval_speaker_verification_rejects_mismatch() {
        let profile = VoiceIdentityProfile {
            mode: VoiceIdentityMode::Assist,
            centroid: Some(vec![1.0, 0.0, 0.0]),
            threshold_accept: 0.8,
            threshold_hold: 0.7,
            hold_window: Duration::from_secs(8),
        };
        let mismatch = Transcription {
            text: "yes".to_owned(),
            is_final: true,
            voiceprint: Some(vec![0.0, 1.0, 0.0]),
            audio_rms: Some(0.08),
            audio_duration_secs: Some(0.6),
            audio_captured_at: Instant::now(),
            transcribed_at: Instant::now(),
        };
        let (ok, sim) = approval_speaker_verified(Some(&profile), &mismatch);
        assert!(!ok);
        assert!(sim.is_some());
    }

    /// Verify GateCommand::Sleep → Idle → GateCommand::Wake → Active cycle.
    #[tokio::test]
    async fn gate_sleep_wake_cycle() {
        let config = SpeechConfig::default();
        let (stt_tx, stt_rx) = mpsc::channel(8);
        let (llm_tx, mut llm_rx) = mpsc::channel(8);
        let (playback_cmd_tx, _playback_cmd_rx) = mpsc::unbounded_channel();
        let (gate_cmd_tx, gate_cmd_rx) = mpsc::unbounded_channel();
        let cancel = CancellationToken::new();

        let gate_active = Arc::new(AtomicBool::new(false));
        let ctl = ConversationGateControl {
            interrupt: Arc::new(AtomicBool::new(false)),
            assistant_speaking: Arc::new(AtomicBool::new(false)),
            assistant_generating: Arc::new(AtomicBool::new(false)),
            playback_cmd_tx,
            llm_queue_cmd_tx: None,
            clear_queue_on_stop: false,
            console_output: false,
            cancel: cancel.clone(),
            gate_cmd_rx: Some(gate_cmd_rx),
            gate_active: Arc::clone(&gate_active),
            awaiting_approval: Arc::new(AtomicBool::new(false)),
        };

        let handle = tokio::spawn(async move {
            run_conversation_gate(config, stt_rx, llm_tx, ctl).await;
        });

        // Wait for gate to be active.
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            gate_active.load(Ordering::Relaxed),
            "gate should start active"
        );

        // Send Sleep command — gate should go Idle.
        gate_cmd_tx
            .send(GateCommand::Sleep)
            .expect("send sleep command");

        // Give the gate time to process.
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(
            !gate_active.load(Ordering::Relaxed),
            "gate should be idle after sleep command"
        );

        // Send a transcription while idle — should NOT reach LLM.
        stt_tx
            .send(Transcription {
                text: "this should be ignored".to_string(),
                is_final: true,
                voiceprint: None,
                audio_rms: None,
                audio_duration_secs: None,
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send while idle");

        // Brief wait, then confirm nothing was forwarded.
        let idle_recv = tokio::time::timeout(Duration::from_millis(200), llm_rx.recv()).await;
        assert!(
            idle_recv.is_err(),
            "transcription should not be forwarded while idle"
        );

        // Send Wake command — gate should return to Active.
        gate_cmd_tx
            .send(GateCommand::Wake)
            .expect("send wake command");

        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            gate_active.load(Ordering::Relaxed),
            "gate should be active after wake"
        );

        // Send transcription again — should flow through.
        stt_tx
            .send(Transcription {
                text: "hello again".to_string(),
                is_final: true,
                voiceprint: None,
                audio_rms: None,
                audio_duration_secs: None,
                audio_captured_at: Instant::now(),
                transcribed_at: Instant::now(),
            })
            .await
            .expect("send after wake");

        let received = tokio::time::timeout(Duration::from_secs(2), llm_rx.recv())
            .await
            .expect("transcription should reach LLM after wake");
        assert!(received.is_some());
        assert_eq!(received.unwrap().text, "hello again");

        cancel.cancel();
        drop(stt_tx);
        let _ = handle.await;
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
            gate_cmd_rx: Some(gate_cmd_rx),
            gate_active: Arc::new(AtomicBool::new(false)),
            awaiting_approval: Arc::new(AtomicBool::new(false)),
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

    #[test]
    fn coding_assistant_context_enabled_for_coding_intent() {
        assert!(should_include_local_coding_assistants_context(
            "Can you debug this Rust compile error?"
        ));
        assert!(should_include_local_coding_assistants_context(
            "Please help me refactor this code"
        ));
    }

    #[test]
    fn coding_assistant_context_skipped_for_general_chat() {
        assert!(!should_include_local_coding_assistants_context(
            "What time is it in London?"
        ));
        assert!(!should_include_local_coding_assistants_context(
            "How's the weather today?"
        ));
    }
}
