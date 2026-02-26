//! Shared test utilities used across multiple test modules.
//!
//! Consolidates helpers that were previously duplicated in `memory::tests`,
//! `scheduler::tasks::tests`, and `pipeline::coordinator::tests`.

use std::path::PathBuf;

/// Create a unique temporary directory for test isolation.
///
/// The directory name includes `prefix`, the process ID, and a nanosecond
/// timestamp so parallel tests never collide.
pub fn temp_test_root(prefix: &str, name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "fae-{prefix}-{name}-{}-{}",
        std::process::id(),
        crate::memory::types::now_epoch_nanos()
    ));
    std::fs::create_dir_all(&dir).expect("create temp test dir");
    dir
}
