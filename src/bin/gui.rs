//! Fae desktop GUI — simple start/stop interface with progress feedback.
//!
//! Requires the `gui` feature: `cargo run --features gui --bin fae-gui`

#[cfg(not(feature = "gui"))]
fn main() {
    eprintln!("fae-gui requires the `gui` feature. Run with:");
    eprintln!("  cargo run --features gui --bin fae-gui");
    std::process::exit(1);
}

#[cfg(feature = "gui")]
fn main() {
    use dioxus::desktop::{Config, LogicalSize, WindowBuilder};

    LaunchBuilder::new()
        .with_cfg(
            Config::new().with_window(
                WindowBuilder::new()
                    .with_title("Fae")
                    .with_inner_size(LogicalSize::new(400.0, 620.0))
                    .with_min_inner_size(LogicalSize::new(320.0, 480.0))
                    .with_resizable(true),
            ),
        )
        .launch(app);
}

#[cfg(feature = "gui")]
mod gui {
    use fae::progress::ProgressEvent;
    use tokio_util::sync::CancellationToken;

    /// Application state phases.
    #[derive(Debug, Clone, PartialEq)]
    pub enum AppStatus {
        /// Waiting for user to press Start.
        Idle,
        /// Downloading model files.
        Downloading {
            /// Current file being downloaded.
            current_file: String,
            /// Bytes downloaded for current file.
            bytes_downloaded: u64,
            /// Total bytes for current file (if known).
            total_bytes: Option<u64>,
        },
        /// Loading models into memory.
        Loading {
            /// Which model is being loaded.
            model_name: String,
        },
        /// Pipeline is running — listening for speech.
        Running,
        /// Pipeline is shutting down.
        Stopping,
        /// An error occurred.
        Error(String),
    }

    impl AppStatus {
        /// Human-readable status text for display.
        pub fn display_text(&self) -> String {
            match self {
                Self::Idle => "Ready".into(),
                Self::Downloading { current_file, .. } => {
                    format!("Downloading {current_file}...")
                }
                Self::Loading { model_name } => format!("Loading {model_name}..."),
                Self::Running => "Listening...".into(),
                Self::Stopping => "Stopping...".into(),
                Self::Error(msg) => format!("Error: {msg}"),
            }
        }

        /// Whether the start button should be shown (vs stop).
        pub fn show_start(&self) -> bool {
            matches!(self, Self::Idle | Self::Error(_))
        }

        /// Whether buttons should be interactive.
        pub fn buttons_enabled(&self) -> bool {
            matches!(self, Self::Idle | Self::Running | Self::Error(_))
        }
    }

    /// Shared state accessible from both the GUI and the background pipeline task.
    pub struct SharedState {
        /// Cancellation token for the running pipeline.
        pub cancel_token: Option<CancellationToken>,
    }

