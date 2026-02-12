//! Model asset download from HuggingFace Hub.

use crate::error::{Result, SpeechError};
use crate::models::ModelManager;
use crate::progress::ProgressCallback;
use std::path::PathBuf;
use tracing::info;

/// HuggingFace repo for Kokoro-82M ONNX models.
pub const KOKORO_REPO_ID: &str = "onnx-community/Kokoro-82M-v1.0-ONNX";

/// Paths to downloaded Kokoro assets.
pub struct KokoroPaths {
    /// Path to the ONNX model file (inside `onnx/` subfolder).
    pub model_onnx: PathBuf,
    /// Path to `tokenizer.json`.
    pub tokenizer_json: PathBuf,
    /// Path to the voice `.bin` file.
    pub voice_bin: PathBuf,
}

/// Map a user-facing variant name to the ONNX filename inside the `onnx/` subfolder.
pub fn model_filename(variant: &str) -> &'static str {
    match variant {
        "fp32" => "onnx/model.onnx",
        "fp16" => "onnx/model_fp16.onnx",
        "q8" | "quantized" => "onnx/model_quantized.onnx",
        "q8f16" => "onnx/model_q8f16.onnx",
        "q4" => "onnx/model_q4.onnx",
        "q4f16" => "onnx/model_q4f16.onnx",
        _ => {
            info!("unknown model variant '{variant}', falling back to q8");
            "onnx/model_quantized.onnx"
        }
    }
}

/// Get the voice filename for a given voice name.
///
/// Returns `None` if the voice is a custom absolute path to a `.bin` file.
pub fn voice_filename(voice: &str) -> Option<String> {
    if std::path::Path::new(voice)
        .extension()
        .is_some_and(|ext| ext == "bin")
        && std::path::Path::new(voice).is_absolute()
    {
        None
    } else {
        Some(format!("voices/{voice}.bin"))
    }
}

/// Download all Kokoro assets with progress callbacks via [`ModelManager`].
///
/// Each file gets individual progress events through the callback,
/// making downloads visible in the GUI.
///
/// # Errors
///
/// Returns an error if any download fails.
pub fn download_kokoro_assets_with_progress(
    variant: &str,
    voice: &str,
    model_manager: &ModelManager,
    callback: Option<&ProgressCallback>,
) -> Result<KokoroPaths> {
    let model_file = model_filename(variant);
    let model_onnx = model_manager.download_with_progress(KOKORO_REPO_ID, model_file, callback)?;

    let tokenizer_json =
        model_manager.download_with_progress(KOKORO_REPO_ID, "tokenizer.json", callback)?;

    let voice_bin = if let Some(vf) = voice_filename(voice) {
        model_manager.download_with_progress(KOKORO_REPO_ID, &vf, callback)?
    } else {
        PathBuf::from(voice)
    };

    Ok(KokoroPaths {
        model_onnx,
        tokenizer_json,
        voice_bin,
    })
}

/// Download (or verify cache of) all Kokoro assets from HuggingFace Hub.
///
/// `voice` is either a built-in voice name like `"bf_emma"` or an absolute path
/// to a custom `.bin` file. When it's a name, the corresponding file is
/// downloaded from the `voices/` subfolder of the HF repo.
///
/// # Errors
///
/// Returns an error if any download fails.
pub fn download_kokoro_assets(variant: &str, voice: &str) -> Result<KokoroPaths> {
    let api = hf_hub::api::sync::Api::new()
        .map_err(|e| SpeechError::Model(format!("HF Hub API init failed: {e}")))?;
    let repo = api.model(KOKORO_REPO_ID.to_owned());

    // Model ONNX
    let model_file = model_filename(variant);
    info!("ensuring Kokoro model: {KOKORO_REPO_ID}/{model_file}");
    let model_onnx = repo
        .get(model_file)
        .map_err(|e| SpeechError::Model(format!("failed to download {model_file}: {e}")))?;

    // Tokenizer
    info!("ensuring tokenizer.json");
    let tokenizer_json = repo
        .get("tokenizer.json")
        .map_err(|e| SpeechError::Model(format!("failed to download tokenizer.json: {e}")))?;

    // Voice style tensor
    let voice_bin = if std::path::Path::new(voice)
        .extension()
        .is_some_and(|ext| ext == "bin")
        && std::path::Path::new(voice).is_absolute()
    {
        // User provided an absolute path to a custom .bin
        PathBuf::from(voice)
    } else {
        let voice_file = format!("voices/{voice}.bin");
        info!("ensuring voice: {voice_file}");
        repo.get(&voice_file)
            .map_err(|e| SpeechError::Model(format!("failed to download {voice_file}: {e}")))?
    };

    Ok(KokoroPaths {
        model_onnx,
        tokenizer_json,
        voice_bin,
    })
}
