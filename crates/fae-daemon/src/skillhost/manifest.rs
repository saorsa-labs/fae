//! `MANIFEST.json` parsing + validation (ADR-013 Vision A, A2.5).
//!
//! Ports the Swift `SkillCapabilityManifest` + `validateManifest`
//! (`native/macos/Fae/Sources/Fae/Skills/SkillManifest.swift`). Executable
//! skills (those with a `scripts/` directory) MUST ship a `MANIFEST.json` with
//! `schemaVersion: 1`, `capabilities` containing `"execute"`, `allowedTools`
//! containing `"run_skill"`, a `timeoutSeconds` in `5..=600`, and an
//! `integrity` block with SHA-256 `checksums`. A missing/invalid manifest
//! quarantines the skill (fail-closed) — see [`crate::skillhost`].
//!
//! Unknown manifest fields (`allowedDomains`, `dataClasses`, `riskTier`,
//! `allowNetwork`, `allowSubprocess`, `settings`, …) are tolerated and ignored:
//! the daemon validates only the fields that gate execution.

use std::collections::BTreeMap;

use serde::Deserialize;

/// The one schema version this loader accepts (Swift `currentSchemaVersion`).
pub const CURRENT_SCHEMA_VERSION: u32 = 1;

/// The declarative capability + integrity manifest for a skill.
///
/// Only the execution-gating fields are modeled; serde ignores the rest.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillManifest {
    /// Must equal [`CURRENT_SCHEMA_VERSION`].
    pub schema_version: u32,
    /// Declared capabilities (executable skills MUST include `"execute"`).
    #[serde(default)]
    pub capabilities: Vec<String>,
    /// Tools the skill may invoke (executable skills MUST include `"run_skill"`).
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    /// Per-run wall-clock cap (seconds). Swift enforces `5..=600`.
    #[serde(default)]
    pub timeout_seconds: u32,
    /// SHA-256 tamper-detection envelope (required for executable skills).
    #[serde(default)]
    pub integrity: Option<SkillIntegrity>,
}

/// The per-skill integrity envelope (Swift `SkillIntegrityManifest`).
#[derive(Debug, Clone, Deserialize)]
pub struct SkillIntegrity {
    /// The digest algorithm — only `"sha256"` (case-insensitive) is supported.
    pub algorithm: String,
    /// Relative-path → lowercase-hex-digest map (e.g. `"scripts/build.py"`).
    #[serde(default)]
    pub checksums: BTreeMap<String, String>,
    // A manifest `signature` field (detached signing) is tolerated but ignored
    // by the loader — serde skips unmodeled keys.
}