    /// Apply a progress event to an optional `AppStatus` update.
    ///
    /// Returns `Some(new_status)` when the event warrants a UI state change,
    /// or `None` for intermediate events (e.g. `DownloadComplete`, `LoadComplete`)
    /// that don't directly change the displayed state.
    pub fn apply_progress_event(event: ProgressEvent) -> Option<AppStatus> {
        match event {
            ProgressEvent::DownloadStarted {
                filename,
                total_bytes,
                ..
            } => Some(AppStatus::Downloading {
                current_file: filename,
                bytes_downloaded: 0,
                total_bytes,
            }),
            ProgressEvent::DownloadProgress {
                filename,
                bytes_downloaded,
                total_bytes,
                ..
            } => Some(AppStatus::Downloading {
                current_file: filename,
                bytes_downloaded,
                total_bytes,
            }),
            ProgressEvent::DownloadComplete { .. } | ProgressEvent::Cached { .. } => {
                // Progress continues to next file or load phase — no state change
                None
            }
            ProgressEvent::LoadStarted { model_name } => Some(AppStatus::Loading { model_name }),
            ProgressEvent::LoadComplete { .. } => {
                // Will transition to Running after all loads complete
                None
            }
            ProgressEvent::Error { message } => Some(AppStatus::Error(message)),
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        // --- AppStatus display_text ---

        #[test]
        fn idle_display_text() {
            assert_eq!(AppStatus::Idle.display_text(), "Ready");
        }

        #[test]
        fn downloading_display_text() {
            let s = AppStatus::Downloading {
                current_file: "model.onnx".into(),
                bytes_downloaded: 500,
                total_bytes: Some(1000),
            };
            assert_eq!(s.display_text(), "Downloading model.onnx...");
        }

        #[test]
        fn loading_display_text() {
            let s = AppStatus::Loading {
                model_name: "STT".into(),
            };
            assert_eq!(s.display_text(), "Loading STT...");
        }

        #[test]
        fn running_display_text() {
            assert_eq!(AppStatus::Running.display_text(), "Listening...");
        }

        #[test]
        fn stopping_display_text() {
            assert_eq!(AppStatus::Stopping.display_text(), "Stopping...");
        }

        #[test]
        fn error_display_text() {
            let s = AppStatus::Error("network failure".into());
            assert_eq!(s.display_text(), "Error: network failure");
        }

        // --- AppStatus button predicates ---

        #[test]
        fn show_start_when_idle_or_error() {
            assert!(AppStatus::Idle.show_start());
            assert!(AppStatus::Error("x".into()).show_start());
            assert!(!AppStatus::Running.show_start());
            assert!(!AppStatus::Stopping.show_start());
        }

        #[test]
        fn buttons_enabled_states() {
            assert!(AppStatus::Idle.buttons_enabled());
            assert!(AppStatus::Running.buttons_enabled());
            assert!(AppStatus::Error("x".into()).buttons_enabled());
            assert!(!AppStatus::Stopping.buttons_enabled());
            assert!(
                !AppStatus::Loading {
                    model_name: "x".into()
                }
                .buttons_enabled()
            );
            assert!(
                !AppStatus::Downloading {
                    current_file: "x".into(),
                    bytes_downloaded: 0,
                    total_bytes: None,
                }
                .buttons_enabled()
            );
        }

        // --- apply_progress_event ---

        #[test]
        fn download_started_sets_downloading() {
            let result = apply_progress_event(ProgressEvent::DownloadStarted {
                repo_id: "test/repo".into(),
                filename: "weights.bin".into(),
                total_bytes: Some(2048),
            });
            assert!(result.is_some());
            let status = result.unwrap_or(AppStatus::Idle);
            match status {
                AppStatus::Downloading {
                    current_file,
                    bytes_downloaded,
                    total_bytes,
                } => {
                    assert_eq!(current_file, "weights.bin");
                    assert_eq!(bytes_downloaded, 0);
                    assert_eq!(total_bytes, Some(2048));
                }
                other => unreachable!("expected Downloading, got {other:?}"),
            }
        }

        #[test]
        fn download_progress_updates_bytes() {
            let result = apply_progress_event(ProgressEvent::DownloadProgress {
                repo_id: "test/repo".into(),
                filename: "weights.bin".into(),
                bytes_downloaded: 1024,
                total_bytes: Some(2048),
            });
            assert!(result.is_some());
            let status = result.unwrap_or(AppStatus::Idle);
            match status {
                AppStatus::Downloading {
                    bytes_downloaded, ..
                } => assert_eq!(bytes_downloaded, 1024),
                other => unreachable!("expected Downloading, got {other:?}"),
            }
        }

        #[test]
        fn download_complete_returns_none() {
            let result = apply_progress_event(ProgressEvent::DownloadComplete {
                repo_id: "test/repo".into(),
                filename: "weights.bin".into(),
            });
            assert!(result.is_none());
        }

        #[test]
        fn cached_returns_none() {
            let result = apply_progress_event(ProgressEvent::Cached {
                repo_id: "test/repo".into(),
                filename: "weights.bin".into(),
            });
            assert!(result.is_none());
        }

        #[test]
        fn load_started_sets_loading() {
            let result = apply_progress_event(ProgressEvent::LoadStarted {
                model_name: "STT (Parakeet)".into(),
            });
            assert!(result.is_some());
            let status = result.unwrap_or(AppStatus::Idle);
            match status {
                AppStatus::Loading { model_name } => {
                    assert_eq!(model_name, "STT (Parakeet)");
                }
                other => unreachable!("expected Loading, got {other:?}"),
            }
        }

        #[test]
        fn load_complete_returns_none() {
            let result = apply_progress_event(ProgressEvent::LoadComplete {
                model_name: "STT".into(),
                duration_secs: 1.5,
            });
            assert!(result.is_none());
        }

        #[test]
        fn error_event_sets_error() {
            let result = apply_progress_event(ProgressEvent::Error {
                message: "download failed".into(),
            });
            assert!(result.is_some());
            let status = result.unwrap_or(AppStatus::Idle);
            match status {
                AppStatus::Error(msg) => assert_eq!(msg, "download failed"),
                other => unreachable!("expected Error, got {other:?}"),
            }
        }
    }
}

#[cfg(feature = "gui")]
use dioxus::prelude::*;

#[cfg(feature = "gui")]
use gui::{AppStatus, SharedState};

/// Root application component.
#[cfg(feature = "gui")]
fn app() -> Element {
    let mut status = use_signal(|| AppStatus::Idle);
    let mut shared = use_signal(|| SharedState { cancel_token: None });

    // Button click handler
    let on_button_click = move |_| {
        let current = status.read().clone();
        match current {
            AppStatus::Idle | AppStatus::Error(_) => {
                // --- START ---
                status.set(AppStatus::Downloading {
                    current_file: "Checking models...".into(),
                    bytes_downloaded: 0,
                    total_bytes: None,
                });

                // Use a channel to bridge progress events from the Send+Sync
                // callback to the single-threaded Dioxus signal.
                let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();

                // Build a Send+Sync callback that sends events through the channel.
                let callback: fae::progress::ProgressCallback = Box::new(move |event| {
                    let _ = tx.send(event);
                });

                // Spawn the pipeline work on a background tokio task.
                // The callback is Send+Sync so it can cross thread boundaries.
                let callback = std::sync::Arc::new(callback);
                let cb_for_task = std::sync::Arc::clone(&callback);

                // Background task: run model init + pipeline on the tokio threadpool.
                // Results come back via channels.
                let (result_tx, mut result_rx) = tokio::sync::mpsc::unbounded_channel();

                tokio::task::spawn(async move {
                    let config = fae::SpeechConfig::default();

                    // Phase 1: Download + Load models
                    let models_result =
                        fae::startup::initialize_models_with_progress(&config, Some(&*cb_for_task))
                            .await;

                    let _ = result_tx.send(PipelineMessage::ModelsReady(
                        models_result.map(|m| (config, m)),
                    ));
                });

                // Coroutine on the Dioxus (main) thread: poll channels and update signals.
                spawn(async move {
                    // Drain progress events periodically while waiting for result.
                    loop {
                        tokio::select! {
                            Some(event) = rx.recv() => {
                                if let Some(new_status) = gui::apply_progress_event(event) {
                                    status.set(new_status);
                                }
                            }
                            Some(msg) = result_rx.recv() => {
                                // Drain any remaining progress events first.
                                while let Ok(event) = rx.try_recv() {
                                    if let Some(new_status) = gui::apply_progress_event(event) {
                                        status.set(new_status);
                                    }
                                }
                                match msg {
                                    PipelineMessage::ModelsReady(Ok((config, models))) => {
                                        status.set(AppStatus::Running);

                                        let pipeline =
                                            fae::PipelineCoordinator::with_models(config, models)
                                                .with_mode(fae::PipelineMode::Conversation);
                                        let cancel = pipeline.cancel_token();
                                        shared.write().cancel_token = Some(cancel);

                                        match pipeline.run().await {
                                            Ok(()) => status.set(AppStatus::Idle),
                                            Err(e) => {
                                                status.set(AppStatus::Error(e.to_string()));
                                            }
                                        }
                                        shared.write().cancel_token = None;
                                    }
                                    PipelineMessage::ModelsReady(Err(e)) => {
                                        status.set(AppStatus::Error(e.to_string()));
                                    }
                                }
                                break;
                            }
                        }
                    }
                });
            }
            AppStatus::Running => {
                // --- STOP ---
                status.set(AppStatus::Stopping);
                if let Some(token) = &shared.read().cancel_token {
                    token.cancel();
                }
            }
            _ => {}
        }
    };

    let current_status = status.read().clone();
    let status_text = current_status.display_text();
    let button_label = if current_status.show_start() {
        "Start"
    } else {
        "Stop"
    };
    let button_enabled = current_status.buttons_enabled();
    let is_running = matches!(current_status, AppStatus::Running);
    let is_loading = matches!(
        current_status,
        AppStatus::Downloading { .. } | AppStatus::Loading { .. }
    );
    let is_error = matches!(current_status, AppStatus::Error(_));

    // Progress bar fraction (0.0 to 1.0)
    let progress_fraction = if let AppStatus::Downloading {
        bytes_downloaded,
        total_bytes: Some(total),
        ..
    } = &current_status
    {
        if *total > 0 {
            *bytes_downloaded as f64 / *total as f64
        } else {
            0.0
        }
    } else {
        0.0
    };
    let progress_pct = format!("{:.0}%", progress_fraction * 100.0);
    let progress_width = format!("{}%", (progress_fraction * 100.0) as u32);

    // Button colors
    let button_bg = if is_error {
        "#a78bfa"
    } else if current_status.show_start() {
        "#22c55e"
    } else {
        "#ef4444"
    };
    let button_opacity = if button_enabled { "1" } else { "0.5" };

    rsx! {
        // Global styles
        style { {GLOBAL_CSS} }

        div { class: "container",
            // Fae avatar with loading/running overlays
            div {
                class: match (&is_running, &is_loading) {
                    (true, _) => "avatar avatar-pulse",
                    (_, true) => "avatar avatar-loading",
                    _ => "avatar",
                },
                img {
                    src: "assets/fae.jpg",
                    alt: "Fae",
                    class: "avatar-img",
                }
                // Spinning ring overlay during loading
                if is_loading {
                    div { class: "avatar-spinner" }
                }
            }

            // Title
            h1 { class: "title", "Fae" }

            // Status text
            p {
                class: if is_error { "status status-error" } else { "status" },
                "{status_text}"
            }

            // Progress bar (visible during downloads)
            if is_loading {
                div { class: "progress-container",
                    div { class: "progress-bar",
                        div {
                            class: "progress-fill",
                            style: "width: {progress_width};",
                        }
                    }
                    if progress_fraction > 0.0 {
                        p { class: "progress-text", "{progress_pct}" }
                    }
                }
            }

            // Start/Stop button
            button {
                class: "main-button",
                style: "background: {button_bg}; opacity: {button_opacity};",
                disabled: !button_enabled,
                onclick: on_button_click,
                "{button_label}"
            }
        }
    }
}

/// Messages sent from the background pipeline task to the GUI coroutine.
#[cfg(feature = "gui")]
enum PipelineMessage {
    /// Model initialization completed (success or failure).
    ModelsReady(
        Result<(fae::SpeechConfig, fae::startup::InitializedModels), fae::error::SpeechError>,
    ),
}

/// Global CSS styles for the application.
#[cfg(feature = "gui")]
const GLOBAL_CSS: &str = r#"
    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
        background: #1a1a2e;
        color: #e0e0e0;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    }

