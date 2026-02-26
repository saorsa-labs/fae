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

/// Tracks download speed and estimates time remaining.
///
/// Uses a rolling window of speed samples for smooth display values.
/// Call [`update`](Self::update) with each progress event to get
/// current speed and ETA.
pub struct DownloadTracker {
    /// When the tracked download started.
    started_at: std::time::Instant,
    /// Bytes count at last update.
    last_bytes: u64,
    /// Timestamp of last update.
    last_time: std::time::Instant,
    /// Rolling window of speed samples (bytes per second).
    speed_samples: std::collections::VecDeque<f64>,
}

/// Maximum number of speed samples in the rolling window.
const SPEED_WINDOW_SIZE: usize = 5;

/// Minimum time between speed samples to avoid spiky readings (milliseconds).
const MIN_SAMPLE_INTERVAL_MS: u64 = 200;

impl DownloadTracker {
    /// Create a new tracker. Call this when downloads begin.
    pub fn new() -> Self {
        let now = std::time::Instant::now();
        Self {
            started_at: now,
            last_bytes: 0,
            last_time: now,
            speed_samples: std::collections::VecDeque::with_capacity(SPEED_WINDOW_SIZE),
        }
    }

    /// Update with current progress and return `(speed_bytes_per_sec, eta_secs)`.
    ///
    /// - `bytes_downloaded`: total bytes downloaded so far
    /// - `total_bytes`: total expected bytes (0 if unknown)
    ///
    /// Returns `(0.0, None)` if not enough data yet.
    pub fn update(&mut self, bytes_downloaded: u64, total_bytes: u64) -> (f64, Option<f64>) {
        let now = std::time::Instant::now();
        let elapsed_since_last = now.duration_since(self.last_time);

        // Only add a speed sample if enough time has elapsed
        if elapsed_since_last.as_millis() >= u128::from(MIN_SAMPLE_INTERVAL_MS)
            && bytes_downloaded > self.last_bytes
        {
            let delta_bytes = bytes_downloaded - self.last_bytes;
            let delta_secs = elapsed_since_last.as_secs_f64();

            if delta_secs > 0.0 {
                let sample = delta_bytes as f64 / delta_secs;
                if self.speed_samples.len() >= SPEED_WINDOW_SIZE {
                    self.speed_samples.pop_front();
                }
                self.speed_samples.push_back(sample);
            }

            self.last_bytes = bytes_downloaded;
            self.last_time = now;
        }

        let speed = self.average_speed();

        let eta = if speed > 0.0 && total_bytes > bytes_downloaded {
            Some((total_bytes - bytes_downloaded) as f64 / speed)
        } else {
            None
        };

        (speed, eta)
    }

    /// Reset the tracker for a new download sequence.
    pub fn reset(&mut self) {
        let now = std::time::Instant::now();
        self.started_at = now;
        self.last_bytes = 0;
        self.last_time = now;
        self.speed_samples.clear();
    }

    /// Average speed across the rolling window (bytes per second).
    fn average_speed(&self) -> f64 {
        if self.speed_samples.is_empty() {
            return 0.0;
        }
        let sum: f64 = self.speed_samples.iter().sum();
        sum / self.speed_samples.len() as f64
    }

    /// Total elapsed time since the tracker was created or last reset.
    pub fn elapsed_secs(&self) -> f64 {
        self.started_at.elapsed().as_secs_f64()
    }
}

impl Default for DownloadTracker {
    fn default() -> Self {
        Self::new()
    }
}

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

    // --- DownloadTracker tests ---

    #[test]
    fn tracker_new_returns_zero_speed() {
        let tracker = DownloadTracker::new();
        assert!((tracker.average_speed() - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn tracker_update_with_zero_bytes_returns_no_eta() {
        let mut tracker = DownloadTracker::new();
        let (speed, eta) = tracker.update(0, 1000);
        assert!((speed - 0.0).abs() < f64::EPSILON);
        assert!(eta.is_none());
    }

    #[test]
    fn tracker_update_produces_speed_after_time() {
        let mut tracker = DownloadTracker::new();
        // Simulate time passing by backdating last_time
        tracker.last_time = std::time::Instant::now() - std::time::Duration::from_secs(1);

        let (speed, eta) = tracker.update(1_000_000, 2_000_000);
        // Should have a positive speed now
        assert!(speed > 0.0, "speed should be positive: {speed}");
        // ETA should exist since total > downloaded
        assert!(eta.is_some(), "eta should exist");
    }

    #[test]
    fn tracker_eta_none_when_download_complete() {
        let mut tracker = DownloadTracker::new();
        tracker.last_time = std::time::Instant::now() - std::time::Duration::from_secs(1);

        let (_speed, eta) = tracker.update(1000, 1000);
        assert!(
            eta.is_none(),
            "eta should be None when download is complete"
        );
    }

    #[test]
    fn tracker_eta_none_when_total_unknown() {
        let mut tracker = DownloadTracker::new();
        tracker.last_time = std::time::Instant::now() - std::time::Duration::from_secs(1);

        let (_speed, eta) = tracker.update(500, 0);
        assert!(eta.is_none(), "eta should be None when total_bytes is 0");
    }

    #[test]
    fn tracker_reset_clears_state() {
        let mut tracker = DownloadTracker::new();
        tracker.last_time = std::time::Instant::now() - std::time::Duration::from_secs(1);
        tracker.update(1_000_000, 2_000_000);
        assert!(tracker.average_speed() > 0.0);

        tracker.reset();
        assert!((tracker.average_speed() - 0.0).abs() < f64::EPSILON);
        assert_eq!(tracker.last_bytes, 0);
        assert!(tracker.speed_samples.is_empty());
    }

    #[test]
    fn tracker_rolling_window_caps_at_size() {
        let mut tracker = DownloadTracker::new();
        // Add more samples than SPEED_WINDOW_SIZE
        for i in 1..=10u64 {
            tracker.last_time = std::time::Instant::now() - std::time::Duration::from_secs(1);
            tracker.last_bytes = (i - 1) * 1_000_000;
            tracker.update(i * 1_000_000, 20_000_000);
        }
        assert!(
            tracker.speed_samples.len() <= SPEED_WINDOW_SIZE,
            "rolling window should be capped at {SPEED_WINDOW_SIZE}, got {}",
            tracker.speed_samples.len()
        );
    }

    #[test]
    fn tracker_default_matches_new() {
        let a = DownloadTracker::new();
        let b = DownloadTracker::default();
        assert!((a.elapsed_secs() - b.elapsed_secs()).abs() < 1.0);
        assert_eq!(a.last_bytes, b.last_bytes);
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
