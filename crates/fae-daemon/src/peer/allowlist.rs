//! Phase E — file-backed live peer allowlist (the consent → allowlist bridge).
//!
//! `<fae data dir>/peer_allowlist.json` is written by the Swift owner surface
//! (`self_config peer_grant` / `peer_revoke`, behind the hardware-click
//! governance card) and read here. The daemon **unions** it with the env
//! lists (`FAE_X0X_ALLOW` / `FAE_X0X_OWNER_FLEET`) — env grants keep working,
//! file grants go live without a daemon restart. The ingress loop re-reads
//! the file when its mtime/length fingerprint changes (checked per inbound
//! frame via [`AllowlistWatcher::reload_if_changed`] — one `stat` per frame).
//!
//! Fail closed: a missing, malformed, or wrong-version file contributes
//! NOTHING (env-only), never crashes. Malformed entries are dropped with a
//! warning — one typo must not kill the rest of the allowlist (the same
//! contract as [`super::config`]'s env parsing).
//!
//! Wire shape (version 1):
//!
//! ```json
//! {
//!   "version": 1,
//!   "allow": [
//!     { "agent_id": "<64-hex>", "label": "Alice", "granted_at": "<iso8601>", "tier": "chat" }
//!   ]
//! }
//! ```
//!
//! `tier` is `"chat"` (direct message / presence) or `"owner_fleet"` (the
//! user's own devices — additionally permitted `session_handoff`). Unknown
//! tiers are dropped: a future tier must never silently widen access.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::Deserialize;

/// The only `peer_allowlist.json` schema version this daemon understands.
const SUPPORTED_VERSION: u64 = 1;

#[derive(Debug, Deserialize)]
struct AllowlistFile {
    version: u64,
    #[serde(default)]
    allow: Vec<AllowlistEntry>,
}

/// One grant row. `label` / `granted_at` are audit metadata for the owner —
/// the daemon only enforces `agent_id` + `tier`, so they are not declared
/// here (serde ignores unknown fields by default).
#[derive(Debug, Deserialize)]
struct AllowlistEntry {
    agent_id: String,
    tier: String,
}

/// The two sender tiers resolved from a source (env or file), ready to feed
/// [`super::verifier::FaeSenderVerifier`].
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct AllowlistSets {
    /// Chat/presence tier — may direct-message and share presence.
    pub chat_allow: HashSet<String>,
    /// Owner-fleet tier — additionally permitted `session_handoff`.
    pub owner_fleet: HashSet<String>,
}

impl AllowlistSets {
    /// Union of two sources — env grants and file grants both count.
    pub fn union_with(&self, other: &AllowlistSets) -> AllowlistSets {
        AllowlistSets {
            chat_allow: self.chat_allow.union(&other.chat_allow).cloned().collect(),
            owner_fleet: self
                .owner_fleet
                .union(&other.owner_fleet)
                .cloned()
                .collect(),
        }
    }
}

/// Load and validate the allowlist file. Missing file = quiet empty (the
/// normal pre-first-grant state); unreadable/malformed/wrong-version = warn +
/// empty (fail closed to env-only).
pub fn load(path: &Path) -> AllowlistSets {
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return AllowlistSets::default();
        }
        Err(error) => {
            tracing::warn!(
                path = %path.display(),
                "peer allowlist file unreadable ({error}); ignoring (env-only)"
            );
            return AllowlistSets::default();
        }
    };
    parse(&raw, path)
}

