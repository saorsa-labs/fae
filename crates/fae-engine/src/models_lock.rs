//! Fail-closed `models.lock` loader.
//!
//! A model artifact is loaded only if its on-disk file matches the size +
//! SHA-256 pinned in the lock. Anything unverifiable — missing file, size
//! mismatch, hash mismatch, or a placeholder (non-64-hex) hash — aborts. This is
//! the supply-chain gate (review-brief W4): the daemon never feeds unpinned
//! weights to the engine.

use std::path::{Path, PathBuf};

use serde::Deserialize;

pub const SUPPORTED_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, thiserror::Error)]
pub enum LockError {
    #[error("read models.lock: {0}")]
    Read(std::io::Error),
    #[error("parse models.lock: {0}")]
    Parse(String),
    #[error("unsupported models.lock schema version: {0}")]
    UnsupportedSchema(u32),
    #[error("artifact {id}: file missing at {path}")]
    Missing { id: String, path: String },
    #[error("artifact {id}: size mismatch (expected {expected}, got {actual})")]
    Size {
        id: String,
        expected: u64,
        actual: u64,
    },
    #[error("artifact {id}: sha256 mismatch or unpinned hash")]
    Checksum { id: String },
}

#[derive(Debug, Clone, Deserialize)]
pub struct ModelsLock {
    pub schema_version: u32,
    #[serde(default)]
    pub created_at: String,
    #[serde(default, rename = "artifact")]
    pub artifacts: Vec<Artifact>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Artifact {
    pub id: String,
    pub role: String,
    pub loader: String,
    #[serde(default)]
    pub source_repo: String,
    #[serde(default)]
    pub source_revision: String,
    pub filename: String,
    #[serde(default)]
    pub size_bytes: u64,
    pub sha256: String,
    #[serde(default)]
    pub signature: String,
    #[serde(default)]
    pub license: String,
    #[serde(default)]
    pub hardware_profile: String,
    #[serde(default)]
    pub approved_by: String,
    #[serde(default)]
    pub created_at: String,
}

impl ModelsLock {
    /// Parse + schema-gate. Does no I/O on artifact files.
    pub fn parse(text: &str) -> Result<ModelsLock, LockError> {
        let lock: ModelsLock =
            toml::from_str(text).map_err(|error| LockError::Parse(error.to_string()))?;
        if lock.schema_version != SUPPORTED_SCHEMA_VERSION {
            return Err(LockError::UnsupportedSchema(lock.schema_version));
        }
        Ok(lock)
    }

    pub fn load(path: &Path) -> Result<ModelsLock, LockError> {
        let text = std::fs::read_to_string(path).map_err(LockError::Read)?;
        Self::parse(&text)
    }

    /// Verify **every** artifact against files under `models_dir`. Fail-closed:
    /// the first failure aborts the whole load.
    pub fn verify_all(&self, models_dir: &Path) -> Result<(), LockError> {
        for artifact in &self.artifacts {
            artifact.verify(models_dir)?;
        }
        Ok(())
    }

    /// Look up a verified artifact by id, returning its on-disk path. Verifies
    /// that one artifact before handing back the path so callers can't load an
    /// unchecked file.
    pub fn verified_path(&self, id: &str, models_dir: &Path) -> Result<PathBuf, LockError> {
        let artifact = self
            .artifacts
            .iter()
            .find(|artifact| artifact.id == id)
            .ok_or_else(|| LockError::Missing {
                id: id.to_owned(),
                path: "<not in lock>".to_owned(),
            })?;
        artifact.verify(models_dir)?;
        Ok(artifact.resolved_path(models_dir))
    }
}

impl Artifact {
    #[must_use]
    pub fn resolved_path(&self, models_dir: &Path) -> PathBuf {
        models_dir.join(&self.filename)
    }

