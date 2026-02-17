//! Scheduler authority and dedupe primitives.

use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

/// Leadership lease timing policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LeaderLeaseConfig {
    /// Lease lifetime in seconds.
    pub ttl_secs: u64,
    /// Expected heartbeat interval in seconds.
    pub heartbeat_secs: u64,
}

impl Default for LeaderLeaseConfig {
    fn default() -> Self {
        Self {
            ttl_secs: 15,
            heartbeat_secs: 5,
        }
    }
}

/// Result of a lease renewal/acquisition attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LeadershipDecision {
    /// This instance owns leadership after the attempt.
    Leader {
        /// `true` when leadership was taken over from an expired peer.
        takeover: bool,
    },
    /// Another instance currently owns leadership.
    Follower {
        leader_instance_id: String,
        lease_expires_at: u64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct LeaderLeaseRecord {
    instance_id: String,
    pid: u32,
    started_at: u64,
    heartbeat_at: u64,
    lease_expires_at: u64,
}

/// File-backed leader lease used to ensure a single active scheduler leader.
pub struct LeaderLease {
    instance_id: String,
    pid: u32,
    lease_path: PathBuf,
    config: LeaderLeaseConfig,
}

impl LeaderLease {
    /// Create a new leader lease controller for one scheduler host instance.
    #[must_use]
    pub fn new(
        instance_id: impl Into<String>,
        pid: u32,
        lease_path: PathBuf,
        config: LeaderLeaseConfig,
    ) -> Self {
        Self {
            instance_id: instance_id.into(),
            pid,
            lease_path,
            config,
        }
    }

    /// Try to acquire or renew leadership at the given epoch-millisecond time.
    pub fn try_acquire_or_renew_at(&self, now_ms: u64) -> Result<LeadershipDecision> {
        let ttl_ms = self.config.ttl_secs.saturating_mul(1000);
        let existing = read_lease_record(&self.lease_path)?;

        match existing {
            None => {
                let record = self.build_record(now_ms, now_ms, now_ms.saturating_add(ttl_ms));
                write_lease_record(&self.lease_path, &record)?;
                Ok(LeadershipDecision::Leader { takeover: false })
            }
            Some(existing) if existing.instance_id == self.instance_id => {
                let record =
                    self.build_record(existing.started_at, now_ms, now_ms.saturating_add(ttl_ms));
                write_lease_record(&self.lease_path, &record)?;
                Ok(LeadershipDecision::Leader { takeover: false })
            }
            Some(existing) if existing.lease_expires_at <= now_ms => {
                let record = self.build_record(now_ms, now_ms, now_ms.saturating_add(ttl_ms));
                write_lease_record(&self.lease_path, &record)?;
                Ok(LeadershipDecision::Leader { takeover: true })
            }
            Some(existing) => Ok(LeadershipDecision::Follower {
                leader_instance_id: existing.instance_id,
                lease_expires_at: existing.lease_expires_at,
            }),
        }
    }

    fn build_record(
        &self,
        started_at: u64,
        heartbeat_at: u64,
        lease_expires_at: u64,
    ) -> LeaderLeaseRecord {
        LeaderLeaseRecord {
            instance_id: self.instance_id.clone(),
            pid: self.pid,
            started_at,
            heartbeat_at,
            lease_expires_at,
        }
    }
}

fn read_lease_record(path: &PathBuf) -> Result<Option<LeaderLeaseRecord>> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(SpeechError::Scheduler(format!(
                "failed to read scheduler leader lease: {e}"
            )));
        }
    };

    match serde_json::from_slice::<LeaderLeaseRecord>(&bytes) {
        Ok(record) => Ok(Some(record)),
        Err(e) => {
            tracing::warn!(
                "ignoring malformed scheduler leader lease at {}: {e}",
                path.display()
            );
            Ok(None)
        }
    }
}

fn write_lease_record(path: &PathBuf, record: &LeaderLeaseRecord) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            SpeechError::Scheduler(format!("failed to create scheduler lease directory: {e}"))
        })?;
    }

    let tmp_path = path.with_extension("tmp");
    let json = serde_json::to_vec(record)
        .map_err(|e| SpeechError::Scheduler(format!("failed to serialize scheduler lease: {e}")))?;
    std::fs::write(&tmp_path, json).map_err(|e| {
        SpeechError::Scheduler(format!("failed to write scheduler lease temp file: {e}"))
    })?;
    std::fs::rename(&tmp_path, path).map_err(|e| {
        SpeechError::Scheduler(format!("failed to finalize scheduler lease file: {e}"))
    })?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RunKeyRecord {
    run_key: String,
    recorded_at_ms: u64,
}