/// A manifest validation failure. The `String` is the quarantine reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestError(pub String);

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl SkillManifest {
    /// Parse a `MANIFEST.json` byte slice. A JSON error is a validation
    /// failure (quarantine), never a panic.
    ///
    /// # Errors
    /// [`ManifestError`] when the bytes are not a well-formed manifest.
    pub fn parse(bytes: &[u8]) -> Result<Self, ManifestError> {
        serde_json::from_slice(bytes).map_err(|e| ManifestError(format!("invalid_manifest: {e}")))
    }

    /// Validate an **executable** skill's manifest (Swift `validateManifest`
    /// with `type == .executable`). Fail-closed: any violation is a quarantine
    /// reason.
    ///
    /// # Errors
    /// [`ManifestError`] on schema/capability/tool/timeout/integrity violations.
    pub fn validate_executable(&self) -> Result<&SkillIntegrity, ManifestError> {
        if self.schema_version != CURRENT_SCHEMA_VERSION {
            return Err(ManifestError(format!(
                "schema_version={}, expected {CURRENT_SCHEMA_VERSION}",
                self.schema_version
            )));
        }
        if !(5..=600).contains(&self.timeout_seconds) {
            return Err(ManifestError(
                "timeout_seconds must be within 5..=600".into(),
            ));
        }
        if self.capabilities.is_empty() {
            return Err(ManifestError("capabilities must not be empty".into()));
        }
        if !self.capabilities.iter().any(|c| c == "execute") {
            return Err(ManifestError(
                "executable skills must declare capability 'execute'".into(),
            ));
        }
        if !self.allowed_tools.iter().any(|t| t == "run_skill") {
            return Err(ManifestError(
                "executable skills must include allowedTools: run_skill".into(),
            ));
        }
        // Executable skills MUST carry an integrity block — without it there are
        // no checksums to verify and every script would be undeclared. Swift's
        // run path (`findExecutableScript`) refuses to run any script when
        // `manifest.integrity` is nil; the daemon fails closed one step earlier.
        self.integrity
            .as_ref()
            .ok_or_else(|| ManifestError("executable skills must carry integrity checksums".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest_json(extra: &str) -> String {
        format!(
            r#"{{"schemaVersion":1,"capabilities":["execute"],"allowedTools":["run_skill"],"timeoutSeconds":120,"integrity":{{"algorithm":"sha256","checksums":{{"SKILL.md":"aa"}},"signature":null}}{extra}}}"#
        )
    }

    #[test]
    fn parses_real_forge_shaped_manifest() {
        let m = SkillManifest::parse(manifest_json("").as_bytes()).expect("parse");
        assert_eq!(m.schema_version, 1);
        assert!(m.capabilities.iter().any(|c| c == "execute"));
        assert!(m.validate_executable().is_ok());
    }

    #[test]
    fn tolerates_unknown_fields() {
        let extra = r#","allowedDomains":[],"dataClasses":["local_files"],"riskTier":"high","allowNetwork":false,"allowSubprocess":true"#;
        let m = SkillManifest::parse(manifest_json(extra).as_bytes()).expect("parse");
        assert!(m.validate_executable().is_ok());
    }

    #[test]
    fn wrong_schema_version_rejected() {
        let j = r#"{"schemaVersion":2,"capabilities":["execute"],"allowedTools":["run_skill"],"timeoutSeconds":120,"integrity":{"algorithm":"sha256","checksums":{},"signature":null}}"#;
        let m = SkillManifest::parse(j.as_bytes()).expect("parse");
        assert!(m.validate_executable().is_err());
    }

    #[test]
    fn missing_execute_capability_rejected() {
        let j = r#"{"schemaVersion":1,"capabilities":["read"],"allowedTools":["run_skill"],"timeoutSeconds":120,"integrity":{"algorithm":"sha256","checksums":{},"signature":null}}"#;
        let m = SkillManifest::parse(j.as_bytes()).expect("parse");
        assert!(m.validate_executable().is_err());
    }

    #[test]
    fn missing_run_skill_tool_rejected() {
        let j = r#"{"schemaVersion":1,"capabilities":["execute"],"allowedTools":[],"timeoutSeconds":120,"integrity":{"algorithm":"sha256","checksums":{},"signature":null}}"#;
        let m = SkillManifest::parse(j.as_bytes()).expect("parse");
        assert!(m.validate_executable().is_err());
    }

    #[test]
    fn out_of_range_timeout_rejected() {
        for t in [4u32, 601] {
            let j = format!(
                r#"{{"schemaVersion":1,"capabilities":["execute"],"allowedTools":["run_skill"],"timeoutSeconds":{t},"integrity":{{"algorithm":"sha256","checksums":{{}},"signature":null}}}}"#
            );
            let m = SkillManifest::parse(j.as_bytes()).expect("parse");
            assert!(m.validate_executable().is_err(), "timeout {t} must reject");
        }
    }

    #[test]
    fn executable_without_integrity_rejected() {
        let j = r#"{"schemaVersion":1,"capabilities":["execute"],"allowedTools":["run_skill"],"timeoutSeconds":120}"#;
        let m = SkillManifest::parse(j.as_bytes()).expect("parse");
        assert!(m.validate_executable().is_err());
    }

    #[test]
    fn malformed_json_is_error_not_panic() {
        assert!(SkillManifest::parse(b"not json").is_err());
    }
}
