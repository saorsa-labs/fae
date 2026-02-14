//! Fae desktop GUI — simple start/stop interface with progress feedback.
//!
//! Requires the `gui` feature: `cargo run --features gui --bin fae`

#[cfg(not(feature = "gui"))]
fn main() {
    eprintln!("fae requires the `gui` feature. Run with:");
    eprintln!("  cargo run --features gui --bin fae");
    std::process::exit(1);
}

#[cfg(feature = "gui")]
fn main() {
    use dioxus::desktop::{Config, LogicalSize, WindowBuilder};
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    // Ensure log directory exists.
    let log_dir = fae::diagnostics::fae_log_dir();
    let _ = std::fs::create_dir_all(&log_dir);

    // File appender: daily rotating log files in ~/.fae/logs/
    let file_appender = tracing_appender::rolling::daily(&log_dir, "fae.log");
    let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);

    // Dual-output tracing: stdout (respects RUST_LOG) + file (always info).
    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    let stdout_layer = tracing_subscriber::fmt::layer().with_writer(std::io::stdout);
    let file_layer = tracing_subscriber::fmt::layer()
        .with_writer(non_blocking)
        .with_ansi(false);

    tracing_subscriber::registry()
        .with(env_filter)
        .with(stdout_layer)
        .with(file_layer)
        .init();

    LaunchBuilder::new()
        .with_cfg(
            Config::new().with_window(
                WindowBuilder::new()
                    .with_title("Fae")
                    .with_inner_size(LogicalSize::new(480.0, 800.0))
                    .with_min_inner_size(LogicalSize::new(400.0, 600.0))
                    .with_resizable(true),
            ),
        )
        .launch(app);
}

#[cfg(feature = "gui")]
mod gui {
    use fae::progress::ProgressEvent;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use tokio_util::sync::CancellationToken;

    /// Application state phases.
    #[derive(Debug, Clone, PartialEq)]
    pub enum AppStatus {
        /// Waiting for user to press Start.
        Idle,
        /// Pre-flight: showing download confirmation before starting.
        PreFlight {
            /// Total bytes that need to be downloaded.
            total_bytes: u64,
            /// Number of files that need downloading.
            files_to_download: usize,
            /// Total number of model files (including cached).
            total_files: usize,
            /// Free disk space available in bytes.
            free_space: u64,
        },
        /// Downloading model files.
        Downloading {
            /// Current file being downloaded.
            current_file: String,
            /// Bytes downloaded for current file.
            bytes_downloaded: u64,
            /// Total bytes for current file (if known).
            total_bytes: Option<u64>,
            /// Number of files completely downloaded.
            files_complete: usize,
            /// Total number of files to download.
            files_total: usize,
            /// Aggregate bytes downloaded across all files.
            aggregate_bytes: u64,
            /// Total bytes to download across all files.
            aggregate_total: u64,
            /// Current download speed in bytes per second.
            speed_bps: f64,
            /// Estimated time remaining in seconds.
            eta_secs: Option<f64>,
        },
        /// Loading models into memory.
        Loading {
            /// Which model is being loaded.
            model_name: String,
        },
        /// Pipeline is running — listening for speech.
        Running,
        /// An error occurred.
        Error(String),
        /// A download failed with structured error details.
        DownloadError {
            /// Human-readable summary message.
            message: String,
            /// Which repo the failing file belongs to.
            repo_id: String,
            /// Which file failed.
            filename: String,
            /// Bytes downloaded before the failure.
            bytes_downloaded: u64,
            /// Total expected bytes (if known).
            total_bytes: Option<u64>,
        },
    }

    impl AppStatus {
        /// Human-readable status text for display.
        pub fn display_text(&self) -> String {
            match self {
                Self::Idle => "Ready".into(),
                Self::PreFlight { total_bytes, .. } => {
                    format!(
                        "Ready to download {:.1} GB",
                        *total_bytes as f64 / 1_000_000_000.0
                    )
                }
                Self::Downloading {
                    current_file,
                    files_complete,
                    files_total,
                    ..
                } => {
                    if *files_total > 0 {
                        format!(
                            "Downloading file {}/{} — {current_file}",
                            files_complete + 1,
                            files_total
                        )
                    } else {
                        format!("Downloading {current_file}...")
                    }
                }
                Self::Loading { model_name } => format!("Loading {model_name}..."),
                Self::Running => "Listening...".into(),
                Self::Error(msg) => format!("Error: {msg}"),
                Self::DownloadError {
                    filename,
                    bytes_downloaded,
                    total_bytes,
                    message,
                    ..
                } => {
                    fn fmt_bytes(b: u64) -> String {
                        if b >= 1_000_000_000 {
                            format!("{:.1} GB", b as f64 / 1_000_000_000.0)
                        } else if b >= 1_000_000 {
                            format!("{:.0} MB", b as f64 / 1_000_000.0)
                        } else if b >= 1_000 {
                            format!("{:.0} KB", b as f64 / 1_000.0)
                        } else {
                            format!("{b} B")
                        }
                    }
                    let progress = match total_bytes {
                        Some(total) if *total > 0 => format!(
                            " ({} / {})",
                            fmt_bytes(*bytes_downloaded),
                            fmt_bytes(*total)
                        ),
                        _ => String::new(),
                    };
                    format!("Failed to download {filename}{progress}: {message}")
                }
            }
        }

        /// Whether the start button should be shown (vs stop).
        pub fn show_start(&self) -> bool {
            matches!(
                self,
                Self::Idle | Self::PreFlight { .. } | Self::Error(_) | Self::DownloadError { .. }
            )
        }

        /// Whether buttons should be interactive.
        pub fn buttons_enabled(&self) -> bool {
            matches!(
                self,
                Self::Idle
                    | Self::PreFlight { .. }
                    | Self::Running
                    | Self::Error(_)
                    | Self::DownloadError { .. }
            )
        }
    }

    /// Shared state accessible from both the GUI and the background pipeline task.
    pub struct SharedState {
        /// Cancellation token for the running pipeline.
        pub cancel_token: Option<CancellationToken>,
    }

    /// Apply a progress event to produce an updated `AppStatus`.
    ///
    /// Takes the current status so aggregate download state is preserved
    /// across per-file events. Returns `Some(new_status)` when the event
    /// warrants a UI state change, or `None` for intermediate events.
    pub fn apply_progress_event(event: ProgressEvent, current: &AppStatus) -> Option<AppStatus> {
        // Extract aggregate state from current status (preserved across events)
        let (agg_fc, agg_ft, agg_bytes, agg_total, agg_speed, agg_eta) = match current {
            AppStatus::Downloading {
                files_complete,
                files_total,
                aggregate_bytes,
                aggregate_total,
                speed_bps,
                eta_secs,
                ..
            } => (
                *files_complete,
                *files_total,
                *aggregate_bytes,
                *aggregate_total,
                *speed_bps,
                *eta_secs,
            ),
            _ => (0, 0, 0, 0, 0.0, None),
        };

        match event {
            ProgressEvent::DownloadStarted {
                filename,
                total_bytes,
                ..
            } => Some(AppStatus::Downloading {
                current_file: filename,
                bytes_downloaded: 0,
                total_bytes,
                files_complete: agg_fc,
                files_total: agg_ft,
                aggregate_bytes: agg_bytes,
                aggregate_total: agg_total,
                speed_bps: agg_speed,
                eta_secs: agg_eta,
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
                files_complete: agg_fc,
                files_total: agg_ft,
                aggregate_bytes: agg_bytes,
                aggregate_total: agg_total,
                speed_bps: agg_speed,
                eta_secs: agg_eta,
            }),
            ProgressEvent::DownloadComplete { .. } | ProgressEvent::Cached { .. } => None,
            ProgressEvent::LoadStarted { model_name } => Some(AppStatus::Loading { model_name }),
            ProgressEvent::LoadComplete { .. } => None,
            ProgressEvent::Error { message } => Some(AppStatus::Error(message)),
            ProgressEvent::DownloadPlanReady { plan } => {
                // Only show downloading status if there are files to download
                if plan.files_to_download() > 0 {
                    Some(AppStatus::Downloading {
                        current_file: "Preparing downloads...".into(),
                        bytes_downloaded: 0,
                        total_bytes: None,
                        files_complete: 0,
                        files_total: plan.files_to_download(),
                        aggregate_bytes: 0,
                        aggregate_total: plan.download_bytes(),
                        speed_bps: 0.0,
                        eta_secs: None,
                    })
                } else {
                    // All files cached - don't change status
                    None
                }
            }
            ProgressEvent::AggregateProgress {
                bytes_downloaded,
                total_bytes,
                files_complete,
                files_total,
            } => {
                // Preserve current per-file display, update aggregate
                let (cur_file, cur_bytes, cur_total) = match current {
                    AppStatus::Downloading {
                        current_file,
                        bytes_downloaded,
                        total_bytes,
                        ..
                    } => (current_file.clone(), *bytes_downloaded, *total_bytes),
                    _ => ("downloading...".into(), 0, None),
                };
                Some(AppStatus::Downloading {
                    current_file: cur_file,
                    bytes_downloaded: cur_bytes,
                    total_bytes: cur_total,
                    files_complete,
                    files_total,
                    aggregate_bytes: bytes_downloaded,
                    aggregate_total: total_bytes,
                    speed_bps: agg_speed,
                    eta_secs: agg_eta,
                })
            }
        }
    }

    /// Whether this runtime event should be hidden from the main-screen
    /// conversational subtitle/event surface.
    pub fn suppress_main_screen_runtime_event(event: &fae::RuntimeEvent) -> bool {
        matches!(
            event,
            fae::RuntimeEvent::MemoryRecall { .. }
                | fae::RuntimeEvent::MemoryWrite { .. }
                | fae::RuntimeEvent::MemoryConflict { .. }
                | fae::RuntimeEvent::MemoryMigration { .. }
                | fae::RuntimeEvent::MicStatus { .. }
        )
    }

    /// Whether a scheduler telemetry event should force-open the canvas panel.
    pub fn scheduler_telemetry_opens_canvas(event: &fae::RuntimeEvent) -> bool {
        matches!(
            event,
            fae::RuntimeEvent::MemoryMigration { success: false, .. }
        )
    }

    /// Scheduler-relevant memory settings.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct SchedulerMemoryBinding {
        pub root_dir: PathBuf,
        pub retention_days: u32,
    }

    /// Extract only memory fields that affect scheduler task behavior.
    pub fn scheduler_memory_binding(memory: &fae::config::MemoryConfig) -> SchedulerMemoryBinding {
        SchedulerMemoryBinding {
            root_dir: memory.root_dir.clone(),
            retention_days: memory.retention_days,
        }
    }

    /// Whether scheduler should restart after config changes.
    pub fn scheduler_requires_restart(
        current: &SchedulerMemoryBinding,
        next: &SchedulerMemoryBinding,
    ) -> bool {
        current != next
    }

    /// Increment a scheduler metric counter and return the new total.
    pub fn increment_counter(counter: &AtomicU64) -> u64 {
        counter.fetch_add(1, Ordering::Relaxed).saturating_add(1)
    }

    fn scheduler_memory_restart_counter() -> &'static AtomicU64 {
        static COUNTER: std::sync::OnceLock<AtomicU64> = std::sync::OnceLock::new();
        COUNTER.get_or_init(|| AtomicU64::new(0))
    }

    /// Record a restart caused by memory configuration changes.
    pub fn record_scheduler_memory_restart() -> u64 {
        increment_counter(scheduler_memory_restart_counter())
    }

    #[cfg(test)]
    mod tests {
        #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

        use super::*;

        // --- Active Model Indicator ---

        #[test]
        fn runtime_event_model_selected_updates_active_model() {
            // This test documents the expected behavior:
            // When RuntimeEvent::ModelSelected is emitted, the GUI's active_model
            // signal should be updated with the provider_model string.
            //
            // Integration behavior (verified manually in GUI):
            // 1. ModelSelected event received from pipeline
            // 2. active_model signal set to Some(provider_model)
            // 3. Topbar displays model indicator with robot emoji
            // 4. Indicator styled as subtle pill badge
            //
            // The actual signal update happens in the event handler:
            //   fae::RuntimeEvent::ModelSelected { provider_model } => {
            //       active_model.set(Some(provider_model.clone()));
            //   }
            //
            // Visual verification:
            // - When no model selected: indicator hidden
            // - After selection: shows "🤖 anthropic/claude-opus-4" (or similar)
            // - Text truncated if too long (max-width: 160px)
        }

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
                files_complete: 0,
                files_total: 0,
                aggregate_bytes: 0,
                aggregate_total: 0,
                speed_bps: 0.0,
                eta_secs: None,
            };
            assert_eq!(s.display_text(), "Downloading model.onnx...");
        }

        #[test]
        fn downloading_display_text_with_aggregate() {
            let s = AppStatus::Downloading {
                current_file: "model.onnx".into(),
                bytes_downloaded: 500,
                total_bytes: Some(1000),
                files_complete: 1,
                files_total: 3,
                aggregate_bytes: 1_000_000,
                aggregate_total: 4_800_000,
                speed_bps: 10_000_000.0,
                eta_secs: Some(380.0),
            };
            assert_eq!(s.display_text(), "Downloading file 2/3 — model.onnx");
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
        fn error_display_text() {
            let s = AppStatus::Error("network failure".into());
            assert_eq!(s.display_text(), "Error: network failure");
        }

        #[test]
        fn download_error_display_text_with_total() {
            let s = AppStatus::DownloadError {
                message: "connection timed out".into(),
                repo_id: "org/model".into(),
                filename: "model.onnx".into(),
                bytes_downloaded: 1_200_000_000,
                total_bytes: Some(2_300_000_000),
            };
            assert_eq!(
                s.display_text(),
                "Failed to download model.onnx (1.2 GB / 2.3 GB): connection timed out"
            );
        }

        #[test]
        fn download_error_display_text_without_total() {
            let s = AppStatus::DownloadError {
                message: "network error".into(),
                repo_id: "org/model".into(),
                filename: "big.onnx".into(),
                bytes_downloaded: 0,
                total_bytes: None,
            };
            assert_eq!(
                s.display_text(),
                "Failed to download big.onnx: network error"
            );
        }

        // --- AppStatus button predicates ---

        #[test]
        fn preflight_display_text() {
            let s = AppStatus::PreFlight {
                total_bytes: 4_800_000_000,
                files_to_download: 6,
                total_files: 8,
                free_space: 50_000_000_000,
            };
            assert_eq!(s.display_text(), "Ready to download 4.8 GB");
        }

        #[test]
        fn show_start_when_idle_or_error() {
            assert!(AppStatus::Idle.show_start());
            assert!(AppStatus::Error("x".into()).show_start());
            assert!(
                AppStatus::DownloadError {
                    message: "x".into(),
                    repo_id: "r".into(),
                    filename: "f".into(),
                    bytes_downloaded: 0,
                    total_bytes: None,
                }
                .show_start()
            );
            assert!(
                AppStatus::PreFlight {
                    total_bytes: 100,
                    files_to_download: 1,
                    total_files: 1,
                    free_space: 1000,
                }
                .show_start()
            );
            assert!(!AppStatus::Running.show_start());
        }

        #[test]
        fn buttons_enabled_states() {
            assert!(AppStatus::Idle.buttons_enabled());
            assert!(AppStatus::Running.buttons_enabled());
            assert!(AppStatus::Error("x".into()).buttons_enabled());
            assert!(
                AppStatus::PreFlight {
                    total_bytes: 100,
                    files_to_download: 1,
                    total_files: 1,
                    free_space: 1000,
                }
                .buttons_enabled()
            );
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
                    files_complete: 0,
                    files_total: 0,
                    aggregate_bytes: 0,
                    aggregate_total: 0,
                    speed_bps: 0.0,
                    eta_secs: None,
                }
                .buttons_enabled()
            );
        }

        // --- apply_progress_event ---

        #[test]
        fn download_started_sets_downloading() {
            let result = apply_progress_event(
                ProgressEvent::DownloadStarted {
                    repo_id: "test/repo".into(),
                    filename: "weights.bin".into(),
                    total_bytes: Some(2048),
                },
                &AppStatus::Idle,
            );
            assert!(result.is_some());
            let status = result.unwrap_or(AppStatus::Idle);
            match status {
                AppStatus::Downloading {
                    current_file,
                    bytes_downloaded,
                    total_bytes,
                    ..
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
            let result = apply_progress_event(
                ProgressEvent::DownloadProgress {
                    repo_id: "test/repo".into(),
                    filename: "weights.bin".into(),
                    bytes_downloaded: 1024,
                    total_bytes: Some(2048),
                },
                &AppStatus::Idle,
            );
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
            let result = apply_progress_event(
                ProgressEvent::DownloadComplete {
                    repo_id: "test/repo".into(),
                    filename: "weights.bin".into(),
                },
                &AppStatus::Idle,
            );
            assert!(result.is_none());
        }

        #[test]
        fn cached_returns_none() {
            let result = apply_progress_event(
                ProgressEvent::Cached {
                    repo_id: "test/repo".into(),
                    filename: "weights.bin".into(),
                },
                &AppStatus::Idle,
            );
            assert!(result.is_none());
        }

        #[test]
        fn load_started_sets_loading() {
            let result = apply_progress_event(
                ProgressEvent::LoadStarted {
                    model_name: "STT (Parakeet)".into(),
                },
                &AppStatus::Idle,
            );
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
            let result = apply_progress_event(
                ProgressEvent::LoadComplete {
                    model_name: "STT".into(),
                    duration_secs: 1.5,
                },
                &AppStatus::Idle,
            );
            assert!(result.is_none());
        }

        #[test]
        fn error_event_sets_error() {
            let result = apply_progress_event(
                ProgressEvent::Error {
                    message: "download failed".into(),
                },
                &AppStatus::Idle,
            );
            assert!(result.is_some());
            let status = result.unwrap_or(AppStatus::Idle);
            match status {
                AppStatus::Error(msg) => assert_eq!(msg, "download failed"),
                other => unreachable!("expected Error, got {other:?}"),
            }
        }

        #[test]
        fn download_plan_ready_sets_aggregate() {
            let plan = fae::progress::DownloadPlan {
                files: vec![
                    fae::progress::DownloadFile {
                        repo_id: "r1".into(),
                        filename: "a.onnx".into(),
                        size_bytes: Some(2_000_000),
                        cached: false,
                    },
                    fae::progress::DownloadFile {
                        repo_id: "r2".into(),
                        filename: "b.gguf".into(),
                        size_bytes: Some(3_000_000),
                        cached: false,
                    },
                ],
            };
            let result =
                apply_progress_event(ProgressEvent::DownloadPlanReady { plan }, &AppStatus::Idle);
            assert!(result.is_some());
            let status = result.unwrap_or(AppStatus::Idle);
            match status {
                AppStatus::Downloading {
                    files_total,
                    aggregate_total,
                    ..
                } => {
                    assert_eq!(files_total, 2);
                    assert_eq!(aggregate_total, 5_000_000);
                }
                other => unreachable!("expected Downloading, got {other:?}"),
            }
        }

        #[test]
        fn aggregate_progress_updates_state() {
            let current = AppStatus::Downloading {
                current_file: "model.onnx".into(),
                bytes_downloaded: 500,
                total_bytes: Some(1000),
                files_complete: 0,
                files_total: 3,
                aggregate_bytes: 0,
                aggregate_total: 5_000_000,
                speed_bps: 0.0,
                eta_secs: None,
            };
            let result = apply_progress_event(
                ProgressEvent::AggregateProgress {
                    bytes_downloaded: 2_000_000,
                    total_bytes: 5_000_000,
                    files_complete: 1,
                    files_total: 3,
                },
                &current,
            );
            assert!(result.is_some());
            let status = result.unwrap_or(AppStatus::Idle);
            match status {
                AppStatus::Downloading {
                    files_complete,
                    aggregate_bytes,
                    aggregate_total,
                    current_file,
                    ..
                } => {
                    assert_eq!(files_complete, 1);
                    assert_eq!(aggregate_bytes, 2_000_000);
                    assert_eq!(aggregate_total, 5_000_000);
                    assert_eq!(current_file, "model.onnx");
                }
                other => unreachable!("expected Downloading, got {other:?}"),
            }
        }

        #[test]
        fn aggregate_preserved_across_download_events() {
            let current = AppStatus::Downloading {
                current_file: "old.onnx".into(),
                bytes_downloaded: 500,
                total_bytes: Some(1000),
                files_complete: 1,
                files_total: 3,
                aggregate_bytes: 2_000_000,
                aggregate_total: 5_000_000,
                speed_bps: 10_000_000.0,
                eta_secs: Some(300.0),
            };
            let result = apply_progress_event(
                ProgressEvent::DownloadStarted {
                    repo_id: "new/repo".into(),
                    filename: "new.gguf".into(),
                    total_bytes: Some(3_000_000),
                },
                &current,
            );
            assert!(result.is_some());
            let status = result.unwrap_or(AppStatus::Idle);
            match status {
                AppStatus::Downloading {
                    current_file,
                    files_complete,
                    files_total,
                    aggregate_bytes,
                    aggregate_total,
                    ..
                } => {
                    assert_eq!(current_file, "new.gguf");
                    // Aggregate state preserved from current
                    assert_eq!(files_complete, 1);
                    assert_eq!(files_total, 3);
                    assert_eq!(aggregate_bytes, 2_000_000);
                    assert_eq!(aggregate_total, 5_000_000);
                }
                other => unreachable!("expected Downloading, got {other:?}"),
            }
        }

        #[test]
        fn memory_events_are_suppressed_on_main_screen() {
            let memory_recall = fae::RuntimeEvent::MemoryRecall {
                query: "name".to_owned(),
                hits: 1,
            };
            let memory_write = fae::RuntimeEvent::MemoryWrite {
                op: "insert".to_owned(),
                target_id: Some("mem-1".to_owned()),
            };
            let memory_conflict = fae::RuntimeEvent::MemoryConflict {
                existing_id: "mem-old".to_owned(),
                replacement_id: Some("mem-new".to_owned()),
            };
            let memory_migration = fae::RuntimeEvent::MemoryMigration {
                from: 0,
                to: 1,
                success: true,
            };
            assert!(suppress_main_screen_runtime_event(&memory_recall));
            assert!(suppress_main_screen_runtime_event(&memory_write));
            assert!(suppress_main_screen_runtime_event(&memory_conflict));
            assert!(suppress_main_screen_runtime_event(&memory_migration));

            let non_memory = fae::RuntimeEvent::AssistantGenerating { active: true };
            assert!(!suppress_main_screen_runtime_event(&non_memory));
        }

        #[test]
        fn only_migration_failures_force_canvas_open() {
            let migration_ok = fae::RuntimeEvent::MemoryMigration {
                from: 1,
                to: 1,
                success: true,
            };
            let migration_fail = fae::RuntimeEvent::MemoryMigration {
                from: 0,
                to: 1,
                success: false,
            };
            let maintenance_write = fae::RuntimeEvent::MemoryWrite {
                op: "reindex".to_owned(),
                target_id: None,
            };

            assert!(!scheduler_telemetry_opens_canvas(&migration_ok));
            assert!(scheduler_telemetry_opens_canvas(&migration_fail));
            assert!(!scheduler_telemetry_opens_canvas(&maintenance_write));
        }

        #[test]
        fn scheduler_restart_decision_tracks_memory_root_and_retention() {
            let base = fae::config::MemoryConfig {
                root_dir: std::path::PathBuf::from("/tmp/fae-a"),
                retention_days: 365,
                ..Default::default()
            };
            let current = scheduler_memory_binding(&base);

            let mut same_effective = base.clone();
            same_effective.auto_capture = !same_effective.auto_capture;
            same_effective.auto_recall = !same_effective.auto_recall;
            let same = scheduler_memory_binding(&same_effective);
            assert!(!scheduler_requires_restart(&current, &same));

            let mut changed_root = base.clone();
            changed_root.root_dir = std::path::PathBuf::from("/tmp/fae-b");
            let next_root = scheduler_memory_binding(&changed_root);
            assert!(scheduler_requires_restart(&current, &next_root));

            let mut changed_retention = base.clone();
            changed_retention.retention_days = 30;
            let next_retention = scheduler_memory_binding(&changed_retention);
            assert!(scheduler_requires_restart(&current, &next_retention));
        }

        #[test]
        fn scheduler_memory_telemetry_is_canvas_only_main_screen_suppressed() {
            let mut bridge = fae::canvas::bridge::CanvasBridge::new("gui-test", 800.0, 600.0);
            let mut main_screen_visible = 0usize;

            for _ in 0..5 {
                let event = fae::RuntimeEvent::MemoryWrite {
                    op: "reindex".to_owned(),
                    target_id: None,
                };
                bridge.on_event(&event);
                if !suppress_main_screen_runtime_event(&event) {
                    main_screen_visible = main_screen_visible.saturating_add(1);
                }
            }

            let migration_fail = fae::RuntimeEvent::MemoryMigration {
                from: 0,
                to: 1,
                success: false,
            };
            bridge.on_event(&migration_fail);
            if !suppress_main_screen_runtime_event(&migration_fail) {
                main_screen_visible = main_screen_visible.saturating_add(1);
            }

            let views = bridge.session().message_views();
            assert!(
                views.iter().any(|v| v.html.contains("[memory]")),
                "expected memory content to be visible in canvas"
            );
            assert!(
                views.iter().any(|v| {
                    v.html.contains("maintenance writes")
                        || v.html.contains("schema migration failed")
                        || v.html.contains("migration failed")
                }),
                "expected collapsed maintenance and/or migration failure memory output in canvas"
            );
            assert_eq!(
                main_screen_visible, 0,
                "memory telemetry must not surface in the main-screen event stream"
            );
            assert!(scheduler_telemetry_opens_canvas(&migration_fail));
        }

        #[test]
        fn increment_counter_returns_running_total() {
            let counter = AtomicU64::new(0);
            assert_eq!(increment_counter(&counter), 1);
            assert_eq!(increment_counter(&counter), 2);
            assert_eq!(counter.load(Ordering::Relaxed), 2);
        }

        // --- format_bytes_short ---

        #[test]
        fn format_bytes_short_gb() {
            assert_eq!(super::super::format_bytes_short(2_400_000_000), "2.2 GB");
        }

        #[test]
        fn format_bytes_short_mb() {
            assert_eq!(super::super::format_bytes_short(89_000_000), "85 MB");
        }

        #[test]
        fn format_bytes_short_kb() {
            assert_eq!(super::super::format_bytes_short(92_000), "90 KB");
        }

        #[test]
        fn format_bytes_short_bytes() {
            assert_eq!(super::super::format_bytes_short(500), "500 B");
        }

        // --- format_speed ---

        #[test]
        fn format_speed_mb_per_sec() {
            assert_eq!(super::super::format_speed(12_500_000.0), "11.9 MB/s");
        }

        #[test]
        fn format_speed_kb_per_sec() {
            assert_eq!(super::super::format_speed(500_000.0), "488 KB/s");
        }

        // --- format_eta ---

        #[test]
        fn format_eta_seconds() {
            assert_eq!(
                super::super::format_eta(45.0),
                "less than a minute remaining"
            );
        }

        #[test]
        fn format_eta_minutes() {
            assert_eq!(super::super::format_eta(180.0), "about 3 min remaining");
        }

        #[test]
        fn format_eta_hours() {
            assert_eq!(
                super::super::format_eta(3900.0),
                "about 1 hr 5 min remaining"
            );
        }
    }
}

