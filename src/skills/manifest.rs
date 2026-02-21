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
//!
//! [[credentials]]
//! name = "bot_token"
//! env_var = "DISCORD_BOT_TOKEN"
//! description = "Your Discord bot token (starts with 'Bot ...')"
//! required = true
//!
//! [[credentials]]
//! name = "guild_id"
//! env_var = "DISCORD_GUILD_ID"
//! description = "Your Discord server (guild) ID"
//! required = false
//! default = "0"
//! ```

use super::error::PythonSkillError;
use serde::Deserialize;
use std::path::Path;

/// A single credential required by a Python skill.
///
/// Skills declare their credential requirements in `manifest.toml` under
/// the `[[credentials]]` array. The credential mediation layer uses this
/// schema to collect values from the user (via Keychain) and inject them
/// as environment variables into the skill subprocess.
///
/// # Example
///
/// ```toml
/// [[credentials]]
/// name = "bot_token"
/// env_var = "DISCORD_BOT_TOKEN"
/// description = "Your Discord bot token"
/// required = true
/// ```
#[derive(Debug, Clone, Deserialize)]
pub struct CredentialSchema {
    /// Unique identifier for this credential within the skill.
    ///
    /// Must consist of lowercase ASCII letters, digits, and underscores only.
    /// May not be empty.
    pub name: String,

    /// Name of the environment variable injected into the skill subprocess.
    ///
    /// Must consist of uppercase ASCII letters, digits, and underscores only.
    /// May not be empty.
    pub env_var: String,

    /// Plain-English description of what this credential is.
    ///
    /// Shown to the user when prompting for the credential value.
    pub description: String,

    /// Whether this credential is required for the skill to function.
    ///
    /// If `true` and no value is available, credential collection fails.
    /// Defaults to `true`.
    #[serde(default = "default_required")]
    pub required: bool,

    /// Optional default value used when the credential is not required and
    /// not yet collected.
    ///
    /// Defaults to `None`.
    #[serde(default)]
    pub default: Option<String>,
}

fn default_required() -> bool {
    true
}