fn parse(raw: &str, path: &Path) -> AllowlistSets {
    let file: AllowlistFile = match serde_json::from_str(raw) {
        Ok(file) => file,
        Err(error) => {
            tracing::warn!(
                path = %path.display(),
                "peer allowlist file malformed ({error}); ignoring (env-only)"
            );
            return AllowlistSets::default();
        }
    };
    if file.version != SUPPORTED_VERSION {
        tracing::warn!(
            path = %path.display(),
            version = file.version,
            "peer allowlist file has unsupported version (expected {SUPPORTED_VERSION}); \
             ignoring (env-only)"
        );
        return AllowlistSets::default();
    }
    let mut sets = AllowlistSets::default();
    for entry in file.allow {
        let id = entry.agent_id.trim();
        if !(id.len() == 64 && id.bytes().all(|b| b.is_ascii_hexdigit())) {
            tracing::warn!(
                entry = %entry.agent_id,
                "dropping malformed peer-allowlist agent id (expected 64 hex chars)"
            );
            continue;
        }
        let id = id.to_ascii_lowercase();
        match entry.tier.as_str() {
            "chat" => {
                sets.chat_allow.insert(id);
            }
            "owner_fleet" => {
                sets.owner_fleet.insert(id);
            }
            other => {
                tracing::warn!(
                    tier = other,
                    "dropping peer-allowlist entry with unknown tier (fail closed)"
                );
            }
        }
    }
    sets
}

/// Watches `peer_allowlist.json` by mtime+length fingerprint and re-reads it
/// on change. Owned by the ingress loop; [`reload_if_changed`] is called once
/// per inbound frame (a single `stat` on the unchanged path).
///
/// [`reload_if_changed`]: AllowlistWatcher::reload_if_changed
pub struct AllowlistWatcher {
    path: PathBuf,
    fingerprint: Option<(SystemTime, u64)>,
    sets: AllowlistSets,
}

impl AllowlistWatcher {
    /// Construct with an initial read of the file.
    pub fn new(path: PathBuf) -> Self {
        let fingerprint = fingerprint_of(&path);
        let sets = load(&path);
        Self {
            path,
            fingerprint,
            sets,
        }
    }

    /// The current file-derived sets.
    pub fn sets(&self) -> &AllowlistSets {
        &self.sets
    }

    /// Re-read the file if its fingerprint changed (including appearing or
    /// disappearing). Returns `true` when the sets were reloaded.
    pub fn reload_if_changed(&mut self) -> bool {
        let current = fingerprint_of(&self.path);
        if current == self.fingerprint {
            return false;
        }
        self.fingerprint = current;
        self.sets = load(&self.path);
        true
    }
}

