//! Shared helpers for integration tests.
//!
//! Extracted from duplicate helper functions across multiple test files.

use fae::config::SpeechConfig;
use fae::host::contract::EventEnvelope;
use fae::host::handler::FaeDeviceTransferHandler;
use tokio::sync::broadcast;

/// Build a temporary `FaeDeviceTransferHandler` that does not write to disk.
/// Returns `(handler, tempdir, runtime)`. Drops the event receiver.
pub(crate) fn temp_handler() -> (
    FaeDeviceTransferHandler,
    tempfile::TempDir,
    tokio::runtime::Runtime,
) {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("config.toml");
    let config = SpeechConfig::default();
    let rt = tokio::runtime::Runtime::new().expect("create tokio runtime");
    let (event_tx, _) = broadcast::channel::<EventEnvelope>(16);
    let handler = FaeDeviceTransferHandler::new(config, path, rt.handle().clone(), event_tx);
    (handler, dir, rt)
}

/// Build a temporary `FaeDeviceTransferHandler` that also returns the event
/// receiver. Returns `(handler, event_rx, tempdir, runtime)`.
pub(crate) fn temp_handler_with_events() -> (
    FaeDeviceTransferHandler,
    broadcast::Receiver<EventEnvelope>,
    tempfile::TempDir,
    tokio::runtime::Runtime,
) {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("config.toml");
    let config = SpeechConfig::default();
    let rt = tokio::runtime::Runtime::new().expect("create tokio runtime");
    let (event_tx, event_rx) = broadcast::channel::<EventEnvelope>(64);
    let handler = FaeDeviceTransferHandler::new(config, path, rt.handle().clone(), event_tx);
    (handler, event_rx, dir, rt)
}

/// Drain all pending events from the broadcast receiver into a Vec.
pub(crate) fn drain_events(rx: &mut broadcast::Receiver<EventEnvelope>) -> Vec<EventEnvelope> {
    let mut events = Vec::new();
    while let Ok(evt) = rx.try_recv() {
        events.push(evt);
    }
    events
}

/// Drain all pending events from the broadcast receiver into a Vec.
/// (Alias for `drain_events`, used in some test files as `collect_events`.)
pub(crate) fn collect_events(rx: &mut broadcast::Receiver<EventEnvelope>) -> Vec<EventEnvelope> {
    drain_events(rx)
}
