//! Startup initialization: downloads models with progress bars and eagerly loads them.
//!
//! Call [`initialize_models`] at startup to pre-download and pre-load all ML models
//! so the pipeline is ready to run without mid-conversation delays.
//!
//! For GUI consumers, use [`initialize_models_with_progress`] which accepts a
//! [`ProgressCallback`] for structured progress events.

use crate::config::{AgentToolMode, LlmBackend, SpeechConfig, TtsBackend};
use crate::error::Result;
use crate::llm::LocalLlm;
use crate::llm::server::LlmServer;
use crate::models::ModelManager;
use crate::progress::{ProgressCallback, ProgressEvent};
use crate::stt::ParakeetStt;
use crate::tts::KokoroTts;
use std::time::Instant;
use tracing::info;

/// Pre-loaded model instances ready for the pipeline.
pub struct InitializedModels {
    /// Parakeet TDT speech-to-text engine.
    pub stt: ParakeetStt,
    /// Local LLM engine (only loaded for local backend).
    pub llm: Option<LocalLlm>,
    /// Kokoro TTS engine (None if using Fish Speech or other backend).
    pub tts: Option<KokoroTts>,
    /// OpenAI-compatible HTTP server for local LLM inference.
    pub llm_server: Option<LlmServer>,
}

impl InitializedModels {
    /// Returns the port the LLM server is listening on, if running.
    pub fn llm_server_port(&self) -> Option<u16> {
        self.llm_server.as_ref().map(LlmServer::port)
    }
}

impl InitializedModels {
    /// Shut down the LLM server and clean up Pi's models.json.
    ///
    /// Call this before dropping the struct if you want to clean up the
    /// Pi provider entry. The server task is aborted automatically via
    /// [`LlmServer::drop`], but the models.json cleanup requires this
    /// explicit call.
    pub fn shutdown_llm_server(&mut self) {
        if let Some(server) = self.llm_server.take() {
            server.shutdown();
            if let Some(pi_path) = crate::llm::pi_config::default_pi_models_path()
                && let Err(e) = crate::llm::pi_config::remove_fae_local_provider(&pi_path)
            {
                tracing::warn!("failed to clean Pi models.json: {e}");
            }
        }
    }
}

/// STT model files to pre-download.
const STT_FILES: &[&str] = &[
    "encoder-model.onnx",
    "encoder-model.onnx.data",
    "decoder_joint-model.onnx",
    "vocab.txt",
];

/// Download all model files with progress bars, then eagerly load each model.
///
/// Prints user-friendly progress to stdout. This is designed for CLI use.
/// For GUI consumers, use [`initialize_models_with_progress`] instead.
///
/// # Errors
///
/// Returns an error if any download or model load fails.
pub async fn initialize_models(config: &SpeechConfig) -> Result<InitializedModels> {
    initialize_models_with_progress(config, None).await
}

