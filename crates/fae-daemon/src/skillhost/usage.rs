//! Skill usage counters for lifecycle curation (Phase G4).
//!
//! Counters survive daemon restarts via a JSON file in the conductor store
//! directory. A corrupt file starts fresh with a loud tracing warning —
//! counters inform curation only, they are NOT a security surface.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// One skill's lifetime usage summary.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UsageEntry {
    /// Total successful `prepare_run` invocations.
    pub run_count: u64,
    /// Most recent successful run (ms since UNIX epoch).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_used_ms: Option<u64>,
    /// When this skill was first seen by the store (ms since UNIX epoch).
    /// Set once on discovery; never overwritten.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_seen_ms: Option<u64>,
}

/// A public listing row for `skillhost.usage`.
#[derive(Debug, Clone, Serialize)]
pub struct UsageListing {
    /// The skill name.
    pub name: String,
    /// Total successful `prepare_run` invocations.
    pub run_count: u64,
    /// Most recent successful run timestamp; absent when never run.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_used_ms: Option<u64>,
    /// When this skill was first discovered; absent for pre-G4 stores.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_seen_ms: Option<u64>,
}

/// In-memory + on-disk usage counter store.
pub struct UsageStore {
    path: PathBuf,
    map: HashMap<String, UsageEntry>,
}

impl UsageStore {
    /// Load counters from `path`; a missing or corrupt file starts fresh
    /// (corruption is surfaced with a tracing warning, never an error).
    pub fn load(path: PathBuf) -> Self {
        let map = match std::fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<HashMap<String, UsageEntry>>(&bytes) {
                Ok(m) => m,
                Err(err) => {
                    tracing::warn!(
                        path = %path.display(),
                        %err,
                        "skillhost: usage file corrupt — starting fresh"
                    );
                    HashMap::new()
                }
            },
            Err(_) => HashMap::new(),
        };
        Self { path, map }
    }

    /// A memory-only store (no persistence) for tests and pathless hosts.
    #[must_use]
    pub fn empty() -> Self {
        Self {
            path: PathBuf::new(),
            map: HashMap::new(),
        }
    }

    /// Record that skills `names` were discovered at `now_ms`. Sets
    /// `first_seen_ms` only for skills not yet in the store; never overwrites.
    pub fn note_discovered(&mut self, names: &[&str], now_ms: u64) {
        let mut changed = false;
        for name in names {
            let entry = self.map.entry((*name).to_string()).or_default();
            if entry.first_seen_ms.is_none() {
                entry.first_seen_ms = Some(now_ms);
                changed = true;
            }
        }
        if changed {
            self.persist();
        }
    }

    /// Increment `skill`'s run counter and stamp `last_used_ms`; best-effort
    /// persist.
    pub fn increment(&mut self, skill: &str, now_ms: u64) {
        let entry = self.map.entry(skill.to_string()).or_default();
        entry.run_count += 1;
        entry.last_used_ms = Some(now_ms);
        self.persist();
    }

    /// Build a merged listing: every skill in `all_names` gets an entry,
    /// zero-filled when never seen. Sorted by name for determinism.
    pub fn merged_listing<'a>(
        &self,
        all_names: impl Iterator<Item = &'a str>,
    ) -> Vec<UsageListing> {
        let mut out: Vec<UsageListing> = all_names
            .map(|name| {
                let e = self.map.get(name).cloned().unwrap_or_default();
                UsageListing {
                    name: name.to_owned(),
                    run_count: e.run_count,
                    last_used_ms: e.last_used_ms,
                    first_seen_ms: e.first_seen_ms,
                }
            })
            .collect();
        out.sort_by(|a, b| a.name.cmp(&b.name));
        out
    }

    fn persist(&self) {
        if self.path.as_os_str().is_empty() {
            return;
        }
        match serde_json::to_vec_pretty(&self.map) {
            Ok(bytes) => {
                if let Err(err) = std::fs::write(&self.path, &bytes) {
                    tracing::warn!(
                        path = %self.path.display(),
                        %err,
                        "skillhost: failed to persist usage counters"
                    );
                }
            }
            Err(err) => {
                tracing::warn!(%err, "skillhost: failed to serialize usage counters");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_store_yields_zero_counts() {
        let store = UsageStore::empty();
        let listing = store.merged_listing(["forge", "toolbox"].into_iter());
        assert_eq!(listing.len(), 2);
        assert!(listing.iter().all(|l| l.run_count == 0));
        assert!(listing.iter().all(|l| l.last_used_ms.is_none()));
    }

    #[test]
    fn increment_updates_count_and_last_used() {
        let mut store = UsageStore::empty();
        store.increment("forge", 1_000);
        store.increment("forge", 2_000);
        let listing = store.merged_listing(["forge", "toolbox"].into_iter());
        let forge = listing.iter().find(|l| l.name == "forge").expect("forge");
        assert_eq!(forge.run_count, 2);
        assert_eq!(forge.last_used_ms, Some(2_000));
        let toolbox = listing
            .iter()
            .find(|l| l.name == "toolbox")
            .expect("toolbox");
        assert_eq!(toolbox.run_count, 0);
    }

    #[test]
    fn note_discovered_sets_first_seen_once() {
        let mut store = UsageStore::empty();
        store.note_discovered(&["auto-skill"], 1_000);
        store.note_discovered(&["auto-skill"], 9_999); // must not overwrite
        let listing = store.merged_listing(["auto-skill"].into_iter());
        assert_eq!(listing[0].first_seen_ms, Some(1_000));
    }

    #[test]
    fn corrupt_file_starts_fresh() {
        let dir = tempfile::tempdir().expect("tmp");
        let path = dir.path().join("usage.json");
        std::fs::write(&path, b"not valid json{{{").expect("write");
        let store = UsageStore::load(path);
        assert!(store.map.is_empty());
    }

    #[test]
    fn persist_and_reload_round_trip() {
        let dir = tempfile::tempdir().expect("tmp");
        let path = dir.path().join("usage.json");
        let mut store = UsageStore::load(path.clone());
        store.increment("forge", 42_000);
        let store2 = UsageStore::load(path);
        let entry = store2.map.get("forge").expect("forge");
        assert_eq!(entry.run_count, 1);
        assert_eq!(entry.last_used_ms, Some(42_000));
    }
}
