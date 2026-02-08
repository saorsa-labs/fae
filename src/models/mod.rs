//! Model downloading, caching, and management via hf-hub.

use crate::config::ModelConfig;
use crate::error::{Result, SpeechError};
use crate::progress::{ProgressCallback, ProgressEvent};
use indicatif::{ProgressBar, ProgressStyle};
use std::io::Read;
use std::path::PathBuf;
use tracing::info;

/// Manages downloading and caching of ML models.
pub struct ModelManager {
    cache_dir: PathBuf,
}

impl ModelManager {
    /// Create a new model manager.
    ///
    /// # Errors
    ///
    /// Returns an error if the cache directory cannot be created.
    pub fn new(config: &ModelConfig) -> Result<Self> {
        std::fs::create_dir_all(&config.cache_dir)?;
        info!("model cache directory: {}", config.cache_dir.display());

        Ok(Self {
            cache_dir: config.cache_dir.clone(),
        })
    }

    /// Get the path to a cached model file, downloading if necessary.
    ///
    /// # Errors
    ///
    /// Returns an error if the model cannot be downloaded.
    pub fn get_model_path(&self, repo_id: &str, filename: &str) -> Result<PathBuf> {
        let api = hf_hub::api::sync::Api::new()
            .map_err(|e| SpeechError::Model(format!("failed to create HF API: {e}")))?;

        let repo = api.model(repo_id.to_owned());
        let path = repo.get(filename).map_err(|e| {
            SpeechError::Model(format!("failed to download {filename} from {repo_id}: {e}"))
        })?;

        Ok(path)
    }

    /// Get the directory containing all cached files for a repository.
    ///
    /// This downloads the repo info and returns the snapshot directory where
    /// `hf-hub` stores downloaded files. Useful for models that expect a
    /// directory path (like Parakeet TDT).
    ///
    /// # Errors
    ///
    /// Returns an error if the repo directory cannot be determined.
    pub fn get_repo_dir(&self, repo_id: &str) -> Result<PathBuf> {
        let api = hf_hub::api::sync::Api::new()
            .map_err(|e| SpeechError::Model(format!("failed to create HF API: {e}")))?;

        let repo = api.model(repo_id.to_owned());

        // hf-hub stores files under a snapshot directory. We can get it by
        // resolving any file and taking its parent directory.
        // First, try to list known files or use the repo info.
        let repo_info = repo.info().map_err(|e| {
            SpeechError::Model(format!("failed to get repo info for {repo_id}: {e}"))
        })?;

        // The repo info contains siblings (files). Use the first file to
        // determine the snapshot directory.
        if let Some(sibling) = repo_info.siblings.first() {
            let file_path = repo.get(&sibling.rfilename).map_err(|e| {
                SpeechError::Model(format!(
                    "failed to download {} from {repo_id}: {e}",
                    sibling.rfilename
                ))
            })?;

            // The file path is inside a snapshot dir. Walk up to find it.
            if let Some(parent) = file_path.parent() {
                return Ok(parent.to_path_buf());
            }
        }

        Err(SpeechError::Model(format!(
            "could not determine repo directory for {repo_id}"
        )))
    }

    /// Download a model file with a visible progress bar.
    ///
    /// If the file is already cached, returns immediately without showing a bar.
    /// Uses `hf-hub`'s built-in `Progress` impl for `indicatif::ProgressBar`.
    ///
    /// An optional `callback` receives [`ProgressEvent`]s for GUI or other consumers.
    ///
    /// # Errors
    ///
    /// Returns an error if the download fails.
    pub fn download_with_progress(
        &self,
        repo_id: &str,
        filename: &str,
        callback: Option<&ProgressCallback>,
    ) -> Result<PathBuf> {
        let api = hf_hub::api::sync::Api::new()
            .map_err(|e| SpeechError::Model(format!("failed to create HF API: {e}")))?;

        // Check if already cached — avoid showing a progress bar for cached files.
        let cache = hf_hub::Cache::default();
        if let Some(path) = cache.model(repo_id.to_owned()).get(filename) {
            println!("  {repo_id}/{filename}  [cached]");
            if let Some(cb) = callback {
                cb(ProgressEvent::Cached {
                    repo_id: repo_id.to_owned(),
                    filename: filename.to_owned(),
                });
            }
            return Ok(path);
        }

        if let Some(cb) = callback {
            cb(ProgressEvent::DownloadStarted {
                repo_id: repo_id.to_owned(),
                filename: filename.to_owned(),
                total_bytes: None,
            });
        }

        let pb = ProgressBar::new(0);
        if let Ok(style) = ProgressStyle::with_template(
            "  {msg} [{bar:30}] {bytes}/{total_bytes} {bytes_per_sec} ETA {eta}",
        ) {
            pb.set_style(style);
        }
        pb.set_message(format!("{repo_id}/{filename}"));

        let repo = api.model(repo_id.to_owned());
        let path = repo
            .download_with_progress(filename, pb)
            .map_err(|e| SpeechError::Model(format!("failed to download {filename}: {e}")))?;

        if let Some(cb) = callback {
            cb(ProgressEvent::DownloadComplete {
                repo_id: repo_id.to_owned(),
                filename: filename.to_owned(),
            });
        }

        Ok(path)
    }

