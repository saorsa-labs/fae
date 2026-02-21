//! Python skill package manifest (`manifest.toml`).
//!
//! Each Python skill package directory must contain a `manifest.toml` file
//! that describes the skill. This file is used during installation to register
//! the skill in the lifecycle registry.
//!
//! # Example `manifest.toml`
//!
//! ```toml
//! id = "discord-bot"
//! name = "Discord Bot"
//! version = "1.0.0"
//! description = "Sends and receives messages from a Discord server."
//! entry_file = "skill.py"
//! min_uv_version = "0.4.0"
//! min_python = "3.11"
//! ```

use super::error::PythonSkillError;
use serde::Deserialize;
use std::path::Path;

/// Parsed contents of a Python skill's `manifest.toml`.
#[derive(Debug, Clone, Deserialize)]
pub struct PythonSkillManifest {
    /// Unique skill identifier.
    ///
    /// Must consist of lowercase ASCII letters, digits, hyphens, and underscores.
    /// May not be empty.
    pub id: String,

    /// Human-readable skill name. May not be empty.
    pub name: String,

    /// Semantic version string (e.g. `"1.0.0"`).
    #[serde(default = "default_version")]
    pub version: String,

    /// Optional plain-English description of what the skill does.
    #[serde(default)]
    pub description: Option<String>,

    /// Filename of the Python entry point within the package directory.
    ///
    /// Defaults to `"skill.py"`.
    #[serde(default = "default_entry_file")]
    pub entry_file: String,

    /// Minimum `uv` version required (e.g. `"0.4.0"`). Optional.
    #[serde(default)]
    pub min_uv_version: Option<String>,

    /// Minimum Python version required (e.g. `"3.11"`). Optional.
    #[serde(default)]
    pub min_python: Option<String>,
}

fn default_version() -> String {
    "0.1.0".to_owned()
}

fn default_entry_file() -> String {
    "skill.py".to_owned()
}

impl PythonSkillManifest {
    /// Loads and parses `manifest.toml` from `dir`.
    ///
    /// # Errors
    ///
    /// - [`PythonSkillError::BootstrapFailed`] if the file cannot be read or parsed.
    /// - [`PythonSkillError::BootstrapFailed`] if validation fails.
    pub fn load_from_dir(dir: &Path) -> Result<Self, PythonSkillError> {
        let manifest_path = dir.join("manifest.toml");
        let raw = std::fs::read_to_string(&manifest_path).map_err(|e| {
            PythonSkillError::BootstrapFailed {
                reason: format!("cannot read {}: {e}", manifest_path.display()),
            }
        })?;

        let manifest: Self = toml::from_str(&raw).map_err(|e| {
            PythonSkillError::BootstrapFailed {
                reason: format!("invalid manifest.toml: {e}"),
            }
        })?;

        manifest.validate()?;
        Ok(manifest)
    }