/// Download all model files and load them, sending progress events via callback.
///
/// When `callback` is `None`, progress is printed to stdout (CLI mode).
/// When `callback` is `Some`, structured [`ProgressEvent`]s are emitted for
/// each download and load step (GUI mode).
///
/// # Errors
///
/// Returns an error if any download or model load fails.
pub async fn initialize_models_with_progress(
    config: &SpeechConfig,
    callback: Option<&ProgressCallback>,
) -> Result<InitializedModels> {
    let model_manager = ModelManager::new(&config.models)?;
    // Agent and Pi backends rely on a local model:
    // - Agent: in-process inference
    // - Pi: served via the local OpenAI-compatible HTTP server (`llm_server`)
    let use_local_llm = matches!(
        config.llm.backend,
        LlmBackend::Local | LlmBackend::Agent | LlmBackend::Pi
    );

    if matches!(config.llm.backend, LlmBackend::Local | LlmBackend::Api)
        && !matches!(config.llm.tool_mode, AgentToolMode::Off)
    {
        tracing::warn!(
            "tool_mode={:?} is ignored for {:?} backend; use llm.backend=pi or llm.backend=agent to enable tools",
            config.llm.tool_mode,
            config.llm.backend
        );
        println!(
            "  Note: tool_mode is ignored for {:?} backend; use llm.backend=pi or llm.backend=agent for tool access.",
            config.llm.backend
        );
    }

    // --- Phase 1: Download all model files ---
    println!("\nChecking models...");

    // STT files
    for filename in STT_FILES {
        model_manager.download_with_progress(&config.stt.model_id, filename, callback)?;
    }

    // LLM: mistralrs handles its own HF downloads, so we skip manual download
    // for the local backend. Only STT needs explicit pre-download.

    // TTS: Chatterbox models are downloaded by the engine via hf-hub on load.

    // --- Phase 2: Load models ---
    println!("\nLoading models...");

    let stt = load_stt(config, callback)?;
    let llm = if use_local_llm {
        Some(load_llm(config, callback).await?)
    } else {
        println!(
            "  LLM: using API backend ({} @ {})",
            config.llm.api_model, config.llm.api_url
        );
        None
    };
    let tts = if matches!(config.tts.backend, TtsBackend::Kokoro) {
        Some(load_tts(config, callback)?)
    } else {
        println!(
            "  TTS: using {} backend (loaded at pipeline start)",
            match config.tts.backend {
                TtsBackend::Kokoro => "Kokoro",
                TtsBackend::FishSpeech => "Fish Speech",
            }
        );
        None
    };

    // --- Phase 3: Start LLM HTTP server ---
    // Pi backend requires the local OpenAI endpoint so it can default to
    // Fae's local brain (`fae-local/fae-qwen3`) and keep local fallback available.
    let should_start_llm_server =
        config.llm_server.enabled || matches!(config.llm.backend, LlmBackend::Pi);
    if matches!(config.llm.backend, LlmBackend::Pi) && !config.llm_server.enabled {
        tracing::info!(
            "llm_server.enabled=false ignored for Pi backend; starting local LLM server"
        );
    }
    let llm_server = match (should_start_llm_server, &llm) {
        (true, Some(local_llm)) => match start_llm_server(local_llm, config).await {
            Ok(server) => Some(server),
            Err(e) => {
                tracing::warn!("failed to start LLM server: {e}");
                None
            }
        },
        _ => None,
    };

    Ok(InitializedModels {
        stt,
        llm,
        tts,
        llm_server,
    })
}

/// Start the LLM HTTP server with the shared model and optionally register with Pi.
async fn start_llm_server(llm: &LocalLlm, config: &SpeechConfig) -> Result<LlmServer> {
    let model = llm.shared_model();
    let server = LlmServer::start(model, &config.llm_server).await?;

    info!(
        "LLM server listening on http://127.0.0.1:{}/v1",
        server.port()
    );

    // Write the fae-local provider to Pi's models.json so Pi can discover us.
    if let Some(pi_path) = crate::llm::pi_config::default_pi_models_path()
        && let Err(e) = crate::llm::pi_config::write_fae_local_provider(&pi_path, server.port())
    {
        tracing::warn!("failed to write Pi models.json: {e}");
    }

    Ok(server)
}

/// Generic wrapper for model loading with timing, logging, and progress callbacks.
fn load_model_with_progress<T>(
    model_name: String,
    callback: Option<&ProgressCallback>,
    loader: impl FnOnce() -> Result<T>,
) -> Result<T> {
    print!("  Loading {model_name}...");
    if let Some(cb) = callback {
        cb(ProgressEvent::LoadStarted {
            model_name: model_name.clone(),
        });
    }

    let start = Instant::now();
    let model = loader()?;
    let elapsed = start.elapsed();

    println!("  done ({:.1}s)", elapsed.as_secs_f64());
    if let Some(cb) = callback {
        cb(ProgressEvent::LoadComplete {
            model_name,
            duration_secs: elapsed.as_secs_f64(),
        });
    }
    Ok(model)
}

