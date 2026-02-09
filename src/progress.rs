//! Progress event types for model download and initialization.
//!
//! Provides callback-based progress reporting that decouples the model
//! loading logic from UI presentation (CLI indicatif vs GUI signals).

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
}
