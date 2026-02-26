//! Integration tests for Phase 5.2 — Error Recovery & Resilience.
//!
//! Covers model integrity, memory pressure thresholds, graceful degradation
//! modes, fallback chain ordering, and log rotation cleanup.

use std::fs;

// ─── Task 2: Model Integrity ──────────────────────────────────────────────────

use fae::model_integrity::{IntegrityResult, verify};

#[test]
fn test_model_integrity_missing() {
    let tmp = tempfile::TempDir::new().unwrap();
    let path = tmp.path().join("nonexistent.bin");
    let result = verify(&path, Some("abc123"));
    assert_eq!(
        result,
        IntegrityResult::Missing,
        "missing file should return Missing"
    );
}

#[test]
fn test_model_integrity_no_checksum() {
    let tmp = tempfile::TempDir::new().unwrap();
    let path = tmp.path().join("model.bin");
    fs::write(&path, b"some model bytes").unwrap();
    let result = verify(&path, None);
    assert_eq!(
        result,
        IntegrityResult::NoChecksum,
        "None checksum should return NoChecksum"
    );
}

#[test]
fn test_model_integrity_ok() {
    use sha2::{Digest, Sha256};

    let tmp = tempfile::TempDir::new().unwrap();
    let path = tmp.path().join("model.bin");
    let content = b"valid model content for integrity test";
    fs::write(&path, content).unwrap();

    let mut hasher = Sha256::new();
    hasher.update(content);
    let expected = format!("{:x}", hasher.finalize());

    let result = verify(&path, Some(&expected));
    assert_eq!(
        result,
        IntegrityResult::Ok,
        "correct checksum should return Ok"
    );
}

#[test]
fn test_model_integrity_corrupt() {
    let tmp = tempfile::TempDir::new().unwrap();
    let path = tmp.path().join("model.bin");
    fs::write(&path, b"wrong bytes").unwrap();

    let result = verify(
        &path,
        Some("0000000000000000000000000000000000000000000000000000000000000000"),
    );
    assert_eq!(
        result,
        IntegrityResult::Corrupt,
        "wrong checksum should return Corrupt"
    );
}

// ─── Task 5: Memory Pressure Thresholds ──────────────────────────────────────

use fae::memory_pressure::{CRITICAL_THRESHOLD_MB, PressureLevel, WARNING_THRESHOLD_MB};

#[test]
fn test_memory_pressure_normal_level() {
    let level = PressureLevel::from_available_mb(WARNING_THRESHOLD_MB + 1);
    assert_eq!(level, PressureLevel::Normal);
}

#[test]
fn test_memory_pressure_warning_threshold() {
    let level = PressureLevel::from_available_mb(WARNING_THRESHOLD_MB);
    assert_eq!(level, PressureLevel::Warning);
}

#[test]
fn test_memory_pressure_critical_threshold() {
    let level = PressureLevel::from_available_mb(CRITICAL_THRESHOLD_MB);
    assert_eq!(level, PressureLevel::Critical);
}

#[test]
fn test_memory_pressure_thresholds_ordering() {
    // Critical < Warning < Normal
    const _: () = assert!(CRITICAL_THRESHOLD_MB < WARNING_THRESHOLD_MB);

    let normal = PressureLevel::from_available_mb(2048);
    let warning = PressureLevel::from_available_mb(700);
    let critical = PressureLevel::from_available_mb(256);

    assert_eq!(normal, PressureLevel::Normal);
    assert_eq!(warning, PressureLevel::Warning);
    assert_eq!(critical, PressureLevel::Critical);
}

// ─── Task 6: Graceful Degradation Modes ──────────────────────────────────────

use fae::pipeline::coordinator::PipelineMode;

#[test]
fn test_pipeline_mode_display() {
    assert_eq!(PipelineMode::Conversation.to_string(), "conversation");
    assert_eq!(PipelineMode::TranscribeOnly.to_string(), "transcribe_only");
    assert_eq!(PipelineMode::TextOnly.to_string(), "text_only");
    assert_eq!(PipelineMode::LlmOnly.to_string(), "llm_only");
}

#[test]
fn test_pipeline_mode_text_only_is_distinct() {
    let mode = PipelineMode::TextOnly;
    assert_ne!(mode, PipelineMode::Conversation);
    assert_ne!(mode, PipelineMode::TranscribeOnly);
    assert_ne!(mode, PipelineMode::LlmOnly);
    assert_eq!(mode, PipelineMode::TextOnly);
}

#[test]
fn test_pipeline_mode_llm_only_is_distinct() {
    let mode = PipelineMode::LlmOnly;
    assert_ne!(mode, PipelineMode::Conversation);
    assert_ne!(mode, PipelineMode::TranscribeOnly);
    assert_ne!(mode, PipelineMode::TextOnly);
    assert_eq!(mode, PipelineMode::LlmOnly);
}

#[test]
fn test_graceful_degradation_text_only_mode_parseable() {
    // Verify TextOnly mode display can be used as an identifier string.
    let mode = PipelineMode::TextOnly;
    let s = mode.to_string();
    assert_eq!(s, "text_only");
    assert!(s.contains("text"));
}

// ─── Task 4: Fallback Chain Ordering ─────────────────────────────────────────

use fae::llm::fallback::{FallbackChain, ProviderError, RETRY_ATTEMPTS};

