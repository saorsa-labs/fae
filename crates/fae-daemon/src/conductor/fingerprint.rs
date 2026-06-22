//! Privacy-critical request fingerprint (review finding F-4).
//!
//! **No user text is ever hashed or stored.** The sole correlation key between
//! an owner turn and its route telemetry is a [`RequestFingerprint`]:
//! HMAC-SHA-256 of the **opaque `request_id`** with a **per-install random
//! key**. This guarantees:
//!
//! - Telemetry cannot be joined to query *content* (the request id is already
//!   an opaque random value; the HMAC adds nothing content-derived).
//! - Telemetry cannot be correlated across installations (different install
//!   keys ⇒ different fingerprints for the same request id).
//! - A database/log adversary sees only an opaque token with no derivable
//!   value — defeating the "re-identifiable wiretap" failure the reviewer
//!   flagged for a naive SHA-256-of-user-text scheme.
//!
//! The install key is generated once (CSPRNG, 32 bytes) and persisted `0600`
//! alongside the daemon run dir, mirroring the bootstrap-token pattern.

use std::path::Path;

use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::conductor::error::ConductorError;

type HmacSha256 = Hmac<Sha256>;

/// 32-byte per-install HMAC key. Non-secret in the sense that the fingerprints
/// it produces are non-reversible, but kept `0600` so an attacker who reads
/// telemetry still cannot forge or join fingerprints off-device.
#[derive(Debug, Clone)]
pub struct InstallKey([u8; 32]);

impl InstallKey {
    /// Load the key from `path`, or generate + persist it (`0600`) if absent.
    /// The parent directory must already exist with restrictive permissions.
    ///
    /// A corrupt/truncated key file is **regenerated AND re-persisted** so the
    /// next load is stable — otherwise a truncated file would regenerate a
    /// different key on every daemon restart, breaking telemetry correlation
    /// repeatedly (M2's reward aggregator reads this telemetry, so silently-
    /// discontinuous fingerprints would corrupt the eval signal). The
    /// discontinuity is logged once.
    pub fn load_or_create(path: &Path) -> Result<Self, ConductorError> {
        if path.exists() {
            let bytes = std::fs::read(path)?;
            if bytes.len() == 32 {
                let mut tmp = [0u8; 32];
                tmp.copy_from_slice(&bytes);
                // Re-lock permissions defensively.
                Self::chmod_0600(path)?;
                return Ok(Self(tmp));
            }
            // Corrupt/truncated key file (no user data is at stake; the
            // conductor store is telemetry-only). Regenerate AND re-persist so
            // the discontinuity happens exactly once, not on every restart.
            eprintln!(
                "fae-daemon: conductor install key at {} was corrupt \
                 ({} bytes, expected 32) — regenerating and re-persisting; \
                 route telemetry prior to this point will no longer correlate",
                path.display(),
                bytes.len()
            );
            let key = Self::generate()?;
            Self::persist(path, &key.0)?;
            return Ok(key);
        }
        let key = Self::generate()?;
        Self::persist(path, &key.0)?;
        Ok(key)
    }

    /// Atomically persist the key to `path` (temp sibling + rename on POSIX) and
    /// lock it `0600`. The parent directory must already exist with restrictive
    /// permissions; the temp file is created inside it, so the write→chmod
    /// window is owner-only regardless of umask.
    fn persist(path: &Path, arr: &[u8; 32]) -> Result<(), ConductorError> {
        let tmp: std::path::PathBuf = format!("{}.tmp", path.display()).into();
        std::fs::write(&tmp, arr)?;
        Self::chmod_0600(&tmp)?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    fn generate() -> Result<Self, ConductorError> {
        let mut buf = [0u8; 32];
        getrandom::getrandom(&mut buf)?;
        Ok(Self(buf))
    }

    #[cfg(unix)]
    fn chmod_0600(path: &Path) -> Result<(), ConductorError> {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, perms)?;
        Ok(())
    }

    #[cfg(not(unix))]
    fn chmod_0600(_path: &Path) -> Result<(), ConductorError> {
        Ok(())
    }

