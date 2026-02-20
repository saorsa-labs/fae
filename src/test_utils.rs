//! Shared test utilities used across multiple test modules.
//!
//! Consolidates helpers that were previously duplicated in `memory::tests`,
//! `scheduler::tasks::tests`, and `pipeline::coordinator::tests`.

use std::path::{Path, PathBuf};

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

/// Seed the memory directory with a v0 manifest from the test fixtures,
/// plus empty records and audit files.  Used to test schema migration.
pub fn seed_manifest_v0(root: &Path) {
    let memory_dir = root.join("memory");
    std::fs::create_dir_all(&memory_dir).expect("create memory dir");

    let fixture_manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("memory")
        .join("manifest_v0.toml");
    std::fs::copy(fixture_manifest, memory_dir.join("manifest.toml"))
        .expect("copy manifest v0 fixture");
    std::fs::write(memory_dir.join("records.jsonl"), "").expect("write empty records");
    std::fs::write(memory_dir.join("audit.jsonl"), "").expect("write empty audit");
}