    /// Verify this artifact's file: exists, size matches (when pinned), and the
    /// SHA-256 matches the pinned hash. A non-64-hex `sha256` (e.g. the
    /// `<64-hex-sha256>` placeholder) is rejected — we never "verify" against a
    /// non-hash.
    pub fn verify(&self, models_dir: &Path) -> Result<(), LockError> {
        let path = self.resolved_path(models_dir);
        let bytes = std::fs::read(&path).map_err(|_| LockError::Missing {
            id: self.id.clone(),
            path: path.display().to_string(),
        })?;
        let actual_size = bytes.len() as u64;
        if self.size_bytes != 0 && actual_size != self.size_bytes {
            return Err(LockError::Size {
                id: self.id.clone(),
                expected: self.size_bytes,
                actual: actual_size,
            });
        }
        let expected = self.sha256.trim().to_ascii_lowercase();
        if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(LockError::Checksum {
                id: self.id.clone(),
            });
        }
        if sha256_hex(&bytes) != expected {
            return Err(LockError::Checksum {
                id: self.id.clone(),
            });
        }
        Ok(())
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, name: &str, contents: &[u8]) -> std::path::PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, contents).expect("write fixture");
        path
    }

    fn unique_dir(tag: &str) -> std::path::PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("fae-engine-{tag}-{nanos}"));
        std::fs::create_dir_all(&dir).expect("mkdir");
        dir
    }

    fn lock_with(filename: &str, size_bytes: u64, sha256: &str) -> ModelsLock {
        ModelsLock {
            schema_version: SUPPORTED_SCHEMA_VERSION,
            created_at: String::new(),
            artifacts: vec![Artifact {
                id: "m".to_owned(),
                role: "llm".to_owned(),
                loader: "mistralrs".to_owned(),
                source_repo: String::new(),
                source_revision: String::new(),
                filename: filename.to_owned(),
                size_bytes,
                sha256: sha256.to_owned(),
                signature: String::new(),
                license: String::new(),
                hardware_profile: String::new(),
                approved_by: String::new(),
                created_at: String::new(),
            }],
        }
    }

    #[test]
    fn parse_rejects_unsupported_schema() {
        let toml = "schema_version = 99\n";
        assert!(matches!(
            ModelsLock::parse(toml),
            Err(LockError::UnsupportedSchema(99))
        ));
    }

    #[test]
    fn verify_succeeds_on_matching_size_and_hash() -> Result<(), LockError> {
        let dir = unique_dir("ok");
        let body = b"weights-bytes";
        write(&dir, "model.bin", body);
        let lock = lock_with("model.bin", body.len() as u64, &sha256_hex(body));
        lock.verify_all(&dir)?;
        assert_eq!(lock.verified_path("m", &dir)?, dir.join("model.bin"));
        std::fs::remove_dir_all(&dir).ok();
        Ok(())
    }

    #[test]
    fn verify_fails_closed_on_missing_size_and_hash() {
        let dir = unique_dir("fail");
        let body = b"weights-bytes";
        let good = sha256_hex(body);

        // Missing file.
        let lock = lock_with("absent.bin", 0, &good);
        assert!(matches!(
            lock.verify_all(&dir),
            Err(LockError::Missing { .. })
        ));

        write(&dir, "model.bin", body);
        // Size mismatch.
        let lock = lock_with("model.bin", 999, &good);
        assert!(matches!(lock.verify_all(&dir), Err(LockError::Size { .. })));
        // Hash mismatch.
        let lock = lock_with("model.bin", body.len() as u64, &sha256_hex(b"other"));
        assert!(matches!(
            lock.verify_all(&dir),
            Err(LockError::Checksum { .. })
        ));
        // Placeholder (non-hex) hash — never "verifies".
        let lock = lock_with("model.bin", body.len() as u64, "<64-hex-sha256>");
        assert!(matches!(
            lock.verify_all(&dir),
            Err(LockError::Checksum { .. })
        ));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn example_template_is_failclosed_until_real_hashes() {
        // The shipped template uses placeholder hashes — it must never verify.
        let dir = unique_dir("tmpl");
        write(&dir, "model.safetensors", b"x");
        let lock = lock_with("model.safetensors", 0, "<64-hex-sha256>");
        assert!(matches!(
            lock.verify_all(&dir),
            Err(LockError::Checksum { .. })
        ));
        std::fs::remove_dir_all(&dir).ok();
    }
}
