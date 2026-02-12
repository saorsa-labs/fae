//! Progress event types for model download and initialization.
//!
//! Provides callback-based progress reporting that decouples the model
//! loading logic from UI presentation (CLI indicatif vs GUI signals).

/// A single file in the download plan.
#[derive(Debug, Clone)]
pub struct DownloadFile {
    /// HuggingFace repo ID (e.g. `"unsloth/Qwen3-4B-Instruct-2507-GGUF"`).
    pub repo_id: String,
    /// Filename within the repo.
    pub filename: String,
    /// File size in bytes, if known from HF Hub metadata.
    pub size_bytes: Option<u64>,
    /// Whether this file is already cached locally.
    pub cached: bool,
}

/// A plan of all files needed for startup, with cache status and sizes.
///
/// Built before downloads begin so the UI can show total download size
/// and let users confirm before starting.
#[derive(Debug, Clone)]
pub struct DownloadPlan {
    /// All files needed for the application.
    pub files: Vec<DownloadFile>,
}

impl DownloadPlan {
    /// Returns `true` if any file still needs to be downloaded.
    pub fn needs_download(&self) -> bool {
        self.files.iter().any(|f| !f.cached)
    }

    /// Total bytes that need to be downloaded (non-cached files only).
    ///
    /// Files with unknown size contribute 0 to the total.
    pub fn download_bytes(&self) -> u64 {
        self.files
            .iter()
            .filter(|f| !f.cached)
            .filter_map(|f| f.size_bytes)
            .sum()
    }

    /// Total bytes across all files (cached and uncached).
    ///
    /// Files with unknown size contribute 0 to the total.
    pub fn total_bytes(&self) -> u64 {
        self.files.iter().filter_map(|f| f.size_bytes).sum()
    }

    /// Total bytes already cached locally.
    ///
    /// Files with unknown size contribute 0 to the total.
    pub fn cached_bytes(&self) -> u64 {
        self.files
            .iter()
            .filter(|f| f.cached)
            .filter_map(|f| f.size_bytes)
            .sum()
    }

    /// Number of files that still need to be downloaded.
    pub fn files_to_download(&self) -> usize {
        self.files.iter().filter(|f| !f.cached).count()
    }

    /// Total number of files in the plan.
    pub fn total_files(&self) -> usize {
        self.files.len()
    }
}

/// Progress events emitted during model download and loading.
#[derive(Debug, Clone)]
pub enum ProgressEvent {
    /// A model file download has started.
    DownloadStarted {
        /// HuggingFace repo ID (e.g. `"istupakov/parakeet-tdt-0.6b-v3-onnx"`).
        repo_id: String,
        /// Filename within the repo.
        filename: String,
        /// Total size in bytes, if known.
        total_bytes: Option<u64>,
    },

    /// Download progress update.
    DownloadProgress {
        /// HuggingFace repo ID.
        repo_id: String,
        /// Filename within the repo.
        filename: String,
        /// Bytes downloaded so far.
        bytes_downloaded: u64,
        /// Total size in bytes, if known.
        total_bytes: Option<u64>,
    },

    /// A model file download completed.
    DownloadComplete {
        /// HuggingFace repo ID.
        repo_id: String,
        /// Filename within the repo.
        filename: String,
    },

    /// A model file was already cached (no download needed).
    Cached {
        /// HuggingFace repo ID.
        repo_id: String,
        /// Filename within the repo.
        filename: String,
    },

    /// Model loading into memory has started.
    LoadStarted {
        /// Human-readable model name (e.g. `"STT (Parakeet TDT)"`).
        model_name: String,
    },

    /// Model loading completed.
    LoadComplete {
        /// Human-readable model name.
        model_name: String,
        /// Time taken to load in seconds.
        duration_secs: f64,
    },

    /// The download plan is ready with file list and sizes.
    DownloadPlanReady {
        /// The computed download plan.
        plan: DownloadPlan,
    },

    /// Aggregate progress across all downloads.
    AggregateProgress {
        /// Total bytes downloaded across all files so far.
        bytes_downloaded: u64,
        /// Total bytes to download across all files.
        total_bytes: u64,
        /// Number of files completely downloaded.
        files_complete: usize,
        /// Total number of files to download.
        files_total: usize,
    },

    /// An error occurred during download or loading.
    Error {
        /// Human-readable error description.
        message: String,
    },
}