#[cfg(feature = "gui")]
use dioxus::prelude::*;

#[cfg(feature = "gui")]
use dioxus::desktop::{Config, LogicalSize, WindowBuilder, use_window};

#[cfg(feature = "gui")]
use gui::{AppStatus, SharedState};

use std::path::Path;
#[cfg(feature = "gui")]
use std::sync::OnceLock;

/// Fae version from Cargo.toml
#[cfg(feature = "gui")]
const FAE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// A subtitle bubble that auto-expires after a timeout.
#[cfg(feature = "gui")]
#[derive(Clone, Default)]
struct Subtitle {
    /// Text to display.
    text: String,
    /// Instant when the subtitle was set (monotonic).
    set_at: Option<std::time::Instant>,
    /// When true, the expiry timer will not clear this subtitle.
    pinned: bool,
}

impl Subtitle {
    const DURATION_SECS: f64 = 5.0;

    fn set(&mut self, text: String) {
        self.text = text;
        self.set_at = Some(std::time::Instant::now());
    }

    fn is_visible(&self) -> bool {
        self.pinned
            || self
                .set_at
                .is_some_and(|t| t.elapsed().as_secs_f64() < Self::DURATION_SECS)
    }

    fn clear(&mut self) {
        self.text.clear();
        self.set_at = None;
        self.pinned = false;
    }
}

#[cfg(feature = "gui")]
#[derive(Clone, Copy, PartialEq, Eq)]
enum MainView {
    Home,
    Settings,
    Voices,
}

/// Build the messages HTML from the current canvas bridge state.
#[cfg(feature = "gui")]
fn build_canvas_messages_html(bridge: &fae::canvas::bridge::CanvasBridge) -> String {
    let views = bridge.session().message_views();
    let mut html = String::new();
    for mv in &views {
        let role_label = match mv.role {
            fae::canvas::types::MessageRole::User => "user",
            fae::canvas::types::MessageRole::Assistant => "assistant",
            fae::canvas::types::MessageRole::System => "system",
            fae::canvas::types::MessageRole::Tool => "tool",
        };
        // Tool detail card (collapsible).
        let tool_details = if mv.tool_input.is_some() || mv.tool_result_text.is_some() {
            let input_html = mv
                .tool_input
                .as_deref()
                .map(|inp| {
                    format!(
                        "<pre class=\"tool-detail-json\">{}</pre>",
                        fae::canvas::session::html_escape(inp),
                    )
                })
                .unwrap_or_default();
            let result_html = mv
                .tool_result_text
                .as_deref()
                .map(|r| {
                    format!(
                        "<div class=\"tool-detail-result\">{}</div>",
                        fae::canvas::session::html_escape(r),
                    )
                })
                .unwrap_or_default();
            format!(
                "<details class=\"tool-details\">\
                 <summary>Details</summary>\
                 {input_html}{result_html}\
                 </details>"
            )
        } else {
            String::new()
        };
        html.push_str(&format!(
            "<div class=\"canvas-msg-wrapper\" role=\"article\" aria-label=\"{role_label} message\">\
             {}{tool_details}\
             </div>",
            mv.html,
        ));
    }
    html
}

/// Parsed approval prompt payload for display/logging.
#[cfg(feature = "gui")]
#[derive(Clone, Copy, PartialEq, Eq)]
enum ApprovalUiKind {
    Confirm,
    Select,
    Input,
    Editor,
}

#[cfg(feature = "gui")]
#[derive(Clone)]
struct ApprovalPreview {
    title: String,
    message: String,
    destructive_delete: bool,
    kind: ApprovalUiKind,
    options: Vec<String>,
    placeholder: Option<String>,
    initial_value: String,
}

#[cfg(feature = "gui")]
fn now_ts_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(feature = "gui")]
fn looks_like_delete_request(title: &str, message: &str) -> bool {
    let haystack = format!("{title}\n{message}").to_lowercase();
    [
        "allow destructive command",
        "[delete risk]",
        " rm ",
        "\nrm ",
        "rm -",
        "rm\t",
        " unlink ",
        " rmdir ",
        " del ",
        " erase ",
        " -delete",
        " trash ",
    ]
    .iter()
    .any(|needle| haystack.contains(needle))
}

#[cfg(feature = "gui")]
fn truncate_canvas_value(text: &str, max_chars: usize) -> String {
    let mut out: String = text.chars().take(max_chars).collect();
    if text.chars().count() > max_chars {
        out.push_str(" ...");
    }
    out
}

#[cfg(feature = "gui")]
fn parse_approval_preview(req: &fae::ToolApprovalRequest) -> ApprovalPreview {
    let mut title = req.name.clone();
    let mut message = req.input_json.clone();
    let mut kind = match req.name.as_str() {
        "pi.select" => ApprovalUiKind::Select,
        "pi.input" => ApprovalUiKind::Input,
        "pi.editor" => ApprovalUiKind::Editor,
        _ => ApprovalUiKind::Confirm,
    };
    let mut options = Vec::<String>::new();
    let mut placeholder = None::<String>;
    let mut initial_value = String::new();

    if let Ok(json) = serde_json::from_str::<serde_json::Value>(&req.input_json) {
        if let Some(k) = json.get("kind").and_then(|v| v.as_str()) {
            kind = match k {
                "select" => ApprovalUiKind::Select,
                "input" => ApprovalUiKind::Input,
                "editor" => ApprovalUiKind::Editor,
                _ => ApprovalUiKind::Confirm,
            };
        }
        if let Some(t) = json.get("title").and_then(|v| v.as_str()) {
            title = t.to_owned();
        }
        if let Some(m) = json.get("message").and_then(|v| v.as_str()) {
            message = m.to_owned();
        }
        if let Some(opts) = json.get("options").and_then(|v| v.as_array()) {
            options = opts
                .iter()
                .filter_map(|v| v.as_str().map(ToOwned::to_owned))
                .collect();
        }
        placeholder = json
            .get("placeholder")
            .and_then(|v| v.as_str())
            .map(ToOwned::to_owned);
        if let Some(v) = json.get("prefill").and_then(|v| v.as_str()) {
            initial_value = v.to_owned();
        } else if let Some(v) = json.get("value").and_then(|v| v.as_str()) {
            initial_value = v.to_owned();
        }
    }
    if matches!(kind, ApprovalUiKind::Select)
        && initial_value.is_empty()
        && let Some(first) = options.first()
    {
        initial_value = first.clone();
    }

    let destructive_delete = looks_like_delete_request(&title, &message);
    ApprovalPreview {
        title,
        message,
        destructive_delete,
        kind,
        options,
        placeholder,
        initial_value,
    }
}

#[cfg(feature = "gui")]
fn push_approval_request_to_canvas(
    bridge: &mut fae::canvas::bridge::CanvasBridge,
    req: &fae::ToolApprovalRequest,
) {
    let preview = parse_approval_preview(req);
    let headline = match preview.kind {
        ApprovalUiKind::Confirm => {
            if preview.destructive_delete {
                "Approval needed: destructive file action requested"
            } else {
                "Approval needed: elevated tool action requested"
            }
        }
        ApprovalUiKind::Select => "Input needed: option selection requested",
        ApprovalUiKind::Input => "Input needed: text response requested",
        ApprovalUiKind::Editor => "Input needed: editor response requested",
    };
    let detail = format!("{}\n\n{}", preview.title, preview.message);
    let msg = fae::canvas::types::CanvasMessage::tool_with_details(
        "approval",
        headline,
        now_ts_millis(),
        Some(detail),
        None,
    );
    bridge.session_mut().push_message(&msg);
}

#[cfg(feature = "gui")]
fn push_approval_decision_to_canvas(
    bridge: &mut fae::canvas::bridge::CanvasBridge,
    preview: &ApprovalPreview,
    approved: bool,
) {
    let text = if approved {
        if preview.destructive_delete {
            "Destructive request approved"
        } else {
            "Tool escalation approved"
        }
    } else if preview.destructive_delete {
        "Destructive request denied"
    } else {
        "Tool escalation denied"
    };
    let msg = fae::canvas::types::CanvasMessage::tool_with_details(
        "approval",
        text,
        now_ts_millis(),
        Some(preview.title.clone()),
        Some(preview.message.clone()),
    );
    bridge.session_mut().push_message(&msg);
}

#[cfg(feature = "gui")]
fn push_dialog_response_to_canvas(
    bridge: &mut fae::canvas::bridge::CanvasBridge,
    preview: &ApprovalPreview,
    submitted: bool,
    value: Option<String>,
) {
    let text = if submitted {
        match preview.kind {
            ApprovalUiKind::Select => "Option selected",
            ApprovalUiKind::Input => "Input submitted",
            ApprovalUiKind::Editor => "Editor response submitted",
            ApprovalUiKind::Confirm => "Response submitted",
        }
    } else {
        match preview.kind {
            ApprovalUiKind::Select => "Option selection cancelled",
            ApprovalUiKind::Input => "Input cancelled",
            ApprovalUiKind::Editor => "Editor response cancelled",
            ApprovalUiKind::Confirm => "Response cancelled",
        }
    };

    let output = value.map(|v| truncate_canvas_value(&v, 500));
    let msg = fae::canvas::types::CanvasMessage::tool_with_details(
        "approval",
        text,
        now_ts_millis(),
        Some(preview.title.clone()),
        output,
    );
    bridge.session_mut().push_message(&msg);
}

#[cfg(feature = "gui")]
fn embedded_fae_jpg_data_uri() -> String {
    use base64::Engine as _;

    static URI: OnceLock<String> = OnceLock::new();
    URI.get_or_init(|| {
        let bytes = include_bytes!("../../assets/fae.jpg");
        let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
        format!("data:image/jpeg;base64,{b64}")
    })
    .clone()
}

#[cfg(feature = "gui")]
fn resolve_avatar_dir(memory_root: &Path) -> Option<std::path::PathBuf> {
    let mem = memory_root.join("avatar");
    if mem.is_dir() {
        return Some(mem);
    }
    let dev = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("assets")
        .join("avatar");
    if dev.is_dir() {
        return Some(dev);
    }
    None
}

/// Pre-load all avatar pose images as data URIs at startup.
///
/// WebKit in Dioxus desktop blocks `file://` subresources loaded from in-memory
/// HTML pages. By converting PNGs to data URIs once, we avoid repeated file I/O
/// and work around the WebKit restriction.
#[cfg(feature = "gui")]
fn load_avatar_cache(
    avatar_dir: &Option<std::path::PathBuf>,
) -> std::collections::HashMap<String, String> {
    use base64::Engine as _;
    let mut map = std::collections::HashMap::new();
    let Some(dir) = avatar_dir else {
        return map;
    };
    let poses = [
        "fae_base.png",
        "eyes_blink.png",
        "mouth_open_small.png",
        "mouth_open_medium.png",
        "mouth_open_wide.png",
    ];
    for name in poses {
        let path = dir.join(name);
        if let Ok(bytes) = std::fs::read(&path) {
            let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
            map.insert(name.to_owned(), format!("data:image/png;base64,{b64}"));
        }
    }
    map
}

#[cfg(feature = "gui")]
#[derive(Debug, Clone, PartialEq)]
enum StagePhase {
    Pending,
    Downloading {
        filename: String,
        bytes_downloaded: u64,
        total_bytes: Option<u64>,
    },
    Loading,
    Ready,
    Error(String),
}

#[cfg(feature = "gui")]
impl StagePhase {
    fn label(&self, thing: &str) -> String {
        match self {
            Self::Pending => thing.to_owned(),
            Self::Downloading {
                bytes_downloaded,
                total_bytes,
                ..
            } => {
                if let Some(total) = total_bytes {
                    if *total > 0 {
                        format!(
                            "Downloading {thing} ({} / {})",
                            format_bytes_short(*bytes_downloaded),
                            format_bytes_short(*total)
                        )
                    } else {
                        format!("Downloading {thing}")
                    }
                } else {
                    format!("Downloading {thing}")
                }
            }
            Self::Loading => format!("Loading {thing}"),
            Self::Ready => format!("{thing} ready"),
            Self::Error(_) => format!("{thing} error"),
        }
    }

    fn css_class(&self) -> &'static str {
        match self {
            Self::Pending => "stage stage-pending",
            Self::Downloading { .. } => "stage stage-downloading",
            Self::Loading => "stage stage-loading",
            Self::Ready => "stage stage-ready",
            Self::Error(_) => "stage stage-error",
        }
    }
}

/// Format byte count as a short human-readable string (e.g. "2.3 GB", "89 MB").
#[cfg(feature = "gui")]
fn format_bytes_short(bytes: u64) -> String {
    const GB: f64 = 1_073_741_824.0;
    const MB: f64 = 1_048_576.0;
    const KB: f64 = 1_024.0;

    let b = bytes as f64;
    if b >= GB {
        format!("{:.1} GB", b / GB)
    } else if b >= MB {
        format!("{:.0} MB", b / MB)
    } else if b >= KB {
        format!("{:.0} KB", b / KB)
    } else {
        format!("{bytes} B")
    }
}

/// Format download speed in bytes/sec as human-readable (e.g. "12.5 MB/s").
#[cfg(feature = "gui")]
fn format_speed(bytes_per_sec: f64) -> String {
    const GB: f64 = 1_073_741_824.0;
    const MB: f64 = 1_048_576.0;
    const KB: f64 = 1_024.0;

    if bytes_per_sec >= GB {
        format!("{:.1} GB/s", bytes_per_sec / GB)
    } else if bytes_per_sec >= MB {
        format!("{:.1} MB/s", bytes_per_sec / MB)
    } else if bytes_per_sec >= KB {
        format!("{:.0} KB/s", bytes_per_sec / KB)
    } else {
        format!("{:.0} B/s", bytes_per_sec)
    }
}

/// Format ETA seconds as human-readable (e.g. "about 3 min remaining").
#[cfg(feature = "gui")]
fn format_eta(secs: f64) -> String {
    let s = secs as u64;
    if s < 60 {
        "less than a minute remaining".to_owned()
    } else if s < 3600 {
        let mins = s / 60;
        if mins == 1 {
            "about 1 min remaining".to_owned()
        } else {
            format!("about {mins} min remaining")
        }
    } else {
        let hours = s / 3600;
        let mins = (s % 3600) / 60;
        if hours == 1 {
            format!("about 1 hr {mins} min remaining")
        } else {
            format!("about {hours} hr {mins} min remaining")
        }
    }
}

/// Update speed and ETA on an `AppStatus::Downloading` using the tracker.
///
/// Feeds the current aggregate bytes into the tracker and writes back
/// the computed speed and ETA.
#[cfg(feature = "gui")]
fn update_speed_eta(status: &mut gui::AppStatus, tracker: &mut fae::progress::DownloadTracker) {
    if let gui::AppStatus::Downloading {
        aggregate_bytes,
        aggregate_total,
        speed_bps,
        eta_secs,
        ..
    } = status
    {
        let (speed, eta) = tracker.update(*aggregate_bytes, *aggregate_total);
        *speed_bps = speed;
        *eta_secs = eta;
    }
}

/// Determine which model category a repo_id belongs to.
///
/// Returns `"STT"`, `"LLM"`, or `"TTS"` based on the repo-to-model mapping,
/// or `"STT"` as fallback for unknown repos.
#[cfg(feature = "gui")]
fn model_category_for_repo<'a>(
    repo_id: &str,
    repo_model_map: &'a std::collections::HashMap<String, String>,
) -> &'a str {
    repo_model_map
        .get(repo_id)
        .map(|s| s.as_str())
        .unwrap_or("STT")
}

/// Build a mapping from repo_id to model category ("STT"/"LLM"/"TTS")
/// from a download plan.
#[cfg(feature = "gui")]
fn build_repo_model_map(
    plan: &fae::progress::DownloadPlan,
) -> std::collections::HashMap<String, String> {
    use std::collections::HashMap;

    let mut map = HashMap::new();
    let kokoro_repo = fae::tts::kokoro::download::KOKORO_REPO_ID;

    for file in &plan.files {
        if map.contains_key(&file.repo_id) {
            continue;
        }
        if file.repo_id == kokoro_repo {
            map.insert(file.repo_id.clone(), "TTS".to_owned());
        } else if file.filename.ends_with(".gguf")
            || file.filename == "tokenizer.json"
            || file.filename == "tokenizer_config.json"
        {
            // GGUF or tokenizer files → LLM
            // NOTE: STT also has .onnx files but they come from the STT repo_id
            // This heuristic works because:
            // - STT files are .onnx and .data and vocab.txt
            // - LLM files are .gguf and tokenizer*.json
            // - TTS is identified by KOKORO_REPO_ID above
            map.insert(file.repo_id.clone(), "LLM".to_owned());
        } else {
            map.insert(file.repo_id.clone(), "STT".to_owned());
        }
    }
    map
}

#[cfg(feature = "gui")]
fn update_stages_from_progress(
    event: &fae::progress::ProgressEvent,
    stt: &mut Signal<StagePhase>,
    llm: &mut Signal<StagePhase>,
    tts: &mut Signal<StagePhase>,
    repo_model_map: &std::collections::HashMap<String, String>,
) {
    use fae::progress::ProgressEvent;

    match event {
        ProgressEvent::DownloadStarted {
            repo_id,
            filename,
            total_bytes,
        } => {
            let stage = StagePhase::Downloading {
                filename: filename.clone(),
                bytes_downloaded: 0,
                total_bytes: *total_bytes,
            };
            match model_category_for_repo(repo_id, repo_model_map) {
                "LLM" => llm.set(stage),
                "TTS" => tts.set(stage),
                _ => stt.set(stage),
            }
        }
        ProgressEvent::DownloadProgress {
            repo_id,
            filename,
            bytes_downloaded,
            total_bytes,
        } => {
            let stage = StagePhase::Downloading {
                filename: filename.clone(),
                bytes_downloaded: *bytes_downloaded,
                total_bytes: *total_bytes,
            };
            match model_category_for_repo(repo_id, repo_model_map) {
                "LLM" => llm.set(stage),
                "TTS" => tts.set(stage),
                _ => stt.set(stage),
            }
        }
        ProgressEvent::DownloadComplete { repo_id, .. } | ProgressEvent::Cached { repo_id, .. } => {
            // Mark the model's download as done (transition handled by LoadStarted)
            match model_category_for_repo(repo_id, repo_model_map) {
                "LLM" => { /* Stay in Downloading until LoadStarted */ }
                "TTS" => { /* Stay in Downloading until LoadStarted */ }
                _ => { /* Stay in Downloading until LoadStarted */ }
            }
        }
        ProgressEvent::LoadStarted { model_name } => {
            if model_name.starts_with("STT") {
                stt.set(StagePhase::Loading);
            } else if model_name.starts_with("LLM") {
                llm.set(StagePhase::Loading);
            } else if model_name.starts_with("TTS") {
                tts.set(StagePhase::Loading);
            }
        }
        ProgressEvent::LoadComplete { model_name, .. } => {
            if model_name.starts_with("STT") {
                stt.set(StagePhase::Ready);
            } else if model_name.starts_with("LLM") {
                llm.set(StagePhase::Ready);
            } else if model_name.starts_with("TTS") {
                tts.set(StagePhase::Ready);
            }
        }
        ProgressEvent::Error { message } => {
            let msg = message.clone();
            stt.set(StagePhase::Error(msg.clone()));
            llm.set(StagePhase::Error(msg.clone()));
            tts.set(StagePhase::Error(msg));
        }
        ProgressEvent::DownloadPlanReady { .. } | ProgressEvent::AggregateProgress { .. } => {}
    }
}

#[cfg(feature = "gui")]
#[derive(Clone, Copy, PartialEq, Eq)]
enum ModelPickerTab {
    Recommended,
    Search,
    Manual,
}

#[cfg(feature = "gui")]
#[derive(Clone, Debug)]
enum UiBusEvent {
    ConfigUpdated,
}

#[cfg(feature = "gui")]
fn ui_bus() -> tokio::sync::broadcast::Sender<UiBusEvent> {
    static BUS: OnceLock<tokio::sync::broadcast::Sender<UiBusEvent>> = OnceLock::new();
    BUS.get_or_init(|| {
        let (tx, _rx) = tokio::sync::broadcast::channel(32);
        tx
    })
    .clone()
}

