//! Durable audit log for runtime profile transitions.
//!
//! Stores JSONL entries for rescue/standard profile transitions so recovery
//! actions remain inspectable across restarts.

use crate::config::RuntimeProfile;
use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

/// Source of a runtime profile transition.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeAuditSource {
    /// Profile changed automatically due to restart pressure.
    AutoRecovery,
    /// Profile changed by host command (`config.patch runtime.profile`).
    ConfigPatch,
}

/// One persisted runtime profile transition event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeAuditEntry {
    /// Timestamp when the transition was recorded.
    pub timestamp_secs: u64,
    /// Transition initiator.
    pub source: RuntimeAuditSource,
    /// Previous profile.
    pub from_profile: RuntimeProfile,
    /// New profile.
    pub to_profile: RuntimeProfile,
    /// Human-readable transition reason.
    pub reason: String,
    /// Optional restart count used for auto recovery.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub restart_count: Option<u32>,
    /// Optional rescue threshold used for auto recovery.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub threshold: Option<u32>,
    /// Optional host request ID associated with the transition.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

impl RuntimeAuditEntry {
    /// Create a new entry with the current timestamp.
    #[must_use]
    pub fn new(
        source: RuntimeAuditSource,
        from_profile: RuntimeProfile,
        to_profile: RuntimeProfile,
        reason: impl Into<String>,
        restart_count: Option<u32>,
        threshold: Option<u32>,
        request_id: Option<String>,
    ) -> Self {
        Self {
            timestamp_secs: now_epoch_secs(),
            source,
            from_profile,
            to_profile,
            reason: reason.into(),
            restart_count,
            threshold,
            request_id,
        }
    }
}

/// Returns the default runtime audit file path (`config_dir()/runtime_audit.jsonl`).
#[must_use]
pub fn default_runtime_audit_file() -> PathBuf {
    crate::fae_dirs::runtime_audit_file()
}

/// Derive the runtime audit file path from an explicit config path.
///
/// This keeps audit data colocated with `config.toml` even in tests and custom
/// deployments where config lives outside default directories.
#[must_use]
pub fn runtime_audit_file_for_config(config_path: &Path) -> PathBuf {
    config_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("runtime_audit.jsonl")
}

/// Append an audit entry to the default runtime audit file.
pub fn append_runtime_audit(entry: &RuntimeAuditEntry) -> Result<()> {
    append_runtime_audit_to_path(&default_runtime_audit_file(), entry)
}

/// Append an audit entry using a config path-derived audit file location.
pub fn append_runtime_audit_for_config(
    config_path: &Path,
    entry: &RuntimeAuditEntry,
) -> Result<()> {
    let path = runtime_audit_file_for_config(config_path);
    append_runtime_audit_to_path(&path, entry)
}

/// Read the most recent `limit` audit entries from the default audit file.
pub fn read_recent_runtime_audit(limit: usize) -> Result<Vec<RuntimeAuditEntry>> {
    read_recent_runtime_audit_from_path(&default_runtime_audit_file(), limit)
}

/// Read the most recent `limit` audit entries using a config path-derived location.
pub fn read_recent_runtime_audit_for_config(
    config_path: &Path,
    limit: usize,
) -> Result<Vec<RuntimeAuditEntry>> {
    let path = runtime_audit_file_for_config(config_path);
    read_recent_runtime_audit_from_path(&path, limit)
}

fn append_runtime_audit_to_path(path: &Path, entry: &RuntimeAuditEntry) -> Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let canonical_parent = parent.canonicalize()?;
    let file_name = path
        .file_name()
        .ok_or_else(|| SpeechError::Config("runtime audit path has no filename".to_string()))?;
    let anchored_path = canonical_parent.join(file_name);

    if let Ok(meta) = std::fs::symlink_metadata(&anchored_path)
        && meta.file_type().is_symlink()
    {
        return Err(SpeechError::Config(
            "runtime audit path cannot be a symlink".to_string(),
        ));
    }

    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }

    let mut file = options.open(&anchored_path)?;
    let line = serde_json::to_string(entry)
        .map_err(|e| SpeechError::Config(format!("runtime audit serialization failed: {e}")))?;
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

