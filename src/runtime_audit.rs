//! Durable audit log for runtime profile transitions.
//!
//! Stores JSONL entries for rescue/standard profile transitions so recovery
//! actions remain inspectable across restarts.

use crate::config::RuntimeProfile;
use crate::error::{Result, SpeechError};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, Write};
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

const RUNTIME_AUDIT_KEY_FILE_NAME: &str = "runtime_audit.key";
const RUNTIME_AUDIT_KEY_LEN: usize = 32;

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

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedRuntimeAuditEntry {
    #[serde(flatten)]
    entry: RuntimeAuditEntry,
    #[serde(skip_serializing_if = "Option::is_none")]
    chain_prev: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chain_hash: Option<String>,
}

#[derive(Debug, Serialize)]
struct RuntimeAuditHashPayload<'a> {
    timestamp_secs: u64,
    source: RuntimeAuditSource,
    from_profile: RuntimeProfile,
    to_profile: RuntimeProfile,
    reason: &'a str,
    restart_count: Option<u32>,
    threshold: Option<u32>,
    request_id: Option<&'a str>,
    chain_prev: Option<&'a str>,
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

    let integrity_key = load_or_create_runtime_audit_integrity_key(&anchored_path)?;

    let mut options = OpenOptions::new();
    options.create(true).read(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }

    let mut file = options.open(&anchored_path)?;
    lock_file_exclusive(&file)?;

    let chain_prev = read_last_chain_hash_from_file(&mut file, &integrity_key)?;
    let chain_hash =
        compute_runtime_audit_chain_hash(&integrity_key, entry, chain_prev.as_deref())?;
    let persisted = PersistedRuntimeAuditEntry {
        entry: entry.clone(),
        chain_prev,
        chain_hash: Some(chain_hash),
    };

    let line = serde_json::to_string(&persisted)
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

    let integrity_key = load_runtime_audit_integrity_key_if_present(path)?;
    let mut last_verified_hash: Option<String> = None;
    let mut tail: VecDeque<RuntimeAuditEntry> = VecDeque::new();
    for (idx, line) in BufReader::new(file).lines().enumerate() {
        let Ok(line) = line else {
            continue;
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        match serde_json::from_str::<PersistedRuntimeAuditEntry>(trimmed) {
            Ok(persisted) => {
                verify_runtime_audit_chain_entry(
                    &persisted,
                    integrity_key.as_ref(),
                    &mut last_verified_hash,
                    idx + 1,
                )?;

                if tail.len() == limit {
                    let _ = tail.pop_front();
                }
                tail.push_back(persisted.entry);
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

fn compute_runtime_audit_chain_hash(
    key: &[u8; RUNTIME_AUDIT_KEY_LEN],
    entry: &RuntimeAuditEntry,
    chain_prev: Option<&str>,
) -> Result<String> {
    let payload = RuntimeAuditHashPayload {
        timestamp_secs: entry.timestamp_secs,
        source: entry.source,
        from_profile: entry.from_profile,
        to_profile: entry.to_profile,
        reason: &entry.reason,
        restart_count: entry.restart_count,
        threshold: entry.threshold,
        request_id: entry.request_id.as_deref(),
        chain_prev,
    };
    let payload_bytes = serde_json::to_vec(&payload).map_err(|e| {
        SpeechError::Config(format!("runtime audit hash serialization failed: {e}"))
    })?;
    Ok(blake3::keyed_hash(key, &payload_bytes).to_hex().to_string())
}

fn runtime_audit_key_file_for_audit_path(audit_path: &Path) -> PathBuf {
    audit_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(RUNTIME_AUDIT_KEY_FILE_NAME)
}

fn load_or_create_runtime_audit_integrity_key(
    audit_path: &Path,
) -> Result<[u8; RUNTIME_AUDIT_KEY_LEN]> {
    let key_path = runtime_audit_key_file_for_audit_path(audit_path);
    if let Some(parent) = key_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    match read_runtime_audit_integrity_key(&key_path) {
        Ok(key) => Ok(key),
        Err(SpeechError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {
            let mut key = [0u8; RUNTIME_AUDIT_KEY_LEN];
            rand::rngs::OsRng.fill_bytes(&mut key);
            if let Err(write_err) = write_runtime_audit_integrity_key(&key_path, &key) {
                if let SpeechError::Io(io_err) = &write_err
                    && io_err.kind() == std::io::ErrorKind::AlreadyExists
                {
                    return read_runtime_audit_integrity_key(&key_path);
                }
                return Err(write_err);
            }
            Ok(key)
        }
        Err(e) => Err(e),
    }
}

fn load_runtime_audit_integrity_key_if_present(
    audit_path: &Path,
) -> Result<Option<[u8; RUNTIME_AUDIT_KEY_LEN]>> {
    let key_path = runtime_audit_key_file_for_audit_path(audit_path);
    match read_runtime_audit_integrity_key(&key_path) {
        Ok(key) => Ok(Some(key)),
        Err(SpeechError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

fn write_runtime_audit_integrity_key(
    key_path: &Path,
    key: &[u8; RUNTIME_AUDIT_KEY_LEN],
) -> Result<()> {
    if let Ok(meta) = std::fs::symlink_metadata(key_path)
        && meta.file_type().is_symlink()
    {
        return Err(SpeechError::Config(
            "runtime audit key path cannot be a symlink".to_string(),
        ));
    }

    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(key_path)?;
    file.write_all(key)?;
    file.sync_all()?;
    Ok(())
}

fn read_runtime_audit_integrity_key(key_path: &Path) -> Result<[u8; RUNTIME_AUDIT_KEY_LEN]> {
    if let Ok(meta) = std::fs::symlink_metadata(key_path)
        && meta.file_type().is_symlink()
    {
        return Err(SpeechError::Config(
            "runtime audit key path cannot be a symlink".to_string(),
        ));
    }

    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(key_path)?;
    let mut key = [0u8; RUNTIME_AUDIT_KEY_LEN];
    file.read_exact(&mut key)?;
    let mut trailing = [0u8; 1];
    match file.read(&mut trailing) {
        Ok(0) => Ok(key),
        Ok(_) => Err(SpeechError::Config(
            "runtime audit key file has invalid length".to_string(),
        )),
        Err(e) => Err(SpeechError::Io(e)),
    }
}

fn read_last_chain_hash_from_file(
    file: &mut File,
    integrity_key: &[u8; RUNTIME_AUDIT_KEY_LEN],
) -> Result<Option<String>> {
    file.rewind()?;
    let mut last_verified_hash: Option<String> = None;
    for (idx, line) in BufReader::new(file.try_clone()?).lines().enumerate() {
        let line = line?;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let persisted =
            serde_json::from_str::<PersistedRuntimeAuditEntry>(trimmed).map_err(|e| {
                SpeechError::Config(format!(
                    "runtime audit log is malformed at line {}: {e}",
                    idx + 1
                ))
            })?;
        verify_runtime_audit_chain_entry(
            &persisted,
            Some(integrity_key),
            &mut last_verified_hash,
            idx + 1,
        )?;
    }
    Ok(last_verified_hash)
}

fn verify_runtime_audit_chain_entry(
    persisted: &PersistedRuntimeAuditEntry,
    integrity_key: Option<&[u8; RUNTIME_AUDIT_KEY_LEN]>,
    last_verified_hash: &mut Option<String>,
    line_number: usize,
) -> Result<()> {
    if let Some(chain_hash) = persisted.chain_hash.as_deref() {
        let key = integrity_key.ok_or_else(|| {
            SpeechError::Config(
                "runtime audit integrity key missing for signed audit entries".to_string(),
            )
        })?;
        if persisted.chain_prev.as_deref() != last_verified_hash.as_deref() {
            return Err(SpeechError::Config(format!(
                "runtime audit integrity chain mismatch at line {line_number}"
            )));
        }
        let expected = compute_runtime_audit_chain_hash(
            key,
            &persisted.entry,
            persisted.chain_prev.as_deref(),
        )?;
        if chain_hash != expected {
            return Err(SpeechError::Config(format!(
                "runtime audit integrity hash mismatch at line {line_number}"
            )));
        }
        *last_verified_hash = Some(chain_hash.to_owned());
    } else {
        *last_verified_hash = None;
    }
    Ok(())
}

fn lock_file_exclusive(file: &File) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        if rc != 0 {
            return Err(SpeechError::Io(std::io::Error::last_os_error()));
        }
    }
    #[cfg(not(unix))]
    {
        let _ = file;
    }
    Ok(())
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

    #[test]
    fn append_creates_integrity_key_file() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("runtime_audit.jsonl");
        append_runtime_audit_to_path(
            &path,
            &entry(
                "manual switch",
                RuntimeProfile::Standard,
                RuntimeProfile::Rescue,
            ),
        )
        .expect("append entry");

        let key_path = runtime_audit_key_file_for_audit_path(&path);
        assert!(key_path.exists(), "integrity key file should exist");
        let key_bytes = std::fs::read(key_path).expect("read key file");
        assert_eq!(key_bytes.len(), RUNTIME_AUDIT_KEY_LEN);
    }

    #[test]
    fn read_recent_detects_integrity_tampering() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("runtime_audit.jsonl");
        append_runtime_audit_to_path(
            &path,
            &entry("first", RuntimeProfile::Standard, RuntimeProfile::Rescue),
        )
        .expect("append first");
        append_runtime_audit_to_path(
            &path,
            &entry("second", RuntimeProfile::Rescue, RuntimeProfile::Standard),
        )
        .expect("append second");

        let original = std::fs::read_to_string(&path).expect("read audit");
        let tampered = original.replace("\"reason\":\"second\"", "\"reason\":\"tampered\"");
        std::fs::write(&path, tampered).expect("write tampered audit");

        let err = read_recent_runtime_audit_from_path(&path, 10).expect_err("tamper should fail");
        let msg = err.to_string();
        assert!(
            msg.contains("integrity"),
            "expected integrity error message, got: {msg}"
        );
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