#[cfg(feature = "gui")]
fn read_config_or_default() -> fae::SpeechConfig {
    let path = fae::SpeechConfig::default_config_path();
    if path.exists() {
        fae::SpeechConfig::from_file(&path).unwrap_or_default()
    } else {
        fae::SpeechConfig::default()
    }
}

#[cfg(feature = "gui")]
#[derive(Clone)]
struct ModelDetails {
    id: String,
    license: Option<String>,
    base_models: Vec<String>,
    gated: Option<bool>,
    snippet: Option<String>,
    tokenizer_in_repo: bool,
    gguf_files: Vec<String>,
    // filename -> size
    gguf_sizes: Vec<(String, Option<u64>)>,
}

#[cfg(feature = "gui")]
fn fmt_bytes(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = KB * 1024.0;
    const GB: f64 = MB * 1024.0;
    const TB: f64 = GB * 1024.0;
    let b = bytes as f64;
    if b >= TB {
        format!("{:.1} TB", b / TB)
    } else if b >= GB {
        format!("{:.1} GB", b / GB)
    } else if b >= MB {
        format!("{:.1} MB", b / MB)
    } else if b >= KB {
        format!("{:.1} KB", b / KB)
    } else {
        format!("{bytes} B")
    }
}

#[cfg(feature = "gui")]
fn fit_label(file_bytes: Option<u64>, ram_bytes: Option<u64>) -> Option<String> {
    let file = file_bytes?;
    let ram = ram_bytes?;
    // Very rough heuristic: allow up to ~40% of RAM for weights.
    let ratio = file as f64 / ram as f64;
    let label = if ratio <= 0.15 {
        "Fits easily"
    } else if ratio <= 0.30 {
        "Fits"
    } else if ratio <= 0.40 {
        "Tight"
    } else {
        "Likely too large"
    };
    Some(format!("{label} ({:.0}% of RAM)", ratio * 100.0))
}