impl CredentialSchema {
    /// Validates that the schema fields are well-formed.
    ///
    /// # Errors
    ///
    /// - [`PythonSkillError::BootstrapFailed`] if `name` or `env_var` is empty.
    /// - [`PythonSkillError::BootstrapFailed`] if `name` or `env_var` contains
    ///   invalid characters.
    pub fn validate(&self) -> Result<(), PythonSkillError> {
        if self.name.trim().is_empty() {
            return Err(PythonSkillError::BootstrapFailed {
                reason: "credential `name` cannot be empty".to_owned(),
            });
        }
        if !self
            .name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        {
            return Err(PythonSkillError::BootstrapFailed {
                reason: format!(
                    "credential `name` `{}` is invalid (use lowercase letters, digits, or _)",
                    self.name
                ),
            });
        }
        if self.env_var.trim().is_empty() {
            return Err(PythonSkillError::BootstrapFailed {
                reason: "credential `env_var` cannot be empty".to_owned(),
            });
        }
        if !self
            .env_var
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
        {
            return Err(PythonSkillError::BootstrapFailed {
                reason: format!(
                    "credential `env_var` `{}` is invalid (use UPPERCASE letters, digits, or _)",
                    self.env_var
                ),
            });
        }
        Ok(())
    }
}

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

    /// Credentials required by this skill.
    ///
    /// Each entry declares an API key, token, or password that the skill
    /// needs. The credential mediation layer collects these from the user
    /// and injects them as environment variables before spawning the process.
    ///
    /// Defaults to an empty list (no credentials required).
    #[serde(default)]
    pub credentials: Vec<CredentialSchema>,
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

        let manifest: Self =
            toml::from_str(&raw).map_err(|e| PythonSkillError::BootstrapFailed {
                reason: format!("invalid manifest.toml: {e}"),
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

        if !self
            .id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
        {
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

        for cred in &self.credentials {
            cred.validate()?;
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
        assert_eq!(
            manifest.description.as_deref(),
            Some("Connects to Discord.")
        );
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
        assert!(
            msg.contains("cannot read"),
            "expected read error, got: {msg}"
        );
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
            credentials: Vec::new(),
        };

        let result = manifest.validate();
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("invalid"),
            "expected invalid error, got: {msg}"
        );
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
            credentials: Vec::new(),
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
            credentials: Vec::new(),
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

    // ── CredentialSchema tests ──

    #[test]
    fn parse_manifest_with_credentials() {
        let dir = std::env::temp_dir().join("fae-manifest-test-creds");
        write_manifest(
            &dir,
            r#"
id = "discord-bot"
name = "Discord Bot"
version = "1.0.0"

[[credentials]]
name = "bot_token"
env_var = "DISCORD_BOT_TOKEN"
description = "Your Discord bot token"
required = true

[[credentials]]
name = "guild_id"
env_var = "DISCORD_GUILD_ID"
description = "Your Discord server ID"
required = false
default = "0"
"#,
        );

        let manifest = PythonSkillManifest::load_from_dir(&dir).expect("load");
        assert_eq!(manifest.credentials.len(), 2);

        let tok = &manifest.credentials[0];
        assert_eq!(tok.name, "bot_token");
        assert_eq!(tok.env_var, "DISCORD_BOT_TOKEN");
        assert_eq!(tok.description, "Your Discord bot token");
        assert!(tok.required);
        assert!(tok.default.is_none());

        let guild = &manifest.credentials[1];
        assert_eq!(guild.name, "guild_id");
        assert_eq!(guild.env_var, "DISCORD_GUILD_ID");
        assert!(!guild.required);
        assert_eq!(guild.default.as_deref(), Some("0"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn manifest_without_credentials_defaults_to_empty() {
        let dir = std::env::temp_dir().join("fae-manifest-test-no-creds");
        write_manifest(
            &dir,
            r#"
id = "simple-skill"
name = "Simple Skill"
"#,
        );

        let manifest = PythonSkillManifest::load_from_dir(&dir).expect("load");
        assert!(manifest.credentials.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn credential_schema_invalid_name_rejected() {
        let schema = CredentialSchema {
            name: "Bad Name!".to_owned(),
            env_var: "VALID_VAR".to_owned(),
            description: "desc".to_owned(),
            required: true,
            default: None,
        };
        let result = schema.validate();
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("name"), "expected name error, got: {msg}");
    }

    #[test]
    fn credential_schema_invalid_env_var_rejected() {
        let schema = CredentialSchema {
            name: "valid_name".to_owned(),
            env_var: "lowercase_bad".to_owned(),
            description: "desc".to_owned(),
            required: true,
            default: None,
        };
        let result = schema.validate();
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("env_var"),
            "expected env_var error, got: {msg}"
        );
    }

    #[test]
    fn credential_schema_empty_name_rejected() {
        let schema = CredentialSchema {
            name: String::new(),
            env_var: "VALID_VAR".to_owned(),
            description: "desc".to_owned(),
            required: true,
            default: None,
        };
        let result = schema.validate();
        assert!(result.is_err());
    }

    #[test]
    fn credential_schema_empty_env_var_rejected() {
        let schema = CredentialSchema {
            name: "valid_name".to_owned(),
            env_var: String::new(),
            description: "desc".to_owned(),
            required: true,
            default: None,
        };
        let result = schema.validate();
        assert!(result.is_err());
    }

    #[test]
    fn credential_schema_valid_chars_accepted() {
        let schema = CredentialSchema {
            name: "bot_token_123".to_owned(),
            env_var: "MY_BOT_TOKEN_123".to_owned(),
            description: "A valid credential".to_owned(),
            required: false,
            default: Some("default_value".to_owned()),
        };
        assert!(schema.validate().is_ok());
    }

    #[test]
    fn manifest_with_invalid_credential_name_fails_validation() {
        let dir = std::env::temp_dir().join("fae-manifest-test-invalid-cred-name");
        write_manifest(
            &dir,
            r#"
id = "test-skill"
name = "Test Skill"

[[credentials]]
name = "Bad Name!"
env_var = "VALID_VAR"
description = "desc"
"#,
        );

        let result = PythonSkillManifest::load_from_dir(&dir);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("name"),
            "expected credential name error, got: {msg}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn credential_required_defaults_to_true() {
        let schema = CredentialSchema {
            name: "token".to_owned(),
            env_var: "TOKEN".to_owned(),
            description: "desc".to_owned(),
            required: true, // default_required() → true
            default: None,
        };
        assert!(schema.required);
    }
}
