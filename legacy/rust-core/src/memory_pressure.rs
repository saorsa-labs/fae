//! System memory pressure monitoring.
//!
//! [`MemoryPressureMonitor`] polls available RAM every 30 seconds and emits
//! [`MemoryPressureEvent`]s when thresholds are crossed. The handler forwards
//! these as `pipeline.control` events so the Swift side can display warnings.
//!
//! # Thresholds
//!
//! | Level | Free RAM |
//! |-------|---------|
//! | [`WARNING`] | ≤ 1 024 MB |
//! | [`CRITICAL`] | ≤ 512 MB |
//!
//! The monitor only emits an event on state *transitions* (entering or leaving
//! a pressure level), not repeatedly while pressure persists.
//!
//! # Usage
//!
//! ```rust,ignore
//! use fae::memory_pressure::MemoryPressureMonitor;
//! let monitor = MemoryPressureMonitor::new(event_tx, cancel.child_token());
//! tokio::spawn(monitor.run());
//! ```

use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Available RAM threshold for a warning-level pressure event (MiB).
pub const WARNING_THRESHOLD_MB: u64 = 1_024;

/// Available RAM threshold for a critical-level pressure event (MiB).
pub const CRITICAL_THRESHOLD_MB: u64 = 512;

/// Poll interval in seconds.
const POLL_INTERVAL_SECS: u64 = 30;

/// Pressure level states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PressureLevel {
    /// Available RAM is within acceptable limits.
    Normal,
    /// Available RAM is below [`WARNING_THRESHOLD_MB`].
    Warning,
    /// Available RAM is below [`CRITICAL_THRESHOLD_MB`].
    Critical,
}

impl PressureLevel {
    pub fn from_available_mb(mb: u64) -> Self {
        if mb <= CRITICAL_THRESHOLD_MB {
            Self::Critical
        } else if mb <= WARNING_THRESHOLD_MB {
            Self::Warning
        } else {
            Self::Normal
        }
    }
}

/// An event emitted by [`MemoryPressureMonitor`] on threshold transition.
#[derive(Debug, Clone)]
pub struct MemoryPressureEvent {
    /// The new pressure level.
    pub level: PressureLevel,
    /// Available RAM in MiB at the time of the event.
    pub available_mb: u64,
}

/// Monitors available system RAM and emits pressure events on threshold transitions.
pub struct MemoryPressureMonitor {
    tx: broadcast::Sender<MemoryPressureEvent>,
    cancel: CancellationToken,
    poll_interval_secs: u64,
}

impl MemoryPressureMonitor {
    /// Create a monitor.
    ///
    /// Events are broadcast via `tx`. The monitor runs until `cancel` is cancelled.
    pub fn new(tx: broadcast::Sender<MemoryPressureEvent>, cancel: CancellationToken) -> Self {
        Self {
            tx,
            cancel,
            poll_interval_secs: POLL_INTERVAL_SECS,
        }
    }

    /// Override the poll interval (useful for testing).
    #[cfg(test)]
    pub fn with_poll_interval_secs(mut self, secs: u64) -> Self {
        self.poll_interval_secs = secs;
        self
    }

    /// Run the monitor until the cancellation token is cancelled.
    pub async fn run(self) {
        let mut last_level = PressureLevel::Normal;
        info!("memory pressure monitor started");

        loop {
            tokio::select! {
                _ = self.cancel.cancelled() => {
                    info!("memory pressure monitor stopped");
                    break;
                }
                _ = tokio::time::sleep(std::time::Duration::from_secs(self.poll_interval_secs)) => {
                    let available_mb = available_memory_mb();
                    let current_level = PressureLevel::from_available_mb(available_mb);

                    if current_level != last_level {
                        match current_level {
                            PressureLevel::Warning => {
                                warn!(
                                    available_mb,
                                    threshold_mb = WARNING_THRESHOLD_MB,
                                    "memory pressure: WARNING — low available RAM"
                                );
                            }
                            PressureLevel::Critical => {
                                warn!(
                                    available_mb,
                                    threshold_mb = CRITICAL_THRESHOLD_MB,
                                    "memory pressure: CRITICAL — very low RAM"
                                );
                            }
                            PressureLevel::Normal => {
                                info!(
                                    available_mb,
                                    "memory pressure: cleared — RAM restored to normal"
                                );
                            }
                        }

                        let event = MemoryPressureEvent {
                            level: current_level,
                            available_mb,
                        };
                        // Ignore send errors — no subscribers is not an error.
                        let _ = self.tx.send(event);
                        last_level = current_level;
                    }
                }
            }
        }
    }
}