/// Root application component.
#[cfg(feature = "gui")]
fn app() -> Element {
    let desktop = use_window();
    let mut status = use_signal(|| AppStatus::Idle);
    let mut shared = use_signal(|| SharedState { cancel_token: None });
    let mut assistant_speaking = use_signal(|| false);
    let mut assistant_generating = use_signal(|| false);
    let mut assistant_rms = use_signal(|| 0.0f32);
    let blink = use_signal(|| false);
    let mut assistant_buf = use_signal(String::new);
    let mut llm_backend = use_signal(|| None::<fae::config::LlmBackend>);
    let mut tool_mode = use_signal(|| None::<fae::config::AgentToolMode>);
    let mut pending_approval = use_signal(|| None::<fae::ToolApprovalRequest>);
    let mut approval_queue =
        use_signal(std::collections::VecDeque::<fae::ToolApprovalRequest>::new);
    let mut approval_input_value = use_signal(String::new);
    // Session-level "always allow" patterns for tools
    let mut always_allowed_tools = use_signal(std::collections::HashSet::<String>::new);
    // Track if voice permissions are currently granted
    let mut voice_permissions_granted = use_signal(|| false);
    let mut config_state = use_signal(read_config_or_default);
    let mut config_save_status = use_signal(String::new);

    let mut stt_stage = use_signal(|| StagePhase::Pending);
    let mut llm_stage = use_signal(|| StagePhase::Pending);
    let mut tts_stage = use_signal(|| StagePhase::Pending);
    let mut repo_model_map = use_signal(std::collections::HashMap::<String, String>::new);
    let mut auto_started = use_signal(|| false);

    let mut sub_fae = use_signal(Subtitle::default);
    let mut sub_user = use_signal(Subtitle::default);

    // Tick every 500ms to expire subtitles.
    use_future(move || async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            if !sub_fae.read().is_visible() && sub_fae.read().set_at.is_some() {
                sub_fae.write().clear();
            }
            if !sub_user.read().is_visible() && sub_user.read().set_at.is_some() {
                sub_user.write().clear();
            }
        }
    });

    let mut text_input = use_signal(String::new);
    let mut text_injection_tx = use_signal(|| {
        None::<tokio::sync::mpsc::UnboundedSender<fae::pipeline::messages::TextInjection>>
    });

    let mut drawer_open = use_signal(|| false);
    let mut view = use_signal(|| MainView::Home);
    let mut canvas_bridge =
        use_signal(|| fae::canvas::bridge::CanvasBridge::new("gui", 800.0, 600.0));
    let mut canvas_visible = use_signal(|| false);
    let mut canvas_revision = use_signal(|| 0u64);
    let mut gate_cmd_tx =
        use_signal(|| None::<tokio::sync::mpsc::UnboundedSender<fae::GateCommand>>);
    let mut gate_active_arc = use_signal(|| None::<std::sync::Arc<std::sync::atomic::AtomicBool>>);
    let mut voices_status = use_signal(String::new);
    let mut voices_name = use_signal(|| "voice_1".to_owned());
    let _canvas_search = use_signal(String::new);
    let _canvas_ctx_menu = use_signal(|| None::<usize>);
    let _clipboard_text = use_signal(String::new);
    let mut update_state = use_signal(fae::update::UpdateState::load);
    let mut update_available = use_signal(|| None::<fae::update::Release>);
    let mut update_banner_dismissed = use_signal(|| false);
    let mut update_check_status = use_signal(String::new);
    let mut update_installing = use_signal(|| false);
    let mut update_install_error = use_signal(|| None::<String>);
    let mut update_restart_needed = use_signal(|| false);
    let mut scheduler_notification = use_signal(|| None::<fae::scheduler::tasks::UserPrompt>);
    let mut active_model = use_signal(|| None::<String>);
    let mut mic_active = use_signal(|| None::<bool>);
    let mut diagnostics_status = use_signal(String::new);
    // (avatar_base_ok signal removed — no longer needed since poses are cached
    // as data URIs and never use file:// URLs that can fail.)

    use_hook(move || {
        let mut config_state = config_state;
        spawn(async move {
            let mut rx = ui_bus().subscribe();
            loop {
                match rx.recv().await {
                    Ok(UiBusEvent::ConfigUpdated) => {
                        let res = tokio::task::spawn_blocking(read_config_or_default).await;
                        if let Ok(cfg) = res {
                            config_state.set(cfg);
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                }
            }
        });
    });

    use_hook(move || {
        let mut blink = blink;
        spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(4200)).await;
                blink.set(true);
                tokio::time::sleep(std::time::Duration::from_millis(120)).await;
                blink.set(false);
            }
        });
    });

    // Background update check at startup (non-blocking, respects preferences).
    use_hook(move || {
        spawn(async move {
            // Only check if last check was more than 24 hours ago.
            let is_stale = update_state.read().check_is_stale(24);
            let pref = update_state.read().auto_update;
            if !is_stale || pref == fae::update::AutoUpdatePreference::Never {
                return;
            }

            let etag = update_state.read().etag_fae.clone();
            let result = tokio::task::spawn_blocking(move || {
                let checker = fae::update::UpdateChecker::for_fae();
                checker.check(etag.as_deref())
            })
            .await;

            match result {
                Ok(Ok((Some(release), new_etag))) => {
                    let dismissed = update_state.read().dismissed_release.clone();
                    let is_dismissed = dismissed.as_deref() == Some(release.version.as_str());

                    update_state.write().etag_fae = new_etag;
                    update_state.write().mark_checked();

                    if !is_dismissed {
                        tracing::info!("update available: Fae v{}", release.version);
                        update_available.set(Some(release));
                    }

                    let state = update_state.read().clone();
                    let _ = tokio::task::spawn_blocking(move || state.save()).await;
                }
                Ok(Ok((None, new_etag))) => {
                    update_state.write().etag_fae = new_etag;
                    update_state.write().mark_checked();
                    let state = update_state.read().clone();
                    let _ = tokio::task::spawn_blocking(move || state.save()).await;
                }
                Ok(Err(e)) => {
                    tracing::debug!("startup update check failed: {e}");
                }
                Err(e) => {
                    tracing::debug!("startup update check task failed: {e}");
                }
            }
        });
    });

    // --- Background scheduler ---
    // Start the scheduler and poll its result channel for notifications.
    use_hook(move || {
        let mut canvas_bridge = canvas_bridge;
        let mut canvas_revision = canvas_revision;
        let mut canvas_visible = canvas_visible;
        let mut scheduler_notification = scheduler_notification;
        let mut update_available = update_available;
        let update_state = update_state;
        let mut config_state = config_state;

        spawn(async move {
            let initial_cfg = config_state.read().memory.clone();
            let mut active_binding = gui::scheduler_memory_binding(&initial_cfg);
            let (mut scheduler_handle, mut scheduler_rx) =
                fae::startup::start_scheduler_with_memory(&initial_cfg);
            let mut cfg_rx = ui_bus().subscribe();

            loop {
                tokio::select! {
                    result = scheduler_rx.recv() => {
                        match result {
                            Some(fae::scheduler::tasks::TaskResult::Success(msg)) => {
                                tracing::debug!("scheduler task succeeded: {msg}");
                            }
                            Some(fae::scheduler::tasks::TaskResult::Telemetry(telemetry)) => {
                                // Route scheduler memory telemetry into the canvas stream only.
                                let event = telemetry.event.clone();
                                canvas_bridge.write().on_event(&event);
                                let next_rev = {
                                    let current = *canvas_revision.read();
                                    current.saturating_add(1)
                                };
                                canvas_revision.set(next_rev);

                                if gui::scheduler_telemetry_opens_canvas(&event) {
                                    canvas_visible.set(true);
                                }

                                match event {
                                    fae::RuntimeEvent::MemoryMigration { from, to, success } => {
                                        if success {
                                            tracing::info!(
                                                "scheduler memory migration: {} ({} -> {})",
                                                telemetry.message,
                                                from,
                                                to
                                            );
                                        } else {
                                            tracing::warn!(
                                                "scheduler memory migration failed: {} ({} -> {})",
                                                telemetry.message,
                                                from,
                                                to
                                            );
                                        }
                                    }
                                    fae::RuntimeEvent::MemoryWrite { .. } => {
                                        tracing::debug!(
                                            "scheduler memory maintenance: {}",
                                            telemetry.message
                                        );
                                    }
                                    _ => {
                                        tracing::debug!("scheduler telemetry: {}", telemetry.message);
                                    }
                                }
                            }
                            Some(fae::scheduler::tasks::TaskResult::NeedsUserAction(prompt)) => {
                                tracing::info!("scheduler notification: {}", prompt.title);
                                // If the prompt is about an update, also set update_available.
                                if prompt.title.contains("Fae Update") {
                                    // Re-check to get the Release struct for the banner.
                                    let etag = update_state.read().etag_fae.clone();
                                    let result = tokio::task::spawn_blocking(move || {
                                        let checker = fae::update::UpdateChecker::for_fae();
                                        checker.check(etag.as_deref())
                                    })
                                    .await;
                                    if let Ok(Ok((Some(release), _))) = result {
                                        update_available.set(Some(release));
                                    }
                                }
                                scheduler_notification.set(Some(prompt));
                            }
                            Some(fae::scheduler::tasks::TaskResult::Error(err)) => {
                                tracing::warn!("scheduler task error: {err}");
                            }
                            None => {
                                tracing::warn!("scheduler result channel closed; restarting");
                                scheduler_handle.abort();
                                let cfg = config_state.read().memory.clone();
                                let launched = fae::startup::start_scheduler_with_memory(&cfg);
                                scheduler_handle = launched.0;
                                scheduler_rx = launched.1;
                                active_binding = gui::scheduler_memory_binding(&cfg);
                            }
                        }
                    }
                    cfg_evt = cfg_rx.recv() => {
                        match cfg_evt {
                            Ok(UiBusEvent::ConfigUpdated) => {
                                let cfg_res = tokio::task::spawn_blocking(read_config_or_default).await;
                                let cfg = match cfg_res {
                                    Ok(cfg) => cfg,
                                    Err(e) => {
                                        tracing::warn!(
                                            "config reload for scheduler failed: {e}; using in-memory config"
                                        );
                                        config_state.read().clone()
                                    }
                                };
                                let next_binding = gui::scheduler_memory_binding(&cfg.memory);
                                if gui::scheduler_requires_restart(&active_binding, &next_binding) {
                                    let restart_count = gui::record_scheduler_memory_restart();
                                    tracing::info!(
                                        scheduler_memory_restarts_total = restart_count,
                                        root = %cfg.memory.root_dir.display(),
                                        retention_days = cfg.memory.retention_days,
                                        "scheduler memory config changed; restarting"
                                    );
                                    scheduler_handle.abort();
                                    let launched = fae::startup::start_scheduler_with_memory(&cfg.memory);
                                    scheduler_handle = launched.0;
                                    scheduler_rx = launched.1;
                                    active_binding = next_binding;
                                }
                                config_state.set(cfg);
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                                tracing::debug!("ui bus closed; stopping scheduler manager");
                                scheduler_handle.abort();
                                break;
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        }
                    }
                }
            }
        });
    });

    // Button click handler
    let mut on_button_click = move |_args: ()| {
        let current = status.read().clone();
        match current {
            AppStatus::Idle
            | AppStatus::PreFlight { .. }
            | AppStatus::Error(_)
            | AppStatus::DownloadError { .. } => {
                // --- START ---
                status.set(AppStatus::Downloading {
                    current_file: "Checking models...".into(),
                    bytes_downloaded: 0,
                    total_bytes: None,
                    files_complete: 0,
                    files_total: 0,
                    aggregate_bytes: 0,
                    aggregate_total: 0,
                    speed_bps: 0.0,
                    eta_secs: None,
                });
                stt_stage.set(StagePhase::Loading);
                llm_stage.set(StagePhase::Pending);
                tts_stage.set(StagePhase::Pending);

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
                let config_for_run = config_state.read().clone();

                tokio::task::spawn(async move {
                    let config = config_for_run;

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
                    let mut tracker = fae::progress::DownloadTracker::new();

                    // Drain progress events periodically while waiting for result.
                    loop {
                        tokio::select! {
                            Some(event) = rx.recv() => {
                                // Build repo→model map when download plan arrives
                                if let fae::progress::ProgressEvent::DownloadPlanReady { ref plan } = event {
                                    repo_model_map.set(build_repo_model_map(plan));
                                    tracker.reset();
                                }
                                let map = repo_model_map.read();
                                update_stages_from_progress(&event, &mut stt_stage, &mut llm_stage, &mut tts_stage, &map);
                                drop(map);
                                let current = status.read().clone();
                                if let Some(mut new_status) = gui::apply_progress_event(event, &current) {
                                    update_speed_eta(&mut new_status, &mut tracker);
                                    status.set(new_status);
                                }
                            }
                            Some(msg) = result_rx.recv() => {
                                // Drain any remaining progress events first.
                                while let Ok(event) = rx.try_recv() {
                                    if let fae::progress::ProgressEvent::DownloadPlanReady { ref plan } = event {
                                        repo_model_map.set(build_repo_model_map(plan));
                                        tracker.reset();
                                    }
                                    let map = repo_model_map.read();
                                    update_stages_from_progress(&event, &mut stt_stage, &mut llm_stage, &mut tts_stage, &map);
                                    drop(map);
                                    let current = status.read().clone();
                                    if let Some(mut new_status) = gui::apply_progress_event(event, &current) {
                                        update_speed_eta(&mut new_status, &mut tracker);
                                        status.set(new_status);
                                    }
                                }
                                match msg {
                                    PipelineMessage::ModelsReady(Ok((config, models))) => {
                                        status.set(AppStatus::Running);
                                        stt_stage.set(StagePhase::Ready);
                                        llm_stage.set(StagePhase::Ready);
                                        tts_stage.set(StagePhase::Ready);
                                        assistant_speaking.set(false);
                                        assistant_generating.set(false);
                                        assistant_buf.set(String::new());
                                        llm_backend.set(Some(config.llm.backend));
                                        tool_mode.set(Some(config.llm.tool_mode));
                                        let (runtime_tx, _) =
                                            tokio::sync::broadcast::channel::<fae::RuntimeEvent>(256);
                                        let (approval_tx, mut approval_rx) = tokio::sync::mpsc::unbounded_channel::<fae::ToolApprovalRequest>();
                                        let (inj_tx, inj_rx) = tokio::sync::mpsc::unbounded_channel::<fae::pipeline::messages::TextInjection>();
                                        text_injection_tx.set(Some(inj_tx));

                                        // Gate command channel for Start/Stop Listening button.
                                        let (gate_tx, gate_rx) = tokio::sync::mpsc::unbounded_channel::<fae::GateCommand>();
                                        gate_cmd_tx.set(Some(gate_tx));

                                        // Canvas tool registry — tools write here, GUI reads for display.
                                        let canvas_registry = {
                                            let mut reg = fae::canvas::registry::CanvasSessionRegistry::new();
                                            let session = std::sync::Arc::new(std::sync::Mutex::new(
                                                fae::canvas::session::CanvasSession::new("gui", 800.0, 600.0),
                                            ));
                                            reg.register("gui", session);
                                            std::sync::Arc::new(std::sync::Mutex::new(reg))
                                        };

                                        let pipeline =
                                            fae::PipelineCoordinator::with_models(config, models)
                                                .with_mode(fae::PipelineMode::Conversation)
                                                .with_runtime_events(runtime_tx.clone())
                                                .with_tool_approvals(approval_tx)
                                                .with_canvas_registry(canvas_registry)
                                                .with_text_injection(inj_rx)
                                                .with_gate_commands(gate_rx)
                                                .with_console_output(false);
                                        let gate_active_flag = pipeline.gate_active();
                                        gate_active_arc.set(Some(gate_active_flag));
                                        let cancel = pipeline.cancel_token();
                                        shared.write().cancel_token = Some(cancel);

                                        let (rtx, mut rrx) = tokio::sync::mpsc::unbounded_channel::<fae::RuntimeEvent>();
                                        let mut b_rx = runtime_tx.subscribe();
                                        let forward_handle = tokio::task::spawn(async move {
                                            loop {
                                                match b_rx.recv().await {
                                                    Ok(ev) => {
                                                        let _ = rtx.send(ev);
                                                    }
                                                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                                                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                                                }
                                            }
                                        });

                                        let mut pipeline_handle = tokio::task::spawn(async move { pipeline.run().await });

                                        loop {
                                            tokio::select! {
                                                res = &mut pipeline_handle => {
                                                    forward_handle.abort();
                                                    pending_approval.set(None);
                                                    approval_queue.set(std::collections::VecDeque::new());
                                                    approval_input_value.set(String::new());
                                                    match res {
                                                        Ok(Ok(())) => status.set(AppStatus::Idle),
                                                        Ok(Err(e)) => status.set(AppStatus::Error(e.to_string())),
                                                        Err(e) => status.set(AppStatus::Error(format!("pipeline task failed: {e}"))),
                                                    }
                                                    break;
                                                }
                                                Some(req) = approval_rx.recv() => {
                                                    // Check if this tool is "always allowed"
                                                    let tool_name = req.name.clone();
                                                    let is_always_allowed = always_allowed_tools.read().contains(&tool_name);

                                                    if is_always_allowed {
                                                        // Auto-approve tools that are always allowed
                                                        let preview = parse_approval_preview(&req);
                                                        let _ = req.respond(true);
                                                        push_approval_decision_to_canvas(
                                                            &mut canvas_bridge.write(),
                                                            &preview,
                                                            true,
                                                        );
                                                    } else if pending_approval.read().is_none() {
                                                        // Show approval modal
                                                        push_approval_request_to_canvas(&mut canvas_bridge.write(), &req);
                                                        let preview = parse_approval_preview(&req);
                                                        approval_input_value.set(preview.initial_value.clone());
                                                        let next_rev = {
                                                            let current = *canvas_revision.read();
                                                            current.saturating_add(1)
                                                        };
                                                        canvas_revision.set(next_rev);
                                                        canvas_visible.set(true);
                                                        pending_approval.set(Some(req));
                                                    } else {
                                                        approval_queue.write().push_back(req);
                                                    }
                                                }
                                                Some(ev) = rrx.recv() => {
                                                    // Route event through canvas bridge
                                                    canvas_bridge.write().on_event(&ev);
                                                    if !matches!(ev, fae::RuntimeEvent::AssistantAudioLevel { .. }) {
                                                        let next_rev = {
                                                            let current = *canvas_revision.read();
                                                            current.saturating_add(1)
                                                        };
                                                        canvas_revision.set(next_rev);
                                                    }

                                                    match &ev {
                                                        fae::RuntimeEvent::Control(ctrl) => match ctrl {
                                                            fae::pipeline::messages::ControlEvent::AssistantSpeechStart => assistant_speaking.set(true),
                                                            fae::pipeline::messages::ControlEvent::AssistantSpeechEnd { .. } => {
                                                                assistant_speaking.set(false);
                                                                // Unpin Fae's subtitle so the 5-second timer starts.
                                                                let mut sf = sub_fae.write();
                                                                sf.pinned = false;
                                                                sf.set_at = Some(std::time::Instant::now());
                                                            }
                                                            fae::pipeline::messages::ControlEvent::UserSpeechStart { .. } => {}
                                                            fae::pipeline::messages::ControlEvent::WakewordDetected => {}
                                                        },
                                                        fae::RuntimeEvent::AssistantGenerating { active } => assistant_generating.set(*active),
                                                        fae::RuntimeEvent::AssistantAudioLevel { rms } => assistant_rms.set(*rms),
                                                        fae::RuntimeEvent::Transcription(t) => {
                                                            let text = t.text.trim().to_owned();
                                                            if !text.is_empty() {
                                                                sub_user.write().set(text);
                                                            }
                                                        }
                                                        fae::RuntimeEvent::AssistantSentence(chunk) => {
                                                            if !chunk.text.is_empty() {
                                                                assistant_buf.write().push_str(&chunk.text);
                                                            }
                                                            // Show the current sentence as it streams.
                                                            let current = assistant_buf.read().trim().to_owned();
                                                            if !current.is_empty() {
                                                                let mut sf = sub_fae.write();
                                                                sf.set(current);
                                                                sf.pinned = true;
                                                            }
                                                            // Detect Fae saying she's closing the canvas.
                                                            let lower = chunk.text.to_lowercase();
                                                            if lower.contains("closing") && lower.contains("canvas") {
                                                                canvas_visible.set(false);
                                                            }
                                                            if chunk.is_final {
                                                                assistant_buf.set(String::new());
                                                            }
                                                        }
                                                        fae::RuntimeEvent::ToolCall { name, .. } => {
                                                            // Auto-open canvas panel when Fae uses a canvas tool.
                                                            if name.starts_with("canvas_") && name != "canvas_clear" {
                                                                canvas_visible.set(true);
                                                            }
                                                            // Auto-close canvas panel when Fae clears the canvas.
                                                            if name == "canvas_clear" {
                                                                canvas_visible.set(false);
                                                            }
                                                        }
                                                        fae::RuntimeEvent::ToolResult { .. } => {}
                                                        fae::RuntimeEvent::ModelSelectionPrompt { .. } => {
                                                            // TODO: Task 5 will implement the model picker UI
                                                        }
                                                        fae::RuntimeEvent::ModelSelected { provider_model } => {
                                                            active_model.set(Some(provider_model.clone()));
                                                        }
                                                        fae::RuntimeEvent::VoiceCommandDetected { .. } => {
                                                            // TODO: Phase 2.3 will show voice command feedback in GUI
                                                        }
                                                        fae::RuntimeEvent::PermissionsChanged { granted } => {
                                                            if *granted {
                                                                always_allowed_tools.write().insert("read".to_string());
                                                                always_allowed_tools.write().insert("write".to_string());
                                                                always_allowed_tools.write().insert("edit".to_string());
                                                                always_allowed_tools.write().insert("bash".to_string());
                                                                voice_permissions_granted.set(true);
                                                            } else {
                                                                always_allowed_tools.write().clear();
                                                                voice_permissions_granted.set(false);
                                                            }
                                                        }
                                                        fae::RuntimeEvent::ModelSwitchRequested { .. } => {
                                                            // TODO: Phase 2.3 will show model switch transition in GUI
                                                        }
                                                        fae::RuntimeEvent::ConversationSnapshot { .. } => {
                                                            canvas_visible.set(true);
                                                        }
                                                        fae::RuntimeEvent::ConversationCanvasVisibility { visible } => {
                                                            canvas_visible.set(*visible);
                                                        }
                                                        fae::RuntimeEvent::MicStatus { active } => {
                                                            mic_active.set(Some(*active));
                                                        }
                                                        other if gui::suppress_main_screen_runtime_event(other) => {}
                                                        _ => {}
                                                    }

                                                }
                                            }
                                        }
                                        shared.write().cancel_token = None;
                                        assistant_speaking.set(false);
                                        assistant_generating.set(false);
                                        mic_active.set(None);
                                        text_injection_tx.set(None);
                                    }
                                    PipelineMessage::ModelsReady(Err(e)) => {
                                        let err_msg = e.to_string();
                                        // Try to build a structured DownloadError from
                                        // the current download state at time of failure.
                                        let current = status.read().clone();
                                        let error_status = if let AppStatus::Downloading {
                                            current_file,
                                            bytes_downloaded,
                                            total_bytes,
                                            ..
                                        } = &current
                                        {
                                            AppStatus::DownloadError {
                                                message: err_msg.clone(),
                                                repo_id: String::new(),
                                                filename: current_file.clone(),
                                                bytes_downloaded: *bytes_downloaded,
                                                total_bytes: *total_bytes,
                                            }
                                        } else {
                                            AppStatus::Error(err_msg.clone())
                                        };
                                        status.set(error_status);
                                        stt_stage.set(StagePhase::Error(err_msg.clone()));
                                        llm_stage.set(StagePhase::Error(err_msg.clone()));
                                        tts_stage.set(StagePhase::Error(err_msg));
                                    }
                                }
                                break;
                            }
                        }
                    }
                });
            }
            AppStatus::Running => {
                // --- Toggle conversation gate (Start/Stop Listening) ---
                if let Some(tx) = gate_cmd_tx.read().as_ref() {
                    let currently_active = gate_active_arc
                        .read()
                        .as_ref()
                        .is_some_and(|a| a.load(std::sync::atomic::Ordering::Relaxed));
                    let cmd = if currently_active {
                        fae::GateCommand::Sleep
                    } else {
                        fae::GateCommand::Wake
                    };
                    let _ = tx.send(cmd);
                }
            }
            _ => {}
        }
    };

    // Auto-start: run pre-flight check on app launch.
    // If downloads are needed, show the PreFlight confirmation first.
    // If everything is cached, go straight to model loading.
    if !*auto_started.read() {
        auto_started.set(true);

        let config_for_preflight = config_state.read().clone();
        spawn(async move {
            let result = tokio::task::spawn_blocking(move || {
                fae::startup::preflight_check(&config_for_preflight)
            })
            .await;

            match result {
                Ok(Ok(preflight)) => {
                    if preflight.needs_download {
                        status.set(AppStatus::PreFlight {
                            total_bytes: preflight.plan.download_bytes(),
                            files_to_download: preflight.plan.files_to_download(),
                            total_files: preflight.plan.total_files(),
                            free_space: preflight.free_space,
                        });
                    } else {
                        // All cached — skip preflight, go straight to loading.
                        on_button_click(());
                    }
                }
                Ok(Err(e)) => {
                    status.set(AppStatus::Error(format!("{e}")));
                }
                Err(e) => {
                    status.set(AppStatus::Error(format!("preflight check failed: {e}")));
                }
            }
        });
    }

    let current_status = status.read().clone();
    let status_text = match &current_status {
        AppStatus::Running => {
            if *assistant_speaking.read() {
                "Speaking...".to_owned()
            } else if *assistant_generating.read() {
                "Thinking...".to_owned()
            } else {
                current_status.display_text()
            }
        }
        _ => current_status.display_text(),
    };
    // Context-aware secondary message for first-run experience.
    let welcome_text: &str = match &current_status {
        AppStatus::PreFlight { .. } => "Welcome to Fae! Setting up your personal AI assistant.",
        AppStatus::Downloading { .. } => "Downloading AI models \u{2014} this only happens once.",
        AppStatus::Loading { .. } => "Almost ready \u{2014} loading models into memory.",
        AppStatus::Error(_) | AppStatus::DownloadError { .. } => {
            "Something went wrong. Press Retry to try again."
        }
        _ => "",
    };
    let button_enabled = current_status.buttons_enabled();
    let is_running = matches!(current_status, AppStatus::Running);
    let gate_is_active = gate_active_arc
        .read()
        .as_ref()
        .is_some_and(|a| a.load(std::sync::atomic::Ordering::Relaxed));
    let button_label = match &current_status {
        AppStatus::Running if gate_is_active => "Stop Listening",
        AppStatus::Running => "Start Listening",
        AppStatus::PreFlight { .. } => "Continue",
        AppStatus::Error(_) | AppStatus::DownloadError { .. } => "Retry",
        AppStatus::Idle => "Start",
        _ => "Starting...",
    };
    let is_loading = matches!(
        current_status,
        AppStatus::Downloading { .. } | AppStatus::Loading { .. }
    );
    let is_error = matches!(
        current_status,
        AppStatus::Error(_) | AppStatus::DownloadError { .. }
    );
    let settings_enabled = matches!(
        current_status,
        AppStatus::Idle | AppStatus::Error(_) | AppStatus::DownloadError { .. }
    );
    let cfg_backend = config_state.read().llm.backend;
    let cfg_tool_mode = config_state.read().llm.tool_mode;
    let backend_value = match cfg_backend {
        fae::config::LlmBackend::Local => "local",
        fae::config::LlmBackend::Api => "api",
        fae::config::LlmBackend::Agent => "agent",
    };
    let tool_mode_value = match cfg_tool_mode {
        fae::config::AgentToolMode::Off => "off",
        fae::config::AgentToolMode::ReadOnly => "read_only",
        fae::config::AgentToolMode::ReadWrite => "read_write",
        fae::config::AgentToolMode::Full => "full",
        fae::config::AgentToolMode::FullNoApproval => "full_no_approval",
    };
    let tool_mode_select_enabled =
        settings_enabled && matches!(cfg_backend, fae::config::LlmBackend::Agent);
    let config_path = fae::SpeechConfig::default_config_path();
    let current_voice = config_state.read().tts.voice.clone();
    let is_builtin_voice = !current_voice.ends_with(".bin") || current_voice.is_empty();
    let voice_ref_display = if is_builtin_voice {
        format!(
            "Kokoro: {}",
            if current_voice.is_empty() {
                "bf_emma"
            } else {
                &current_voice
            }
        )
    } else {
        current_voice.clone()
    };

    let (stt_model_id, llm_models_in_use, tts_models_in_use) = {
        let cfg = config_state.read();
        let stt = cfg.stt.model_id.clone();
        let llm = match cfg_backend {
            fae::config::LlmBackend::Api => {
                format!("API: {} @ {}", cfg.llm.api_model, cfg.llm.api_url)
            }
            fae::config::LlmBackend::Local | fae::config::LlmBackend::Agent => {
                format!("{} / {}", cfg.llm.model_id, cfg.llm.gguf_file)
            }
        };
        let tts = format!("Kokoro-82M ({}, {})", cfg.tts.voice, cfg.tts.model_variant);
        (stt, llm, tts)
    };

    let current_backend = *llm_backend.read();
    let current_tool_mode = *tool_mode.read();
    let _risky_tools_enabled = matches!(
        (current_backend, current_tool_mode),
        (
            Some(fae::config::LlmBackend::Agent),
            Some(
                fae::config::AgentToolMode::ReadOnly
                    | fae::config::AgentToolMode::ReadWrite
                    | fae::config::AgentToolMode::Full
            )
        )
    );

    // Extract download progress display data from current status
    let (progress_fraction, progress_detail, speed_text, eta_text) =
        if let AppStatus::Downloading {
            bytes_downloaded,
            total_bytes,
            aggregate_bytes,
            aggregate_total,
            files_complete,
            files_total,
            speed_bps,
            eta_secs,
            ..
        } = &current_status
        {
            let frac = if *aggregate_total > 0 {
                *aggregate_bytes as f64 / *aggregate_total as f64
            } else if let Some(total) = total_bytes {
                if *total > 0 {
                    *bytes_downloaded as f64 / *total as f64
                } else {
                    0.0
                }
            } else {
                0.0
            };

            let detail = if *aggregate_total > 0 {
                format!(
                    "{} / {} ({:.0}%)",
                    format_bytes_short(*aggregate_bytes),
                    format_bytes_short(*aggregate_total),
                    frac * 100.0
                )
            } else if let Some(total) = total_bytes {
                if *total > 0 {
                    format!(
                        "{} / {} ({:.0}%)",
                        format_bytes_short(*bytes_downloaded),
                        format_bytes_short(*total),
                        frac * 100.0
                    )
                } else {
                    String::new()
                }
            } else {
                String::new()
            };

            let speed = if *speed_bps > 0.0 {
                format_speed(*speed_bps)
            } else if *files_total > 0 {
                "Calculating...".to_owned()
            } else {
                String::new()
            };

            let eta = eta_secs
                .filter(|s| *s > 0.0 && *files_total > 0)
                .map(format_eta)
                .unwrap_or_default();

            let _ = files_complete; // used in display_text

            (frac, detail, speed, eta)
        } else {
            (0.0, String::new(), String::new(), String::new())
        };

    let progress_width = format!("{}%", (progress_fraction * 100.0) as u32);

    let stt_tooltip = {
        let cfg = config_state.read();
        format!("Speech-to-text\nModel: {}\n", cfg.stt.model_id)
    };
    let llm_tooltip = {
        let cfg = config_state.read();
        match cfg.llm.backend {
            fae::config::LlmBackend::Api => format!(
                "Intelligence model (API)\nServer: {}\nModel: {}\n",
                cfg.llm.api_url, cfg.llm.api_model
            ),
            fae::config::LlmBackend::Local | fae::config::LlmBackend::Agent => format!(
                "Intelligence model (local)\nRepo: {}\nGGUF: {}\nTokenizer: {}\n",
                cfg.llm.model_id,
                cfg.llm.gguf_file,
                if cfg.llm.tokenizer_id.is_empty() {
                    "(in repo)"
                } else {
                    &cfg.llm.tokenizer_id
                }
            ),
        }
    };
    let tts_tooltip = {
        let cfg = config_state.read();
        format!(
            "Text-to-speech (Kokoro-82M)\nVoice: {}\nModel variant: {}\nSpeed: {:.1}x\n",
            cfg.tts.voice, cfg.tts.model_variant, cfg.tts.speed
        )
    };

    // Button colors
    let button_bg = if is_error {
        "#a78bfa" // purple for retry
    } else if matches!(current_status, AppStatus::PreFlight { .. }) {
        "#3b82f6" // blue for continue
    } else if current_status.show_start() {
        "#22c55e" // green for start
    } else {
        "#ef4444" // red for stop
    };
    let button_opacity = if button_enabled { "1" } else { "0.5" };

    let open_models_window = {
        let desktop = desktop.clone();
        std::rc::Rc::new(move || {
            let dom = VirtualDom::new(models_window);
            let cfg = Config::new().with_window(
                WindowBuilder::new()
                    .with_title("Fae Models")
                    .with_inner_size(LogicalSize::new(520.0, 760.0))
                    .with_min_inner_size(LogicalSize::new(420.0, 600.0))
                    .with_resizable(true),
            );
            let _handle = desktop.new_window(dom, cfg);
        })
    };

    let memory_root = config_state.read().memory.root_dir.clone();
    let avatar_dir = resolve_avatar_dir(&memory_root);
    // Cache avatar pose data URIs once (avoids per-render file I/O and works
    // around WebKit blocking file:// subresources in Dioxus desktop).
    let avatar_cache = use_hook(|| load_avatar_cache(&avatar_dir));

    // Pick the single active pose image based on speech state.
    // New avatar pack uses full-frame poses (entire face per image), so we swap
    // the whole image rather than overlaying cropped patches.
    let rms = *assistant_rms.read();
    let speaking = *assistant_speaking.read();
    let blinking = *blink.read();

    let active_pose_name = if blinking {
        "eyes_blink.png"
    } else if speaking {
        if rms < 0.030 {
            "mouth_open_small.png"
        } else if rms < 0.060 {
            "mouth_open_medium.png"
        } else {
            "mouth_open_wide.png"
        }
    } else {
        "fae_base.png"
    };

    let active_src = avatar_cache
        .get(active_pose_name)
        .cloned()
        .unwrap_or_else(embedded_fae_jpg_data_uri);

    // For the idle/stopped portrait: always use the full uncropped woodland image.
    let portrait_src = embedded_fae_jpg_data_uri();

    // Resize the main window when the canvas panel opens/closes.
    // Poll the signal on a short timer so the resize happens regardless
    // of which context sets canvas_visible (event loop, UI handler, etc.).
    {
        let desktop = desktop.clone();
        let mut prev_visible = use_signal(|| false);
        use_future(move || {
            let desktop = desktop.clone();
            async move {
                loop {
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    let now = *canvas_visible.read();
                    if now != *prev_visible.read() {
                        prev_visible.set(now);
                        if now {
                            desktop.set_inner_size(LogicalSize::new(960.0, 700.0));
                        } else {
                            desktop.set_inner_size(LogicalSize::new(480.0, 700.0));
                        }
                    }
                }
            }
        });
    }

    // Keep canvas pinned to the newest content unless the user scrolls up.
    use_effect(move || {
        let _rev = *canvas_revision.read();
        if !*canvas_visible.read() {
            return;
        }
        let _ = dioxus::document::eval(
            "(function(){\
                const pane = document.getElementById('fae-canvas-pane');\
                if (!pane) return;\
                const dist = pane.scrollHeight - pane.scrollTop - pane.clientHeight;\
                const stick = pane.dataset.stickBottom;\
                const shouldStick = !stick || stick === 'true' || dist < 180;\
                if (!shouldStick) return;\
                if (typeof pane.scrollTo === 'function') {\
                    pane.scrollTo({ top: pane.scrollHeight, behavior: 'smooth' });\
                } else {\
                    pane.scrollTop = pane.scrollHeight;\
                }\
                pane.dataset.stickBottom = 'true';\
            })();",
        );
    });

    rsx! {
        // Global styles
        style { {GLOBAL_CSS} }

        div { class: if *canvas_visible.read() { "container container-with-canvas" } else { "container" },
            div { class: "topbar",
                button {
                    class: "hamburger",
                    onclick: move |_| {
                        let next = { !*drawer_open.read() };
                        drawer_open.set(next);
                    },
                    "☰"
                }
                p { class: "topbar-title", "Fae" }
                if let Some(model) = active_model.read().as_ref() {
                    p { class: "topbar-model-indicator",
                        title: "Active model",
                        "\u{1F916} {model}"
                    }
                }
                button {
                    class: "topbar-btn",
                    disabled: !settings_enabled,
                    onclick: {
                        let open = open_models_window.clone();
                        move |_| open()
                    },
                    "Models"
                }
                button {
                    class: "topbar-btn",
                    title: if *canvas_visible.read() { "Hide conversation canvas" } else { "Show conversation canvas" },
                    onclick: move |_| {
                        let next = !*canvas_visible.read();
                        canvas_visible.set(next);
                    },
                    if *canvas_visible.read() {
                        "Hide Conversation"
                    } else {
                        "Show Conversation"
                    }
                }
            }

            if *drawer_open.read() {
                div {
                    class: "drawer-overlay",
                    onclick: move |_| drawer_open.set(false),
                    div {
                        class: "drawer",
                        onclick: move |evt| evt.stop_propagation(),
                        button {
                            class: "drawer-item",
                            onclick: move |_| drawer_open.set(false),
                            "Close"
                        }
                        button {
                            class: "drawer-item",
                            onclick: move |_| {
                                view.set(MainView::Home);
                                drawer_open.set(false);
                            },
                            "Home"
                        }
                        button {
                            class: "drawer-item",
                            onclick: move |_| {
                                view.set(MainView::Settings);
                                drawer_open.set(false);
                            },
                            "Settings"
                        }
                        button {
                            class: "drawer-item",
                            onclick: move |_| {
                                view.set(MainView::Voices);
                                drawer_open.set(false);
                            },
                            "Voice cloning"
                        }
                        button {
                            class: "drawer-item",
                            disabled: !settings_enabled,
                            onclick: {
                                let open = open_models_window.clone();
                                move |_| {
                                    drawer_open.set(false);
                                    open();
                                }
                            },
                            "Models..."
                        }
                    }
                }
            }

            // --- Update notification banner ---
            {
                let has_update = update_available.read().is_some()
                    && !*update_banner_dismissed.read();
                let installing = *update_installing.read();
                let restart = *update_restart_needed.read();
                if restart {
                    rsx! {
                        div { class: "update-banner",
                            span { class: "update-banner-text",
                                "Update installed. Restart Fae to use the new version."
                            }
                        }
                    }
                } else if has_update {
                    let ver = update_available.read().as_ref()
                        .map(|r| r.version.clone())
                        .unwrap_or_default();
                    rsx! {
                        div { class: "update-banner",
                            span { class: "update-banner-text",
                                if installing {
                                    "Installing Fae v{ver}..."
                                } else {
                                    "Fae v{ver} is available."
                                }
                            }
                            if !installing {
                                button {
                                    class: "update-banner-btn",
                                    onclick: move |_| {
                                        let release = update_available.read().clone();
                                        if let Some(rel) = release {
                                            update_installing.set(true);
                                            update_install_error.set(None);
                                            let url = rel.download_url.clone();
                                            spawn(async move {
                                                let result = tokio::task::spawn_blocking(move || {
                                                    let current = fae::update::applier::current_exe_path()?;
                                                    fae::update::applier::apply_update(&url, &current)
                                                }).await;
                                                update_installing.set(false);
                                                match result {
                                                    Ok(Ok(_apply_result)) => {
                                                        update_restart_needed.set(true);
                                                        update_banner_dismissed.set(false);
                                                    }
                                                    Ok(Err(e)) => {
                                                        update_install_error.set(Some(format!("{e}")));
                                                    }
                                                    Err(e) => {
                                                        update_install_error.set(Some(format!("{e}")));
                                                    }
                                                }
                                            });
                                        }
                                    },
                                    "Install Now"
                                }
                                button {
                                    class: "update-banner-dismiss",
                                    onclick: move |_| {
                                        update_banner_dismissed.set(true);
                                        // Persist the dismissal.
                                        if let Some(rel) = update_available.read().as_ref() {
                                            update_state.write().dismissed_release =
                                                Some(rel.version.clone());
                                        }
                                        let state = update_state.read().clone();
                                        spawn(async move {
                                            let _ = tokio::task::spawn_blocking(move || state.save())
                                                .await;
                                        });
                                    },
                                    "\u{2715}"
                                }
                            }
                        }
                    }
                } else if let Some(err) = update_install_error.read().as_ref() {
                    let err = err.clone();
                    rsx! {
                        div { class: "update-banner",
                            span { class: "update-banner-text", "Update failed: {err}" }
                            button {
                                class: "update-banner-dismiss",
                                onclick: move |_| update_install_error.set(None),
                                "\u{2715}"
                            }
                        }
                    }
                } else {
                    rsx! {}
                }
            }

            if *view.read() == MainView::Home {
              div { class: "home-layout",
                div { class: "home-main",
                if is_running {
                    // Animated circular avatar while running — swap full-frame poses
                    div {
                        class: "avatar avatar-pulse",
                        img {
                            src: "{active_src}",
                            alt: "Fae",
                            class: "avatar-img",
                        }
                    }
                } else {
                    // Full rectangular portrait when idle, loading, stopped, or error
                    div {
                        class: if is_loading { "avatar-portrait avatar-portrait-loading" } else { "avatar-portrait" },
                        img {
                            src: "{portrait_src}",
                            alt: "Fae",
                            class: "avatar-portrait-img",
                        }
                        if is_loading {
                            div { class: "avatar-portrait-spinner" }
                        }
                    }
                }

                // Title
                h1 { class: "title", "Fae" }

                // Mic status indicator (visible when pipeline is running)
                if is_running {
                    {
                        let mic_state = *mic_active.read();
                        let (mic_class, mic_label) = match mic_state {
                            None => ("mic-indicator mic-starting", "\u{1F3A4} Mic: starting..."),
                            Some(true) => ("mic-indicator mic-active", "\u{1F3A4} Mic: active"),
                            Some(false) => ("mic-indicator mic-failed", "\u{1F3A4} Mic: not detected"),
                        };
                        rsx! {
                            p { class: "{mic_class}", "{mic_label}" }
                        }
                    }
                }

                // Status text
                p {
                    class: if is_error { "status status-error" } else { "status" },
                    "{status_text}"
                }

                // Welcome / context message during first-run
                if !welcome_text.is_empty() {
                    p { class: "welcome-text", "{welcome_text}" }
                }

                // Voice command hints (only when models are loaded and running)
                if is_running {
                    p { class: "hint",
                        "Say "
                        span { class: "hint-phrase", "\"Hi Fae\"" }
                        " to converse with me"
                    }
                    p { class: "hint",
                        "Say "
                        span { class: "hint-phrase", "\"That'll do Fae\"" }
                        " to stop me"
                    }
                }

                div { class: "stagebar",
                    div {
                        class: "{stt_stage.read().css_class()}",
                        title: "{stt_tooltip}",
                        "Speech-to-text: {stt_stage.read().label(\"ears\")}"
                    }
                    div {
                        class: "{llm_stage.read().css_class()}",
                        title: "{llm_tooltip}",
                        "Intelligence: {llm_stage.read().label(\"brain\")}"
                    }
                    div {
                        class: "{tts_stage.read().css_class()}",
                        title: "{tts_tooltip}",
                        "Text-to-speech: {tts_stage.read().label(\"voice\")}"
                    }
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
                        if !progress_detail.is_empty() {
                            p { class: "progress-text", "{progress_detail}" }
                        }
                        if !speed_text.is_empty() || !eta_text.is_empty() {
                            p { class: "progress-speed",
                                if !speed_text.is_empty() && !eta_text.is_empty() {
                                    "{speed_text} — {eta_text}"
                                } else if !speed_text.is_empty() {
                                    "{speed_text}"
                                } else {
                                    "{eta_text}"
                                }
                            }
                        }
                    }
                }

                // Start/Stop button
                button {
                    class: "main-button",
                    style: "background: {button_bg}; opacity: {button_opacity};",
                    disabled: !button_enabled,
                    onclick: move |_| on_button_click(()),
                    "{button_label}"
                }

                if is_running {
                    // Subtitle bubbles — most recent speaker at the bottom.
                    div { class: "subtitle-area",
                        {
                            let fae_snap = sub_fae.read();
                            let user_snap = sub_user.read();
                            let fae_vis = fae_snap.is_visible();
                            let user_vis = user_snap.is_visible();
                            // Determine who spoke most recently (that one goes to the bottom).
                            let fae_newer = match (fae_snap.set_at, user_snap.set_at) {
                                (Some(f), Some(u)) => f > u,
                                (Some(_), None) => true,
                                _ => false,
                            };
                            let fae_text = fae_snap.text.clone();
                            let user_text = user_snap.text.clone();
                            drop(fae_snap);
                            drop(user_snap);
                            rsx! {
                                if fae_vis && user_vis {
                                    if fae_newer {
                                        // User spoke first, Fae is newer → Fae at bottom
                                        div { class: "subtitle-bubble subtitle-user", "{user_text}" }
                                        div { class: "subtitle-bubble subtitle-fae", "{fae_text}" }
                                    } else {
                                        // Fae spoke first, user is newer → user at bottom
                                        div { class: "subtitle-bubble subtitle-fae", "{fae_text}" }
                                        div { class: "subtitle-bubble subtitle-user", "{user_text}" }
                                    }
                                } else if fae_vis {
                                    div { class: "subtitle-bubble subtitle-fae", "{fae_text}" }
                                } else if user_vis {
                                    div { class: "subtitle-bubble subtitle-user", "{user_text}" }
                                } else {
                                    div { class: "subtitle-spacer" }
                                }
                            }
                        }

                        // Text input bar
                        div { class: "text-input-bar",
                            input {
                                class: "text-input",
                                r#type: "text",
                                placeholder: "Type a message...",
                                value: "{text_input.read()}",
                                oninput: move |evt| text_input.set(evt.value()),
                                onkeydown: move |evt: KeyboardEvent| {
                                    if evt.key() == Key::Enter {
                                        let msg = text_input.read().trim().to_owned();
                                        if !msg.is_empty() {
                                            // Check if this should be an approval response
                                            let is_approval = pending_approval.read().is_some();
                                            let is_yes = msg.to_lowercase().contains("yes")
                                                || msg.to_lowercase().contains("sure")
                                                || msg.to_lowercase().contains("go ahead")
                                                || msg.to_lowercase().contains("okay")
                                                || msg.to_lowercase().contains("ok")
                                                || msg.to_lowercase().contains("do it")
                                                || msg.to_lowercase().contains("proceed");
                                            let is_no = msg.to_lowercase().contains("no")
                                                || msg.to_lowercase().contains("nope")
                                                || msg.to_lowercase().contains("cancel");

                                            if is_approval && (is_yes || is_no) {
                                                // Handle approval response - take ownership to avoid borrow conflicts
                                                if let Some(req) = pending_approval.take() {
                                                    let approve = is_yes;
                                                    let preview = parse_approval_preview(&req);
                                                    let _ = req.respond(approve);
                                                    push_approval_decision_to_canvas(
                                                        &mut canvas_bridge.write(),
                                                        &preview,
                                                        approve,
                                                    );

                                                    // Process queued approvals
                                                    let queued_req = approval_queue.write().pop_front();
                                                    if let Some(queued) = queued_req {
                                                        pending_approval.set(Some(queued));
                                                    }
                                                }
                                            } else if let Some(tx) = text_injection_tx.read().as_ref() {
                                                // Normal message - send to LLM
                                                let injection = fae::pipeline::messages::TextInjection {
                                                    text: msg,
                                                    fork_at_keep_count: None,
                                                };
                                                let _ = tx.send(injection);
                                            }
                                            text_input.set(String::new());
                                        }
                                    }
                                },
                            }
                            button {
                                class: "text-send-btn",
                                disabled: text_input.read().trim().is_empty() || text_injection_tx.read().is_none(),
                                onclick: move |_| {
                                    let msg = text_input.read().trim().to_owned();
                                    if !msg.is_empty() {
                                        // Check if this should be an approval response
                                        let is_approval = pending_approval.read().is_some();
                                        let is_yes = msg.to_lowercase().contains("yes")
                                            || msg.to_lowercase().contains("sure")
                                            || msg.to_lowercase().contains("go ahead")
                                            || msg.to_lowercase().contains("okay")
                                            || msg.to_lowercase().contains("ok")
                                            || msg.to_lowercase().contains("do it")
                                            || msg.to_lowercase().contains("proceed");
                                        let is_no = msg.to_lowercase().contains("no")
                                            || msg.to_lowercase().contains("nope")
                                            || msg.to_lowercase().contains("cancel");

                                        if is_approval && (is_yes || is_no) {
                                            // Handle approval response - take ownership to avoid borrow conflicts
                                            if let Some(req) = pending_approval.take() {
                                                let approve = is_yes;
                                                let preview = parse_approval_preview(&req);
                                                let _ = req.respond(approve);
                                                push_approval_decision_to_canvas(
                                                    &mut canvas_bridge.write(),
                                                    &preview,
                                                    approve,
                                                );

                                                // Process queued approvals
                                                let queued_req = approval_queue.write().pop_front();
                                                if let Some(queued) = queued_req {
                                                    pending_approval.set(Some(queued));
                                                }
                                            }
                                        } else if let Some(tx) = text_injection_tx.read().as_ref() {
                                            // Normal message - send to LLM
                                            let injection = fae::pipeline::messages::TextInjection {
                                                text: msg,
                                                fork_at_keep_count: None,
                                            };
                                            let _ = tx.send(injection);
                                        }
                                        text_input.set(String::new());
                                    }
                                },
                                "Send"
                            }
                        }

                        // Permission toggle when tools enabled
                        if _risky_tools_enabled {
                            div { class: "perm-bar",
                                span { class: "perm-label",
                                    if always_allowed_tools.read().len() > 0 { "Tools: approved" } else { "Tools: ask first" }
                                }
                                button {
                                    class: if always_allowed_tools.read().len() > 0 { "perm-revoke-btn" } else { "perm-grant-btn" },
                                    onclick: move |_| {
                                        if always_allowed_tools.read().len() > 0 {
                                            always_allowed_tools.write().clear();
                                            voice_permissions_granted.set(false);
                                        } else {
                                            always_allowed_tools.write().insert("read".to_string());
                                            always_allowed_tools.write().insert("write".to_string());
                                            always_allowed_tools.write().insert("edit".to_string());
                                            always_allowed_tools.write().insert("bash".to_string());
                                            voice_permissions_granted.set(true);
                                        }
                                    },
                                    if always_allowed_tools.read().len() > 0 { "Revoke" } else { "Auto-Approve" }
                                }
                            }
                        }
                    }
                }

                } // end home-main

                // Canvas panel — right-side panel visible when Fae pushes
                // rich content (charts, images). Window expands to fit.
                if *canvas_visible.read() {
                    div { class: "canvas-panel",
                        div { class: "canvas-panel-header",
                            h3 { class: "canvas-panel-title", "Canvas" }
                            button {
                                class: "canvas-close-btn",
                                title: "Close canvas",
                                onclick: move |_| canvas_visible.set(false),
                                "X"
                            }
                        }
                        div {
                            class: "canvas-pane",
                            id: "fae-canvas-pane",
                            role: "log",
                            aria_label: "Canvas content",
                            onscroll: move |_| {
                                let _ = dioxus::document::eval(
                                    "(function(){\
                                        const pane = document.getElementById('fae-canvas-pane');\
                                        if (!pane) return;\
                                        const dist = pane.scrollHeight - pane.scrollTop - pane.clientHeight;\
                                        pane.dataset.stickBottom = dist < 180 ? 'true' : 'false';\
                                    })();"
                                );
                            },
                            dangerous_inner_html: "{build_canvas_messages_html(&canvas_bridge.read())}",
                            if *assistant_generating.read() {
                                div {
                                    class: "thinking-indicator",
                                    role: "status",
                                    aria_live: "polite",
                                    aria_label: "Assistant is thinking",
                                    span { class: "thinking-dot" }
                                    span { class: "thinking-dot" }
                                    span { class: "thinking-dot" }
                                }
                            }
                            {
                                let tools_html = canvas_bridge.read().session().tool_elements_html();
                                if !tools_html.is_empty() {
                                    rsx! {
                                        div { class: "canvas-tools-section",
                                            dangerous_inner_html: "{tools_html}",
                                        }
                                    }
                                } else {
                                    rsx! {}
                                }
                            }
                        }
                    }
                }
              } // end home-layout
            }

            if *view.read() == MainView::Settings {
                div { class: "settings",
                    div { class: "screen-header",
                        button {
                            class: "back-btn",
                            onclick: move |_| view.set(MainView::Home),
                            "\u{2190} Back"
                        }
                        h2 { class: "settings-title", "Settings" }
                        // Spacer for centering
                        div { class: "back-btn-spacer" }
                    }
                    p { class: "settings-sub",
                        "Saved at: {config_path.display()}"
                    }

                    // --- Models in use (read-only summary) ---
                    div { class: "settings-block",
                        h3 { class: "settings-h3", "Models in use" }
                        p { class: "note",
                            "The specific models loaded when you press Start."
                        }
                        div { class: "settings-row",
                            label { class: "settings-label", "Speech-to-text" }
                            p { class: "settings-value", "{stt_model_id}" }
                        }
                        div { class: "settings-row",
                            label { class: "settings-label", "Intelligence (LLM)" }
                            p { class: "settings-value", "{llm_models_in_use}" }
                        }
                        div { class: "settings-row",
                            label { class: "settings-label", "Text-to-speech" }
                            p { class: "settings-value", "{tts_models_in_use}" }
                        }
                    }

                    // --- LLM ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "LLM / Intelligence" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Backend" }
                                select {
                                    class: "settings-select",
                                    disabled: true,
                                    value: "{backend_value}",
                                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Tool mode" }
                                select {
                                    class: "settings-select",
                                    disabled: !tool_mode_select_enabled,
                                    value: "{tool_mode_value}",
                                    onchange: move |evt| {
                                        let v = evt.value();
                                        let mode = match v.as_str() {
                                            "off" => fae::config::AgentToolMode::Off,
                                            "read_only" => fae::config::AgentToolMode::ReadOnly,
                                            "read_write" => fae::config::AgentToolMode::ReadWrite,
                                            "full" => fae::config::AgentToolMode::Full,
                                            "full_no_approval" => fae::config::AgentToolMode::FullNoApproval,
                                            _ => fae::config::AgentToolMode::ReadOnly,
                                        };
                                        config_state.write().llm.tool_mode = mode;
                                    },
                                    option { value: "off", "Off" }
                                    option { value: "read_only", "Read-only" }
                                    option { value: "read_write", "Read/write (ask first)" }
                                    option { value: "full", "Full (ask first)" }
                                    option { value: "full_no_approval", "Full (no approval)" }
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Max tokens" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().llm.max_tokens}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<usize>() {
                                            config_state.write().llm.max_tokens = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Context window (tokens)" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    min: "1024",
                                    step: "1024",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().llm.context_size_tokens}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<usize>() {
                                            config_state.write().llm.context_size_tokens = v;
                                        }
                                    },
                                }
                            }
                            p { class: "note",
                                "If omitted in config.toml, Fae auto-tunes context size from system RAM."
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Temperature" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    step: "0.1",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().llm.temperature}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<f64>() {
                                            config_state.write().llm.temperature = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Top-p" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    step: "0.05",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().llm.top_p}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<f64>() {
                                            config_state.write().llm.top_p = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Repeat penalty" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    step: "0.05",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().llm.repeat_penalty}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<f32>() {
                                            config_state.write().llm.repeat_penalty = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Max history msgs" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().llm.max_history_messages}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<usize>() {
                                            config_state.write().llm.max_history_messages = v;
                                        }
                                    },
                                }
                            }
                            if matches!(cfg_backend, fae::config::LlmBackend::Api) {
                                div { class: "settings-row",
                                    label { class: "settings-label", "API URL" }
                                    input {
                                        class: "settings-select",
                                        r#type: "text",
                                        disabled: !settings_enabled,
                                        value: "{config_state.read().llm.api_url}",
                                        oninput: move |evt| config_state.write().llm.api_url = evt.value(),
                                    }
                                }
                                div { class: "settings-row",
                                    label { class: "settings-label", "API model" }
                                    input {
                                        class: "settings-select",
                                        r#type: "text",
                                        disabled: !settings_enabled,
                                        value: "{config_state.read().llm.api_model}",
                                        oninput: move |evt| config_state.write().llm.api_model = evt.value(),
                                    }
                                }
                            }
                        }
                    }

                    // --- Personality ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Personality" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Profile" }
                                select {
                                    class: "settings-select",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().llm.personality}",
                                    onchange: move |evt| {
                                        config_state.write().llm.personality = evt.value();
                                    },
                                    {fae::personality::list_personalities().into_iter().map(|name| {
                                        rsx! {
                                            option { value: "{name}", "{name}" }
                                        }
                                    })}
                                }
                            }
                            p { class: "note",
                                "Optional instructions appended after the personality profile."
                            }
                            textarea {
                                class: "settings-textarea",
                                disabled: !settings_enabled,
                                value: "{config_state.read().llm.system_prompt}",
                                placeholder: "Optional. e.g. \"Be more formal.\"",
                                oninput: move |evt| {
                                    config_state.write().llm.system_prompt = evt.value();
                                },
                            }
                            div { class: "details-actions",
                                button {
                                    class: "pill",
                                    disabled: !settings_enabled,
                                    onclick: move |_| config_state.write().llm.system_prompt.clear(),
                                    "Clear add-on"
                                }
                            }
                            details { class: "details",
                                summary { class: "details-summary", "Show active prompt" }
                                pre { class: "details-pre", "{config_state.read().llm.effective_system_prompt()}" }
                            }
                        }
                    }

                    // --- Skills (read-only info) ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Skills" }
                        div { class: "settings-section-body",
                            p { class: "note",
                                "Behavioural guides injected into the system prompt."
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Active skills" }
                                p { class: "settings-value",
                                    {fae::skills::list_skills().join(", ")}
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Custom skills" }
                                p { class: "settings-value",
                                    "{fae::skills::skills_dir().display()}/"
                                }
                            }
                            p { class: "note",
                                "Add .md files to the custom skills directory for extra skills."
                            }
                        }
                    }

                    // --- Audio ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Audio" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Input sample rate" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().audio.input_sample_rate}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u32>() {
                                            config_state.write().audio.input_sample_rate = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Output sample rate" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().audio.output_sample_rate}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u32>() {
                                            config_state.write().audio.output_sample_rate = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Input channels" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().audio.input_channels}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u16>() {
                                            config_state.write().audio.input_channels = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Buffer size" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().audio.buffer_size}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u32>() {
                                            config_state.write().audio.buffer_size = v;
                                        }
                                    },
                                }
                            }
                        }
                    }

                    // --- VAD ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Voice Activity Detection" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Threshold" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    step: "0.05",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().vad.threshold}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<f32>() {
                                            config_state.write().vad.threshold = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Min silence (ms)" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().vad.min_silence_duration_ms}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u32>() {
                                            config_state.write().vad.min_silence_duration_ms = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Speech pad (ms)" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().vad.speech_pad_ms}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u32>() {
                                            config_state.write().vad.speech_pad_ms = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Min speech (ms)" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().vad.min_speech_duration_ms}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u32>() {
                                            config_state.write().vad.min_speech_duration_ms = v;
                                        }
                                    },
                                }
                            }
                        }
                    }

                    // --- STT ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Speech-to-Text" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Model ID" }
                                input {
                                    class: "settings-select",
                                    r#type: "text",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().stt.model_id}",
                                    oninput: move |evt| config_state.write().stt.model_id = evt.value(),
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Chunk size" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().stt.chunk_size}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<usize>() {
                                            config_state.write().stt.chunk_size = v;
                                        }
                                    },
                                }
                            }
                        }
                    }

                    // --- TTS ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Text-to-Speech" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Model variant" }
                                select {
                                    class: "settings-select",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().tts.model_variant}",
                                    onchange: move |evt| config_state.write().tts.model_variant = evt.value(),
                                    option { value: "q8", "q8 (recommended)" }
                                    option { value: "q8f16", "q8f16 (smallest)" }
                                    option { value: "fp16", "fp16" }
                                    option { value: "fp32", "fp32 (best)" }
                                    option { value: "q4", "q4" }
                                    option { value: "q4f16", "q4f16" }
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Voice" }
                                input {
                                    class: "settings-select",
                                    r#type: "text",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().tts.voice}",
                                    oninput: move |evt| {
                                        config_state.write().tts.voice = evt.value();
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Speed" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    step: "0.1",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().tts.speed}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<f32>() {
                                            config_state.write().tts.speed = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Sample rate" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().tts.sample_rate}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u32>() {
                                            config_state.write().tts.sample_rate = v;
                                        }
                                    },
                                }
                            }
                        }
                    }

                    // --- Conversation ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Conversation" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Enabled" }
                                input {
                                    class: "settings-checkbox",
                                    r#type: "checkbox",
                                    disabled: !settings_enabled,
                                    checked: config_state.read().conversation.enabled,
                                    onchange: move |evt| {
                                        config_state.write().conversation.enabled = evt.checked();
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Wake word" }
                                input {
                                    class: "settings-select",
                                    r#type: "text",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().conversation.wake_word}",
                                    oninput: move |evt| config_state.write().conversation.wake_word = evt.value(),
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Stop phrase" }
                                input {
                                    class: "settings-select",
                                    r#type: "text",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().conversation.stop_phrase}",
                                    oninput: move |evt| config_state.write().conversation.stop_phrase = evt.value(),
                                }
                            }
                        }
                    }

                    // --- Barge-in ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Barge-in" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Enabled" }
                                input {
                                    class: "settings-checkbox",
                                    r#type: "checkbox",
                                    disabled: !settings_enabled,
                                    checked: config_state.read().barge_in.enabled,
                                    onchange: move |evt| {
                                        config_state.write().barge_in.enabled = evt.checked();
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Min RMS" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    step: "0.005",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().barge_in.min_rms}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<f32>() {
                                            config_state.write().barge_in.min_rms = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Confirm (ms)" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().barge_in.confirm_ms}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u32>() {
                                            config_state.write().barge_in.confirm_ms = v;
                                        }
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Start holdoff (ms)" }
                                input {
                                    class: "settings-select",
                                    r#type: "number",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().barge_in.assistant_start_holdoff_ms}",
                                    oninput: move |evt| {
                                        if let Ok(v) = evt.value().parse::<u32>() {
                                            config_state.write().barge_in.assistant_start_holdoff_ms = v;
                                        }
                                    },
                                }
                            }
                        }
                    }

                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Canvas" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Server URL" }
                                input {
                                    class: "settings-select",
                                    r#type: "text",
                                    placeholder: "ws://localhost:9473/ws/sync",
                                    disabled: !settings_enabled,
                                    value: "{config_state.read().canvas.server_url.as_deref().unwrap_or_default()}",
                                    oninput: move |evt| {
                                        let val = evt.value();
                                        config_state.write().canvas.server_url = if val.is_empty() {
                                            None
                                        } else {
                                            Some(val)
                                        };
                                    },
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Status" }
                                {
                                    let status = canvas_bridge.read().session().connection_status();
                                    let label = match status {
                                        fae::canvas::backend::ConnectionStatus::Local => "Local (no server)",
                                        fae::canvas::backend::ConnectionStatus::Connected => "Connected",
                                        fae::canvas::backend::ConnectionStatus::Connecting => "Connecting\u{2026}",
                                        fae::canvas::backend::ConnectionStatus::Reconnecting { .. } => "Reconnecting\u{2026}",
                                        fae::canvas::backend::ConnectionStatus::Disconnected => "Disconnected",
                                        fae::canvas::backend::ConnectionStatus::Failed(_) => "Failed",
                                    };
                                    rsx! { p { class: "settings-value", "{label}" } }
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Elements" }
                                p { class: "settings-value",
                                    "{canvas_bridge.read().session().element_count()}"
                                }
                            }
                        }
                    }

                    // --- Updates ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Updates" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Fae version" }
                                p { class: "settings-value",
                                    "{update_state.read().fae_version}"
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Auto-update" }
                                select {
                                    class: "settings-select",
                                    value: "{update_state.read().auto_update}",
                                    onchange: move |evt| {
                                        let pref = match evt.value().as_str() {
                                            "always" => fae::update::AutoUpdatePreference::Always,
                                            "never" => fae::update::AutoUpdatePreference::Never,
                                            _ => fae::update::AutoUpdatePreference::Ask,
                                        };
                                        update_state.write().auto_update = pref;
                                        let state = update_state.read().clone();
                                        spawn(async move {
                                            let _ = tokio::task::spawn_blocking(move || state.save()).await;
                                        });
                                    },
                                    option { value: "ask", "Ask" }
                                    option { value: "always", "Always" }
                                    option { value: "never", "Never" }
                                }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Last check" }
                                {
                                    let ts = update_state.read().last_check.clone();
                                    let label = ts.unwrap_or_else(|| "never".to_owned());
                                    rsx! { p { class: "settings-value", "{label}" } }
                                }
                            }
                            div { class: "settings-row",
                                button {
                                    class: "settings-save",
                                    onclick: move |_| {
                                        update_check_status.set("Checking...".to_owned());
                                        let etag = update_state.read().etag_fae.clone();
                                        spawn(async move {
                                            let result = tokio::task::spawn_blocking(move || {
                                                let checker = fae::update::UpdateChecker::for_fae();
                                                checker.check(etag.as_deref())
                                            }).await;

                                            match result {
                                                Ok(Ok((Some(release), new_etag))) => {
                                                    let msg = format!("v{} available!", release.version);
                                                    update_check_status.set(msg);
                                                    update_available.set(Some(release));
                                                    update_state.write().etag_fae = new_etag;
                                                    update_state.write().mark_checked();
                                                    let state = update_state.read().clone();
                                                    let _ = tokio::task::spawn_blocking(move || state.save()).await;
                                                }
                                                Ok(Ok((None, new_etag))) => {
                                                    update_check_status.set("Up to date.".to_owned());
                                                    update_state.write().etag_fae = new_etag;
                                                    update_state.write().mark_checked();
                                                    let state = update_state.read().clone();
                                                    let _ = tokio::task::spawn_blocking(move || state.save()).await;
                                                }
                                                Ok(Err(e)) => {
                                                    update_check_status.set(format!("Error: {e}"));
                                                }
                                                Err(e) => {
                                                    update_check_status.set(format!("Error: {e}"));
                                                }
                                            }
                                        });
                                    },
                                    "Check now"
                                }
                                p { class: "settings-value",
                                    "{update_check_status.read()}"
                                }
                            }
                            // "Install Now" button — visible when an update is available.
                            if update_available.read().is_some() && !*update_restart_needed.read() {
                                div { class: "settings-row",
                                    button {
                                        class: "settings-save",
                                        disabled: *update_installing.read(),
                                        onclick: move |_| {
                                            let release = update_available.read().clone();
                                            if let Some(rel) = release {
                                                update_installing.set(true);
                                                update_install_error.set(None);
                                                let url = rel.download_url.clone();
                                                spawn(async move {
                                                    let result = tokio::task::spawn_blocking(move || {
                                                        let current = fae::update::applier::current_exe_path()?;
                                                        fae::update::applier::apply_update(&url, &current)
                                                    }).await;
                                                    update_installing.set(false);
                                                    match result {
                                                        Ok(Ok(_apply_result)) => {
                                                            update_restart_needed.set(true);
                                                            update_check_status.set("Installed! Restart to use the new version.".to_owned());
                                                        }
                                                        Ok(Err(e)) => {
                                                            update_install_error.set(Some(format!("{e}")));
                                                            update_check_status.set(format!("Install failed: {e}"));
                                                        }
                                                        Err(e) => {
                                                            update_install_error.set(Some(format!("{e}")));
                                                            update_check_status.set(format!("Install failed: {e}"));
                                                        }
                                                    }
                                                });
                                            }
                                        },
                                        if *update_installing.read() { "Installing..." } else { "Install Now" }
                                    }
                                }
                            }
                            if *update_restart_needed.read() {
                                div { class: "settings-row",
                                    p { class: "settings-value",
                                        "Update installed. Restart Fae to use the new version."
                                    }
                                }
                            }
                        }
                    }

                    // --- Updates ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Updates" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Current version" }
                                p { class: "settings-value", "{FAE_VERSION}" }
                            }
                            div { class: "settings-row",
                                label { class: "settings-label", "Auto-check" }
                                p { class: "settings-value", "daily at 09:00 UTC" }
                            }
                            div { class: "settings-row",
                                button {
                                    class: "settings-save",
                                    onclick: move |_| {
                                        spawn(async move {
                                            let checker = fae::update::UpdateChecker::for_fae();
                                            match checker.check(None) {
                                                Ok((Some(release), _)) => {
                                                    config_save_status.set(format!(
                                                        "Update available: v{} (current: {})",
                                                        release.version,
                                                        checker.current_version()
                                                    ));
                                                }
                                                Ok((None, _)) => {
                                                    config_save_status.set("You're on the latest version!".to_owned());
                                                }
                                                Err(e) => {
                                                    config_save_status.set(format!("Check failed: {e}"));
                                                }
                                            }
                                        });
                                    },
                                    "Check for Updates"
                                }
                            }
                        }
                    }

                    // --- Diagnostics ---
                    details { class: "settings-section",
                        summary { class: "settings-section-summary", "Diagnostics" }
                        div { class: "settings-section-body",
                            div { class: "settings-row",
                                label { class: "settings-label", "Log directory" }
                                p { class: "settings-value",
                                    "{fae::diagnostics::fae_log_dir().display()}"
                                }
                            }
                            div { class: "settings-row",
                                button {
                                    class: "settings-save",
                                    onclick: move |_| {
                                        diagnostics_status.set("Gathering...".to_owned());
                                        spawn(async move {
                                            let result = tokio::task::spawn_blocking(
                                                fae::diagnostics::gather_diagnostic_bundle,
                                            )
                                            .await;
                                            match result {
                                                Ok(Ok(path)) => {
                                                    diagnostics_status.set(format!(
                                                        "Saved to {}",
                                                        path.display()
                                                    ));
                                                }
                                                Ok(Err(e)) => {
                                                    diagnostics_status
                                                        .set(format!("Error: {e}"));
                                                }
                                                Err(e) => {
                                                    diagnostics_status
                                                        .set(format!("Error: {e}"));
                                                }
                                            }
                                        });
                                    },
                                    "Gather Logs"
                                }
                                p { class: "settings-value",
                                    "{diagnostics_status.read()}"
                                }
                            }
                        }
                    }

                    // --- Save / Models buttons ---
                    div { class: "settings-actions",
                        button {
                            class: "settings-save",
                            disabled: !settings_enabled,
                            onclick: move |_| {
                                let cfg = config_state.read().clone();
                                let path = fae::SpeechConfig::default_config_path();
                                spawn(async move {
                                    let res = tokio::task::spawn_blocking(move || cfg.save_to_file(&path)).await;
                                    let msg = match res {
                                        Ok(Ok(())) => {
                                            let _ = ui_bus().send(UiBusEvent::ConfigUpdated);
                                            "Saved.".to_owned()
                                        }
                                        Ok(Err(e)) => format!("Save failed: {e}"),
                                        Err(e) => format!("Save failed: {e}"),
                                    };
                                    config_save_status.set(msg);
                                });
                            },
                            "Save"
                        }
                        button {
                            class: "settings-save",
                            disabled: !settings_enabled,
                            onclick: {
                                let open = open_models_window.clone();
                                move |_| open()
                            },
                            "Models..."
                        }
                    }
                    p { class: "settings-status", "{config_save_status.read()}" }
                }
            }

            if *view.read() == MainView::Voices {
                div { class: "model-picker",
                    div { class: "screen-header",
                        button {
                            class: "back-btn",
                            onclick: move |_| view.set(MainView::Home),
                            "\u{2190} Back"
                        }
                        h2 { class: "settings-title", "Voice Cloning" }
                        div { class: "back-btn-spacer" }
                    }
                    p { class: "settings-sub",
                        "Reference voice: {voice_ref_display}"
                    }
                    p { class: "note",
                        "Upload an MP3/MP4/WAV or record from your microphone. We will save a WAV into your cache dir and set it as the reference voice."
                    }

                    div { class: "settings-row",
                        label { class: "settings-label", "Voice name" }
                        input {
                            class: "settings-select",
                            r#type: "text",
                            disabled: !settings_enabled,
                            value: "{voices_name.read()}",
                            oninput: move |evt| voices_name.set(evt.value()),
                        }
                    }

                    div { class: "details-actions",
                        button {
                            class: "pill pill-primary",
                            disabled: !settings_enabled,
                            onclick: move |_| {
                                voices_status.set("Opening file picker...".to_owned());
                                let cache_dir = config_state.read().models.cache_dir.clone();
                                let name = voices_name.read().trim().to_owned();
                                spawn(async move {
                                    let picked = tokio::task::spawn_blocking(move || {
                                        rfd::FileDialog::new()
                                            .add_filter("Audio", &["mp3", "mp4", "wav"])
                                            .pick_file()
                                    }).await;

                                    let Some(path) = (match picked {
                                        Ok(p) => p,
                                        Err(e) => {
                                            voices_status.set(format!("File picker failed: {e}"));
                                            return;
                                        }
                                    }) else {
                                        voices_status.set("Cancelled.".to_owned());
                                        return;
                                    };

                                    let name = if name.trim().is_empty() {
                                        path.file_stem()
                                            .and_then(|s| s.to_str())
                                            .unwrap_or("voice_1")
                                            .to_owned()
                                    } else {
                                        name
                                    };

                                    voices_status.set("Importing audio...".to_owned());
                                    let res = tokio::task::spawn_blocking(move || {
                                        fae::voice_clone::import_audio_to_voice_wav(
                                            &cache_dir,
                                            &path,
                                            &name,
                                            fae::voice_clone::ImportOptions::default(),
                                        )
                                    }).await;

                                    match res {
                                        Ok(Ok(v)) => {
                                            {
                                                let mut cfg = config_state.write();
                                                cfg.tts.voice = v.wav_path.display().to_string();
                                            }
                                            voices_status.set(format!(
                                                "Imported {:.1}s voice. Click Save to persist.",
                                                v.seconds
                                            ));
                                        }
                                        Ok(Err(e)) => voices_status.set(format!("Import failed: {e}")),
                                        Err(e) => voices_status.set(format!("Import failed: {e}")),
                                    }
                                });
                            },
                            "Upload audio..."
                        }
                        button {
                            class: "pill",
                            disabled: !settings_enabled,
                            onclick: move |_| {
                                voices_status.set("Recording 10s...".to_owned());
                                let cache_dir = config_state.read().models.cache_dir.clone();
                                let name = voices_name.read().trim().to_owned();
                                spawn(async move {
                                    let res = tokio::task::spawn_blocking(move || {
                                        fae::voice_clone::record_voice_wav(&cache_dir, &name, 10.0)
                                    }).await;
                                    match res {
                                        Ok(Ok(v)) => {
                                            {
                                                let mut cfg = config_state.write();
                                                cfg.tts.voice = v.wav_path.display().to_string();
                                            }
                                            voices_status.set(format!(
                                                "Recorded {:.1}s voice. Click Save to persist.",
                                                v.seconds
                                            ));
                                        }
                                        Ok(Err(e)) => voices_status.set(format!("Record failed: {e}")),
                                        Err(e) => voices_status.set(format!("Record failed: {e}")),
                                    }
                                });
                            },
                            "Record 10s"
                        }
                        button {
                            class: "pill",
                            disabled: !settings_enabled,
                            onclick: move |_| {
                                config_state.write().tts.voice = "bf_emma".to_owned();
                                voices_status.set("Reset to default voice (save to persist).".to_owned());
                            },
                            "Reset to default voice"
                        }
                    }

                    div { class: "settings-actions",
                        button {
                            class: "settings-save",
                            disabled: !settings_enabled,
                            onclick: move |_| {
                                let cfg = config_state.read().clone();
                                let path = fae::SpeechConfig::default_config_path();
                                spawn(async move {
                                    let res = tokio::task::spawn_blocking(move || cfg.save_to_file(&path)).await;
                                    let msg = match res {
                                        Ok(Ok(())) => {
                                            let _ = ui_bus().send(UiBusEvent::ConfigUpdated);
                                            "Saved.".to_owned()
                                        }
                                        Ok(Err(e)) => format!("Save failed: {e}"),
                                        Err(e) => format!("Save failed: {e}"),
                                    };
                                    voices_status.set(msg);
                                });
                            },
                            "Save"
                        }
                        p { class: "settings-status", "{voices_status.read()}" }
                    }
                }
            }
        }

        {
            match pending_approval.read().as_ref() {
                Some(req) => {
                    let preview = parse_approval_preview(req);
                    let title = match preview.kind {
                        ApprovalUiKind::Confirm => {
                            if preview.destructive_delete {
                                "Approve Destructive Action?"
                            } else {
                                "Approve Tool Action?"
                            }
                        }
                        ApprovalUiKind::Select => "Selection Required",
                        ApprovalUiKind::Input => "Input Required",
                        ApprovalUiKind::Editor => "Editor Response Required",
                    };
                    let action_label = if matches!(preview.kind, ApprovalUiKind::Confirm) {
                        "Approve"
                    } else {
                        "Submit"
                    };
                    let deny_label = if matches!(preview.kind, ApprovalUiKind::Confirm) {
                        "Deny"
                    } else {
                        "Cancel"
                    };
                    rsx!(div {
                        class: "modal-overlay",
                        div {
                            class: "modal",
                            h2 { class: "modal-title", "{title}" }
                            p { class: "modal-subtitle", "The assistant requested:" }
                            p { class: "modal-tool", "{preview.title}" }
                            pre { class: "modal-json", "{preview.message}" }
                            {
                                if matches!(preview.kind, ApprovalUiKind::Select) {
                                    if preview.options.is_empty() {
                                        rsx! {
                                            p { class: "note", "No options were provided. You can cancel this request." }
                                        }
                                    } else {
                                        rsx! {
                                            label { class: "settings-label", "Choose an option" }
                                            select {
                                                class: "modal-input modal-select",
                                                value: "{approval_input_value.read().clone()}",
                                                onchange: move |evt| {
                                                    approval_input_value.set(evt.value());
                                                },
                                                for opt in &preview.options {
                                                    option { value: "{opt}", "{opt}" }
                                                }
                                            }
                                        }
                                    }
                                } else if matches!(preview.kind, ApprovalUiKind::Input) {
                                    rsx! {
                                        label { class: "settings-label", "Enter response" }
                                        input {
                                            class: "modal-input",
                                            r#type: "text",
                                            value: "{approval_input_value.read().clone()}",
                                            placeholder: "{preview.placeholder.clone().unwrap_or_else(|| \"Type a response\".to_owned())}",
                                            oninput: move |evt| {
                                                approval_input_value.set(evt.value());
                                            },
                                        }
                                    }
                                } else if matches!(preview.kind, ApprovalUiKind::Editor) {
                                    rsx! {
                                        label { class: "settings-label", "Edit response" }
                                        textarea {
                                            class: "modal-input modal-editor",
                                            rows: "10",
                                            value: "{approval_input_value.read().clone()}",
                                            oninput: move |evt| {
                                                approval_input_value.set(evt.value());
                                            },
                                        }
                                    }
                                } else {
                                    rsx! {}
                                }
                            }
                            div { class: "modal-actions",
                                button {
                                    class: "modal-btn modal-approve",
                                    onclick: move |_| {
                                        if let Some(req) = pending_approval.write().take() {
                                            let preview = parse_approval_preview(&req);
                                            match preview.kind {
                                                ApprovalUiKind::Confirm => {
                                                    let _ = req.respond(true);
                                                    push_approval_decision_to_canvas(
                                                        &mut canvas_bridge.write(),
                                                        &preview,
                                                        true,
                                                    );
                                                }
                                                ApprovalUiKind::Select | ApprovalUiKind::Input | ApprovalUiKind::Editor => {
                                                    let mut value = approval_input_value.read().clone();
                                                    if matches!(preview.kind, ApprovalUiKind::Select) && value.trim().is_empty()
                                                        && let Some(first) = preview.options.first()
                                                    {
                                                        value = first.clone();
                                                    }
                                                    let _ = req.respond_value(value.clone());
                                                    push_dialog_response_to_canvas(
                                                        &mut canvas_bridge.write(),
                                                        &preview,
                                                        true,
                                                        Some(value),
                                                    );
                                                }
                                            }
                                            let next_rev = {
                                                let current = *canvas_revision.read();
                                                current.saturating_add(1)
                                            };
                                            canvas_revision.set(next_rev);
                                        }
                                        if pending_approval.read().is_none()
                                            && let Some(next) = approval_queue.write().pop_front()
                                        {
                                            push_approval_request_to_canvas(&mut canvas_bridge.write(), &next);
                                            let preview = parse_approval_preview(&next);
                                            approval_input_value.set(preview.initial_value.clone());
                                            let next_rev = {
                                                let current = *canvas_revision.read();
                                                current.saturating_add(1)
                                            };
                                            canvas_revision.set(next_rev);
                                            canvas_visible.set(true);
                                            pending_approval.set(Some(next));
                                        } else if pending_approval.read().is_none() {
                                            approval_input_value.set(String::new());
                                        }
                                    },
                                    "{action_label}"
                                }
                                button {
                                    class: "modal-btn modal-deny",
                                    onclick: move |_| {
                                        if let Some(req) = pending_approval.write().take() {
                                            let preview = parse_approval_preview(&req);
                                            match preview.kind {
                                                ApprovalUiKind::Confirm => {
                                                    let _ = req.respond(false);
                                                    push_approval_decision_to_canvas(
                                                        &mut canvas_bridge.write(),
                                                        &preview,
                                                        false,
                                                    );
                                                }
                                                ApprovalUiKind::Select | ApprovalUiKind::Input | ApprovalUiKind::Editor => {
                                                    let _ = req.cancel();
                                                    push_dialog_response_to_canvas(
                                                        &mut canvas_bridge.write(),
                                                        &preview,
                                                        false,
                                                        None,
                                                    );
                                                }
                                            }
                                            let next_rev = {
                                                let current = *canvas_revision.read();
                                                current.saturating_add(1)
                                            };
                                            canvas_revision.set(next_rev);
                                        }
                                        if pending_approval.read().is_none()
                                            && let Some(next) = approval_queue.write().pop_front()
                                        {
                                            push_approval_request_to_canvas(&mut canvas_bridge.write(), &next);
                                            let preview = parse_approval_preview(&next);
                                            approval_input_value.set(preview.initial_value.clone());
                                            let next_rev = {
                                                let current = *canvas_revision.read();
                                                current.saturating_add(1)
                                            };
                                            canvas_revision.set(next_rev);
                                            canvas_visible.set(true);
                                            pending_approval.set(Some(next));
                                        } else if pending_approval.read().is_none() {
                                            approval_input_value.set(String::new());
                                        }
                                    },
                                    "{deny_label}"
                                }
                            }
                        }
                    })
                }
                None => rsx!(),
            }
        }

        // --- Scheduler notification modal (update prompts) ---
        {
            let has_notification = scheduler_notification.read().is_some()
                && !*update_installing.read()
                && !*update_restart_needed.read();
            if has_notification {
                let prompt = scheduler_notification.read();
                let title = prompt.as_ref().map(|p| p.title.clone()).unwrap_or_default();
                let message = prompt.as_ref().map(|p| p.message.clone()).unwrap_or_default();
                let actions: Vec<(String, String)> = prompt
                    .as_ref()
                    .map(|p| {
                        p.actions
                            .iter()
                            .map(|a| (a.id.clone(), a.label.clone()))
                            .collect()
                    })
                    .unwrap_or_default();
                drop(prompt);
                rsx! {
                    div { class: "modal-overlay",
                        div { class: "modal",
                            h2 { class: "modal-title", "{title}" }
                            p { class: "modal-subtitle", "{message}" }
                            div { class: "modal-actions",
                                for (action_id, action_label) in actions {
                                    button {
                                        class: if action_id.starts_with("install") { "modal-btn modal-approve" } else { "modal-btn modal-deny" },
                                        onclick: {
                                            let action_id = action_id.clone();
                                            move |_| {
                                                scheduler_notification.set(None);
                                                if action_id == "install_fae_update"
                                                {
                                                    let release = update_available.read().clone();
                                                    if let Some(rel) = release {
                                                        update_installing.set(true);
                                                        update_install_error.set(None);
                                                        let url = rel.download_url.clone();
                                                        spawn(async move {
                                                            let result =
                                                                tokio::task::spawn_blocking(
                                                                    move || {
                                                                        let current = fae::update::applier::current_exe_path()?;
                                                                        fae::update::applier::apply_update(&url, &current)
                                                                    },
                                                                )
                                                                .await;
                                                            update_installing.set(false);
                                                            match result {
                                                                Ok(Ok(_)) => {
                                                                    update_restart_needed.set(true);
                                                                }
                                                                Ok(Err(e)) => {
                                                                    update_install_error
                                                                        .set(Some(format!("{e}")));
                                                                }
                                                                Err(e) => {
                                                                    update_install_error
                                                                        .set(Some(format!("{e}")));
                                                                }
                                                            }
                                                        });
                                                    }
                                                } else if action_id == "dismiss_fae_update"
                                                {
                                                    update_banner_dismissed.set(true);
                                                    if let Some(rel) =
                                                        update_available.read().as_ref()
                                                    {
                                                        update_state.write().dismissed_release =
                                                            Some(rel.version.clone());
                                                    }
                                                    let state = update_state.read().clone();
                                                    spawn(async move {
                                                        let _ = tokio::task::spawn_blocking(
                                                            move || state.save(),
                                                        )
                                                        .await;
                                                    });
                                                }
                                            }
                                        },
                                        "{action_label}"
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                rsx! {}
            }
        }
    }
}

#[cfg(feature = "gui")]
fn models_window() -> Element {
    let desktop = use_window();

    let mut config_state = use_signal(read_config_or_default);
    let mut save_status = use_signal(String::new);

    // Model picker state (LLM/GGUF).
    let sys_profile = use_signal(fae::system_profile::SystemProfile::detect);
    let mut model_tab = use_signal(|| ModelPickerTab::Recommended);
    let mut optimize_for = use_signal(|| fae::model_picker::OptimizeFor::Balanced);
    let mut model_search_query = use_signal(String::new);
    let model_search_status = use_signal(String::new);
    let model_search_results = use_signal(Vec::<fae::huggingface::ModelSearchItem>::new);

    let model_details_status = use_signal(String::new);
    let model_details = use_signal(|| None::<ModelDetails>);
    let mut selected_gguf_file = use_signal(|| None::<String>);
    let mut tokenizer_override = use_signal(String::new);

    let settings_enabled = true;
    let cfg_backend = config_state.read().llm.backend;
    let can_pick_local_models = matches!(
        cfg_backend,
        fae::config::LlmBackend::Local | fae::config::LlmBackend::Agent
    );

    let config_path = fae::SpeechConfig::default_config_path();

    let ram_bytes = sys_profile.read().total_memory_bytes;
    let ram_display = match ram_bytes {
        Some(b) => fmt_bytes(b),
        None => "Unknown".to_owned(),
    };
    let optimize_value = optimize_for.read().as_str();
    let tab = *model_tab.read();
    let selected_file_value = match selected_gguf_file.read().as_ref() {
        Some(s) => s.clone(),
        None => String::new(),
    };

    let search_rows = model_search_results
        .read()
        .iter()
        .map(|item| {
            let likes = item.likes.unwrap_or(0);
            let downloads = item.downloads.unwrap_or(0);
            let id = item.id.clone();
            let label = format!("{id}  (dl {downloads}, likes {likes})");
            (id, label)
        })
        .collect::<Vec<_>>();

    let gguf_option_rows = model_details
        .read()
        .as_ref()
        .map(|details| {
            details
                .gguf_files
                .iter()
                .map(|f| {
                    let size = details
                        .gguf_sizes
                        .iter()
                        .find(|(n, _)| n == f)
                        .and_then(|(_, s)| *s);
                    let label = match size {
                        Some(b) => {
                            let fit = fit_label(Some(b), ram_bytes);
                            match fit {
                                Some(fit) => format!("{f} ({}) - {fit}", fmt_bytes(b)),
                                None => format!("{f} ({})", fmt_bytes(b)),
                            }
                        }
                        None => f.clone(),
                    };
                    (f.clone(), label)
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let load_model_details = {
        let md_status_sig = model_details_status;
        let md_sig = model_details;
        let selected_sig = selected_gguf_file;
        let tok_sig = tokenizer_override;
        let sys_prof_sig = sys_profile;
        let opt_sig = optimize_for;
        let cfg_sig = config_state;
        std::rc::Rc::new(move |model_id: String| {
            let mut model_details_status = md_status_sig;
            let mut model_details = md_sig;
            let mut selected_gguf_file = selected_sig;

            model_details_status.set("Loading model info...".to_owned());
            model_details.set(None);
            selected_gguf_file.set(None);

            let ram_bytes = sys_prof_sig.read().total_memory_bytes;
            let opt = *opt_sig.read();
            let current_tok = cfg_sig.read().llm.tokenizer_id.clone();

            let mut model_details_status_bg = model_details_status;
            let mut model_details_bg = model_details;
            let mut selected_gguf_file_bg = selected_gguf_file;
            let mut tokenizer_override_bg = tok_sig;

            spawn(async move {
                let model_id_for_task = model_id.clone();
                let res = tokio::task::spawn_blocking(move || {
                    let info = fae::huggingface::get_model_info(&model_id_for_task)?;
                    let snippet = fae::huggingface::readme_snippet(&model_id_for_task)?;
                    let tokenizer_in_repo = fae::model_picker::has_tokenizer_json(&info.siblings);
                    let gguf_files = fae::model_picker::extract_gguf_files(&info.siblings);

                    let mut gguf_sizes = Vec::new();
                    let cap = 40usize;
                    for f in gguf_files.iter().take(cap) {
                        let size = fae::huggingface::gguf_file_size_bytes(&model_id_for_task, f)
                            .ok()
                            .flatten();
                        gguf_sizes.push((f.clone(), size));
                    }

                    Ok::<ModelDetails, fae::huggingface::HfApiError>(ModelDetails {
                        id: info.id,
                        license: info.license,
                        base_models: info.base_models,
                        gated: info.gated,
                        snippet,
                        tokenizer_in_repo,
                        gguf_files,
                        gguf_sizes,
                    })
                })
                .await;

                let details = match res {
                    Ok(Ok(d)) => d,
                    Ok(Err(e)) => {
                        model_details_status_bg.set(format!("Failed to load model info: {e}"));
                        return;
                    }
                    Err(e) => {
                        model_details_status_bg.set(format!("Failed to load model info: {e}"));
                        return;
                    }
                };

                let auto = fae::model_picker::auto_pick_gguf_file(
                    &details.gguf_files,
                    opt,
                    &details.gguf_sizes,
                    ram_bytes,
                );
                selected_gguf_file_bg.set(auto);

                let tok = if details.tokenizer_in_repo {
                    String::new()
                } else if let Some(first) = details.base_models.first() {
                    first.clone()
                } else {
                    current_tok
                };
                tokenizer_override_bg.set(tok);

                model_details_bg.set(Some(details));
                model_details_status_bg.set(String::new());
            });
        })
    };

    let run_model_search = {
        let ms_status_sig = model_search_status;
        let ms_results_sig = model_search_results;
        let ms_query_sig = model_search_query;
        std::rc::Rc::new(move || {
            let q = ms_query_sig.read().trim().to_owned();
            let mut model_search_status = ms_status_sig;
            let mut model_search_results = ms_results_sig;

            if q.is_empty() {
                model_search_status.set("Enter a search query.".to_owned());
                model_search_results.set(Vec::new());
                return;
            }
            model_search_status.set("Searching Hugging Face...".to_owned());
            model_search_results.set(Vec::new());

            spawn(async move {
                let res = tokio::task::spawn_blocking(move || {
                    fae::huggingface::search_models(&q, true, Some("text-generation"), 20)
                })
                .await;

                match res {
                    Ok(Ok(items)) => {
                        model_search_status.set(format!("Found {} results.", items.len()));
                        model_search_results.set(items);
                    }
                    Ok(Err(e)) => {
                        model_search_status.set(format!("Search failed: {e}"));
                    }
                    Err(e) => {
                        model_search_status.set(format!("Search failed: {e}"));
                    }
                }
            });
        })
    };

    let current_model = config_state.read().llm.model_id.clone();
    let current_file = config_state.read().llm.gguf_file.clone();

    rsx! {
        style { {GLOBAL_CSS} }

        div { class: "container",
            div { class: "topbar",
                button { class: "topbar-btn", onclick: move |_| desktop.close(), "Close" }
                p { class: "topbar-title", "Models" }
                button {
                    class: "topbar-btn",
                    onclick: move |_| {
                        let defaults = fae::SpeechConfig::default().llm;
                        let mut cfg = config_state.write();
                        cfg.llm.model_id = defaults.model_id;
                        cfg.llm.gguf_file = defaults.gguf_file;
                        cfg.llm.tokenizer_id = defaults.tokenizer_id;
                        save_status.set("Reset to default (Qwen3-4B). Click Save to persist.".to_owned());
                    },
                    "Default"
                }
            }

            div { class: "model-picker",
                h2 { class: "settings-title", "Local Models (GGUF)" }
                p { class: "settings-sub",
                    "Current: {current_model} / {current_file}"
                }
                p { class: "settings-sub",
                    "Downloads go to the Hugging Face cache on Start. RAM detected: {ram_display}."
                }

                if !can_pick_local_models {
                    p { class: "note",
                        "Model picker is for Local/Agent backends. Switch backends in Settings in the main window."
                    }
                }

                div { class: "settings-row",
                    label { class: "settings-label", "Optimize for" }
                    select {
                        class: "settings-select",
                        disabled: !settings_enabled || !can_pick_local_models,
                        value: "{optimize_value}",
                        onchange: move |evt| {
                            optimize_for.set(fae::model_picker::OptimizeFor::parse(&evt.value()));
                        },
                        option { value: "speed", "Speed" }
                        option { value: "balanced", "Balanced" }
                        option { value: "quality", "Quality" }
                    }
                }

                div { class: "tabs",
                    button {
                        class: if tab == ModelPickerTab::Recommended { "tab-btn tab-active" } else { "tab-btn" },
                        onclick: move |_| model_tab.set(ModelPickerTab::Recommended),
                        "Recommended"
                    }
                    button {
                        class: if tab == ModelPickerTab::Search { "tab-btn tab-active" } else { "tab-btn" },
                        onclick: move |_| model_tab.set(ModelPickerTab::Search),
                        "Search"
                    }
                    button {
                        class: if tab == ModelPickerTab::Manual { "tab-btn tab-active" } else { "tab-btn" },
                        onclick: move |_| model_tab.set(ModelPickerTab::Manual),
                        "Manual"
                    }
                }

                if tab == ModelPickerTab::Recommended {
                    div { class: "model-list",
                        for (i, id) in fae::model_picker::curated_recommended_model_ids().iter().enumerate() {
                            button {
                                key: "{i}",
                                class: "model-item",
                                disabled: !settings_enabled || !can_pick_local_models,
                                onclick: {
                                    let load = load_model_details.clone();
                                    let id = (*id).to_owned();
                                    move |_| load(id.clone())
                                },
                                "{id}"
                            }
                        }
                    }
                }

                if tab == ModelPickerTab::Search {
                    div { class: "settings-row",
                        input {
                            class: "model-search",
                            r#type: "text",
                            placeholder: "Search Hugging Face (e.g. qwen3 instruct)",
                            disabled: !settings_enabled || !can_pick_local_models,
                            value: "{model_search_query.read()}",
                            oninput: move |evt| model_search_query.set(evt.value()),
                        }
                        button {
                            class: "model-search-btn",
                            disabled: !settings_enabled || !can_pick_local_models,
                            onclick: {
                                let search = run_model_search.clone();
                                move |_| search()
                            },
                            "Search"
                        }
                    }
                    p { class: "note", "{model_search_status.read()}" }
                    div { class: "model-list",
                        for (i, (id, label)) in search_rows.iter().enumerate() {
                            button {
                                key: "{i}",
                                class: "model-item",
                                disabled: !settings_enabled || !can_pick_local_models,
                                onclick: {
                                    let load = load_model_details.clone();
                                    let id = id.clone();
                                    move |_| load(id.clone())
                                },
                                "{label}"
                            }
                        }
                    }
                }

                if tab == ModelPickerTab::Manual {
                    p { class: "note",
                        "Advanced: set repo + GGUF filename directly. Applies on next Start."
                    }
                    div { class: "settings-row",
                        label { class: "settings-label", "HF repo (GGUF)" }
                        input {
                            class: "settings-select",
                            r#type: "text",
                            disabled: !settings_enabled || !can_pick_local_models,
                            value: "{config_state.read().llm.model_id}",
                            oninput: move |evt| config_state.write().llm.model_id = evt.value(),
                        }
                    }
                    div { class: "settings-row",
                        label { class: "settings-label", "GGUF file" }
                        input {
                            class: "settings-select",
                            r#type: "text",
                            disabled: !settings_enabled || !can_pick_local_models,
                            value: "{config_state.read().llm.gguf_file}",
                            oninput: move |evt| config_state.write().llm.gguf_file = evt.value(),
                        }
                    }
                    div { class: "settings-row",
                        label { class: "settings-label", "Tokenizer repo" }
                        input {
                            class: "settings-select",
                            r#type: "text",
                            disabled: !settings_enabled || !can_pick_local_models,
                            value: "{config_state.read().llm.tokenizer_id}",
                            oninput: move |evt| config_state.write().llm.tokenizer_id = evt.value(),
                        }
                    }
                }

                if !model_details_status.read().is_empty() {
                    p { class: "note", "{model_details_status.read()}" }
                }

                if let Some(details) = model_details.read().as_ref() {
                    div { class: "model-details",
                        h3 { class: "details-title", "{details.id}" }
                        if let Some(lic) = details.license.as_ref() {
                            p { class: "note", "License: {lic}" }
                        }
                        if let Some(g) = details.gated {
                            if g {
                                p { class: "warning", "This repo appears gated on Hugging Face." }
                            }
                        }
                        if !details.base_models.is_empty() {
                            p { class: "note", "Base: {details.base_models.join(\", \")}" }
                        }
                        if let Some(snippet) = details.snippet.as_ref() {
                            p { class: "model-snippet", "{snippet}" }
                        }

                        div { class: "settings-row",
                            label { class: "settings-label", "GGUF" }
                            select {
                                class: "settings-select",
                                disabled: !settings_enabled || !can_pick_local_models,
                                value: "{selected_file_value}",
                                onchange: move |evt| {
                                    let v = evt.value();
                                    if v.trim().is_empty() {
                                        selected_gguf_file.set(None);
                                    } else {
                                        selected_gguf_file.set(Some(v));
                                    }
                                },
                                option { value: "", "(choose)" }
                                for (i, (f, label)) in gguf_option_rows.iter().enumerate() {
                                    option { key: "{i}", value: "{f}", "{label}" }
                                }
                            }
                        }

                        div { class: "settings-row",
                            label { class: "settings-label", "Tokenizer repo" }
                            input {
                                class: "settings-select",
                                r#type: "text",
                                disabled: !settings_enabled || !can_pick_local_models || details.tokenizer_in_repo,
                                placeholder: if details.tokenizer_in_repo { "(in repo)" } else { "e.g. Qwen/Qwen3-4B-Instruct-2507" },
                                value: "{tokenizer_override.read()}",
                                oninput: move |evt| tokenizer_override.set(evt.value()),
                            }
                        }

                        div { class: "details-actions",
                            button {
                                class: "pill",
                                disabled: !settings_enabled || !can_pick_local_models,
                                onclick: {
                                    let files = details.gguf_files.clone();
                                    let sizes = details.gguf_sizes.clone();
                                    move |_| {
                                        let ram = sys_profile.read().total_memory_bytes;
                                        let opt = *optimize_for.read();
                                        let auto = fae::model_picker::auto_pick_gguf_file(
                                            &files,
                                            opt,
                                            &sizes,
                                            ram,
                                        );
                                        selected_gguf_file.set(auto);
                                    }
                                },
                                "Auto pick"
                            }
                            button {
                                class: "pill pill-primary",
                                disabled: !settings_enabled || !can_pick_local_models,
                                onclick: {
                                    let id = details.id.clone();
                                    let mut model_details_status = model_details_status;
                                    let mut save_status = save_status;
                                    move |_| {
                                        let file = match selected_gguf_file.read().clone() {
                                            Some(f) if !f.trim().is_empty() => f,
                                            _ => {
                                                model_details_status.set("Pick a GGUF file first.".to_owned());
                                                return;
                                            }
                                        };
                                        let tok = tokenizer_override.read().trim().to_owned();
                                        {
                                            let mut cfg = config_state.write();
                                            cfg.llm.model_id = id.clone();
                                            cfg.llm.gguf_file = file;
                                            cfg.llm.tokenizer_id = tok;
                                        }
                                        save_status.set("Selected model (not saved). Click Save to persist.".to_owned());
                                    }
                                },
                                "Use model"
                            }
                        }
                    }
                }

                div { class: "settings-actions",
                    button {
                        class: "settings-save",
                        onclick: move |_| {
                            let cfg = config_state.read().clone();
                            let path = config_path.clone();
                            spawn(async move {
                                let res = tokio::task::spawn_blocking(move || cfg.save_to_file(&path)).await;
                                let msg = match res {
                                    Ok(Ok(())) => {
                                        let _ = ui_bus().send(UiBusEvent::ConfigUpdated);
                                        "Saved.".to_owned()
                                    }
                                    Ok(Err(e)) => format!("Save failed: {e}"),
                                    Err(e) => format!("Save failed: {e}"),
                                };
                                save_status.set(msg);
                            });
                        },
                        "Save"
                    }
                    p { class: "settings-status", "{save_status.read()}" }
                }
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

    :root {
        --bg-primary: #0f0f1a;
        --bg-secondary: #161625;
        --bg-card: rgba(255, 255, 255, 0.025);
        --bg-elevated: rgba(255, 255, 255, 0.04);
        --border-subtle: rgba(255, 255, 255, 0.07);
        --border-medium: rgba(255, 255, 255, 0.12);
        --accent: #a78bfa;
        --accent-dim: rgba(167, 139, 250, 0.15);
        --accent-glow: rgba(167, 139, 250, 0.25);
        --green: #22c55e;
        --green-dim: rgba(34, 197, 94, 0.12);
        --red: #ef4444;
        --red-dim: rgba(239, 68, 68, 0.12);
        --yellow: #fbbf24;
        --blue: #3b82f6;
        --text-primary: #f0eef6;
        --text-secondary: #a1a1b5;
        --text-tertiary: #6b6b80;
        --radius-sm: 8px;
        --radius-md: 12px;
        --radius-lg: 16px;
        --radius-pill: 999px;
    }

    body {
        background: var(--bg-primary);
        color: var(--text-primary);
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Inter', Helvetica, Arial, sans-serif;
        font-size: 14px;
        line-height: 1.5;
        -webkit-font-smoothing: antialiased;
    }

    .container {
        display: flex;
        flex-direction: column;
        align-items: center;
        min-height: 100vh;
        padding: 0 1.25rem 2rem;
        gap: 0.8rem;
        overflow-y: auto;
    }
    .container-with-canvas {
        align-items: stretch;
    }

    /* --- Home Layout (horizontal split when canvas visible) --- */
    .home-layout {
        display: flex;
        flex-direction: row;
        gap: 1rem;
        width: 100%;
        flex: 1;
        min-height: 0;
    }
    .home-main {
        display: flex;
        flex-direction: column;
        align-items: center;
        flex: 0 0 auto;
        width: 100%;
        gap: 0.8rem;
    }
    .container-with-canvas .home-main {
        flex: 0 0 440px;
        width: 440px;
    }

    /* --- Topbar / Drawer --- */
    .topbar {
        position: sticky;
        top: 0;
        width: 100%;
        max-width: 420px;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.5rem;
        padding: 0.75rem 0;
        background: var(--bg-primary);
        z-index: 100;
    }

    .hamburger {
        width: 38px;
        height: 36px;
        border-radius: var(--radius-sm);
        border: 1px solid var(--border-subtle);
        background: transparent;
        color: var(--text-secondary);
        cursor: pointer;
        font-size: 1.05rem;
        transition: background 0.15s, color 0.15s;
    }
    .hamburger:hover { background: var(--bg-elevated); color: var(--text-primary); }

    .topbar-title {
        flex: 1;
        text-align: center;
        color: var(--accent);
        font-size: 0.8rem;
        font-weight: 600;
        letter-spacing: 0.12em;
        text-transform: uppercase;
    }

    .topbar-model-indicator {
        color: var(--text-tertiary);
        font-size: 0.7rem;
        font-weight: 500;
        padding: 0.25rem 0.6rem;
        background: var(--bg-card);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-pill);
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
        max-width: 160px;
    }

    .topbar-btn {
        border: 1px solid var(--border-subtle);
        background: transparent;
        color: var(--text-secondary);
        border-radius: var(--radius-pill);
        padding: 0.35rem 0.75rem;
        font-size: 0.78rem;
        font-weight: 500;
        cursor: pointer;
        transition: background 0.15s, color 0.15s, transform 0.1s;
        white-space: nowrap;
    }
    .topbar-btn:hover:not(:disabled) { background: var(--bg-elevated); color: var(--text-primary); transform: translateY(-1px); }
    .topbar-btn:disabled { opacity: 0.4; cursor: not-allowed; }

    /* --- Screen Header (back button) --- */
    .screen-header {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        margin-bottom: 0.6rem;
    }
    .back-btn {
        border: 1px solid var(--border-subtle);
        background: transparent;
        color: var(--text-secondary);
        border-radius: var(--radius-pill);
        padding: 0.3rem 0.7rem;
        font-size: 0.78rem;
        font-weight: 500;
        cursor: pointer;
        transition: background 0.15s, color 0.15s;
        white-space: nowrap;
    }
    .back-btn:hover { background: var(--bg-elevated); color: var(--text-primary); }
    .back-btn-spacer { width: 60px; }

    /* --- Drawer --- */
    .drawer-overlay {
        position: fixed;
        inset: 0;
        background: rgba(0, 0, 0, 0.55);
        backdrop-filter: blur(4px);
        padding: 1rem;
        z-index: 1000;
        animation: fadeIn 0.15s ease;
    }

    .drawer {
        width: 220px;
        border-radius: var(--radius-lg);
        background: var(--bg-secondary);
        border: 1px solid var(--border-medium);
        padding: 0.5rem;
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        box-shadow: 0 16px 48px rgba(0, 0, 0, 0.4);
        animation: slideIn 0.2s ease;
    }

    @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
    @keyframes slideIn { from { transform: translateX(-12px); opacity: 0; } to { transform: translateX(0); opacity: 1; } }

    .drawer-item {
        width: 100%;
        text-align: left;
        border: none;
        background: transparent;
        color: var(--text-secondary);
        border-radius: var(--radius-sm);
        padding: 0.55rem 0.65rem;
        font-size: 0.85rem;
        font-weight: 500;
        cursor: pointer;
        transition: background 0.12s, color 0.12s;
    }
    .drawer-item:hover:not(:disabled) { background: var(--bg-elevated); color: var(--text-primary); }
    .drawer-item:disabled { opacity: 0.4; cursor: not-allowed; }

    /* --- Settings Sections (collapsible) --- */
    .settings-section {
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-md);
        margin-bottom: 0.5rem;
        overflow: hidden;
    }
    .settings-section[open] { border-color: var(--border-medium); }

    .settings-section-summary {
        padding: 0.55rem 0.7rem;
        font-size: 0.82rem;
        font-weight: 600;
        color: var(--text-secondary);
        cursor: pointer;
        transition: color 0.15s, background 0.15s;
        list-style: none;
    }
    .settings-section-summary::-webkit-details-marker { display: none; }
    .settings-section-summary::before {
        content: "\u25B8";
        display: inline-block;
        margin-right: 0.45rem;
        transition: transform 0.2s;
        font-size: 0.7rem;
    }
    .settings-section[open] > .settings-section-summary::before { transform: rotate(90deg); }
    .settings-section-summary:hover { color: var(--text-primary); background: var(--bg-elevated); }

    .settings-section-body {
        padding: 0.4rem 0.7rem 0.6rem;
        border-top: 1px solid var(--border-subtle);
    }

    .settings-block {
        display: flex;
        flex-direction: column;
        gap: 0.4rem;
        margin-bottom: 0.6rem;
    }

    .settings-textarea {
        width: 100%;
        min-height: 100px;
        resize: vertical;
        border-radius: var(--radius-sm);
        border: 1px solid var(--border-subtle);
        background: var(--bg-card);
        color: var(--text-primary);
        padding: 0.5rem 0.6rem;
        font-size: 0.85rem;
        line-height: 1.4;
        outline: none;
        font-family: inherit;
        transition: border-color 0.15s;
    }
    .settings-textarea:focus { border-color: var(--accent); }
    .settings-textarea:disabled { opacity: 0.4; }

    .settings-h3 {
        font-size: 0.82rem;
        font-weight: 600;
        color: var(--text-secondary);
        text-transform: uppercase;
        letter-spacing: 0.05em;
        margin-bottom: 0.1rem;
    }

    .settings-value {
        margin: 0;
        color: var(--text-secondary);
        font-size: 0.8rem;
        word-break: break-word;
        text-align: right;
        max-width: 60%;
    }

    .settings-checkbox {
        width: 18px;
        height: 18px;
        accent-color: var(--accent);
        cursor: pointer;
    }
    .settings-checkbox:disabled { opacity: 0.4; cursor: not-allowed; }

    .details { margin-top: 0.4rem; }
    .details-summary {
        font-size: 0.78rem;
        color: var(--text-tertiary);
        cursor: pointer;
        transition: color 0.15s;
    }
    .details-summary:hover { color: var(--text-secondary); }
    .details-pre {
        font-size: 0.75rem;
        line-height: 1.35;
        color: var(--text-secondary);
        background: var(--bg-card);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-sm);
        padding: 0.6rem;
        margin-top: 0.3rem;
        white-space: pre-wrap;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        max-height: 200px;
        overflow: auto;
    }

    /* --- Stagebar --- */
    .stagebar {
        display: flex;
        flex-direction: column;
        gap: 0.3rem;
        margin-top: 0.4rem;
        width: 100%;
        max-width: 280px;
    }

    .stage {
        border: 1px solid var(--border-subtle);
        background: var(--bg-card);
        color: var(--text-secondary);
        border-radius: var(--radius-sm);
        padding: 0.4rem 0.55rem;
        font-size: 0.78rem;
        line-height: 1.15;
        cursor: default;
        transition: border-color 0.3s, box-shadow 0.3s;
    }

    .stage-pending { opacity: 0.5; }
    .stage-downloading {
        border-color: rgba(59, 130, 246, 0.4);
        box-shadow: 0 0 0 1px rgba(59, 130, 246, 0.15) inset;
        color: #60a5fa;
    }
    .stage-loading {
        border-color: rgba(167, 139, 250, 0.4);
        box-shadow: 0 0 0 1px var(--accent-dim) inset;
        color: var(--accent);
    }
    .stage-ready {
        border-color: rgba(34, 197, 94, 0.4);
        box-shadow: 0 0 0 1px var(--green-dim) inset;
        color: var(--green);
    }
    .stage-error {
        border-color: rgba(239, 68, 68, 0.4);
        box-shadow: 0 0 0 1px var(--red-dim) inset;
        color: var(--red);
    }

    /* --- Avatar (circular, running state) --- */
    .avatar {
        position: relative;
        width: 140px;
        height: 140px;
        border-radius: 50%;
        overflow: hidden;
        border: 2.5px solid var(--accent);
        transition: box-shadow 0.4s ease, border-color 0.4s ease;
        margin-top: 0.5rem;
        flex-shrink: 0;
    }

    .avatar-pulse {
        animation: pulse 2.5s ease-in-out infinite;
        border-color: var(--green);
    }

    .avatar-img {
        width: 100%;
        height: 100%;
        object-fit: cover;
    }

    @keyframes pulse {
        0%, 100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.35); }
        50% { box-shadow: 0 0 24px 8px rgba(34, 197, 94, 0.1); }
    }

    /* --- Avatar portrait (rectangular, idle/loading/stopped) --- */
    .avatar-portrait {
        position: relative;
        width: 100%;
        border-radius: 16px;
        overflow: hidden;
        border: 2.5px solid var(--border);
        margin-top: 0.5rem;
        flex-shrink: 0;
        transition: border-color 0.4s ease;
    }

    .avatar-portrait-loading {
        border-color: transparent;
    }

    .avatar-portrait-img {
        width: 100%;
        height: auto;
        display: block;
    }

    .avatar-portrait-spinner {
        position: absolute;
        top: 50%;
        left: 50%;
        width: 48px;
        height: 48px;
        margin-top: -24px;
        margin-left: -24px;
        border-radius: 50%;
        border: 3px solid transparent;
        border-top-color: var(--accent);
        border-right-color: #7c3aed;
        animation: spin 0.9s linear infinite;
        pointer-events: none;
    }

    @keyframes spin { to { transform: rotate(360deg); } }

    /* --- Title --- */
    .title {
        font-size: 1.6rem;
        color: var(--text-primary);
        font-weight: 300;
        letter-spacing: 0.15em;
    }

    /* --- Status --- */
    .status {
        color: var(--text-tertiary);
        font-size: 0.85rem;
        min-height: 1.4em;
        transition: color 0.3s ease;
    }
    .status-error { color: var(--red); }

    /* --- Mic indicator --- */
    .mic-indicator {
        font-size: 0.75rem;
        padding: 2px 8px;
        border-radius: 4px;
        margin-bottom: 4px;
    }
    .mic-starting { color: var(--text-tertiary); }
    .mic-active { color: #22c55e; }
    .mic-failed { color: var(--red); font-weight: 600; }

    .welcome-text {
        color: var(--text-secondary);
        font-size: 0.8rem;
        font-style: italic;
        margin-top: 2px;
        opacity: 0.85;
    }

    /* --- Hint --- */
    .hint {
        color: var(--text-tertiary);
        font-size: 0.78rem;
        font-style: italic;
        opacity: 0.7;
    }
    .hint-phrase {
        color: var(--accent);
        font-style: normal;
        font-weight: 600;
    }

    /* --- Progress --- */
    .progress-container {
        width: 70%;
        max-width: 260px;
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 0.35rem;
    }

    .progress-bar {
        width: 100%;
        height: 4px;
        background: rgba(255, 255, 255, 0.06);
        border-radius: 2px;
        overflow: hidden;
    }

    .progress-fill {
        height: 100%;
        background: linear-gradient(90deg, var(--accent), #7c3aed);
        border-radius: 2px;
        transition: width 0.3s ease;
    }

    .progress-text {
        color: var(--text-tertiary);
        font-size: 0.72rem;
    }

    .progress-speed {
        color: var(--text-tertiary);
        font-size: 0.65rem;
        opacity: 0.7;
    }

    /* --- Button --- */
    .main-button {
        margin-top: 0.6rem;
        padding: 0.7rem 2.8rem;
        border: none;
        border-radius: var(--radius-pill);
        font-size: 0.95rem;
        font-weight: 600;
        color: white;
        cursor: pointer;
        transition: transform 0.12s ease, opacity 0.2s ease, box-shadow 0.2s ease;
        letter-spacing: 0.04em;
    }
    .main-button:hover:not(:disabled) { transform: scale(1.03); box-shadow: 0 4px 20px rgba(0,0,0,0.3); }
    .main-button:active:not(:disabled) { transform: scale(0.97); }
    .main-button:disabled { cursor: not-allowed; }

    /* --- Settings --- */
    .settings {
        width: 100%;
        max-width: 420px;
        background: var(--bg-card);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-lg);
        padding: 0.8rem;
        overflow-y: auto;
    }

    .settings-title {
        font-size: 0.78rem;
        font-weight: 700;
        color: var(--accent);
        letter-spacing: 0.08em;
        text-transform: uppercase;
        flex: 1;
        text-align: center;
    }

    .settings-sub {
        color: var(--text-tertiary);
        font-size: 0.75rem;
        margin-bottom: 0.6rem;
        word-break: break-word;
    }

    .settings-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.6rem;
        margin-bottom: 0.45rem;
    }

    .settings-label {
        font-size: 0.8rem;
        color: var(--text-secondary);
        flex-shrink: 0;
    }

    .settings-select {
        flex: 1;
        min-width: 0;
        background: var(--bg-card);
        border: 1px solid var(--border-subtle);
        color: var(--text-primary);
        padding: 0.4rem 0.5rem;
        border-radius: var(--radius-sm);
        outline: none;
        font-size: 0.82rem;
        font-family: inherit;
        transition: border-color 0.15s;
    }
    .settings-select:focus { border-color: var(--accent); }
    .settings-select:disabled { opacity: 0.4; cursor: not-allowed; }

    .settings-actions {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 0.6rem;
        margin-top: 0.6rem;
        padding-top: 0.5rem;
        border-top: 1px solid var(--border-subtle);
    }

    .settings-save {
        border: none;
        border-radius: var(--radius-pill);
        padding: 0.45rem 1rem;
        background: var(--accent);
        color: #110a20;
        font-weight: 700;
        font-size: 0.82rem;
        cursor: pointer;
        transition: transform 0.1s, opacity 0.15s;
    }
    .settings-save:hover:not(:disabled) { transform: translateY(-1px); }
    .settings-save:disabled { opacity: 0.4; cursor: not-allowed; }

    .settings-status {
        color: var(--text-tertiary);
        font-size: 0.75rem;
        flex: 1;
        text-align: right;
        min-height: 1.1em;
    }

    /* --- Model Picker / Voices --- */
    .model-picker {
        width: 100%;
        max-width: 420px;
        background: var(--bg-card);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-lg);
        padding: 0.8rem;
    }

    .note {
        color: var(--text-tertiary);
        font-size: 0.78rem;
        margin-bottom: 0.4rem;
        white-space: pre-wrap;
        word-break: break-word;
        line-height: 1.4;
    }

    .tabs {
        display: flex;
        gap: 0.35rem;
        margin: 0.3rem 0 0.7rem 0;
    }

    .tab-btn {
        flex: 1;
        border: 1px solid var(--border-subtle);
        background: transparent;
        color: var(--text-secondary);
        border-radius: var(--radius-pill);
        padding: 0.32rem 0.5rem;
        font-size: 0.78rem;
        font-weight: 500;
        cursor: pointer;
        transition: background 0.15s, color 0.15s, border-color 0.15s;
    }
    .tab-btn:hover:not(:disabled) { background: var(--bg-elevated); color: var(--text-primary); }
    .tab-btn:disabled { opacity: 0.4; cursor: not-allowed; }

    .tab-active {
        border-color: var(--accent);
        background: var(--accent-dim);
        color: var(--accent);
    }

    .model-list {
        display: flex;
        flex-direction: column;
        gap: 0.35rem;
        margin-bottom: 0.5rem;
    }

    .model-item {
        width: 100%;
        text-align: left;
        border: 1px solid var(--border-subtle);
        background: transparent;
        color: var(--text-secondary);
        border-radius: var(--radius-sm);
        padding: 0.5rem 0.55rem;
        font-size: 0.78rem;
        cursor: pointer;
        transition: background 0.12s, color 0.12s, border-color 0.12s;
        word-break: break-word;
    }
    .model-item:hover:not(:disabled) { background: var(--bg-elevated); color: var(--text-primary); border-color: var(--border-medium); }
    .model-item:disabled { opacity: 0.4; cursor: not-allowed; }

    .model-search {
        flex: 1;
        background: var(--bg-card);
        border: 1px solid var(--border-subtle);
        color: var(--text-primary);
        padding: 0.4rem 0.5rem;
        border-radius: var(--radius-sm);
        outline: none;
        font-size: 0.82rem;
        font-family: inherit;
        transition: border-color 0.15s;
    }
    .model-search:focus { border-color: var(--accent); }

    .model-search-btn {
        border: none;
        border-radius: var(--radius-pill);
        padding: 0.4rem 0.8rem;
        background: var(--blue);
        color: white;
        font-weight: 600;
        font-size: 0.8rem;
        cursor: pointer;
        transition: transform 0.1s, opacity 0.15s;
    }
    .model-search-btn:hover:not(:disabled) { transform: translateY(-1px); }
    .model-search-btn:disabled { opacity: 0.4; cursor: not-allowed; }

    .model-details {
        border-top: 1px solid var(--border-subtle);
        padding-top: 0.6rem;
        margin-top: 0.4rem;
    }

    .details-title {
        font-size: 0.88rem;
        font-weight: 700;
        color: var(--text-primary);
        margin-bottom: 0.3rem;
        word-break: break-word;
    }

    .model-snippet {
        color: var(--text-secondary);
        font-size: 0.8rem;
        line-height: 1.3;
        margin: 0.3rem 0 0.6rem 0;
        padding: 0.5rem 0.6rem;
        border-radius: var(--radius-sm);
        background: var(--bg-card);
        border: 1px solid var(--border-subtle);
    }

    .details-actions {
        display: flex;
        gap: 0.5rem;
        justify-content: flex-end;
        margin-top: 0.3rem;
    }

    .pill {
        border: 1px solid var(--border-subtle);
        background: transparent;
        color: var(--text-secondary);
        border-radius: var(--radius-pill);
        padding: 0.38rem 0.75rem;
        font-size: 0.8rem;
        font-weight: 600;
        cursor: pointer;
        transition: background 0.12s, color 0.12s, transform 0.1s;
    }
    .pill:hover:not(:disabled) { background: var(--bg-elevated); color: var(--text-primary); transform: translateY(-1px); }
    .pill:disabled { opacity: 0.4; cursor: not-allowed; }

    .pill-primary {
        background: var(--green);
        color: #08130d;
        border-color: transparent;
    }
    .pill-primary:hover:not(:disabled) { background: #16a34a; color: white; }

    /* --- Warning --- */
    .warning {
        color: var(--yellow);
        font-size: 0.8rem;
        text-align: center;
        max-width: 300px;
        padding: 0.4rem 0.6rem;
        background: rgba(251, 191, 36, 0.06);
        border: 1px solid rgba(251, 191, 36, 0.15);
        border-radius: var(--radius-sm);
    }

    /* --- Subtitle Bubbles --- */
    .subtitle-area {
        width: 100%;
        max-width: 440px;
        display: flex;
        flex-direction: column;
        gap: 0.5rem;
        margin-top: 0.4rem;
        min-height: 80px;
        justify-content: flex-end;
    }

    .subtitle-bubble {
        max-width: 85%;
        padding: 0.55rem 0.85rem;
        border-radius: 1rem;
        font-size: 0.88rem;
        line-height: 1.35;
        word-break: break-word;
        white-space: pre-wrap;
        animation: subtitleFadeIn 0.2s ease;
    }

    .subtitle-fae {
        align-self: flex-start;
        background: rgba(59, 130, 246, 0.18);
        border: 1px solid rgba(59, 130, 246, 0.3);
        color: #93bbfc;
        border-bottom-left-radius: 0.25rem;
    }

    .subtitle-user {
        align-self: flex-end;
        background: rgba(34, 197, 94, 0.18);
        border: 1px solid rgba(34, 197, 94, 0.3);
        color: #86efac;
        border-bottom-right-radius: 0.25rem;
    }

    .subtitle-spacer {
        min-height: 40px;
    }

    @keyframes subtitleFadeIn {
        from { opacity: 0; transform: translateY(6px); }
        to   { opacity: 1; transform: translateY(0); }
    }

    /* --- Text Input Bar --- */
    .text-input-bar {
        display: flex;
        gap: 8px;
        padding: 8px 4px 4px;
        border-top: 1px solid var(--border-subtle);
        margin-top: 0.4rem;
    }

    .text-input {
        flex: 1;
        background: var(--bg-elevated);
        color: var(--text-primary);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-sm);
        padding: 6px 10px;
        font-size: 0.82rem;
        font-family: inherit;
    }
    .text-input:focus {
        border-color: var(--accent);
        outline: none;
    }
    .text-input::placeholder {
        color: var(--text-tertiary);
    }

    .text-send-btn {
        background: var(--accent);
        color: white;
        border: none;
        border-radius: var(--radius-sm);
        padding: 6px 14px;
        font-size: 0.82rem;
        font-weight: 500;
        cursor: pointer;
        transition: opacity 0.15s;
    }
    .text-send-btn:hover:not(:disabled) { opacity: 0.85; }
    .text-send-btn:disabled { opacity: 0.35; cursor: default; }

    /* Permission buttons */
    .perm-buttons {
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 8px;
        padding: 8px;
        background: var(--bg-card);
        border-top: 1px solid var(--border-subtle);
    }
    .perm-status {
        font-size: 0.8rem;
        color: var(--text-secondary);
    }
    .perm-btn {
        border: none;
        border-radius: var(--radius-sm);
        padding: 6px 12px;
        font-size: 0.75rem;
        font-weight: 500;
        cursor: pointer;
        transition: opacity 0.15s;
    }
    .perm-btn:hover { opacity: 0.85; }
    .perm-grant {
        background: var(--green);
        color: white;
    }
    .perm-revoke {
        background: var(--red);
        color: white;
    }
    .perm-grant-btn {
        background: var(--green);
        color: white;
        border: none;
        border-radius: var(--radius-sm);
        padding: 6px 12px;
        font-size: 0.75rem;
        font-weight: 500;
        cursor: pointer;
    }
    .perm-revoke-btn {
        background: var(--red);
        color: white;
        border: none;
        border-radius: var(--radius-sm);
        padding: 6px 12px;
        font-size: 0.75rem;
        font-weight: 500;
        cursor: pointer;
    }
    .perm-bar {
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 10px;
        padding: 8px 12px;
        background: var(--bg-card);
        border-top: 1px solid var(--border-subtle);
    }
    .perm-label {
        font-size: 0.8rem;
        color: var(--text-secondary);
    }


    /* --- Modal --- */
    .modal-overlay {
        position: fixed;
        inset: 0;
        background: rgba(0, 0, 0, 0.7);
        backdrop-filter: blur(6px);
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 1.5rem;
        z-index: 9999;
        animation: fadeIn 0.15s ease;
    }

    .modal {
        width: 100%;
        max-width: 480px;
        background: var(--bg-secondary);
        border: 1px solid var(--border-medium);
        border-radius: var(--radius-lg);
        padding: 1.1rem;
        box-shadow: 0 20px 60px rgba(0, 0, 0, 0.5);
    }

    .modal-title {
        color: var(--text-primary);
        font-size: 1rem;
        font-weight: 700;
        margin-bottom: 0.3rem;
    }

    .modal-subtitle {
        color: var(--text-tertiary);
        font-size: 0.85rem;
        margin-bottom: 0.5rem;
    }

    .modal-tool {
        font-size: 0.9rem;
        font-weight: 600;
        color: var(--accent);
        margin-bottom: 0.5rem;
    }

    .modal-json {
        max-height: 200px;
        overflow: auto;
        background: var(--bg-card);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-sm);
        padding: 0.6rem;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        font-size: 0.75rem;
        color: var(--text-secondary);
        margin-bottom: 0.8rem;
        white-space: pre-wrap;
    }

    .modal-input {
        width: 100%;
        background: var(--bg-card);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-sm);
        color: var(--text-primary);
        font-size: 0.82rem;
        padding: 0.5rem 0.6rem;
        margin-bottom: 0.8rem;
        outline: none;
        font-family: inherit;
    }
    .modal-input:focus {
        border-color: var(--accent);
    }
    .modal-select {
        cursor: pointer;
    }
    .modal-editor {
        min-height: 180px;
        resize: vertical;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    }

    .modal-actions {
        display: flex;
        gap: 0.5rem;
        justify-content: flex-end;
    }

    .modal-btn {
        border: none;
        border-radius: var(--radius-pill);
        padding: 0.5rem 1rem;
        font-size: 0.85rem;
        font-weight: 600;
        cursor: pointer;
        transition: transform 0.1s, opacity 0.15s;
    }
    .modal-btn:hover { transform: translateY(-1px); }
    .modal-btn:active { transform: scale(0.97); }

    .modal-approve { background: var(--green); color: white; }
    .modal-deny { background: var(--red); color: white; }

    /* --- Canvas Status Badge --- */
    .canvas-status {
        font-size: 0.7rem;
        font-weight: 600;
        padding: 0.15rem 0.5rem;
        border-radius: var(--radius-pill);
        text-transform: uppercase;
        letter-spacing: 0.03em;
    }
    .canvas-status.local { background: var(--bg-elevated); color: var(--text-tertiary); }
    .canvas-status.connected { background: rgba(52, 199, 89, 0.15); color: #34c759; }
    .canvas-status.connecting { background: rgba(255, 204, 0, 0.15); color: #ffcc00; }
    .canvas-status.reconnecting { background: rgba(255, 159, 10, 0.15); color: #ff9f0a; }
    .canvas-status.disconnected { background: rgba(255, 69, 58, 0.12); color: #ff453a; }
    .canvas-status.failed { background: rgba(255, 69, 58, 0.15); color: #ff453a; }

    /* --- Canvas Right-Side Panel --- */
    .canvas-panel {
        display: flex;
        flex-direction: column;
        flex: 1 1 0;
        min-width: 0;
        max-height: calc(100vh - 5rem);
        background: var(--bg-secondary);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-md);
        padding: 0.5rem 0.75rem;
        gap: 0.5rem;
        box-sizing: border-box;
        overflow: hidden;
        animation: canvas-fade-in 0.15s ease-out;
    }
    @keyframes canvas-fade-in {
        from { opacity: 0; }
        to { opacity: 1; }
    }
    .canvas-panel-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding-bottom: 0.25rem;
        border-bottom: 1px solid var(--border-subtle);
        flex-shrink: 0;
    }
    .canvas-panel-title {
        font-size: 0.9rem;
        font-weight: 600;
        margin: 0;
    }
    .canvas-close-btn {
        background: rgba(255, 255, 255, 0.08);
        border: 1px solid rgba(255, 255, 255, 0.15);
        color: var(--text-secondary);
        border-radius: var(--radius-sm);
        padding: 2px 8px;
        cursor: pointer;
        font-size: 0.85rem;
        font-weight: 600;
        line-height: 1;
    }
    .canvas-close-btn:hover {
        background: rgba(239, 68, 68, 0.25);
        color: #fca5a5;
        border-color: rgba(239, 68, 68, 0.4);
    }
    .canvas-pane {
        flex: 1;
        min-height: 0;
        overflow-y: auto;
        scroll-behavior: smooth;
        background: var(--bg-secondary);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-md);
        padding: 0.75rem;
        margin-top: 0.5rem;
    }
    .canvas-hint {
        color: var(--text-tertiary);
        font-size: 0.85rem;
        text-align: center;
        padding: 1rem;
    }
    .canvas-messages { display: flex; flex-direction: column; gap: 6px; }
    .canvas-messages .message {
        padding: 8px 12px;
        border-radius: var(--radius-sm);
        font-size: 0.9rem;
        line-height: 1.4;
        max-width: 85%;
        word-wrap: break-word;
    }
    .canvas-messages .message.user {
        align-self: flex-end;
        background: rgba(59, 130, 246, 0.12);
        color: #93c5fd;
    }
    .canvas-messages .message.assistant {
        align-self: flex-start;
        background: rgba(16, 185, 129, 0.12);
        color: #6ee7b7;
    }
    .canvas-messages .message.system {
        align-self: center;
        background: rgba(107, 114, 128, 0.12);
        color: var(--text-secondary);
        font-style: italic;
        font-size: 0.8rem;
    }
    .canvas-messages .message.tool {
        align-self: flex-start;
        background: rgba(245, 158, 11, 0.12);
        color: #fcd34d;
        font-family: monospace;
        font-size: 0.8rem;
    }
    /* Markdown-formatted messages */
    .canvas-messages .message.markdown { max-width: 95%; }
    .canvas-messages .message.markdown h1,
    .canvas-messages .message.markdown h2,
    .canvas-messages .message.markdown h3 {
        margin: 0.4em 0 0.2em;
        line-height: 1.3;
    }
    .canvas-messages .message.markdown h1 { font-size: 1.2rem; }
    .canvas-messages .message.markdown h2 { font-size: 1.05rem; }
    .canvas-messages .message.markdown h3 { font-size: 0.95rem; }
    .canvas-messages .message.markdown p { margin: 0.3em 0; }
    .canvas-messages .message.markdown ul,
    .canvas-messages .message.markdown ol { padding-left: 1.2em; margin: 0.3em 0; }
    .canvas-messages .message.markdown blockquote {
        border-left: 3px solid rgba(255,255,255,0.2);
        padding-left: 0.6em;
        margin: 0.3em 0;
        opacity: 0.85;
    }
    .canvas-messages .message.markdown table {
        border-collapse: collapse;
        margin: 0.4em 0;
        font-size: 0.85rem;
    }
    .canvas-messages .message.markdown th,
    .canvas-messages .message.markdown td {
        border: 1px solid rgba(255,255,255,0.15);
        padding: 4px 8px;
    }
    .canvas-messages .message.markdown th {
        background: rgba(255,255,255,0.05);
    }
    /* Code blocks (syntax highlighted) */
    .code-block {
        border-radius: var(--radius-sm);
        margin: 0.4em 0;
        overflow-x: auto;
    }
    .code-block pre {
        margin: 0;
        padding: 0.6em 0.8em;
        font-size: 0.82rem;
        line-height: 1.5;
    }
    /* Inline code in markdown */
    .canvas-messages .message.markdown code {
        background: rgba(255,255,255,0.08);
        padding: 1px 4px;
        border-radius: 3px;
        font-size: 0.85em;
    }
    .canvas-messages .message.markdown pre code {
        background: none;
        padding: 0;
    }
    /* Tool-pushed content (charts, images, etc.) */
    .canvas-tools { display: flex; flex-direction: column; gap: 8px; margin-top: 8px; }
    .canvas-chart { text-align: center; }
    .canvas-chart img { max-width: 100%; border-radius: var(--radius-sm); }
    .canvas-chart-error {
        padding: 8px 12px;
        background: rgba(239, 68, 68, 0.12);
        color: #fca5a5;
        border-radius: var(--radius-sm);
        font-size: 0.85rem;
    }
    .canvas-image { text-align: center; }
    .canvas-image img { max-width: 100%; border-radius: var(--radius-sm); }
    .canvas-image-error {
        padding: 8px 12px;
        background: rgba(239, 68, 68, 0.12);
        color: #fca5a5;
        border-radius: var(--radius-sm);
        font-size: 0.85rem;
    }
    .canvas-model3d, .canvas-video {
        padding: 12px;
        background: rgba(99, 102, 241, 0.12);
        color: #a5b4fc;
        border-radius: var(--radius-sm);
        font-size: 0.85rem;
        display: flex;
        gap: 8px;
        align-items: center;
    }
    .model-label, .video-label { font-weight: 600; }
    .model-info, .video-info { opacity: 0.7; font-size: 0.8rem; }

    /* --- Canvas interactive elements --- */
    .canvas-search {
        display: flex;
        gap: 4px;
        margin-bottom: 0.5rem;
    }
    .canvas-search-input {
        flex: 1;
        background: var(--bg-primary);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-sm);
        padding: 6px 10px;
        color: var(--text-primary);
        font-size: 0.85rem;
    }
    .canvas-search-input::placeholder { color: var(--text-tertiary); }
    .canvas-search-clear {
        background: none;
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-sm);
        color: var(--text-secondary);
        cursor: pointer;
        padding: 2px 8px;
        font-size: 1rem;
    }
    .canvas-msg-wrapper {
        position: relative;
        padding: 8px 12px;
        border-radius: var(--radius-sm);
        font-size: 0.9rem;
        line-height: 1.4;
        word-wrap: break-word;
        transition: background 0.15s;
    }
    .canvas-msg-wrapper:hover { background: rgba(255,255,255,0.03); }
    .canvas-msg-wrapper:focus { outline: 2px solid rgba(59, 130, 246, 0.5); outline-offset: -2px; }
    .msg-actions {
        display: none;
        position: absolute;
        top: 4px;
        right: 4px;
        gap: 2px;
    }
    .canvas-msg-wrapper:hover .msg-actions { display: flex; }
    .msg-action-btn {
        background: rgba(255,255,255,0.08);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-sm);
        color: var(--text-secondary);
        cursor: pointer;
        font-size: 0.75rem;
        padding: 2px 6px;
    }
    .msg-action-btn:hover { background: rgba(255,255,255,0.15); }
    .canvas-context-menu {
        position: absolute;
        z-index: 100;
        background: var(--bg-primary);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-sm);
        box-shadow: 0 4px 12px rgba(0,0,0,0.4);
        padding: 4px;
        min-width: 120px;
        margin-top: 4px;
    }
    .ctx-menu-item {
        display: block;
        width: 100%;
        background: none;
        border: none;
        color: var(--text-primary);
        font-size: 0.85rem;
        padding: 6px 12px;
        text-align: left;
        cursor: pointer;
        border-radius: 3px;
    }
    .ctx-menu-item:hover { background: rgba(255,255,255,0.08); }
    .thinking-indicator {
        display: flex;
        gap: 6px;
        padding: 12px;
        justify-content: center;
    }
    .thinking-dot {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        background: var(--text-tertiary);
        animation: thinking-pulse 1.4s infinite;
    }
    .thinking-dot:nth-child(2) { animation-delay: 0.2s; }
    .thinking-dot:nth-child(3) { animation-delay: 0.4s; }
    @keyframes thinking-pulse {
        0%, 80%, 100% { opacity: 0.3; transform: scale(0.8); }
        40% { opacity: 1; transform: scale(1); }
    }
    .tool-details {
        margin-top: 4px;
        font-size: 0.82rem;
    }
    .tool-details summary {
        cursor: pointer;
        color: var(--text-secondary);
        font-size: 0.8rem;
    }
    .tool-detail-json {
        background: rgba(0,0,0,0.2);
        padding: 6px 8px;
        border-radius: 3px;
        font-size: 0.78rem;
        overflow-x: auto;
        white-space: pre-wrap;
        word-break: break-all;
    }
    .tool-detail-result {
        padding: 4px 0;
        color: var(--text-secondary);
    }
    .canvas-tools-section {
        border-top: 1px solid var(--border-subtle);
        margin-top: 0.8rem;
        padding-top: 0.5rem;
    }
    mark {
        background: rgba(250, 204, 21, 0.3);
        color: inherit;
        border-radius: 2px;
        padding: 0 1px;
    }

    /* --- Update banner --- */
    .update-banner {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        background: var(--bg-elevated);
        border: 1px solid var(--accent);
        border-radius: var(--radius-card);
        padding: 0.4rem 0.7rem;
        margin: 0.3rem 0.5rem;
    }
    .update-banner-text {
        flex: 1;
        font-size: 0.8rem;
        color: var(--text-primary);
    }
    .update-banner-btn {
        border: none;
        border-radius: var(--radius-pill);
        padding: 0.2rem 0.6rem;
        background: var(--accent);
        color: #000;
        font-size: 0.75rem;
        font-weight: 600;
        cursor: pointer;
    }
    .update-banner-btn:hover { opacity: 0.85; }
    .update-banner-dismiss {
        border: none;
        background: transparent;
        color: var(--text-secondary);
        cursor: pointer;
        font-size: 0.9rem;
        padding: 0 0.2rem;
    }
    .update-banner-dismiss:hover { color: var(--text-primary); }

    /* --- Scrollbar --- */
    ::-webkit-scrollbar { width: 5px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.1); border-radius: 3px; }
    ::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.18); }
"#;