/// Load STT with a status message and optional progress callback.
fn load_stt(config: &SpeechConfig, callback: Option<&ProgressCallback>) -> Result<ParakeetStt> {
    load_model_with_progress("STT (Parakeet TDT)".to_owned(), callback, || {
        let mut stt = ParakeetStt::new(&config.stt, &config.models)?;
        stt.ensure_loaded()?;
        Ok(stt)
    })
}

/// Load LLM with a status message and optional progress callback.
async fn load_llm(config: &SpeechConfig, callback: Option<&ProgressCallback>) -> Result<LocalLlm> {
    let model_name = format!("LLM ({} / {})", config.llm.model_id, config.llm.gguf_file);
    print!("  Loading {model_name}...");
    if let Some(cb) = callback {
        cb(ProgressEvent::LoadStarted {
            model_name: model_name.clone(),
        });
    }

    let start = Instant::now();
    let llm = LocalLlm::new(&config.llm).await?;
    let elapsed = start.elapsed();

    println!("  done ({:.1}s)", elapsed.as_secs_f64());
    if let Some(cb) = callback {
        cb(ProgressEvent::LoadComplete {
            model_name,
            duration_secs: elapsed.as_secs_f64(),
        });
    }
    Ok(llm)
}

/// Load TTS with a status message and optional progress callback.
fn load_tts(config: &SpeechConfig, callback: Option<&ProgressCallback>) -> Result<KokoroTts> {
    load_model_with_progress("TTS (Kokoro-82M)".to_owned(), callback, || {
        KokoroTts::new(&config.tts)
    })
}

/// Run a background update check for Fae.
///
/// Respects the user's auto-update preference and only checks if the last
/// check was more than `stale_hours` hours ago. Returns `Some(release)` if
/// a newer version is available, `None` otherwise.
///
/// This function is safe to call from any async context — it spawns the
/// HTTP request on a blocking thread.
pub async fn check_for_fae_update(stale_hours: u64) -> Option<crate::update::Release> {
    let state = crate::update::UpdateState::load();

    if !state.check_is_stale(stale_hours) {
        return None;
    }

    if state.auto_update == crate::update::AutoUpdatePreference::Never {
        return None;
    }

    let etag = state.etag_fae.clone();
    let result = tokio::task::spawn_blocking(move || {
        let checker = crate::update::UpdateChecker::for_fae();
        checker.check(etag.as_deref())
    })
    .await;

    let (release, new_etag) = match result {
        Ok(Ok((release, new_etag))) => (release, new_etag),
        Ok(Err(e)) => {
            tracing::debug!("update check failed: {e}");
            return None;
        }
        Err(e) => {
            tracing::debug!("update check task failed: {e}");
            return None;
        }
    };

    // Update state with new ETag and timestamp.
    let mut new_state = state;
    new_state.etag_fae = new_etag;
    new_state.mark_checked();

    // Check if release should be returned before moving state.
    let should_return_release = match &release {
        Some(rel) => new_state.dismissed_release.as_deref() != Some(rel.version.as_str()),
        None => false,
    };

    // Persist state update.
    let _ = tokio::task::spawn_blocking(move || new_state.save()).await;

    // Return release if available and not dismissed.
    if should_return_release && let Some(rel) = release {
        info!("update available: Fae v{}", rel.version);
        return Some(rel);
    }

    None
}

/// Start the background scheduler with built-in update check tasks.
///
/// Returns a tuple of the background task handle and a receiver for task
/// results. The caller should poll the receiver to surface task outcomes
/// in the GUI (e.g., update-available notifications).
///
/// The scheduler ticks every 60 seconds and persists state to
/// `~/.config/fae/scheduler.json`.
pub fn start_scheduler() -> (
    tokio::task::JoinHandle<()>,
    tokio::sync::mpsc::UnboundedReceiver<crate::scheduler::tasks::TaskResult>,
) {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    let mut scheduler = crate::scheduler::runner::Scheduler::new(tx);
    scheduler.with_update_checks();

    info!(
        "starting background scheduler with {} tasks",
        scheduler.tasks().len()
    );
    let handle = scheduler.run();
    (handle, rx)
}
