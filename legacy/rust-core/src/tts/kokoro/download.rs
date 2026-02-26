//! Model asset download from HuggingFace Hub.

use crate::error::{Result, SpeechError};
use crate::models::ModelManager;
use crate::progress::ProgressCallback;
use std::path::PathBuf;
use tracing::info;

/// HuggingFace repo for Kokoro-82M ONNX models.
pub const KOKORO_REPO_ID: &str = "onnx-community/Kokoro-82M-v1.0-ONNX";

/// Bundled custom Fae voice style (generated from `assets/voices/fae.wav` via KVoiceWalk).
///
/// This is a raw f32 tensor of shape `[510, 1, 256]` — the standard Kokoro voice format.
static BUNDLED_FAE_VOICE: &[u8] = include_bytes!("../../../assets/voices/fae.bin");

/// Resolve voice aliases to their underlying Kokoro voice style name.
///
/// The `"fae"` alias returns `"bf_fae"` indicating a British female voice.
/// The actual voice data is bundled in the binary (see [`materialize_bundled_voice`]).
pub fn resolve_voice_alias(voice: &str) -> &str {
    match voice {
        "fae" => "bf_fae",
        other => other,
    }
}

/// Materialize the bundled Fae voice to a cache file and return its path.
///
/// Writes the embedded voice data to `<cache_dir>/voices/fae.bin` if it
/// doesn't already exist (or if the size doesn't match). Returns the path
/// for loading by the Kokoro engine.
///
/// # Errors
///
/// Returns an error if the cache directory cannot be created or the file cannot be written.
pub fn materialize_bundled_voice() -> Result<PathBuf> {
    let cache_dir = crate::fae_dirs::cache_dir();
    let voice_dir = cache_dir.join("voices");
    let voice_path = voice_dir.join("fae.bin");

    // Skip write if already materialized with correct size.
    if voice_path.is_file()
        && std::fs::metadata(&voice_path)
            .is_ok_and(|meta| meta.len() == BUNDLED_FAE_VOICE.len() as u64)
    {
        info!("using cached bundled voice: {}", voice_path.display());
        return Ok(voice_path);
    }

    std::fs::create_dir_all(&voice_dir).map_err(|e| {
        SpeechError::Tts(format!(
            "failed to create voice cache dir {}: {e}",
            voice_dir.display()
        ))
    })?;

    std::fs::write(&voice_path, BUNDLED_FAE_VOICE).map_err(|e| {
        SpeechError::Tts(format!(
            "failed to write bundled voice to {}: {e}",
            voice_path.display()
        ))
    })?;

    info!(
        "materialized bundled fae voice ({} bytes) to {}",
        BUNDLED_FAE_VOICE.len(),
        voice_path.display()
    );
    Ok(voice_path)
}

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
/// Returns `None` for bundled voices (`"fae"`) or custom absolute `.bin` paths.
/// For HuggingFace-hosted voices, returns the repo-relative filename.
pub fn voice_filename(voice: &str) -> Option<String> {
    // Bundled voice — no HF download needed.
    if voice == "fae" {
        return None;
    }

    let resolved = resolve_voice_alias(voice);
    if std::path::Path::new(resolved)
        .extension()
        .is_some_and(|ext| ext == "bin")
        && std::path::Path::new(resolved).is_absolute()
    {
        None
    } else {
        Some(format!("voices/{resolved}.bin"))
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

    let voice_bin = if voice == "fae" {
        materialize_bundled_voice()?
    } else if let Some(vf) = voice_filename(voice) {
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
    let voice_bin = if voice == "fae" {
        materialize_bundled_voice()?
    } else {
        let resolved_voice = resolve_voice_alias(voice);
        if std::path::Path::new(resolved_voice)
            .extension()
            .is_some_and(|ext| ext == "bin")
            && std::path::Path::new(resolved_voice).is_absolute()
        {
            PathBuf::from(resolved_voice)
        } else {
            let voice_file = format!("voices/{resolved_voice}.bin");
            info!("ensuring voice: {voice_file}");
            repo.get(&voice_file)
                .map_err(|e| SpeechError::Model(format!("failed to download {voice_file}: {e}")))?
        }
    };

    Ok(KokoroPaths {
        model_onnx,
        tokenizer_json,
        voice_bin,
    })
}
