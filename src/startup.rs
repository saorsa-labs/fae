//! Startup initialization: downloads models with progress bars and eagerly loads them.
//!
//! Call [`initialize_models`] at startup to pre-download and pre-load all ML models
//! so the pipeline is ready to run without mid-conversation delays.
//!
//! For GUI consumers, use [`initialize_models_with_progress`] which accepts a
//! [`ProgressCallback`] for structured progress events.

use crate::config::{MemoryConfig, SpeechConfig, TtsBackend};
use crate::error::{Result, SpeechError};
use crate::llm::LocalLlm;
use crate::models::ModelManager;
use crate::progress::{DownloadFile, DownloadPlan, ProgressCallback, ProgressEvent};
use crate::stt::ParakeetStt;
use crate::tts::KokoroTts;
use std::path::Path;
use std::time::Instant;
use tracing::{info, warn};

/// Pre-loaded model instances ready for the pipeline.
pub struct InitializedModels {
    /// Parakeet TDT speech-to-text engine.
    pub stt: ParakeetStt,
    /// Optional preloaded local LLM for local brain mode or local fallback.
    pub llm: Option<LocalLlm>,
    /// Kokoro TTS engine (None if using Fish Speech or other backend).
    pub tts: Option<KokoroTts>,
}

/// STT model files to pre-download.
const STT_FILES: &[&str] = &[
    "encoder-model.onnx",
    "encoder-model.onnx.data",
    "decoder_joint-model.onnx",
    "vocab.txt",
];

/// LLM tokenizer files to pre-download (from the tokenizer repo).
const LLM_TOKENIZER_FILES: &[&str] = &["tokenizer.json", "tokenizer_config.json"];

fn should_preload_local_llm(_config: &SpeechConfig) -> bool {
    true
}