fn read_recent_runtime_audit_from_path(
    path: &Path,
    limit: usize,
) -> Result<Vec<RuntimeAuditEntry>> {
    if limit == 0 {
        return Ok(Vec::new());
    }

    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(SpeechError::Io(e)),
    };

    let mut tail: VecDeque<RuntimeAuditEntry> = VecDeque::new();
    for line in BufReader::new(file).lines() {
        let Ok(line) = line else {
            continue;
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<RuntimeAuditEntry>(trimmed) {
            Ok(entry) => {
                if tail.len() == limit {
                    let _ = tail.pop_front();
                }
                tail.push_back(entry);
            }
            Err(e) => {
                tracing::warn!(error = %e, "runtime_audit: skipping malformed audit line");
            }
        }
    }

    Ok(tail.into_iter().collect())
}

fn now_epoch_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    fn entry(reason: &str, from: RuntimeProfile, to: RuntimeProfile) -> RuntimeAuditEntry {
        RuntimeAuditEntry {
            timestamp_secs: 123,
            source: RuntimeAuditSource::ConfigPatch,
            from_profile: from,
            to_profile: to,
            reason: reason.to_owned(),
            restart_count: None,
            threshold: None,
            request_id: Some("req-1".to_owned()),
        }
    }

    #[test]
    fn append_and_read_roundtrip() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("runtime_audit.jsonl");
        let e = entry(
            "manual switch",
            RuntimeProfile::Standard,
            RuntimeProfile::Rescue,
        );

        append_runtime_audit_to_path(&path, &e).expect("append entry");
        let loaded = read_recent_runtime_audit_from_path(&path, 10).expect("read entries");

        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0], e);
    }

    #[test]
    fn read_recent_returns_tail_in_order() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("runtime_audit.jsonl");
        let entries = [
            entry("a", RuntimeProfile::Standard, RuntimeProfile::Rescue),
            entry("b", RuntimeProfile::Rescue, RuntimeProfile::Standard),
            entry("c", RuntimeProfile::Standard, RuntimeProfile::Rescue),
        ];

        for e in &entries {
            append_runtime_audit_to_path(&path, e).expect("append");
        }

        let loaded = read_recent_runtime_audit_from_path(&path, 2).expect("read");
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].reason, "b");
        assert_eq!(loaded[1].reason, "c");
    }

    #[test]
    fn read_recent_skips_malformed_lines() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("runtime_audit.jsonl");
        std::fs::write(
            &path,
            "{this is not valid json}\n\
             {\"timestamp_secs\":1,\"source\":\"config_patch\",\"from_profile\":\"standard\",\"to_profile\":\"rescue\",\"reason\":\"ok\"}\n",
        )
        .expect("write file");

        let loaded = read_recent_runtime_audit_from_path(&path, 10).expect("read");
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].reason, "ok");
    }

    #[test]
    fn runtime_audit_file_for_config_is_adjacent_to_config() {
        let config_path = PathBuf::from("/tmp/fae/config.toml");
        let audit_path = runtime_audit_file_for_config(&config_path);
        assert_eq!(audit_path, PathBuf::from("/tmp/fae/runtime_audit.jsonl"));
    }

    #[cfg(unix)]
    #[test]
    fn append_rejects_symlink_audit_target() {
        let dir = tempfile::tempdir().expect("temp dir");
        let real = dir.path().join("real_runtime_audit.jsonl");
        std::fs::write(&real, "").expect("create real audit");
        let link = dir.path().join("runtime_audit.jsonl");
        std::os::unix::fs::symlink(&real, &link).expect("create symlink");

        let result = append_runtime_audit_to_path(
            &link,
            &entry(
                "manual switch",
                RuntimeProfile::Standard,
                RuntimeProfile::Rescue,
            ),
        );
        assert!(result.is_err(), "symlink audit target should be rejected");
    }
}