/// File-backed dedupe ledger for scheduled run keys.
pub struct RunKeyLedger {
    path: PathBuf,
    seen: HashSet<String>,
}

impl RunKeyLedger {
    /// Create a new run-key ledger bound to a JSONL file path.
    #[must_use]
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            seen: HashSet::new(),
        }
    }

    /// Record a run key once. Returns `true` when newly inserted.
    pub fn record_once(&mut self, run_key: &str) -> Result<bool> {
        let trimmed = run_key.trim();
        if trimmed.is_empty() {
            return Err(SpeechError::Scheduler(
                "run key must not be empty".to_owned(),
            ));
        }

        let _guard = self.acquire_write_guard(Duration::from_millis(1500))?;
        self.refresh_seen_from_disk()?;

        if self.seen.contains(trimmed) {
            return Ok(false);
        }

        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| {
                SpeechError::Scheduler(format!("failed to create scheduler dedupe directory: {e}"))
            })?;
        }

        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .map_err(|e| SpeechError::Scheduler(format!("failed to open run key ledger: {e}")))?;

        let record = RunKeyRecord {
            run_key: trimmed.to_owned(),
            recorded_at_ms: now_epoch_millis(),
        };
        let json = serde_json::to_string(&record)
            .map_err(|e| SpeechError::Scheduler(format!("failed to encode run key record: {e}")))?;
        writeln!(file, "{json}")
            .map_err(|e| SpeechError::Scheduler(format!("failed to append run key record: {e}")))?;

        self.seen.insert(trimmed.to_owned());
        Ok(true)
    }

    fn refresh_seen_from_disk(&mut self) -> Result<()> {
        self.seen.clear();
        let content = match std::fs::read_to_string(&self.path) {
            Ok(content) => content,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Ok(());
            }
            Err(e) => {
                return Err(SpeechError::Scheduler(format!(
                    "failed to read run key ledger: {e}"
                )));
            }
        };

        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            match serde_json::from_str::<RunKeyRecord>(trimmed) {
                Ok(record) => {
                    self.seen.insert(record.run_key);
                }
                Err(e) => {
                    tracing::warn!(
                        "ignoring malformed run key ledger line in {}: {e}",
                        self.path.display()
                    );
                }
            }
        }

        Ok(())
    }

    fn lock_path(&self) -> PathBuf {
        self.path.with_extension("lock")
    }

    fn acquire_write_guard(&self, timeout: Duration) -> Result<RunKeyLockGuard> {
        let lock_path = self.lock_path();
        if let Some(parent) = lock_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| {
                SpeechError::Scheduler(format!(
                    "failed to create scheduler dedupe lock directory: {e}"
                ))
            })?;
        }

        let started = std::time::Instant::now();
        loop {
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&lock_path)
            {
                Ok(mut file) => {
                    let stamp = now_epoch_millis().to_string();
                    let _ = file.write_all(stamp.as_bytes());
                    return Ok(RunKeyLockGuard { path: lock_path });
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    self.evict_stale_lock(&lock_path);
                    if started.elapsed() > timeout {
                        return Err(SpeechError::Scheduler(format!(
                            "timed out waiting for run-key ledger lock {}",
                            lock_path.display()
                        )));
                    }
                    std::thread::sleep(Duration::from_millis(2));
                }
                Err(e) => {
                    return Err(SpeechError::Scheduler(format!(
                        "failed to create run-key ledger lock {}: {e}",
                        lock_path.display()
                    )));
                }
            }
        }
    }

    fn evict_stale_lock(&self, lock_path: &PathBuf) {
        let metadata = match std::fs::metadata(lock_path) {
            Ok(metadata) => metadata,
            Err(_) => return,
        };

        let modified = match metadata.modified() {
            Ok(modified) => modified,
            Err(_) => return,
        };

        let age = match SystemTime::now().duration_since(modified) {
            Ok(age) => age,
            Err(_) => return,
        };

        if age > Duration::from_secs(30) {
            let _ = std::fs::remove_file(lock_path);
        }
    }
}

struct RunKeyLockGuard {
    path: PathBuf,
}

impl Drop for RunKeyLockGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Current epoch time in milliseconds.
#[must_use]
pub fn now_epoch_millis() -> u64 {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(duration) => u64::try_from(duration.as_millis()).unwrap_or(u64::MAX),
        Err(_) => 0,
    }
}