/// Build a download plan listing all files needed for startup.
///
/// Checks cache status and queries file sizes for each file.
/// The plan is used by the GUI to show total download size before starting.
pub fn build_download_plan(config: &SpeechConfig) -> DownloadPlan {
    let needs_local_model = should_preload_local_llm(config);

    let mut files = Vec::new();

    // STT files
    let stt_sizes = ModelManager::query_file_sizes(&config.stt.model_id, STT_FILES);
    for (filename, size_bytes) in stt_sizes {
        files.push(DownloadFile {
            repo_id: config.stt.model_id.clone(),
            filename: filename.clone(),
            size_bytes,
            cached: ModelManager::is_file_cached(&config.stt.model_id, &filename),
        });
    }

    // LLM: either GGUF pre-download or vision model size estimate.
    let vision_mode = config.llm.enable_vision && config.llm.gguf_file.is_empty();
    if needs_local_model && vision_mode {
        // Vision models are downloaded by VisionModelBuilder at load time.
        // Include an estimated download size so disk space checks and progress
        // UI account for the multi-GB full-precision weights from HuggingFace.
        let estimated_bytes: u64 = if config.llm.model_id.contains("8B") {
            16_000_000_000 // ~16 GB bf16 weights for VL-8B
        } else {
            8_000_000_000 // ~8 GB bf16 weights for VL-4B
        };
        // Check if the HF cache already has the model repo.
        // If any file (like config.json) is cached, the model was likely downloaded.
        let hf_cached = hf_hub::Cache::default()
            .repo(hf_hub::Repo::model(config.llm.model_id.clone()))
            .get("config.json")
            .is_some();

        files.push(DownloadFile {
            repo_id: config.llm.model_id.clone(),
            filename: "(vision model weights — downloaded at load time)".to_owned(),
            size_bytes: Some(estimated_bytes),
            cached: hf_cached,
        });
    } else if needs_local_model {
        let llm_sizes =
            ModelManager::query_file_sizes(&config.llm.model_id, &[config.llm.gguf_file.as_str()]);
        for (filename, size_bytes) in llm_sizes {
            files.push(DownloadFile {
                repo_id: config.llm.model_id.clone(),
                filename: filename.clone(),
                size_bytes,
                cached: ModelManager::is_file_cached(&config.llm.model_id, &filename),
            });
        }

        // LLM tokenizer
        if !config.llm.tokenizer_id.is_empty() {
            let tok_sizes =
                ModelManager::query_file_sizes(&config.llm.tokenizer_id, LLM_TOKENIZER_FILES);
            for (filename, size_bytes) in tok_sizes {
                files.push(DownloadFile {
                    repo_id: config.llm.tokenizer_id.clone(),
                    filename: filename.clone(),
                    size_bytes,
                    cached: ModelManager::is_file_cached(&config.llm.tokenizer_id, &filename),
                });
            }
        }
    }

    // TTS (Kokoro)
    if matches!(config.tts.backend, TtsBackend::Kokoro) {
        let tts_repo = crate::tts::kokoro::download::KOKORO_REPO_ID;
        let model_file = crate::tts::kokoro::download::model_filename(&config.tts.model_variant);
        let voice_file = crate::tts::kokoro::download::voice_filename(&config.tts.voice);

        let mut tts_filenames: Vec<&str> = vec![model_file, "tokenizer.json"];
        if let Some(ref vf) = voice_file {
            tts_filenames.push(vf.as_str());
        }

        let tts_sizes = ModelManager::query_file_sizes(tts_repo, &tts_filenames);
        for (filename, size_bytes) in tts_sizes {
            files.push(DownloadFile {
                repo_id: tts_repo.to_owned(),
                filename: filename.clone(),
                size_bytes,
                cached: ModelManager::is_file_cached(tts_repo, &filename),
            });
        }
    }

    DownloadPlan { files }
}

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
    if let Err(e) = crate::personality::ensure_prompt_assets() {
        tracing::warn!("failed to ensure prompt assets: {e}");
    }

    // Point hf-hub at our sandbox-safe cache before any model downloads.
    crate::fae_dirs::ensure_hf_home();

    let mut resolved_config = config.clone();
    // Apply RAM-based model selection for managed default models.
    // This upgrades default Qwen3-4B to Qwen3-VL based on available memory,
    // but never overwrites user-customised model_id values.
    crate::config::apply_ram_model_selection(&mut resolved_config.llm);

    let config = &resolved_config;

    let model_manager = ModelManager::new(&config.models)?;
    let use_local_llm = should_preload_local_llm(config);

    // --- Phase 0: Build download plan and check disk space ---
    let plan = build_download_plan(config);

    // Verify we have enough disk space before starting downloads.
    if plan.needs_download() {
        let space = check_disk_space(plan.download_bytes())?;
        if !space.has_enough_space() {
            return Err(SpeechError::Model(format!(
                "Not enough disk space. Need {:.1} GB, have {:.1} GB free.",
                space.required_bytes as f64 / 1_000_000_000.0,
                space.free_bytes as f64 / 1_000_000_000.0,
            )));
        }
    }

    if let Some(cb) = callback {
        cb(ProgressEvent::DownloadPlanReady { plan: plan.clone() });
    }
    if plan.needs_download() {
        info!(
            "download plan: {} files to download ({} bytes), {} cached",
            plan.files_to_download(),
            plan.download_bytes(),
            plan.total_files() - plan.files_to_download()
        );
    } else {
        info!("all {} model files cached", plan.total_files());
    }

    // --- Phase 1: Download all model files ---
    // Aggregate progress tracking
    let files_total = plan.files_to_download();
    let total_download_bytes = plan.download_bytes();
    let mut files_complete: usize = 0;

    println!("\nChecking models...");

    // STT files
    for filename in STT_FILES {
        let was_cached = ModelManager::is_file_cached(&config.stt.model_id, filename);
        model_manager.download_with_progress(&config.stt.model_id, filename, callback)?;
        if !was_cached {
            files_complete += 1;
            emit_aggregate(callback, files_complete, files_total, total_download_bytes);
        }
    }

    // LLM: Pre-download GGUF and tokenizer so mistralrs finds them in the
    // shared hf-hub cache. This gives us progress visibility instead of a
    // frozen "Loading..." screen.
    //
    // Vision models skip this — VisionModelBuilder downloads HF weights
    // internally at load time.
    let vision_download_mode = config.llm.enable_vision && config.llm.gguf_file.is_empty();
    if use_local_llm && !vision_download_mode {
        let was_cached = ModelManager::is_file_cached(&config.llm.model_id, &config.llm.gguf_file);
        model_manager.download_with_progress(
            &config.llm.model_id,
            &config.llm.gguf_file,
            callback,
        )?;
        if !was_cached {
            files_complete += 1;
            emit_aggregate(callback, files_complete, files_total, total_download_bytes);
        }

        // Tokenizer files (from separate repo if configured)
        if !config.llm.tokenizer_id.is_empty() {
            for filename in LLM_TOKENIZER_FILES {
                let was_cached = ModelManager::is_file_cached(&config.llm.tokenizer_id, filename);
                model_manager.download_with_progress(
                    &config.llm.tokenizer_id,
                    filename,
                    callback,
                )?;
                if !was_cached {
                    files_complete += 1;
                    emit_aggregate(callback, files_complete, files_total, total_download_bytes);
                }
            }
        }
    } else if use_local_llm && vision_download_mode {
        info!(
            "vision model {} — weights will be downloaded by VisionModelBuilder at load time",
            config.llm.model_id
        );
    }

    // TTS: Pre-download Kokoro assets with progress callbacks.
    let kokoro_paths = if matches!(config.tts.backend, TtsBackend::Kokoro) {
        Some(
            crate::tts::kokoro::download::download_kokoro_assets_with_progress(
                &config.tts.model_variant,
                &config.tts.voice,
                &model_manager,
                callback,
            )?,
        )
    } else {
        None
    };

    // --- Phase 2: Load models ---
    println!("\nLoading models...");

    let stt = load_stt(config, callback)?;
    let llm = if use_local_llm {
        println!("  LLM brain: local (embedded)");
        Some(load_llm(config, callback).await?)
    } else {
        None
    };
    let tts = if let Some(paths) = kokoro_paths {
        Some(load_tts_from_paths(paths, config, callback)?)
    } else if matches!(config.tts.backend, TtsBackend::Kokoro) {
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

    Ok(InitializedModels { stt, llm, tts })
}