#[test]
fn test_fallback_chain_ordering() {
    let mut chain = FallbackChain::new(vec!["anthropic".into(), "openai".into(), "local".into()]);

    // First call returns anthropic.
    assert_eq!(chain.next_provider(), Some("anthropic".into()));

    // After permanent failure, skips to openai.
    chain.report_failure("anthropic", ProviderError::Permanent("auth".into()));
    assert_eq!(chain.next_provider(), Some("openai".into()));

    // After permanent failure, skips to local.
    chain.report_failure("openai", ProviderError::Permanent("auth".into()));
    assert_eq!(chain.next_provider(), Some("local".into()));

    // After success, local remains current.
    chain.report_success("local");
    assert!(!chain.is_exhausted());
}

#[test]
fn test_fallback_chain_transient_retry_limit() {
    let mut chain = FallbackChain::new(vec!["cloud".into(), "local".into()]);

    // Exhaust cloud with transient failures.
    for _ in 0..RETRY_ATTEMPTS {
        assert_eq!(chain.next_provider(), Some("cloud".into()));
        chain.report_failure("cloud", ProviderError::Transient("timeout".into()));
    }

    // Now cloud is exhausted — next should be local.
    assert_eq!(chain.next_provider(), Some("local".into()));
}

#[test]
fn test_fallback_chain_exhaustion() {
    let mut chain = FallbackChain::new(vec!["a".into(), "b".into()]);
    chain.report_failure("a", ProviderError::Permanent("fail".into()));
    chain.report_failure("b", ProviderError::Permanent("fail".into()));

    assert_eq!(chain.next_provider(), None);
    assert!(chain.is_exhausted());
}

// ─── Task 7: Log Rotation Cleanup ────────────────────────────────────────────

use fae::diagnostics::log_rotation::{MAX_LOG_FILES, RotatingFileWriter};

#[test]
fn test_log_rotation_creates_daily_file() {
    let tmp = tempfile::TempDir::new().unwrap();
    let log_dir = tmp.path().to_path_buf();

    let mut writer = RotatingFileWriter::open(&log_dir).unwrap();
    writer
        .write_line("INFO", "integration_test", "log rotation test")
        .unwrap();

    let log_path = writer.path().to_path_buf();
    assert!(log_path.exists(), "log file should exist at: {log_path:?}");

    let name = log_path.file_name().unwrap().to_string_lossy();
    assert!(
        name.starts_with("fae-"),
        "log file name should start with fae-: {name}"
    );
    assert!(
        name.ends_with(".log"),
        "log file name should end with .log: {name}"
    );
}

#[test]
fn test_log_rotation_cleanup_old_files() {
    let tmp = tempfile::TempDir::new().unwrap();
    let log_dir = tmp.path().to_path_buf();

    // Create more than MAX_LOG_FILES fake log files with past dates.
    // We write all files quickly but expect prune to work on count, not age.
    let total = MAX_LOG_FILES + 5;
    for i in 0..total {
        let name = format!("fae-2025-01-{:02}.log", i + 1);
        fs::write(log_dir.join(&name), format!("entry {i}")).unwrap();
        // Small sleep so each file gets a distinct mtime for ordering.
        std::thread::sleep(std::time::Duration::from_millis(2));
    }

    // Before opening, count the old files (all pre-written).
    let before_count = fs::read_dir(&log_dir)
        .unwrap()
        .flatten()
        .filter(|e| {
            let n = e.file_name().to_string_lossy().to_string();
            n.starts_with("fae-") && n.ends_with(".log")
        })
        .count();
    assert_eq!(before_count, total, "should start with {total} log files");

    // Opening a writer triggers pruning of over-limit files, then creates today's file.
    let _writer = RotatingFileWriter::open(&log_dir).unwrap();

    let remaining_count = fs::read_dir(&log_dir)
        .unwrap()
        .flatten()
        .filter(|e| {
            let n = e.file_name().to_string_lossy().to_string();
            n.starts_with("fae-") && n.ends_with(".log")
        })
        .count();

    // After pruning and creating today's file, total should be at most MAX_LOG_FILES + 1.
    // The +1 accounts for today's newly created log file (which was not among the
    // pre-written files). The prune runs before the new file is created.
    assert!(
        remaining_count <= MAX_LOG_FILES + 1,
        "after rotation, at most {} log files should remain; got {}",
        MAX_LOG_FILES + 1,
        remaining_count
    );
    // Prune definitely removed some files (started with total > MAX_LOG_FILES).
    assert!(
        remaining_count < total,
        "prune should have removed some files; before={total} after={remaining_count}"
    );
}

#[test]
fn test_log_rotation_file_content_format() {
    let tmp = tempfile::TempDir::new().unwrap();
    let log_dir = tmp.path().to_path_buf();

    let mut writer = RotatingFileWriter::open(&log_dir).unwrap();
    writer
        .write_line("WARN", "memory_pressure", "RAM below warning threshold")
        .unwrap();
    writer
        .write_line("ERROR", "pipeline", "crash detected")
        .unwrap();

    let content = fs::read_to_string(writer.path()).unwrap();
    assert!(content.contains("[WARN]"), "should contain level tag");
    assert!(
        content.contains("[memory_pressure]"),
        "should contain target tag"
    );
    assert!(
        content.contains("RAM below warning threshold"),
        "should contain message"
    );
    assert!(content.contains("[ERROR]"), "should contain error level");
    assert!(
        content.contains("crash detected"),
        "should contain second message"
    );
}
