//! Startup initialization: downloads models with progress bars and eagerly loads them.
//!
//! Call [`initialize_models`] at startup to pre-download and pre-load all ML models
//! so the pipeline is ready to run without mid-conversation delays.

use crate::config::{LlmBackend, SpeechConfig};
use crate::error::{Result, SpeechError};
use crate::llm::LocalLlm;
use crate::models::ModelManager;
use crate::stt::ParakeetStt;
use crate::tts::ChatterboxTts;
use std::time::Instant;

/// Pre-loaded model instances ready for the pipeline.
pub struct InitializedModels {
    /// Parakeet TDT speech-to-text engine.
    pub stt: ParakeetStt,
    /// Local LLM engine (only loaded for local backend).
    pub llm: Option<LocalLlm>,
    /// Chatterbox TTS engine.
    pub tts: ChatterboxTts,
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
/// When the LLM backend is set to API, the local LLM model download and
/// loading is skipped entirely.
///
/// # Errors
///
/// Returns an error if any download or model load fails.
pub async fn initialize_models(config: &SpeechConfig) -> Result<InitializedModels> {
    let model_manager = ModelManager::new(&config.models)?;
    let use_local_llm = config.llm.backend == LlmBackend::Local;

    // --- Phase 1: Download all model files ---
    println!("\nChecking models...");

    // STT files
    for filename in STT_FILES {
        model_manager.download_with_progress(&config.stt.model_id, filename)?;
    }

    // LLM: mistralrs handles its own HF downloads, so we skip manual download
    // for the local backend. Only STT needs explicit pre-download.

    // TTS: Chatterbox models are downloaded by the engine via hf-hub on load.

    // --- Phase 2: Load models ---
    println!("\nLoading models...");

    let stt = load_stt(config)?;
    let llm = if use_local_llm {
        Some(load_llm(config).await?)
    } else {
        println!(
            "  LLM: using API backend ({} @ {})",
            config.llm.api_model, config.llm.api_url
        );
        None
    };
    let tts = load_tts(config)?;

    Ok(InitializedModels { stt, llm, tts })
}

/// Load STT with a status message.
fn load_stt(config: &SpeechConfig) -> Result<ParakeetStt> {
    print!("  Loading STT (Parakeet TDT)...");
    let start = Instant::now();
    let mut stt = ParakeetStt::new(&config.stt, &config.models)?;
    stt.ensure_loaded()?;
    let elapsed = start.elapsed();
    println!("  done ({:.1}s)", elapsed.as_secs_f64());
    Ok(stt)
}

/// Load LLM with a status message.
async fn load_llm(config: &SpeechConfig) -> Result<LocalLlm> {
    print!(
        "  Loading LLM ({} / {})...",
        config.llm.model_id, config.llm.gguf_file
    );
    let start = Instant::now();
    let llm = LocalLlm::new(&config.llm).await?;
    let elapsed = start.elapsed();
    println!("  done ({:.1}s)", elapsed.as_secs_f64());
    Ok(llm)
}

/// Load TTS with a status message.
///
/// When `voice_reference` is empty, downloads and uses a default voice profile.
/// When set, encodes a custom voice profile from the WAV file.
fn load_tts(config: &SpeechConfig) -> Result<ChatterboxTts> {
    print!("  Loading TTS (Chatterbox Turbo)...");
    let start = Instant::now();

    let tts = match crate::tts::resolve_voice_wav(&config.tts) {
        Some(voice_wav) => {
            if !voice_wav.exists() {
                return Err(SpeechError::Tts(format!(
                    "voice reference WAV not found: {}",
                    voice_wav.display()
                )));
            }
            ChatterboxTts::new(&config.tts, &voice_wav)?
        }
        None => ChatterboxTts::new_with_default_voice(&config.tts)?,
    };

    let elapsed = start.elapsed();
    println!("  done ({:.1}s)", elapsed.as_secs_f64());
    Ok(tts)
}
