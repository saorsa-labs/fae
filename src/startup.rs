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
use crate::models::ModelManager;
use crate::progress::{ProgressCallback, ProgressEvent};
use crate::stt::ParakeetStt;
use crate::tts::KokoroTts;
use std::time::Instant;

/// Pre-loaded model instances ready for the pipeline.
pub struct InitializedModels {
    /// Parakeet TDT speech-to-text engine.
    pub stt: ParakeetStt,
    /// Local LLM engine (only loaded for local backend).
    pub llm: Option<LocalLlm>,
    /// Kokoro TTS engine.
    pub tts: KokoroTts,
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

    Ok(InitializedModels { stt, llm, tts })
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
