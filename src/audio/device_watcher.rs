//! Audio input device change detection.
//!
//! [`AudioDeviceWatcher`] polls the list of available CPAL input devices every
//! two seconds and emits a [`GateCommand::RestartAudio`] when the default
//! device changes (or appears/disappears).
//!
//! This allows the pipeline to pick up newly plugged-in headphones or
//! microphones without requiring a full pipeline restart.
//!
//! # Design
//!
//! The watcher runs as a background tokio task. It does not use OS-level
//! audio change notifications because CPAL's cross-platform API does not
//! expose them. Polling every 2 s is cheap and sufficient for the use case.

use crate::pipeline::messages::GateCommand;
use cpal::traits::{DeviceTrait, HostTrait};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Polls CPAL for input device changes and sends a [`GateCommand::RestartAudio`]
/// when the default device changes.
pub struct AudioDeviceWatcher {
    gate_tx: mpsc::UnboundedSender<GateCommand>,
    cancel: CancellationToken,
    poll_interval: Duration,
}

impl AudioDeviceWatcher {
    /// Create a watcher that sends gate commands via `gate_tx`.
    ///
    /// Call [`run`](Self::run) to start polling.
    pub fn new(gate_tx: mpsc::UnboundedSender<GateCommand>, cancel: CancellationToken) -> Self {
        Self {
            gate_tx,
            cancel,
            poll_interval: Duration::from_secs(2),
        }
    }

    /// Override the poll interval (useful for testing).
    #[cfg(test)]
    pub fn with_poll_interval(mut self, interval: Duration) -> Self {
        self.poll_interval = interval;
        self
    }

    /// Run the watcher loop until the cancellation token is cancelled.
    ///
    /// This method is `async` and is intended to be spawned as a background task:
    ///
    /// ```rust,ignore
    /// let watcher = AudioDeviceWatcher::new(gate_tx, cancel.child_token());
    /// tokio::spawn(watcher.run());
    /// ```
    pub async fn run(self) {
        let mut last_device: Option<String> = current_default_device_name();
        info!(device = ?last_device, "audio device watcher started");

        loop {
            tokio::select! {
                _ = self.cancel.cancelled() => {
                    info!("audio device watcher cancelled");
                    break;
                }
                _ = tokio::time::sleep(self.poll_interval) => {
                    let current = current_default_device_name();
                    if current != last_device {
                        let old = last_device.as_deref().unwrap_or("<none>");
                        let new_name = current.as_deref().unwrap_or("<none>");
                        info!(
                            old_device = old,
                            new_device = new_name,
                            "audio input device changed — sending RestartAudio"
                        );
                        let cmd = GateCommand::RestartAudio {
                            device_name: current.clone(),
                        };
                        if self.gate_tx.send(cmd).is_err() {
                            // Pipeline no longer accepting commands — stop watching.
                            warn!("audio device watcher: gate_tx closed, stopping");
                            break;
                        }
                        last_device = current;
                    }
                }
            }
        }
    }
}

/// Return the name of the default CPAL input device, or `None` if unavailable.
fn current_default_device_name() -> Option<String> {
    let host = cpal::default_host();
    host.default_input_device()
        .and_then(|dev| dev.description().ok().map(|d| d.name().to_owned()))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use tokio::sync::mpsc;
    use tokio_util::sync::CancellationToken;

    #[tokio::test]
    async fn watcher_stops_on_cancel() {
        let (tx, _rx) = mpsc::unbounded_channel::<GateCommand>();
        let cancel = CancellationToken::new();
        let watcher =
            AudioDeviceWatcher::new(tx, cancel.clone()).with_poll_interval(Duration::from_secs(60)); // Very long so it doesn't poll

        let cancel_clone = cancel.clone();
        let task = tokio::spawn(async move { watcher.run().await });

        // Cancel and give the task time to stop.
        tokio::time::sleep(Duration::from_millis(50)).await;
        cancel_clone.cancel();

        // Task should finish shortly after cancel.
        let result = tokio::time::timeout(Duration::from_secs(2), task).await;
        assert!(result.is_ok(), "watcher task should finish after cancel");
    }

    #[tokio::test]
    async fn watcher_stops_when_gate_tx_closed() {
        let (tx, rx) = mpsc::unbounded_channel::<GateCommand>();
        let cancel = CancellationToken::new();
        let watcher = AudioDeviceWatcher::new(tx, cancel.clone())
            .with_poll_interval(Duration::from_millis(10));

        // Drop the receiver — the watcher should stop when it tries to send.
        drop(rx);

        // We need a device change to trigger a send. We can't force a real device
        // change in tests, so just verify the watcher starts and stops cleanly.
        let task = tokio::spawn(async move { watcher.run().await });
        cancel.cancel();
        let result = tokio::time::timeout(Duration::from_secs(2), task).await;
        assert!(result.is_ok(), "watcher task should finish");
    }

    #[test]
    fn restart_audio_gate_command_has_device_name() {
        let cmd = GateCommand::RestartAudio {
            device_name: Some("Built-in Microphone".to_owned()),
        };
        match cmd {
            GateCommand::RestartAudio { device_name } => {
                assert_eq!(device_name, Some("Built-in Microphone".to_owned()));
            }
            _ => panic!("expected RestartAudio"),
        }
    }

    #[test]
    fn restart_audio_gate_command_none_device() {
        let cmd = GateCommand::RestartAudio { device_name: None };
        match cmd {
            GateCommand::RestartAudio { device_name } => {
                assert_eq!(device_name, None);
            }
            _ => panic!("expected RestartAudio"),
        }
    }
}