    .container {
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        min-height: 100vh;
        padding: 2rem;
        gap: 1.2rem;
    }

    /* --- Avatar --- */
    .avatar {
        position: relative;
        width: 160px;
        height: 160px;
        border-radius: 50%;
        overflow: hidden;
        border: 3px solid #a78bfa;
        transition: box-shadow 0.4s ease, border-color 0.4s ease;
    }

    .avatar-pulse {
        animation: pulse 2s ease-in-out infinite;
        border-color: #22c55e;
    }

    .avatar-loading {
        border-color: transparent;
    }

    .avatar-img {
        width: 100%;
        height: 100%;
        object-fit: cover;
    }

    /* Spinning ring overlay while loading */
    .avatar-spinner {
        position: absolute;
        top: -3px;
        left: -3px;
        width: calc(100% + 6px);
        height: calc(100% + 6px);
        border-radius: 50%;
        border: 3px solid transparent;
        border-top-color: #a78bfa;
        border-right-color: #7c3aed;
        animation: spin 1s linear infinite;
        pointer-events: none;
    }

    @keyframes pulse {
        0%, 100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.4); }
        50% { box-shadow: 0 0 20px 10px rgba(34, 197, 94, 0.15); }
    }

    @keyframes spin {
        to { transform: rotate(360deg); }
    }

    /* --- Title --- */
    .title {
        font-size: 2rem;
        color: #a78bfa;
        font-weight: 300;
        letter-spacing: 0.1em;
    }

    /* --- Status --- */
    .status {
        color: #888;
        font-size: 0.9rem;
        min-height: 1.4em;
        transition: color 0.3s ease;
    }

    .status-error {
        color: #ef4444;
    }

    /* --- Progress --- */
    .progress-container {
        width: 80%;
        max-width: 300px;
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 0.4rem;
    }

    .progress-bar {
        width: 100%;
        height: 6px;
        background: #2a2a4a;
        border-radius: 3px;
        overflow: hidden;
    }

    .progress-fill {
        height: 100%;
        background: linear-gradient(90deg, #a78bfa, #7c3aed);
        border-radius: 3px;
        transition: width 0.3s ease;
    }

    .progress-text {
        color: #666;
        font-size: 0.75rem;
    }

    /* --- Button --- */
    .main-button {
        margin-top: 1rem;
        padding: 0.8rem 3rem;
        border: none;
        border-radius: 2rem;
        font-size: 1.1rem;
        font-weight: 500;
        color: white;
        cursor: pointer;
        transition: transform 0.15s ease, opacity 0.2s ease, background 0.3s ease;
        letter-spacing: 0.05em;
    }

    .main-button:hover:not(:disabled) {
        transform: scale(1.05);
    }

    .main-button:active:not(:disabled) {
        transform: scale(0.97);
    }

    .main-button:disabled {
        cursor: not-allowed;
    }
"#;