    /// Validates that the manifest fields are well-formed.
    ///
    /// # Errors
    ///
    /// - [`PythonSkillError::BootstrapFailed`] if `id` or `name` is empty.
    /// - [`PythonSkillError::BootstrapFailed`] if `id` contains invalid characters.
    pub fn validate(&self) -> Result<(), PythonSkillError> {
        if self.id.trim().is_empty() {
            return Err(PythonSkillError::BootstrapFailed {
                reason: "manifest.toml: `id` cannot be empty".to_owned(),
            });
        }

        if !self.id.chars().all(|c| {
            c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_'
        }) {
            return Err(PythonSkillError::BootstrapFailed {
                reason: format!(
                    "manifest.toml: `id` `{}` is invalid (use lowercase letters, digits, - or _)",
                    self.id
                ),
            });
        }

        if self.name.trim().is_empty() {
            return Err(PythonSkillError::BootstrapFailed {
                reason: "manifest.toml: `name` cannot be empty".to_owned(),
            });
        }

        Ok(())
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use std::io::Write;

    fn write_manifest(dir: &std::path::Path, content: &str) {
        let path = dir.join("manifest.toml");
        std::fs::create_dir_all(dir).expect("create dir");
        let mut f = std::fs::File::create(&path).expect("create file");
        f.write_all(content.as_bytes()).expect("write");
    }

    #[test]
    fn parse_full_manifest() {
        let dir = std::env::temp_dir().join("fae-manifest-test-full");
        write_manifest(
            &dir,
            r#"
id = "discord-bot"
name = "Discord Bot"
version = "2.1.0"
description = "Connects to Discord."
entry_file = "discord.py"
min_uv_version = "0.5.0"
min_python = "3.12"
"#,
        );

        let manifest = PythonSkillManifest::load_from_dir(&dir).expect("load");
        assert_eq!(manifest.id, "discord-bot");
        assert_eq!(manifest.name, "Discord Bot");
        assert_eq!(manifest.version, "2.1.0");
        assert_eq!(manifest.description.as_deref(), Some("Connects to Discord."));
        assert_eq!(manifest.entry_file, "discord.py");
        assert_eq!(manifest.min_uv_version.as_deref(), Some("0.5.0"));
        assert_eq!(manifest.min_python.as_deref(), Some("3.12"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn parse_minimal_manifest_uses_defaults() {
        let dir = std::env::temp_dir().join("fae-manifest-test-minimal");
        write_manifest(
            &dir,
            r#"
id = "my-skill"
name = "My Skill"
"#,
        );

        let manifest = PythonSkillManifest::load_from_dir(&dir).expect("load");
        assert_eq!(manifest.id, "my-skill");
        assert_eq!(manifest.name, "My Skill");
        assert_eq!(manifest.version, "0.1.0");
        assert_eq!(manifest.entry_file, "skill.py");
        assert!(manifest.description.is_none());
        assert!(manifest.min_uv_version.is_none());
        assert!(manifest.min_python.is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_manifest_file_returns_error() {
        let dir = std::env::temp_dir().join("fae-manifest-test-missing");
        let _ = std::fs::remove_dir_all(&dir);

        let result = PythonSkillManifest::load_from_dir(&dir);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("cannot read"), "expected read error, got: {msg}");
    }

    #[test]
    fn empty_id_is_rejected() {
        let dir = std::env::temp_dir().join("fae-manifest-test-empty-id");
        write_manifest(&dir, r#"id = ""\nname = "Test"\n"#);

        let result = PythonSkillManifest::load_from_dir(&dir);
        // Either parse error (empty toml line) or validate error
        assert!(result.is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn invalid_id_chars_rejected() {
        let manifest = PythonSkillManifest {
            id: "My Skill!".to_owned(),
            name: "My Skill".to_owned(),
            version: "1.0.0".to_owned(),
            description: None,
            entry_file: "skill.py".to_owned(),
            min_uv_version: None,
            min_python: None,
        };

        let result = manifest.validate();
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("invalid"), "expected invalid error, got: {msg}");
    }

    #[test]
    fn empty_name_is_rejected() {
        let manifest = PythonSkillManifest {
            id: "valid-id".to_owned(),
            name: "   ".to_owned(),
            version: "1.0.0".to_owned(),
            description: None,
            entry_file: "skill.py".to_owned(),
            min_uv_version: None,
            min_python: None,
        };

        let result = manifest.validate();
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("name"), "expected name error, got: {msg}");
    }

    #[test]
    fn valid_id_chars_accepted() {
        let manifest = PythonSkillManifest {
            id: "my-skill_123".to_owned(),
            name: "Test".to_owned(),
            version: "1.0.0".to_owned(),
            description: None,
            entry_file: "skill.py".to_owned(),
            min_uv_version: None,
            min_python: None,
        };

        assert!(manifest.validate().is_ok());
    }

    #[test]
    fn malformed_toml_returns_parse_error() {
        let dir = std::env::temp_dir().join("fae-manifest-test-malformed");
        write_manifest(&dir, "this is not toml ][[[");

        let result = PythonSkillManifest::load_from_dir(&dir);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("invalid manifest.toml"),
            "expected parse error, got: {msg}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}