/// Callback type for receiving progress events.
///
/// Both CLI (indicatif) and GUI (Dioxus signals) implement this
/// to receive updates from the model download/load pipeline.
pub type ProgressCallback = Box<dyn Fn(ProgressEvent) + Send + Sync>;

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn callback_receives_events() {
        let events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let events_clone = Arc::clone(&events);

        let callback: ProgressCallback = Box::new(move |event| {
            let label = match &event {
                ProgressEvent::DownloadStarted { .. } => "started",
                ProgressEvent::DownloadProgress { .. } => "progress",
                ProgressEvent::DownloadComplete { .. } => "complete",
                ProgressEvent::Cached { .. } => "cached",
                ProgressEvent::LoadStarted { .. } => "load_started",
                ProgressEvent::LoadComplete { .. } => "load_complete",
                ProgressEvent::DownloadPlanReady { .. } => "plan_ready",
                ProgressEvent::AggregateProgress { .. } => "aggregate",
                ProgressEvent::Error { .. } => "error",
            };
            let Ok(mut guard) = events_clone.lock() else {
                return;
            };
            guard.push(label.to_owned());
        });

        callback(ProgressEvent::DownloadStarted {
            repo_id: "test/repo".into(),
            filename: "model.onnx".into(),
            total_bytes: Some(1000),
        });
        callback(ProgressEvent::DownloadProgress {
            repo_id: "test/repo".into(),
            filename: "model.onnx".into(),
            bytes_downloaded: 500,
            total_bytes: Some(1000),
        });
        callback(ProgressEvent::DownloadComplete {
            repo_id: "test/repo".into(),
            filename: "model.onnx".into(),
        });

        let guard = events.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(guard.len(), 3);
        assert_eq!(guard[0], "started");
        assert_eq!(guard[1], "progress");
        assert_eq!(guard[2], "complete");
    }

    #[test]
    fn load_events_round_trip() {
        let events: Arc<Mutex<Vec<ProgressEvent>>> = Arc::new(Mutex::new(Vec::new()));
        let events_clone = Arc::clone(&events);

        let callback: ProgressCallback = Box::new(move |event| {
            let Ok(mut guard) = events_clone.lock() else {
                return;
            };
            guard.push(event);
        });

        callback(ProgressEvent::LoadStarted {
            model_name: "STT (Parakeet)".into(),
        });
        callback(ProgressEvent::LoadComplete {
            model_name: "STT (Parakeet)".into(),
            duration_secs: 2.5,
        });

        let guard = events.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(guard.len(), 2);
        assert!(
            matches!(&guard[0], ProgressEvent::LoadStarted { model_name } if model_name == "STT (Parakeet)")
        );
        assert!(
            matches!(&guard[1], ProgressEvent::LoadComplete { duration_secs, .. } if (*duration_secs - 2.5).abs() < f64::EPSILON)
        );
    }

    fn make_plan(files: Vec<DownloadFile>) -> DownloadPlan {
        DownloadPlan { files }
    }

    fn make_file(repo: &str, name: &str, size: Option<u64>, cached: bool) -> DownloadFile {
        DownloadFile {
            repo_id: repo.to_owned(),
            filename: name.to_owned(),
            size_bytes: size,
            cached,
        }
    }

    #[test]
    fn download_plan_needs_download_when_uncached() {
        let plan = make_plan(vec![
            make_file("repo/a", "model.onnx", Some(1000), false),
            make_file("repo/b", "vocab.txt", Some(100), true),
        ]);
        assert!(plan.needs_download());
    }

    #[test]
    fn download_plan_no_download_when_all_cached() {
        let plan = make_plan(vec![
            make_file("repo/a", "model.onnx", Some(1000), true),
            make_file("repo/b", "vocab.txt", Some(100), true),
        ]);
        assert!(!plan.needs_download());
    }

    #[test]
    fn download_plan_bytes_calculation() {
        let plan = make_plan(vec![
            make_file("repo/a", "big.onnx", Some(2000), false),
            make_file("repo/b", "small.txt", Some(300), true),
            make_file("repo/c", "unknown.bin", None, false),
        ]);
        assert_eq!(plan.download_bytes(), 2000);
        assert_eq!(plan.total_bytes(), 2300);
        assert_eq!(plan.cached_bytes(), 300);
    }

    #[test]
    fn download_plan_file_counts() {
        let plan = make_plan(vec![
            make_file("repo/a", "a.onnx", Some(100), false),
            make_file("repo/b", "b.onnx", Some(200), true),
            make_file("repo/c", "c.onnx", Some(300), false),
        ]);
        assert_eq!(plan.files_to_download(), 2);
        assert_eq!(plan.total_files(), 3);
    }

    #[test]
    fn download_plan_empty() {
        let plan = make_plan(vec![]);
        assert!(!plan.needs_download());
        assert_eq!(plan.download_bytes(), 0);
        assert_eq!(plan.total_bytes(), 0);
        assert_eq!(plan.cached_bytes(), 0);
        assert_eq!(plan.files_to_download(), 0);
        assert_eq!(plan.total_files(), 0);
    }

    #[test]
    fn callback_receives_plan_and_aggregate_events() {
        let events: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let events_clone = Arc::clone(&events);

        let callback: ProgressCallback = Box::new(move |event| {
            let label = match &event {
                ProgressEvent::DownloadPlanReady { .. } => "plan_ready",
                ProgressEvent::AggregateProgress { .. } => "aggregate",
                _ => "other",
            };
            let Ok(mut guard) = events_clone.lock() else {
                return;
            };
            guard.push(label.to_owned());
        });

        let plan = make_plan(vec![make_file("repo/a", "model.onnx", Some(1000), false)]);
        callback(ProgressEvent::DownloadPlanReady { plan });
        callback(ProgressEvent::AggregateProgress {
            bytes_downloaded: 500,
            total_bytes: 1000,
            files_complete: 0,
            files_total: 1,
        });

        let guard = events.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(guard.len(), 2);
        assert_eq!(guard[0], "plan_ready");
        assert_eq!(guard[1], "aggregate");
    }
}
