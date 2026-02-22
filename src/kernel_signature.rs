//! Optional kernel-signature verification for higher-assurance deployments.
//!
//! Signature checks are policy-controlled:
//! - `off`: disabled.
//! - `warn`: report mismatches, continue startup.
//! - `enforce`: fail startup on missing/mismatched signatures.

use crate::config::{KernelSignatureMode, RuntimeConfig};
use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const KERNEL_SIGNATURES_SCHEMA_VERSION: u32 = 1;

/// One expected kernel signature entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KernelSignatureEntry {
    /// Human-readable entry ID.
    pub name: String,
    /// File path (absolute or relative to the manifest directory).
    pub path: String,
    /// Expected sha256 hex digest.
    pub sha256: String,
    /// Whether this entry is mandatory for a successful check.
    #[serde(default = "default_required")]
    pub required: bool,
}

fn default_required() -> bool {
    true
}

/// Kernel signature manifest file schema.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct KernelSignatureManifest {
    /// Schema version.
    pub version: u32,
    /// Signature entries to verify.
    pub entries: Vec<KernelSignatureEntry>,
}

impl Default for KernelSignatureManifest {
    fn default() -> Self {
        Self {
            version: KERNEL_SIGNATURES_SCHEMA_VERSION,
            entries: Vec::new(),
        }
    }
}

/// High-level signature check status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KernelSignatureStatus {
    Disabled,
    ManifestMissing,
    Ok,
    Failed,
}

/// Signature check report for runtime observability.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KernelSignatureReport {
    pub mode: KernelSignatureMode,
    pub manifest_path: String,
    pub status: KernelSignatureStatus,
    pub checked: usize,
    pub ok: usize,
    pub missing: usize,
    pub mismatched: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl KernelSignatureReport {
    fn new(mode: KernelSignatureMode, manifest_path: &Path) -> Self {
        Self {
            mode,
            manifest_path: manifest_path.display().to_string(),
            status: KernelSignatureStatus::Disabled,
            checked: 0,
            ok: 0,
            missing: 0,
            mismatched: 0,
            error: None,
        }
    }
}

/// Returns the default kernel-signature manifest path.
#[must_use]
pub fn default_kernel_signatures_file() -> PathBuf {
    crate::fae_dirs::kernel_signatures_file()
}

/// Run signature checks according to runtime policy.
///
/// In `warn` mode, failures are reported in the returned report.
/// In `enforce` mode, failures return an error.
pub fn run_kernel_signature_check(runtime: &RuntimeConfig) -> Result<KernelSignatureReport> {
    let manifest_path = runtime
        .kernel_signature_manifest
        .clone()
        .unwrap_or_else(default_kernel_signatures_file);
    let mut report = KernelSignatureReport::new(runtime.kernel_signature_mode, &manifest_path);

    if runtime.kernel_signature_mode == KernelSignatureMode::Off {
        report.status = KernelSignatureStatus::Disabled;
        return Ok(report);
    }

    let manifest = match load_manifest(&manifest_path) {
        Ok(Some(manifest)) => manifest,
        Ok(None) => {
            report.status = KernelSignatureStatus::ManifestMissing;
            report.error = Some(format!("manifest not found at {}", manifest_path.display()));
            return enforce_or_return(runtime.kernel_signature_mode, report);
        }
        Err(e) => {
            report.status = KernelSignatureStatus::Failed;
            report.error = Some(e.to_string());
            return enforce_or_return(runtime.kernel_signature_mode, report);
        }
    };

    let manifest_dir = manifest_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    for entry in &manifest.entries {
        report.checked = report.checked.saturating_add(1);
        let resolved_path = resolve_manifest_entry_path(&manifest_dir, &entry.path);
        if !resolved_path.is_file() {
            if entry.required {
                report.missing = report.missing.saturating_add(1);
            }
            continue;
        }

        let actual = sha256_file_hex(&resolved_path)?;
        if actual.eq_ignore_ascii_case(entry.sha256.trim()) {
            report.ok = report.ok.saturating_add(1);
        } else if entry.required {
            report.mismatched = report.mismatched.saturating_add(1);
        }
    }

    report.status = if report.missing == 0 && report.mismatched == 0 {
        KernelSignatureStatus::Ok
    } else {
        KernelSignatureStatus::Failed
    };

    enforce_or_return(runtime.kernel_signature_mode, report)
}

fn enforce_or_return(
    mode: KernelSignatureMode,
    report: KernelSignatureReport,
) -> Result<KernelSignatureReport> {
    if mode == KernelSignatureMode::Enforce
        && matches!(
            report.status,
            KernelSignatureStatus::ManifestMissing | KernelSignatureStatus::Failed
        )
    {
        return Err(SpeechError::Config(format!(
            "kernel signature check failed: status={:?}, checked={}, ok={}, missing={}, mismatched={}",
            report.status, report.checked, report.ok, report.missing, report.mismatched
        )));
    }
    Ok(report)
}

