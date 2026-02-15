//! External LLM profile loading and runtime overlay.
//!
//! External profiles live under the app data directory (`external_apis/*.toml`) and let Fae
//! configure remote providers without storing all provider details in the main
//! config file.

use crate::config::{LlmApiType, LlmConfig};
use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Runtime metadata after applying an external profile.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedExternalProfile {
    pub profile_id: String,
    pub provider: String,
    pub api_model: String,
    pub api_type: LlmApiType,
}

/// Secret reference used by external LLM profiles.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ExternalApiSecretRef {
    /// No API key.
    #[default]
    None,
    /// Inline literal key (discouraged; use env/command when possible).
    Literal { value: String },
    /// Resolve API key from an environment variable.
    Env { var: String },
    /// Resolve API key by running a local command.
    Command { cmd: String },
}

impl ExternalApiSecretRef {
    fn resolve(&self) -> Result<Option<String>> {
        match self {
            Self::None => Ok(None),
            Self::Literal { value } => Ok(Some(value.clone())),
            Self::Env { var } => {
                let value = std::env::var(var).map_err(|_| {
                    SpeechError::Config(format!(
                        "external profile secret env var is missing: {var}"
                    ))
                })?;
                if value.trim().is_empty() {
                    return Err(SpeechError::Config(format!(
                        "external profile secret env var is empty: {var}"
                    )));
                }
                Ok(Some(value))
            }
            Self::Command { cmd } => {
                if cmd.trim().is_empty() {
                    return Err(SpeechError::Config(
                        "external profile secret command is empty".to_owned(),
                    ));
                }
                let output = std::process::Command::new("/bin/sh")
                    .arg("-lc")
                    .arg(cmd)
                    .output()
                    .map_err(|e| {
                        SpeechError::Config(format!(
                            "failed to run external profile secret command: {e}"
                        ))
                    })?;

                if !output.status.success() {
                    return Err(SpeechError::Config(format!(
                        "external profile secret command failed with status {}",
                        output
                            .status
                            .code()
                            .map_or_else(|| "unknown".to_owned(), |c| c.to_string())
                    )));
                }

                let value = String::from_utf8_lossy(&output.stdout).trim().to_owned();
                if value.is_empty() {
                    return Err(SpeechError::Config(
                        "external profile secret command returned empty output".to_owned(),
                    ));
                }

                Ok(Some(value))
            }
        }
    }
}

/// On-disk profile schema for external remote providers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExternalLlmProfile {
    /// Provider hint (for profile quirks), e.g. `openai`, `anthropic`, `deepseek`.
    pub provider: String,
    /// API protocol type.
    #[serde(default)]
    pub api_type: LlmApiType,
    /// Provider base URL.
    pub api_url: String,
    /// Default model for this profile.
    pub api_model: String,
    /// API key reference.
    #[serde(default)]
    pub api_key: ExternalApiSecretRef,
    /// Optional provider API version.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_version: Option<String>,
    /// Optional organization/project hint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_organization: Option<String>,
    /// Whether this profile can be selected.
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

fn default_enabled() -> bool {
    true
}

impl ExternalLlmProfile {
    fn validate(&self, profile_id: &str) -> Result<()> {
        if self.provider.trim().is_empty() {
            return Err(SpeechError::Config(format!(
                "external profile '{profile_id}' has empty provider"
            )));
        }
        if self.api_url.trim().is_empty() {
            return Err(SpeechError::Config(format!(
                "external profile '{profile_id}' has empty api_url"
            )));
        }
        if self.api_model.trim().is_empty() {
            return Err(SpeechError::Config(format!(
                "external profile '{profile_id}' has empty api_model"
            )));
        }
        Ok(())
    }
}

/// Returns the directory where external LLM profiles are stored.
#[must_use]
pub fn external_apis_dir() -> PathBuf {
    crate::fae_dirs::external_apis_dir()
}

/// Returns the expected path for a profile ID.
///
/// The profile ID is sanitized to prevent path traversal.
pub fn profile_path(profile_id: &str) -> Result<PathBuf> {
    let profile_id = normalize_profile_id(profile_id)?;
    Ok(external_apis_dir().join(format!("{profile_id}.toml")))
}

/// Load and validate an external profile by ID.
pub fn load_profile(profile_id: &str) -> Result<ExternalLlmProfile> {
    let path = profile_path(profile_id)?;
    load_profile_from_path(profile_id, &path)
}

/// Apply `llm.external_profile` (if set) to the runtime LLM config.
///
/// This overlays provider URL/model/type/secret fields from the profile.
pub fn apply_external_profile(llm: &mut LlmConfig) -> Result<Option<AppliedExternalProfile>> {
    let Some(profile_id_raw) = llm.external_profile.as_deref() else {
        return Ok(None);
    };

    let profile_id = profile_id_raw.trim();
    if profile_id.is_empty() {
        return Ok(None);
    }

    let profile = load_profile(profile_id)?;
    if !profile.enabled {
        return Err(SpeechError::Config(format!(
            "external profile '{profile_id}' is disabled"
        )));
    }

    let resolved_api_key = profile.api_key.resolve()?.unwrap_or_default();

    llm.api_url = profile.api_url.clone();
    llm.api_model = profile.api_model.clone();
    llm.api_type = profile.api_type;
    llm.api_version = profile.api_version.clone();
    llm.api_organization = profile.api_organization.clone();
    llm.api_key = crate::credentials::CredentialRef::Plaintext(resolved_api_key);
    llm.cloud_provider = Some(profile.provider.clone());
    llm.cloud_model = Some(profile.api_model.clone());

    Ok(Some(AppliedExternalProfile {
        profile_id: profile_id.to_owned(),
        provider: profile.provider,
        api_model: profile.api_model,
        api_type: profile.api_type,
    }))
}