fn fingerprint_of(path: &Path) -> Option<(SystemTime, u64)> {
    let metadata = std::fs::metadata(path).ok()?;
    Some((metadata.modified().ok()?, metadata.len()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEX_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const HEX_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const HEX_C: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

    fn write_allowlist(dir: &Path, body: &str) -> PathBuf {
        let path = dir.join("peer_allowlist.json");
        std::fs::write(&path, body).unwrap();
        path
    }

    fn valid_body() -> String {
        format!(
            r#"{{"version":1,"allow":[
                {{"agent_id":"{HEX_A}","label":"Alice","granted_at":"2026-07-15T10:00:00Z","tier":"chat"}},
                {{"agent_id":"{HEX_B}","label":"my laptop","granted_at":"2026-07-15T10:00:00Z","tier":"owner_fleet"}}
            ]}}"#
        )
    }

    #[test]
    fn valid_file_maps_tiers() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_allowlist(dir.path(), &valid_body());
        let sets = load(&path);
        assert_eq!(sets.chat_allow, HashSet::from([HEX_A.to_owned()]));
        assert_eq!(sets.owner_fleet, HashSet::from([HEX_B.to_owned()]));
    }

    #[test]
    fn missing_file_is_quietly_empty() {
        let dir = tempfile::tempdir().unwrap();
        let sets = load(&dir.path().join("peer_allowlist.json"));
        assert_eq!(sets, AllowlistSets::default());
    }

    #[test]
    fn malformed_json_fails_closed_to_empty() {
        // WHY: a corrupt grant file must degrade to env-only trust, never
        // crash the ingress or (worse) admit anyone it should not.
        let dir = tempfile::tempdir().unwrap();
        let path = write_allowlist(dir.path(), "{not json");
        assert_eq!(load(&path), AllowlistSets::default());
    }

    #[test]
    fn unsupported_version_fails_closed_to_empty() {
        // WHY: a future schema might change grant semantics — an old daemon
        // must not guess at them.
        let dir = tempfile::tempdir().unwrap();
        let body = format!(r#"{{"version":2,"allow":[{{"agent_id":"{HEX_A}","tier":"chat"}}]}}"#);
        let path = write_allowlist(dir.path(), &body);
        assert_eq!(load(&path), AllowlistSets::default());
    }

    #[test]
    fn malformed_id_and_unknown_tier_dropped_valid_kept() {
        // WHY: one bad row must not kill the rest (matches env parsing), and
        // an unknown tier must never widen access.
        let dir = tempfile::tempdir().unwrap();
        let body = format!(
            r#"{{"version":1,"allow":[
                {{"agent_id":"not-hex","tier":"chat"}},
                {{"agent_id":"{HEX_C}","tier":"superuser"}},
                {{"agent_id":"{}","tier":"chat"}}
            ]}}"#,
            HEX_A.to_ascii_uppercase()
        );
        let path = write_allowlist(dir.path(), &body);
        let sets = load(&path);
        // Valid entry kept, normalised to lowercase; bad id + unknown tier dropped.
        assert_eq!(sets.chat_allow, HashSet::from([HEX_A.to_owned()]));
        assert!(sets.owner_fleet.is_empty());
    }

    #[test]
    fn union_with_merges_env_and_file_grants() {
        let env = AllowlistSets {
            chat_allow: HashSet::from([HEX_A.to_owned()]),
            owner_fleet: HashSet::from([HEX_B.to_owned()]),
        };
        let file = AllowlistSets {
            chat_allow: HashSet::from([HEX_C.to_owned()]),
            owner_fleet: HashSet::new(),
        };
        let merged = env.union_with(&file);
        assert_eq!(
            merged.chat_allow,
            HashSet::from([HEX_A.to_owned(), HEX_C.to_owned()])
        );
        assert_eq!(merged.owner_fleet, HashSet::from([HEX_B.to_owned()]));
    }

    #[test]
    fn watcher_reloads_on_fingerprint_change_and_only_then() {
        // WHY: this is the live-grant mechanism — a grant written by the app
        // must be picked up without a daemon restart, and an untouched file
        // must not trigger re-reads.
        let dir = tempfile::tempdir().unwrap();
        let path = write_allowlist(dir.path(), &valid_body());
        let mut watcher = AllowlistWatcher::new(path.clone());
        assert_eq!(watcher.sets().chat_allow, HashSet::from([HEX_A.to_owned()]));
        assert!(
            !watcher.reload_if_changed(),
            "untouched file must not reload"
        );

        // Grant a new chat peer; force a distinct fingerprint (mtime bump —
        // content length changes too, so either signal suffices).
        let body = format!(
            r#"{{"version":1,"allow":[
                {{"agent_id":"{HEX_A}","tier":"chat"}},
                {{"agent_id":"{HEX_C}","tier":"chat"}}
            ]}}"#
        );
        std::fs::write(&path, &body).unwrap();
        let file = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        file.set_modified(SystemTime::now() + std::time::Duration::from_secs(2))
            .unwrap();

        assert!(watcher.reload_if_changed(), "changed file must reload");
        assert_eq!(
            watcher.sets().chat_allow,
            HashSet::from([HEX_A.to_owned(), HEX_C.to_owned()])
        );
    }

    #[test]
    fn watcher_falls_back_to_empty_when_file_removed() {
        // WHY: deleting the grant file is a revoke-everything act — it must
        // take effect live, back to env-only trust.
        let dir = tempfile::tempdir().unwrap();
        let path = write_allowlist(dir.path(), &valid_body());
        let mut watcher = AllowlistWatcher::new(path.clone());
        assert!(!watcher.sets().chat_allow.is_empty());
        std::fs::remove_file(&path).unwrap();
        assert!(watcher.reload_if_changed());
        assert_eq!(watcher.sets(), &AllowlistSets::default());
    }
}
