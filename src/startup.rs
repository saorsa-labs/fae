//! Startup initialization: downloads models with progress bars and eagerly loads them.
//!
//! Call [`initialize_models`] at startup to pre-download and pre-load all ML models
//! so the pipeline is ready to run without mid-conversation delays.
//!
//! For GUI consumers, use [`initialize_models_with_progress`] which accepts a
//! [`ProgressCallback`] for structured progress events.

use crate::config::{LlmBackend, SpeechConfig};
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
    /// Kokoro TTS engine.
    pub tts: KokoroTts,
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
    // Agent backend uses in-process inference (local model) by default.
    let use_local_llm = matches!(config.llm.backend, LlmBackend::Local | LlmBackend::Agent);

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
    let tts = load_tts(config, callback)?;

    // --- Phase 3: Start LLM HTTP server (if enabled and model is loaded) ---
    let llm_server = if config.llm_server.enabled
        && let Some(ref local_llm) = llm
    {
        match start_llm_server(local_llm, config).await {
            Ok(server) => Some(server),
            Err(e) => {
                tracing::warn!("failed to start LLM server: {e}");
                None
            }
        }
    } else {
        None
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

/// Load STT with a status message and optional progress callback.
fn load_stt(config: &SpeechConfig, callback: Option<&ProgressCallback>) -> Result<ParakeetStt> {
    let model_name = "STT (Parakeet TDT)".to_owned();
    print!("  Loading {model_name}...");
    if let Some(cb) = callback {
        cb(ProgressEvent::LoadStarted {
            model_name: model_name.clone(),
        });
    }

    let start = Instant::now();
    let mut stt = ParakeetStt::new(&config.stt, &config.models)?;
    stt.ensure_loaded()?;
    let elapsed = start.elapsed();

    println!("  done ({:.1}s)", elapsed.as_secs_f64());
    if let Some(cb) = callback {
        cb(ProgressEvent::LoadComplete {
            model_name,
            duration_secs: elapsed.as_secs_f64(),
        });
    }
    Ok(stt)
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
    let model_name = "TTS (Kokoro-82M)".to_owned();
    print!("  Loading {model_name}...");
    if let Some(cb) = callback {
        cb(ProgressEvent::LoadStarted {
            model_name: model_name.clone(),
        });
    }

    let start = Instant::now();
    let tts = KokoroTts::new(&config.tts)?;
    let elapsed = start.elapsed();

    println!("  done ({:.1}s)", elapsed.as_secs_f64());
    if let Some(cb) = callback {
        cb(ProgressEvent::LoadComplete {
            model_name,
            duration_secs: elapsed.as_secs_f64(),
        });
    }
    Ok(tts)
}