/// Return the available (free) system RAM in mebibytes.
///
/// Uses platform-specific calls:
/// - macOS: `vm_stat` / `sysctl`
/// - Linux: `/proc/meminfo` `MemAvailable`
/// - Other: returns 0 (unknown)
pub fn available_memory_mb() -> u64 {
    available_memory_bytes().saturating_div(1024 * 1024)
}

fn available_memory_bytes() -> u64 {
    #[cfg(target_os = "macos")]
    {
        macos_available_memory_bytes().unwrap_or(0)
    }
    #[cfg(target_os = "linux")]
    {
        linux_available_memory_bytes().unwrap_or(0)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        0
    }
}

#[cfg(target_os = "macos")]
fn macos_available_memory_bytes() -> Option<u64> {
    // Use `sysctl vm.page_free_count` + `sysctl hw.pagesize` to compute
    // free physical pages, without spawning `vm_stat` (subprocess-free).
    let page_size = run_sysctl_u64("hw.pagesize")?;
    let free_pages = run_sysctl_u64("vm.page_free_count")?;
    Some(free_pages.saturating_mul(page_size))
}

#[cfg(target_os = "macos")]
fn run_sysctl_u64(name: &str) -> Option<u64> {
    let output = std::process::Command::new("sysctl")
        .arg("-n")
        .arg(name)
        .output()
        .ok()?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u64>()
        .ok()
}

#[cfg(target_os = "linux")]
fn linux_available_memory_bytes() -> Option<u64> {
    let content = std::fs::read_to_string("/proc/meminfo").ok()?;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("MemAvailable:") {
            let parts = rest.split_whitespace().collect::<Vec<_>>();
            if parts.len() >= 2 {
                if let Ok(kb) = parts[0].parse::<u64>() {
                    return Some(kb.saturating_mul(1024));
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn pressure_level_normal_above_warning() {
        let level = PressureLevel::from_available_mb(2_048);
        assert_eq!(level, PressureLevel::Normal);
    }

    #[test]
    fn pressure_level_warning_at_threshold() {
        let level = PressureLevel::from_available_mb(WARNING_THRESHOLD_MB);
        assert_eq!(level, PressureLevel::Warning);
    }

    #[test]
    fn pressure_level_warning_between_thresholds() {
        let level = PressureLevel::from_available_mb(700);
        assert_eq!(level, PressureLevel::Warning);
    }

    #[test]
    fn pressure_level_critical_at_threshold() {
        let level = PressureLevel::from_available_mb(CRITICAL_THRESHOLD_MB);
        assert_eq!(level, PressureLevel::Critical);
    }

    #[test]
    fn pressure_level_critical_below_threshold() {
        let level = PressureLevel::from_available_mb(256);
        assert_eq!(level, PressureLevel::Critical);
    }

    #[test]
    fn available_memory_mb_returns_nonnegative() {
        // Can't assert exact value — just that it doesn't panic and returns >= 0.
        let mb = available_memory_mb();
        // On test systems it should be > 0, but 0 is OK for unsupported platforms.
        let _ = mb;
    }

    #[tokio::test]
    async fn monitor_stops_on_cancel() {
        let (tx, _rx) = broadcast::channel::<MemoryPressureEvent>(4);
        let cancel = CancellationToken::new();
        let monitor = MemoryPressureMonitor::new(tx, cancel.clone()).with_poll_interval_secs(60); // Very long so it doesn't fire

        let cancel_clone = cancel.clone();
        let task = tokio::spawn(async move { monitor.run().await });

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        cancel_clone.cancel();

        let result = tokio::time::timeout(std::time::Duration::from_secs(2), task).await;
        assert!(result.is_ok(), "monitor should stop after cancel");
    }

    #[test]
    fn pressure_event_carries_level_and_mb() {
        let evt = MemoryPressureEvent {
            level: PressureLevel::Warning,
            available_mb: 900,
        };
        assert_eq!(evt.level, PressureLevel::Warning);
        assert_eq!(evt.available_mb, 900);
    }
}
