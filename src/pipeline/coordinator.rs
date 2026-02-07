//! Main pipeline orchestrator that wires all stages together.

use crate::config::SpeechConfig;
use crate::error::Result;
use crate::pipeline::messages::{
    AudioChunk, SentenceChunk, SpeechSegment, SynthesizedAudio, Transcription,
};
use crate::startup::InitializedModels;
use std::io::Write;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{error, info};

/// Channel buffer sizes.
const AUDIO_CHANNEL_SIZE: usize = 64;
const SPEECH_CHANNEL_SIZE: usize = 8;
const TRANSCRIPTION_CHANNEL_SIZE: usize = 8;
const SENTENCE_CHANNEL_SIZE: usize = 8;
const SYNTH_CHANNEL_SIZE: usize = 16;

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
}

impl PipelineCoordinator {
    /// Create a new pipeline coordinator with the given configuration.
    pub fn new(config: SpeechConfig) -> Self {
        Self {
            config,
            cancel: CancellationToken::new(),
            mode: PipelineMode::Conversation,
            models: None,
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
        }
    }

    /// Set the pipeline operating mode.
    pub fn with_mode(mut self, mode: PipelineMode) -> Self {
        self.mode = mode;
        self
    }

    /// Run the full pipeline until cancelled.
    ///
    /// # Errors
    ///
    /// Returns an error if any pipeline stage fails to initialize.
    pub async fn run(mut self) -> Result<()> {
        info!("initializing speech pipeline (mode: {:?})", self.mode);

        // Split pre-loaded models (if any) into per-stage pieces.
        let (preloaded_stt, preloaded_llm, preloaded_tts) = match self.models.take() {
            Some(m) => (Some(m.stt), m.llm, Some(m.tts)),
            None => (None, None, None),
        };

        // Create channels between stages
        let (audio_tx, audio_rx) = mpsc::channel::<AudioChunk>(AUDIO_CHANNEL_SIZE);
        let (speech_tx, speech_rx) = mpsc::channel::<SpeechSegment>(SPEECH_CHANNEL_SIZE);
        let (transcription_tx, transcription_rx) =
            mpsc::channel::<Transcription>(TRANSCRIPTION_CHANNEL_SIZE);

        let cancel = self.cancel.clone();

        // Shared flag: suppresses VAD while AI audio is playing to prevent
        // speaker → mic feedback loop. Set by LLM stage, cleared by Playback.
        let ai_speaking = Arc::new(AtomicBool::new(false));

        // Stage 1: Audio capture (always)
        let capture_handle = {
            let config = self.config.audio.clone();
            let cancel = cancel.clone();
            tokio::spawn(async move {
                run_capture_stage(config, audio_tx, cancel).await;
            })
        };

        // Stage 2: VAD (always)
        let vad_handle = {
            let config = self.config.clone();
            let cancel = cancel.clone();
            let ai_speaking = Arc::clone(&ai_speaking);
            tokio::spawn(async move {
                run_vad_stage(config, audio_rx, speech_tx, ai_speaking, cancel).await;
            })
        };

        // Stage 3: STT (always)
        let stt_handle = {
            let config = self.config.clone();
            let cancel = cancel.clone();
            tokio::spawn(async move {
                run_stt_stage(config, preloaded_stt, speech_rx, transcription_tx, cancel).await;
            })
        };

        // Build remaining handles depending on mode
        match self.mode {
            PipelineMode::Conversation => {
                let (sentence_tx, sentence_rx) =
                    mpsc::channel::<SentenceChunk>(SENTENCE_CHANNEL_SIZE);
                let (synth_tx, synth_rx) = mpsc::channel::<SynthesizedAudio>(SYNTH_CHANNEL_SIZE);

                // Shared interrupt flag between gate and LLM
                let interrupt = Arc::new(AtomicBool::new(false));

                // Insert conversation gate between STT and LLM when enabled
                let (llm_rx, gate_handle) = if self.config.conversation.enabled {
                    let (gated_tx, gated_rx) =
                        mpsc::channel::<Transcription>(TRANSCRIPTION_CHANNEL_SIZE);
                    let config = self.config.clone();
                    let cancel = cancel.clone();
                    let interrupt = Arc::clone(&interrupt);
                    let handle = Some(tokio::spawn(async move {
                        run_conversation_gate(
                            config,
                            transcription_rx,
                            gated_tx,
                            interrupt,
                            cancel,
                        )
                        .await;
                    }));
                    (gated_rx, handle)
                } else {
                    (transcription_rx, None)
                };

                // Stage 4: LLM
                let llm_handle = {
                    let config = self.config.clone();
                    let cancel = cancel.clone();
                    let interrupt = Arc::clone(&interrupt);
                    let ai_speaking = Arc::clone(&ai_speaking);
                    tokio::spawn(async move {
                        run_llm_stage(
                            config,
                            preloaded_llm,
                            llm_rx,
                            sentence_tx,
                            interrupt,
                            ai_speaking,
                            cancel,
                        )
                        .await;
                    })
                };

                // Stage 5: TTS
                let tts_handle = {
                    let config = self.config.clone();
                    let cancel = cancel.clone();
                    tokio::spawn(async move {
                        run_tts_stage(config, preloaded_tts, sentence_rx, synth_tx, cancel).await;
                    })
                };

                // Stage 6: Playback
                let playback_handle = {
                    let config = self.config.audio.clone();
                    let cancel = cancel.clone();
                    let ai_speaking = Arc::clone(&ai_speaking);
                    tokio::spawn(async move {
                        run_playback_stage(config, synth_rx, ai_speaking, cancel).await;
                    })
                };

                // Wait for cancellation
                cancel.cancelled().await;
                info!("pipeline shutting down");

                if let Some(gate) = gate_handle {
                    let _ = tokio::join!(
                        capture_handle,
                        vad_handle,
                        stt_handle,
                        gate,
                        llm_handle,
                        tts_handle,
                        playback_handle,
                    );
                } else {
                    let _ = tokio::join!(
                        capture_handle,
                        vad_handle,
                        stt_handle,
                        llm_handle,
                        tts_handle,
                        playback_handle,
                    );
                }
            }
            PipelineMode::TranscribeOnly => {
                // Just print transcriptions to stdout
                let print_handle = {
                    let cancel = cancel.clone();
                    tokio::spawn(async move {
                        run_print_stage(transcription_rx, cancel).await;
                    })
                };

                cancel.cancelled().await;
                info!("pipeline shutting down");

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
    cancel: CancellationToken,
) {
    use crate::audio::capture::CpalCapture;

    match CpalCapture::new(&config) {
        Ok(capture) => {
            if let Err(e) = capture.run(tx, cancel).await {
                error!("capture stage error: {e}");
            }
        }
        Err(e) => error!("failed to init capture: {e}"),
    }
}

async fn run_vad_stage(
    config: SpeechConfig,
    mut rx: mpsc::Receiver<AudioChunk>,
    tx: mpsc::Sender<SpeechSegment>,
    ai_speaking: Arc<AtomicBool>,
    cancel: CancellationToken,
) {
    use crate::vad::SileroVad;

    let mut vad = match SileroVad::new(&config.vad, &config.models) {
        Ok(v) => v,
        Err(e) => {
            error!("failed to init VAD: {e}");
            return;
        }
    };

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            chunk = rx.recv() => {
                match chunk {
                    Some(chunk) => {
                        // Skip mic input while AI is speaking to prevent
                        // speaker → mic → STT → LLM feedback loop.
                        if ai_speaking.load(Ordering::Relaxed) {
                            continue;
                        }
                        match vad.process_chunk(&chunk) {
                            Ok(Some(segment)) => {
                                let duration_s = segment.samples.len() as f32
                                    / segment.sample_rate as f32;
                                info!("speech segment detected: {duration_s:.1}s");
                                if tx.send(segment).await.is_err() {
                                    break;
                                }
                            }
                            Ok(None) => {}
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

/// Internal engine wrapper for either local or API-based LLM.
enum LlmEngine {
    Local(Box<crate::llm::LocalLlm>),
    Api(Box<crate::llm::ApiLlm>),
}

impl LlmEngine {
    /// Generate a response using whichever backend is active.
    async fn generate_response(
        &mut self,
        user_input: &str,
        tx: &mpsc::Sender<SentenceChunk>,
        interrupt: &Arc<AtomicBool>,
    ) -> crate::error::Result<bool> {
        match self {
            Self::Local(llm) => llm.generate_response(user_input, tx, interrupt).await,
            Self::Api(llm) => llm.generate_response(user_input, tx, interrupt).await,
        }
    }
}

async fn run_llm_stage(
    config: SpeechConfig,
    preloaded: Option<crate::llm::LocalLlm>,
    mut rx: mpsc::Receiver<Transcription>,
    tx: mpsc::Sender<SentenceChunk>,
    interrupt: Arc<AtomicBool>,
    ai_speaking: Arc<AtomicBool>,
    cancel: CancellationToken,
) {
    use crate::config::LlmBackend;
    use crate::llm::{ApiLlm, LocalLlm};

    let mut engine = match config.llm.backend {
        LlmBackend::Local => {
            let llm = match preloaded {
                Some(l) => l,
                None => match LocalLlm::new(&config.llm).await {
                    Ok(l) => l,
                    Err(e) => {
                        error!("failed to init LLM: {e}");
                        return;
                    }
                },
            };
            LlmEngine::Local(Box::new(llm))
        }
        LlmBackend::Api => match ApiLlm::new(&config.llm) {
            Ok(l) => LlmEngine::Api(Box::new(l)),
            Err(e) => {
                error!("failed to init API LLM: {e}");
                return;
            }
        },
    };

    let name = config
        .conversation
        .wake_word
        .chars()
        .next()
        .map_or(String::new(), |c| {
            let mut s = c.to_uppercase().to_string();
            s.push_str(&config.conversation.wake_word[c.len_utf8()..]);
            s
        });

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            transcription = rx.recv() => {
                match transcription {
                    Some(transcription) => {
                        if transcription.text.is_empty() {
                            continue;
                        }
                        // When gate is disabled, print [You] here since
                        // there is no gate stage to do it
                        if !config.conversation.enabled {
                            let latency = transcription.transcribed_at
                                .duration_since(transcription.audio_captured_at);
                            println!("\n[You] {} (STT: {:.0}ms)",
                                transcription.text, latency.as_millis());
                            print!("[AI] ");
                        } else {
                            print!("[{name}] ");
                        }
                        let _ = std::io::stdout().flush();
                        // Mute mic while generating + speaking
                        ai_speaking.store(true, Ordering::Relaxed);
                        match engine.generate_response(&transcription.text, &tx, &interrupt).await {
                            Ok(interrupted) => {
                                println!();
                                if interrupted {
                                    info!("LLM generation was interrupted");
                                }
                                // ai_speaking cleared by playback on final chunk
                            }
                            Err(e) => {
                                println!();
                                error!("LLM error: {e}");
                                // On error, no final chunk sent — clear flag here
                                ai_speaking.store(false, Ordering::Relaxed);
                            }
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

async fn run_tts_stage(
    config: SpeechConfig,
    preloaded: Option<crate::tts::ChatterboxTts>,
    mut rx: mpsc::Receiver<SentenceChunk>,
    tx: mpsc::Sender<SynthesizedAudio>,
    cancel: CancellationToken,
) {
    use crate::tts::{ChatterboxTts, resolve_voice_wav};

    let mut tts = match preloaded {
        Some(t) => t,
        None => {
            let result = match resolve_voice_wav(&config.tts) {
                Some(voice_wav) => ChatterboxTts::new(&config.tts, &voice_wav),
                None => ChatterboxTts::new_with_default_voice(&config.tts),
            };
            match result {
                Ok(t) => t,
                Err(e) => {
                    error!("failed to init TTS: {e}");
                    return;
                }
            }
        }
    };

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            sentence = rx.recv() => {
                match sentence {
                    Some(sentence) => {
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
                        match tts.synthesize(&sentence.text).await {
                            Ok(audio) => {
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

async fn run_playback_stage(
    config: crate::config::AudioConfig,
    mut rx: mpsc::Receiver<SynthesizedAudio>,
    ai_speaking: Arc<AtomicBool>,
    cancel: CancellationToken,
) {
    use crate::audio::playback::CpalPlayback;

    let mut playback = match CpalPlayback::new(&config) {
        Ok(p) => p,
        Err(e) => {
            error!("failed to init playback: {e}");
            return;
        }
    };

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            audio = rx.recv() => {
                match audio {
                    Some(audio) => {
                        if !audio.samples.is_empty()
                            && let Err(e) = playback.play(&audio.samples, audio.sample_rate)
                        {
                            error!("playback error: {e}");
                        }
                        // When the final chunk of a response is played,
                        // wait briefly for residual speaker audio to
                        // dissipate, then re-enable the microphone.
                        if audio.is_final {
                            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                            ai_speaking.store(false, Ordering::Relaxed);
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

/// Conversation gate: filters transcriptions based on wake word / stop phrase.
///
/// In `Idle` state, listens for the wake word and discards everything else.
/// In `Active` state, forwards transcriptions to the LLM and checks for the
/// stop phrase. Any new transcription in Active state also sets the interrupt
/// flag to enable barge-in.
async fn run_conversation_gate(
    config: SpeechConfig,
    mut stt_rx: mpsc::Receiver<Transcription>,
    llm_tx: mpsc::Sender<Transcription>,
    interrupt: Arc<AtomicBool>,
    cancel: CancellationToken,
) {
    let wake_word = config.conversation.wake_word.to_lowercase();
    let stop_phrase = config.conversation.stop_phrase.to_lowercase();
    let mut state = GateState::Idle;

    // Capitalize wake word for display
    let display_name = {
        let mut chars = config.conversation.wake_word.chars();
        match chars.next() {
            Some(c) => {
                let mut s = c.to_uppercase().to_string();
                s.push_str(chars.as_str());
                s
            }
            None => String::new(),
        }
    };

    info!("conversation gate active, wake word: \"{wake_word}\"");

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            transcription = stt_rx.recv() => {
                match transcription {
                    Some(t) => {
                        if t.text.is_empty() {
                            continue;
                        }

                        let lower = expand_contractions(&t.text.to_lowercase());

                        match state {
                            GateState::Idle => {
                                if let Some(pos) = lower.find(&wake_word) {
                                    // Wake word detected — transition to Active
                                    state = GateState::Active;
                                    println!("\n[{display_name}] Listening...");

                                    // Extract text after the wake word (if any),
                                    // stripping surrounding punctuation so "Hi, Fae."
                                    // doesn't send "." as a query.
                                    let after = &t.text[pos + wake_word.len()..];
                                    let after =
                                        after.trim_start_matches([',', ':', '.', '!', '?', ' ']);
                                    let after = after.trim();

                                    if !after.is_empty() {
                                        // There's a query after the wake word
                                        let latency = t.transcribed_at
                                            .duration_since(t.audio_captured_at);
                                        println!("[You] {after} (STT: {:.0}ms)",
                                            latency.as_millis());

                                        let forwarded = Transcription {
                                            text: after.to_owned(),
                                            ..t
                                        };
                                        if llm_tx.send(forwarded).await.is_err() {
                                            break;
                                        }
                                    }
                                }
                                // If no wake word, silently discard
                            }
                            GateState::Active => {
                                // Check for stop phrase
                                if lower.contains(&stop_phrase) {
                                    // Stop — interrupt any running generation
                                    interrupt.store(true, Ordering::Relaxed);
                                    state = GateState::Idle;
                                    println!("\n[{display_name}] Standing by.\n");
                                    info!("stop phrase detected, returning to idle");
                                    continue;
                                }

                                // Check if this is a new wake word activation
                                // (barge-in with new query)
                                if lower.contains(&wake_word) {
                                    // Interrupt current generation
                                    interrupt.store(true, Ordering::Relaxed);

                                    let after = if let Some(pos) = lower.find(&wake_word) {
                                        let after = &t.text[pos + wake_word.len()..];
                                        let after = after
                                            .trim_start_matches([',', ':', '.', '!', '?', ' ']);
                                        after.trim().to_owned()
                                    } else {
                                        String::new()
                                    };

                                    if after.is_empty() {
                                        println!("\n[{display_name}] Listening...");
                                        continue;
                                    }

                                    let latency = t.transcribed_at
                                        .duration_since(t.audio_captured_at);
                                    println!("\n[You] {after} (STT: {:.0}ms)",
                                        latency.as_millis());

                                    let forwarded = Transcription {
                                        text: after,
                                        ..t
                                    };
                                    if llm_tx.send(forwarded).await.is_err() {
                                        break;
                                    }
                                    continue;
                                }

                                // Normal active transcription — barge-in interrupts
                                // any running generation
                                interrupt.store(true, Ordering::Relaxed);

                                let latency = t.transcribed_at
                                    .duration_since(t.audio_captured_at);
                                println!("\n[You] {} (STT: {:.0}ms)",
                                    t.text, latency.as_millis());

                                if llm_tx.send(t).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    None => break,
                }
            }
        }
    }
}

/// Print transcriptions to stdout (for transcribe-only mode).
async fn run_print_stage(mut rx: mpsc::Receiver<Transcription>, cancel: CancellationToken) {
    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            transcription = rx.recv() => {
                match transcription {
                    Some(t) => {
                        if !t.text.is_empty() {
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