    /// Download all files in a repo with progress bars, returning the repo directory.
    ///
    /// Each file gets its own progress bar. Already-cached files are skipped.
    ///
    /// # Errors
    ///
    /// Returns an error if any download fails or the repo directory cannot be determined.
    pub fn download_repo_with_progress(
        &self,
        repo_id: &str,
        filenames: &[&str],
        callback: Option<&ProgressCallback>,
    ) -> Result<PathBuf> {
        for filename in filenames {
            self.download_with_progress(repo_id, filename, callback)?;
        }
        self.get_repo_dir(repo_id)
    }

    /// Download a file from a direct URL into the cache directory with progress.
    ///
    /// The file is stored at `<cache_dir>/<filename>`. If the file already
    /// exists, returns immediately. This is used for models not hosted on
    /// HuggingFace (e.g. GitHub releases).
    ///
    /// # Errors
    ///
    /// Returns an error if the download fails.
    pub fn download_url_with_progress(
        &self,
        url: &str,
        filename: &str,
        callback: Option<&ProgressCallback>,
    ) -> Result<PathBuf> {
        let dest = self.cache_dir.join(filename);

        if dest.exists() {
            println!("  {filename}  [cached]");
            if let Some(cb) = callback {
                cb(ProgressEvent::Cached {
                    repo_id: url.to_owned(),
                    filename: filename.to_owned(),
                });
            }
            return Ok(dest);
        }

        if let Some(cb) = callback {
            cb(ProgressEvent::DownloadStarted {
                repo_id: url.to_owned(),
                filename: filename.to_owned(),
                total_bytes: None,
            });
        }

        let pb = ProgressBar::new(0);
        if let Ok(style) = ProgressStyle::with_template(
            "  {msg} [{bar:30}] {bytes}/{total_bytes} {bytes_per_sec} ETA {eta}",
        ) {
            pb.set_style(style);
        }
        pb.set_message(filename.to_owned());

        let resp = ureq::get(url)
            .call()
            .map_err(|e| SpeechError::Model(format!("failed to download {filename}: {e}")))?;

        let total_bytes = resp
            .header("content-length")
            .and_then(|v| v.parse::<u64>().ok());

        if let Some(len) = total_bytes {
            pb.set_length(len);
        }

        // Write to a temp file then rename (atomic-ish on same filesystem).
        let tmp = dest.with_extension("part");
        let mut file = std::fs::File::create(&tmp)?;
        let mut reader = resp.into_reader();
        let mut buf = [0u8; 64 * 1024];
        let mut bytes_downloaded: u64 = 0;
        loop {
            let n = reader
                .read(&mut buf)
                .map_err(|e| SpeechError::Model(format!("download read error: {e}")))?;
            if n == 0 {
                break;
            }
            std::io::Write::write_all(&mut file, &buf[..n])?;
            pb.inc(n as u64);
            bytes_downloaded += n as u64;
            if let Some(cb) = callback {
                cb(ProgressEvent::DownloadProgress {
                    repo_id: url.to_owned(),
                    filename: filename.to_owned(),
                    bytes_downloaded,
                    total_bytes,
                });
            }
        }
        pb.finish();

        std::fs::rename(&tmp, &dest)?;

        if let Some(cb) = callback {
            cb(ProgressEvent::DownloadComplete {
                repo_id: url.to_owned(),
                filename: filename.to_owned(),
            });
        }

        Ok(dest)
    }

    /// Get the cache directory path.
    pub fn cache_dir(&self) -> &PathBuf {
        &self.cache_dir
    }
}