    /// Derive the opaque fingerprint for a request id. Returns an error only
    /// if the underlying HMAC rejects the install key (unreachable for a
    /// 32-byte key + SHA-256) — surfaced rather than `expect`-ed to stay
    /// panic-free in production code.
    pub fn fingerprint(&self, request_id: &str) -> Result<RequestFingerprint, ConductorError> {
        let mut mac = HmacSha256::new_from_slice(&self.0)
            .map_err(|e| ConductorError::KeyLength(e.to_string()))?;
        mac.update(request_id.as_bytes());
        let bytes = mac.finalize().into_bytes();
        let mut hex = String::with_capacity(bytes.len() * 2);
        for b in bytes.iter() {
            hex.push_str(&format!("{b:02x}"));
        }
        Ok(RequestFingerprint(hex))
    }
}

/// An opaque, per-install correlation token. The **only** identifier stored in
/// route telemetry. Carries no derivable information about the user's request.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RequestFingerprint(pub String);

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> InstallKey {
        // Deterministic test key.
        InstallKey([0x42u8; 32])
    }

    #[test]
    fn fingerprint_is_deterministic_for_same_key_and_id() {
        let k = key();
        let a = k.fingerprint("req-123").expect("fp in test");
        let b = k.fingerprint("req-123").expect("fp in test");
        assert_eq!(a, b);
        assert_eq!(a.0.len(), 64); // 32 bytes hex
    }

    #[test]
    fn fingerprint_differs_for_different_request_ids() {
        let k = key();
        assert_ne!(
            k.fingerprint("req-1").expect("fp in test"),
            k.fingerprint("req-2").expect("fp in test")
        );
    }

    #[test]
    fn fingerprint_differs_across_install_keys() {
        let k1 = InstallKey([0x01u8; 32]);
        let k2 = InstallKey([0x02u8; 32]);
        assert_ne!(
            k1.fingerprint("req-1").expect("fp in test"),
            k2.fingerprint("req-1").expect("fp in test")
        );
    }

    #[test]
    fn load_or_create_is_idempotent() {
        let dir = tempfile::tempdir().expect("tempdir in test");
        let path = dir.path().join("conductor.key");
        let k1 = InstallKey::load_or_create(&path).expect("create in test");
        let k2 = InstallKey::load_or_create(&path).expect("reload in test");
        assert_eq!(
            k1.fingerprint("x").expect("fp in test"),
            k2.fingerprint("x").expect("fp in test")
        );
    }

    #[test]
    #[cfg(unix)]
    fn created_key_is_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().expect("tempdir in test");
        let path = dir.path().join("conductor.key");
        let _ = InstallKey::load_or_create(&path).expect("create in test");
        let mode = std::fs::metadata(&path)
            .map(|m| m.permissions().mode())
            .expect("stat in test");
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn corrupt_key_is_regenerated_and_repersisted() {
        // The live-path fix (M2 telemetry depends on it): a truncated key file
        // must be regenerated AND re-persisted, so the discontinuity happens
        // exactly once. Before the fix, a corrupt file regenerated a different
        // key on every restart and stayed corrupt on disk forever.
        let dir = tempfile::tempdir().expect("tempdir in test");
        let path = dir.path().join("conductor.key");
        // Seed a corrupt (truncated) key.
        std::fs::write(&path, b"only-a-few-bytes").expect("seed corrupt key");
        let first = InstallKey::load_or_create(&path).expect("regen in test");
        // The file is now a valid 32-byte key on disk (re-persisted).
        assert_eq!(
            std::fs::read(&path).expect("read re-persisted").len(),
            32,
            "corrupt key re-persisted at 32 bytes"
        );
        // A second load yields the SAME key (stable, not another regeneration).
        let second = InstallKey::load_or_create(&path).expect("reload in test");
        assert_eq!(
            first.fingerprint("x").expect("fp1 in test"),
            second.fingerprint("x").expect("fp2 in test"),
            "re-persisted key is stable across loads"
        );
    }
}