fn load_manifest(path: &Path) -> Result<Option<KernelSignatureManifest>> {
    if !path.exists() {
        return Ok(None);
    }
    let raw = std::fs::read_to_string(path).map_err(|e| {
        SpeechError::Config(format!(
            "failed reading kernel signatures manifest {}: {e}",
            path.display()
        ))
    })?;
    let manifest = toml::from_str::<KernelSignatureManifest>(&raw).map_err(|e| {
        SpeechError::Config(format!(
            "failed parsing kernel signatures manifest {}: {e}",
            path.display()
        ))
    })?;
    Ok(Some(manifest))
}

fn resolve_manifest_entry_path(manifest_dir: &Path, entry_path: &str) -> PathBuf {
    let path = PathBuf::from(entry_path);
    if path.is_absolute() {
        path
    } else {
        manifest_dir.join(path)
    }
}

fn sha256_file_hex(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path).map_err(|e| {
        SpeechError::Config(format!(
            "failed reading signature target {}: {e}",
            path.display()
        ))
    })?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    Ok(format!("{:x}", hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn write_file(path: &Path, contents: &str) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("create parent");
        }
        std::fs::write(path, contents).expect("write file");
    }

    fn sha256_for(contents: &str) -> String {
        let mut hasher = Sha256::new();
        hasher.update(contents.as_bytes());
        format!("{:x}", hasher.finalize())
    }

    fn runtime_with(mode: KernelSignatureMode, manifest: &Path) -> RuntimeConfig {
        RuntimeConfig {
            kernel_signature_mode: mode,
            kernel_signature_manifest: Some(manifest.to_path_buf()),
            ..RuntimeConfig::default()
        }
    }

    #[test]
    fn off_mode_returns_disabled() {
        let temp = TempDir::new().expect("tempdir");
        let runtime = runtime_with(KernelSignatureMode::Off, &temp.path().join("missing.toml"));
        let report = run_kernel_signature_check(&runtime).expect("off should pass");
        assert_eq!(report.status, KernelSignatureStatus::Disabled);
    }

    #[test]
    fn warn_mode_missing_manifest_is_non_fatal() {
        let temp = TempDir::new().expect("tempdir");
        let runtime = runtime_with(KernelSignatureMode::Warn, &temp.path().join("missing.toml"));
        let report = run_kernel_signature_check(&runtime).expect("warn should pass");
        assert_eq!(report.status, KernelSignatureStatus::ManifestMissing);
    }

    #[test]
    fn enforce_mode_missing_manifest_errors() {
        let temp = TempDir::new().expect("tempdir");
        let runtime = runtime_with(
            KernelSignatureMode::Enforce,
            &temp.path().join("missing.toml"),
        );
        let err = run_kernel_signature_check(&runtime).expect_err("enforce should fail");
        let msg = err.to_string();
        assert!(msg.contains("kernel signature check failed"));
    }

    #[test]
    fn enforce_mode_passes_when_hashes_match() {
        let temp = TempDir::new().expect("tempdir");
        let binary = temp.path().join("bin").join("fae");
        write_file(&binary, "kernel-bytes");
        let expected_hash = sha256_for("kernel-bytes");

        let manifest_path = temp.path().join("kernel-signatures.toml");
        write_file(
            &manifest_path,
            &format!(
                "version = 1\n[[entries]]\nname = \"fae\"\npath = \"bin/fae\"\nsha256 = \"{}\"\nrequired = true\n",
                expected_hash
            ),
        );

        let runtime = runtime_with(KernelSignatureMode::Enforce, &manifest_path);
        let report = run_kernel_signature_check(&runtime).expect("matching signatures should pass");
        assert_eq!(report.status, KernelSignatureStatus::Ok);
        assert_eq!(report.ok, 1);
        assert_eq!(report.missing, 0);
        assert_eq!(report.mismatched, 0);
    }

    #[test]
    fn warn_mode_reports_mismatch_without_failing() {
        let temp = TempDir::new().expect("tempdir");
        let binary = temp.path().join("bin").join("fae");
        write_file(&binary, "kernel-bytes");

        let manifest_path = temp.path().join("kernel-signatures.toml");
        write_file(
            &manifest_path,
            "version = 1\n[[entries]]\nname = \"fae\"\npath = \"bin/fae\"\nsha256 = \"deadbeef\"\nrequired = true\n",
        );

        let runtime = runtime_with(KernelSignatureMode::Warn, &manifest_path);
        let report = run_kernel_signature_check(&runtime).expect("warn should not fail");
        assert_eq!(report.status, KernelSignatureStatus::Failed);
        assert_eq!(report.mismatched, 1);
    }

    #[test]
    fn enforce_mode_fails_on_mismatch() {
        let temp = TempDir::new().expect("tempdir");
        let binary = temp.path().join("bin").join("fae");
        write_file(&binary, "kernel-bytes");

        let manifest_path = temp.path().join("kernel-signatures.toml");
        write_file(
            &manifest_path,
            "version = 1\n[[entries]]\nname = \"fae\"\npath = \"bin/fae\"\nsha256 = \"deadbeef\"\nrequired = true\n",
        );

        let runtime = runtime_with(KernelSignatureMode::Enforce, &manifest_path);
        let err =
            run_kernel_signature_check(&runtime).expect_err("enforce should fail on mismatch");
        assert!(err.to_string().contains("kernel signature check failed"));
    }
}