fn load_profile_from_path(profile_id: &str, path: &Path) -> Result<ExternalLlmProfile> {
    let raw = std::fs::read_to_string(path).map_err(|e| {
        SpeechError::Config(format!(
            "failed to read external profile '{}' ({}): {e}",
            profile_id,
            path.display()
        ))
    })?;

    let profile: ExternalLlmProfile = toml::from_str(&raw).map_err(|e| {
        SpeechError::Config(format!(
            "invalid external profile '{}' ({}): {e}",
            profile_id,
            path.display()
        ))
    })?;

    profile.validate(profile_id)?;
    Ok(profile)
}

fn normalize_profile_id(profile_id: &str) -> Result<String> {
    let trimmed = profile_id.trim();
    if trimmed.is_empty() {
        return Err(SpeechError::Config(
            "external profile id is empty".to_owned(),
        ));
    }

    let valid = trimmed
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.');
    if !valid {
        return Err(SpeechError::Config(
            "external profile id contains invalid characters".to_owned(),
        ));
    }

    Ok(trimmed.to_owned())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    struct EnvGuard {
        key: &'static str,
        old: Option<std::ffi::OsString>,
    }

    impl EnvGuard {
        fn set(key: &'static str, value: &str) -> Self {
            let old = std::env::var_os(key);
            unsafe { std::env::set_var(key, value) };
            Self { key, old }
        }

        fn unset(key: &'static str) -> Self {
            let old = std::env::var_os(key);
            unsafe { std::env::remove_var(key) };
            Self { key, old }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.old {
                Some(v) => unsafe { std::env::set_var(self.key, v) },
                None => unsafe { std::env::remove_var(self.key) },
            }
        }
    }

    #[test]
    fn profile_id_blocks_traversal() {
        assert!(normalize_profile_id("../../etc/passwd").is_err());
        assert!(normalize_profile_id("bad/name").is_err());
        assert!(normalize_profile_id("ok-profile_1").is_ok());
    }

    #[test]
    fn load_profile_parses_and_validates() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("demo.toml");
        std::fs::write(
            &path,
            r#"
provider = "openai"
api_type = "openai_completions"
api_url = "https://api.openai.com"
api_model = "gpt-4o-mini"

[api_key]
type = "none"
"#,
        )
        .unwrap();

        let profile = load_profile_from_path("demo", &path).unwrap();
        assert_eq!(profile.provider, "openai");
        assert_eq!(profile.api_model, "gpt-4o-mini");
        assert_eq!(profile.api_type, LlmApiType::OpenAiCompletions);
    }

    #[test]
    fn secret_env_resolves() {
        let _env = EnvGuard::set("FAE_TEST_PROFILE_KEY", "secret-123");
        let secret = ExternalApiSecretRef::Env {
            var: "FAE_TEST_PROFILE_KEY".to_owned(),
        };
        let resolved = secret.resolve().unwrap();
        assert_eq!(resolved, Some("secret-123".to_owned()));
    }

    #[test]
    fn secret_env_missing_errors() {
        let _env = EnvGuard::unset("FAE_TEST_PROFILE_KEY_MISSING");
        let secret = ExternalApiSecretRef::Env {
            var: "FAE_TEST_PROFILE_KEY_MISSING".to_owned(),
        };
        assert!(secret.resolve().is_err());
    }

    #[test]
    fn apply_external_profile_overlays_llm_fields() {
        let home = tempfile::tempdir().unwrap();
        let _home = EnvGuard::set("HOME", home.path().to_string_lossy().as_ref());
        let _env = EnvGuard::set("FAE_PROFILE_KEY", "sk-test-xyz");

        let profile_dir = external_apis_dir();
        std::fs::create_dir_all(&profile_dir).unwrap();
        std::fs::write(
            profile_dir.join("work.toml"),
            r#"
provider = "openai"
api_type = "openai_responses"
api_url = "https://example.com"
api_model = "example-model"
api_organization = "org-123"

enabled = true

[api_key]
type = "env"
var = "FAE_PROFILE_KEY"
"#,
        )
        .unwrap();

        let mut llm = crate::config::LlmConfig {
            external_profile: Some("work".to_owned()),
            ..Default::default()
        };
        llm.api_key = crate::credentials::CredentialRef::None;
        llm.cloud_provider = None;

        let applied = apply_external_profile(&mut llm).unwrap().unwrap();
        assert_eq!(applied.profile_id, "work");
        assert_eq!(llm.api_url, "https://example.com");
        assert_eq!(llm.api_model, "example-model");
        assert_eq!(llm.api_type, LlmApiType::OpenAiResponses);
        assert_eq!(
            llm.api_key,
            crate::credentials::CredentialRef::Plaintext("sk-test-xyz".to_owned())
        );
        assert_eq!(llm.api_organization.as_deref(), Some("org-123"));
        assert_eq!(llm.cloud_provider.as_deref(), Some("openai"));
        assert_eq!(llm.cloud_model.as_deref(), Some("example-model"));
    }
}