/// Emit an aggregate progress event after a file download completes.
fn emit_aggregate(
    callback: Option<&ProgressCallback>,
    files_complete: usize,
    files_total: usize,
    total_bytes: u64,
) {
    if let Some(cb) = callback {
        cb(ProgressEvent::AggregateProgress {
            // After a file completes, we report aggregate bytes equal to
            // the proportion of files complete (approximation — exact byte
            // tracking would require wrapping every download_with_progress call).
            bytes_downloaded: if files_total > 0 {
                total_bytes * files_complete as u64 / files_total as u64
            } else {
                0
            },
            total_bytes,
            files_complete,
            files_total,
        });
    }
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
    let model_name = if config.llm.enable_vision && config.llm.gguf_file.is_empty() {
        format!("LLM ({} / vision+ISQ)", config.llm.model_id)
    } else {
        format!("LLM ({} / {})", config.llm.model_id, config.llm.gguf_file)
    };
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

/// Load TTS from pre-downloaded paths (skips download phase).
fn load_tts_from_paths(
    paths: crate::tts::kokoro::download::KokoroPaths,
    config: &SpeechConfig,
    callback: Option<&ProgressCallback>,
) -> Result<KokoroTts> {
    load_model_with_progress("TTS (Kokoro-82M)".to_owned(), callback, || {
        KokoroTts::from_paths(paths, &config.tts)
    })
}

// ── Disk space check ────────────────────────────────────────────────────────

/// Extra headroom required beyond the download size (500 MB).
const DISK_SPACE_HEADROOM: u64 = 500 * 1024 * 1024;

/// Result of a disk space check.
pub struct DiskSpaceCheck {
    /// Free space available on the filesystem in bytes.
    pub free_bytes: u64,
    /// Required space for pending downloads in bytes.
    pub required_bytes: u64,
}

impl DiskSpaceCheck {
    /// Returns `true` if there is enough free space (with 500 MB headroom).
    pub fn has_enough_space(&self) -> bool {
        self.free_bytes >= self.required_bytes.saturating_add(DISK_SPACE_HEADROOM)
    }
}

/// Query available disk space at `path` using platform-specific APIs.
///
/// On Unix, uses `statvfs` to get the free blocks available to unprivileged
/// users. On non-Unix platforms, returns `u64::MAX` (effectively skipping
/// the check).
///
/// # Errors
///
/// Returns an error if the filesystem stats cannot be retrieved.
#[cfg(unix)]
pub fn available_disk_space(path: &Path) -> Result<u64> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let c_path = CString::new(path.as_os_str().as_bytes())
        .map_err(|e| SpeechError::Model(format!("invalid path for statvfs: {e}")))?;

    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    let ret = unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) };

    if ret != 0 {
        return Err(SpeechError::Model(format!(
            "failed to check disk space at {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        )));
    }

    // f_bavail = blocks available to unprivileged users.
    // f_frsize = fundamental file system block size.
    // The `as u64` casts are needed for macOS where these are i32/i64; on Linux
    // they are already u64 (clippy::unnecessary_cast).  Using a let-binding with
    // explicit type annotation avoids the platform-specific lint.
    let bavail: u64 = stat.f_bavail as _;
    let frsize: u64 = stat.f_frsize as _;
    Ok(bavail.wrapping_mul(frsize))
}

/// Fallback for non-Unix platforms — returns `u64::MAX` (skip the check).
#[cfg(not(unix))]
pub fn available_disk_space(_path: &Path) -> Result<u64> {
    Ok(u64::MAX)
}

/// Check that enough disk space is available for pending model downloads.
///
/// Uses the hf-hub default cache directory to determine the target filesystem.
/// Ensures `required_bytes` plus 500 MB headroom are available.
///
/// # Errors
///
/// Returns an error if the cache directory cannot be created or the
/// filesystem stats cannot be retrieved.
pub fn check_disk_space(required_bytes: u64) -> Result<DiskSpaceCheck> {
    let cache_dir = hf_hub::Cache::default().path().to_path_buf();
    std::fs::create_dir_all(&cache_dir)?;
    let free_bytes = available_disk_space(&cache_dir)?;
    Ok(DiskSpaceCheck {
        free_bytes,
        required_bytes,
    })
}

// ── Pre-flight check ────────────────────────────────────────────────────────

/// Pre-flight check result: everything the GUI needs to show the confirmation
/// dialog before starting downloads.
pub struct PreFlightResult {
    /// Full download plan with per-file details.
    pub plan: DownloadPlan,
    /// Free disk space in bytes.
    pub free_space: u64,
    /// Whether any files need downloading (false = all cached).
    pub needs_download: bool,
}

/// Run a pre-flight check: build the download plan and check disk space
/// without starting any downloads.
///
/// The GUI calls this on a background thread (file size queries are blocking
/// HTTP HEAD requests) to populate the pre-flight confirmation dialog.
///
/// # Errors
///
/// Returns an error if disk space cannot be determined.
pub fn preflight_check(config: &SpeechConfig) -> Result<PreFlightResult> {
    let plan = build_download_plan(config);
    let needs_download = plan.needs_download();

    let free_space = if needs_download {
        let space = check_disk_space(plan.download_bytes())?;
        if !space.has_enough_space() {
            return Err(SpeechError::Model(format!(
                "Not enough disk space. Need {:.1} GB, have {:.1} GB free.",
                space.required_bytes as f64 / 1_000_000_000.0,
                space.free_bytes as f64 / 1_000_000_000.0,
            )));
        }
        space.free_bytes
    } else {
        // All cached — still report free space for display.
        check_disk_space(0)
            .map(|s| s.free_bytes)
            .unwrap_or(u64::MAX)
    };

    Ok(PreFlightResult {
        plan,
        free_space,
        needs_download,
    })
}

/// Result of a startup update check that may include a staged download.
pub struct UpdateCheckResult {
    /// The release that was found (if any).
    pub release: Option<crate::update::Release>,
    /// A staged binary ready to install (pre-existing or freshly downloaded).
    pub staged: Option<crate::update::StagedUpdate>,
}

/// Clean up leftover staging files from a previous successful update.
///
/// Call this early at startup. Also clears the `staged_update` record from the
/// persistent state if the staged version matches the running version (meaning
/// the update was successfully installed).
pub fn cleanup_after_successful_update() {
    let mut state = crate::update::UpdateState::load();

    // If the staged version matches the running version, the update succeeded.
    let update_completed = state
        .staged_update
        .as_ref()
        .is_some_and(|s| s.version == env!("CARGO_PKG_VERSION"));

    if update_completed || state.staged_update.is_some() {
        state.clear_staged_update();
        let _ = state.save();
    }

    // Always clean up staging directory (leftover files from any previous attempt).
    if let Err(e) = crate::update::cleanup_staged_update() {
        tracing::debug!("staging cleanup: {e}");
    }

    // Also clean up old backup from in-place updates.
    if let Err(e) = crate::update::cleanup_old_backup() {
        tracing::debug!("old backup cleanup: {e}");
    }
}

/// Run a background update check for Fae.
///
/// Respects the user's auto-update preference and only checks if the last
/// check was more than `stale_hours` hours ago. Returns `Some(release)` if
/// a newer version is available, `None` otherwise.
///
/// When a newer release is found, the binary is also staged (downloaded in
/// the background) so it is ready to install instantly when the user clicks
/// "Install & Relaunch".
///
/// This function is safe to call from any async context — it spawns the
/// HTTP request on a blocking thread.
pub async fn check_for_fae_update(stale_hours: u64) -> Option<crate::update::Release> {
    let result = check_for_fae_update_with_staging(stale_hours).await;
    result.release
}

/// Run a background update check and stage the download if a new version is found.
///
/// Returns both the release info and any staged binary path. The staged binary
/// can be installed immediately via [`crate::update::install_via_helper`].
pub async fn check_for_fae_update_with_staging(stale_hours: u64) -> UpdateCheckResult {
    let state = crate::update::UpdateState::load();

    // Check for an already-staged update from a previous check.
    if let Some(ref staged) = state.staged_update
        && std::path::Path::new(&staged.staged_path).exists()
    {
        info!(
            "found already-staged update v{} at {}",
            staged.version,
            staged.staged_path.display()
        );
        // Synthesise a release from the staged info so the GUI can display it.
        let release = crate::update::Release {
            tag_name: format!("v{}", staged.version),
            version: staged.version.clone(),
            download_url: staged.download_url.clone(),
            asset_name: staged.asset_name.clone(),
            checksums_url: staged.checksums_url.clone(),
            checksums_signature_url: staged.checksums_signature_url.clone(),
            release_notes: String::new(),
            published_at: String::new(),
            asset_size: 0,
        };
        return UpdateCheckResult {
            release: Some(release),
            staged: Some(staged.clone()),
        };
    }

    if !state.check_is_stale(stale_hours) {
        return UpdateCheckResult {
            release: None,
            staged: None,
        };
    }

    if state.auto_update == crate::update::AutoUpdatePreference::Never {
        return UpdateCheckResult {
            release: None,
            staged: None,
        };
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
            return UpdateCheckResult {
                release: None,
                staged: None,
            };
        }
        Err(e) => {
            tracing::debug!("update check task failed: {e}");
            return UpdateCheckResult {
                release: None,
                staged: None,
            };
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

    let mut staged = None;

    // Stage the download in the background if we have a release to offer.
    if should_return_release
        && let Some(ref rel) = release
        && !rel.download_url.is_empty()
    {
        let rel = rel.clone();
        let stage_result =
            tokio::task::spawn_blocking(move || crate::update::stage_update(&rel)).await;

        match stage_result {
            Ok(crate::update::StageResult::Staged(s)) => {
                info!(
                    "update v{} staged at {}",
                    s.version,
                    s.staged_path.display()
                );
                new_state.set_staged_update(s.clone());
                staged = Some(s);
            }
            Ok(crate::update::StageResult::AlreadyStaged(s)) => {
                info!("update v{} already staged", s.version);
                new_state.set_staged_update(s.clone());
                staged = Some(s);
            }
            Ok(crate::update::StageResult::Failed(e)) => {
                warn!("failed to stage update: {e}");
            }
            Err(e) => {
                warn!("stage task panicked: {e}");
            }
        }
    }

    // Persist state update.
    let _ = tokio::task::spawn_blocking(move || new_state.save()).await;

    // Return release if available and not dismissed.
    if should_return_release && let Some(rel) = release {
        info!("update available: Fae v{}", rel.version);
        return UpdateCheckResult {
            release: Some(rel),
            staged,
        };
    }

    UpdateCheckResult {
        release: None,
        staged: None,
    }
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
    let config = load_scheduler_config_or_default();
    start_scheduler_with_config(&config)
}

fn load_scheduler_config_or_default() -> SpeechConfig {
    let path = SpeechConfig::default_config_path();
    if path.exists() {
        match SpeechConfig::from_file(&path) {
            Ok(config) => config,
            Err(e) => {
                warn!(
                    "failed to read scheduler config from {}: {e}; using defaults",
                    path.display()
                );
                SpeechConfig::default()
            }
        }
    } else {
        SpeechConfig::default()
    }
}

/// Start the background scheduler using explicit memory settings.
///
/// This binds memory maintenance tasks to the active configured memory root
/// and retention policy while leaving other built-in tasks unchanged.
pub fn start_scheduler_with_memory(
    memory: &MemoryConfig,
) -> (
    tokio::task::JoinHandle<()>,
    tokio::sync::mpsc::UnboundedReceiver<crate::scheduler::tasks::TaskResult>,
) {
    let mut config = load_scheduler_config_or_default();
    config.memory = memory.clone();
    start_scheduler_with_config(&config)
}

/// Start the background scheduler using explicit runtime configuration.
///
/// Scheduled conversations use this config directly instead of process defaults,
/// so model settings stay aligned with the active application config.
pub fn start_scheduler_with_config(
    config: &SpeechConfig,
) -> (
    tokio::task::JoinHandle<()>,
    tokio::sync::mpsc::UnboundedReceiver<crate::scheduler::tasks::TaskResult>,
) {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();

    // Create channel for conversation requests from scheduled tasks
    let (conversation_req_tx, conversation_req_rx) = tokio::sync::mpsc::unbounded_channel();

    // Create task executor bridge
    let bridge = crate::scheduler::executor_bridge::TaskExecutorBridge::new(conversation_req_tx);

    let mut scheduler = crate::scheduler::runner::Scheduler::new(tx);
    let authority_root = crate::fae_dirs::config_dir();
    let lease = crate::scheduler::authority::LeaderLease::new(
        format!("fae-{}-{}", std::process::id(), uuid::Uuid::new_v4()),
        std::process::id(),
        authority_root.join("scheduler.leader.lock"),
        crate::scheduler::authority::LeaderLeaseConfig::default(),
    );
    let run_key_ledger = crate::scheduler::authority::RunKeyLedger::new(
        authority_root.join("scheduler.run_keys.jsonl"),
    );
    scheduler = scheduler
        .with_leader_lease(lease)
        .with_run_key_ledger(run_key_ledger);
    scheduler.with_update_checks();
    scheduler.with_memory_maintenance();
    let memory_root = config.memory.root_dir.clone();
    let retention_days = config.memory.retention_days;
    let backup_keep_count = config.memory.backup_keep_count;
    let scheduler_config = config.clone();

    // Wrap the bridge executor to also handle built-in tasks
    let bridge_executor = bridge.into_executor();
    scheduler = scheduler.with_executor(Box::new(move |task| {
        // User tasks with ConversationTrigger payloads go through bridge
        if task.kind == crate::scheduler::tasks::TaskKind::User {
            return bridge_executor(task);
        }

        // Built-in tasks use the existing executor
        execute_scheduler_task(task, &memory_root, retention_days, backup_keep_count)
    }));

    info!(
        "starting background scheduler with {} tasks",
        scheduler.tasks().len()
    );
    let handle = scheduler.run();

    // Spawn background task to handle conversation requests
    tokio::spawn(async move {
        handle_conversation_requests(conversation_req_rx, scheduler_config).await;
    });

    (handle, rx)
}

/// Background task to handle conversation requests from the scheduler.
///
/// This handler receives conversation requests from scheduled tasks and
/// executes them using a lightweight agent session (not the full STT→TTS pipeline).
async fn handle_conversation_requests(
    mut rx: tokio::sync::mpsc::UnboundedReceiver<crate::pipeline::messages::ConversationRequest>,
    config: SpeechConfig,
) {
    use crate::pipeline::messages::ConversationResponse;
    use tokio::time::{Duration, timeout};
    use tracing::{debug, error, info};

    while let Some(request) = rx.recv().await {
        info!(
            "Handling conversation request for task {}: {}",
            request.task_id, request.prompt
        );

        // Execute conversation with timeout (use request.timeout_secs or default to 300)
        let timeout_secs = request.timeout_secs.unwrap_or(300);
        let conversation_timeout = Duration::from_secs(timeout_secs);
        let result = timeout(
            conversation_timeout,
            execute_scheduled_conversation(&config, &request),
        )
        .await;

        let response = match result {
            Ok(Ok(text)) => {
                debug!(
                    "Conversation completed for task {}: {}",
                    request.task_id, text
                );
                ConversationResponse::Success(text)
            }
            Ok(Err(e)) => {
                error!("Conversation failed for task {}: {e}", request.task_id);
                ConversationResponse::Error(format!("{e}"))
            }
            Err(_) => {
                error!("Conversation timed out for task {}", request.task_id);
                ConversationResponse::Timeout
            }
        };

        // Send response back to executor
        if request.response_tx.send(response).is_err() {
            error!(
                "Failed to send conversation response for task {}: receiver dropped",
                request.task_id
            );
        }
    }
}

/// Execute a scheduled conversation using the embedded local agent.
///
/// # TODO (Phase 6.2)
/// Wire to the embedded local LLM instead of external API.
async fn execute_scheduled_conversation(
    _config: &SpeechConfig,
    request: &crate::pipeline::messages::ConversationRequest,
) -> crate::error::Result<String> {
    tracing::warn!(
        "Scheduled conversation for task {} deferred: local LLM wiring pending (Phase 6.2)",
        request.task_id
    );
    Err(SpeechError::Config(
        "Scheduled conversation via embedded LLM not yet implemented (Phase 6.2)".to_owned(),
    ))
}

fn execute_scheduler_task(
    task: &crate::scheduler::ScheduledTask,
    memory_root: &Path,
    retention_days: u32,
    backup_keep_count: usize,
) -> crate::scheduler::tasks::TaskResult {
    if task.kind == crate::scheduler::tasks::TaskKind::Builtin {
        return crate::scheduler::tasks::execute_builtin_with_memory_root(
            &task.id,
            memory_root,
            retention_days,
            backup_keep_count,
        );
    }

    execute_user_scheduler_task(task)
}

fn execute_user_scheduler_task(
    task: &crate::scheduler::ScheduledTask,
) -> crate::scheduler::tasks::TaskResult {
    let title = task
        .payload
        .as_ref()
        .and_then(|payload| payload.get("title"))
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("Reminder: {}", task.name));

    let message = task
        .payload
        .as_ref()
        .and_then(|payload| payload.get("message"))
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("Scheduled task `{}` is ready.", task.name));

    crate::scheduler::tasks::TaskResult::NeedsUserAction(crate::scheduler::tasks::UserPrompt {
        title,
        message,
        actions: vec![crate::scheduler::tasks::PromptAction {
            label: "Acknowledge".to_owned(),
            id: "acknowledge_scheduler_prompt".to_owned(),
        }],
    })
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn disk_space_check_has_enough_space() {
        let check = DiskSpaceCheck {
            free_bytes: 10_000_000_000,
            required_bytes: 5_000_000_000,
        };
        assert!(check.has_enough_space());
    }

    #[test]
    fn disk_space_check_not_enough_space() {
        let check = DiskSpaceCheck {
            free_bytes: 1_000_000_000,
            required_bytes: 5_000_000_000,
        };
        assert!(!check.has_enough_space());
    }

    #[test]
    fn disk_space_check_headroom_required() {
        // Exactly the required bytes but no headroom (500 MB) — should fail.
        let check = DiskSpaceCheck {
            free_bytes: 5_000_000_000,
            required_bytes: 5_000_000_000,
        };
        assert!(!check.has_enough_space());
    }

    #[test]
    fn disk_space_check_just_enough_with_headroom() {
        let check = DiskSpaceCheck {
            free_bytes: 5_000_000_000 + DISK_SPACE_HEADROOM,
            required_bytes: 5_000_000_000,
        };
        assert!(check.has_enough_space());
    }

    #[test]
    fn available_disk_space_works_on_temp_dir() {
        let dir = std::env::temp_dir();
        let result = available_disk_space(&dir);
        assert!(result.is_ok());
        let bytes = result.unwrap_or(0);
        // Should be non-zero on any real system
        assert!(bytes > 0);
    }

    #[test]
    fn check_disk_space_returns_result() {
        let result = check_disk_space(1000);
        assert!(result.is_ok());
        let check = result.unwrap();
        assert!(check.free_bytes > 0);
        assert_eq!(check.required_bytes, 1000);
    }

    #[test]
    fn available_disk_space_fails_on_nonexistent_path() {
        let result = available_disk_space(Path::new("/nonexistent/path/that/does/not/exist"));
        assert!(result.is_err());
    }

    #[test]
    fn preflight_result_fields() {
        // Construct a PreFlightResult manually and verify field access.
        let plan = DownloadPlan {
            files: vec![
                DownloadFile {
                    repo_id: "org/model".into(),
                    filename: "model.onnx".into(),
                    size_bytes: Some(2_000_000_000),
                    cached: false,
                },
                DownloadFile {
                    repo_id: "org/model".into(),
                    filename: "vocab.txt".into(),
                    size_bytes: Some(100_000),
                    cached: true,
                },
            ],
        };
        let result = PreFlightResult {
            plan,
            free_space: 50_000_000_000,
            needs_download: true,
        };
        assert!(result.needs_download);
        assert_eq!(result.plan.files_to_download(), 1);
        assert_eq!(result.plan.total_files(), 2);
        assert_eq!(result.plan.download_bytes(), 2_000_000_000);
        assert!(result.free_space > 0);
    }

    #[test]
    fn preflight_result_all_cached() {
        let plan = DownloadPlan {
            files: vec![DownloadFile {
                repo_id: "org/model".into(),
                filename: "model.onnx".into(),
                size_bytes: Some(2_000_000_000),
                cached: true,
            }],
        };
        let result = PreFlightResult {
            plan,
            free_space: 50_000_000_000,
            needs_download: false,
        };
        assert!(!result.needs_download);
        assert_eq!(result.plan.files_to_download(), 0);
    }

    #[test]
    fn disk_space_check_zero_required() {
        // Zero required bytes should always pass.
        let check = DiskSpaceCheck {
            free_bytes: 1,
            required_bytes: 0,
        };
        // Need at least DISK_SPACE_HEADROOM even with 0 required
        assert!(!check.has_enough_space());

        let check = DiskSpaceCheck {
            free_bytes: DISK_SPACE_HEADROOM,
            required_bytes: 0,
        };
        assert!(check.has_enough_space());
    }

    #[test]
    fn disk_space_headroom_constant_is_500mb() {
        assert_eq!(DISK_SPACE_HEADROOM, 500 * 1024 * 1024);
    }

    #[test]
    fn user_scheduler_task_emits_prompt_from_payload() {
        let mut task = crate::scheduler::ScheduledTask::user_task(
            "reminder-test",
            "Reminder test",
            crate::scheduler::Schedule::Interval { secs: 3600 },
        );
        task.payload = Some(serde_json::json!({
            "title": "Stand up",
            "message": "Time to take a short break."
        }));

        let result = execute_scheduler_task(&task, Path::new("/tmp"), 30, 7);
        match result {
            crate::scheduler::tasks::TaskResult::NeedsUserAction(prompt) => {
                assert_eq!(prompt.title, "Stand up");
                assert_eq!(prompt.message, "Time to take a short break.");
                assert!(!prompt.actions.is_empty());
            }
            other => panic!("unexpected task result: {other:?}"),
        }
    }

    #[test]
    fn user_scheduler_task_falls_back_to_default_message() {
        let task = crate::scheduler::ScheduledTask::user_task(
            "reminder-fallback",
            "Water",
            crate::scheduler::Schedule::Interval { secs: 3600 },
        );

        let result = execute_scheduler_task(&task, Path::new("/tmp"), 30, 7);
        match result {
            crate::scheduler::tasks::TaskResult::NeedsUserAction(prompt) => {
                assert!(prompt.title.contains("Reminder"));
                assert!(prompt.message.contains("Scheduled task"));
            }
            other => panic!("unexpected task result: {other:?}"),
        }
    }
}
