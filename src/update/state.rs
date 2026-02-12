//! Update state persistence.
//!
//! Tracks update preferences, last check timestamps, dismissed releases,
//! and cached ETags. Persisted to `~/.config/fae/update-state.json`.

use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// User preference for automatic updates.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AutoUpdatePreference {
    /// Show a dialog each time an update is available (default).
    #[default]
    Ask,
    /// Auto-update without asking.
    Always,
    /// Never auto-update, just log availability.
    Never,
}

impl std::fmt::Display for AutoUpdatePreference {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Ask => write!(f, "ask"),
            Self::Always => write!(f, "always"),
            Self::Never => write!(f, "never"),
        }
    }
}

/// Persistent update state for Fae.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct UpdateState {
    /// Current Fae version (set at startup from `CARGO_PKG_VERSION`).
    pub fae_version: String,
    /// User preference for automatic updates.
    pub auto_update: AutoUpdatePreference,
    /// ISO 8601 timestamp of the last update check.
    pub last_check: Option<String>,
    /// Release version the user chose to skip (dismiss).
    pub dismissed_release: Option<String>,
    /// Cached GitHub ETag for Fae release requests.
    pub etag_fae: Option<String>,
}

impl Default for UpdateState {
    fn default() -> Self {
        Self {
            fae_version: env!("CARGO_PKG_VERSION").to_owned(),
            auto_update: AutoUpdatePreference::default(),
            last_check: None,
            dismissed_release: None,
            etag_fae: None,
        }
    }
}

impl UpdateState {
    /// Returns the path to the state file (`~/.config/fae/update-state.json`).
    pub fn state_file_path() -> Option<PathBuf> {
        #[cfg(target_os = "windows")]
        {
            std::env::var_os("LOCALAPPDATA")
                .map(|d| PathBuf::from(d).join("fae").join("update-state.json"))
        }
        #[cfg(not(target_os = "windows"))]
        {
            std::env::var_os("HOME").map(|h| {
                PathBuf::from(h)
                    .join(".config")
                    .join("fae")
                    .join("update-state.json")
            })
        }
    }

    /// Load state from disk. Returns the default state if the file is missing
    /// or cannot be parsed.
    pub fn load() -> Self {
        let path = match Self::state_file_path() {
            Some(p) => p,
            None => return Self::default(),
        };

        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(_) => return Self::default(),
        };

        serde_json::from_slice(&bytes).unwrap_or_default()
    }

    /// Persist the current state to disk.
    ///
    /// # Errors
    ///
    /// Returns an error if the state file directory cannot be created or the
    /// file cannot be written.
    pub fn save(&self) -> Result<()> {
        let path = Self::state_file_path().ok_or_else(|| {
            SpeechError::Update("cannot determine update state file path".to_owned())
        })?;

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| {
                SpeechError::Update(format!(
                    "cannot create state directory {}: {e}",
                    parent.display()
                ))
            })?;
        }

        let json = serde_json::to_string_pretty(self)
            .map_err(|e| SpeechError::Update(format!("cannot serialize update state: {e}")))?;

        std::fs::write(&path, json).map_err(|e| {
            SpeechError::Update(format!(
                "cannot write update state to {}: {e}",
                path.display()
            ))
        })?;

        Ok(())
    }

    /// Record that an update check was performed at the current time.
    pub fn mark_checked(&mut self) {
        // Simple ISO 8601 without pulling in a chrono dependency.
        // We use the system time formatted via std.
        let now = std::time::SystemTime::now();
        let since_epoch = now
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        self.last_check = Some(format!("{}", since_epoch.as_secs()));
    }

    /// Returns `true` if the last check was more than `hours` hours ago
    /// (or if no check has been recorded yet).
    pub fn check_is_stale(&self, hours: u64) -> bool {
        let timestamp = match &self.last_check {
            Some(ts) => ts,
            None => return true,
        };

        let last_secs: u64 = match timestamp.parse() {
            Ok(s) => s,
            Err(_) => return true,
        };

        let now_secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let elapsed_hours = (now_secs.saturating_sub(last_secs)) / 3600;
        elapsed_hours >= hours
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn default_state_has_current_version() {
        let state = UpdateState::default();
        assert_eq!(state.fae_version, env!("CARGO_PKG_VERSION"));
        assert_eq!(state.auto_update, AutoUpdatePreference::Ask);
        assert!(state.last_check.is_none());
        assert!(state.dismissed_release.is_none());
        assert!(state.etag_fae.is_none());
    }

    #[test]
    fn auto_update_preference_default_is_ask() {
        assert_eq!(AutoUpdatePreference::default(), AutoUpdatePreference::Ask);
    }

    #[test]
    fn auto_update_preference_display() {
        assert_eq!(AutoUpdatePreference::Ask.to_string(), "ask");
        assert_eq!(AutoUpdatePreference::Always.to_string(), "always");
        assert_eq!(AutoUpdatePreference::Never.to_string(), "never");
    }

    #[test]
    fn state_serialization_round_trip() {
        let state = UpdateState {
            fae_version: "0.1.0".to_owned(),
            auto_update: AutoUpdatePreference::Always,
            last_check: Some("1706000000".to_owned()),
            dismissed_release: Some("0.2.0".to_owned()),
            etag_fae: Some("abc123".to_owned()),
        };

        let json = serde_json::to_string(&state).unwrap();
        let restored: UpdateState = serde_json::from_str(&json).unwrap();

        assert_eq!(restored.fae_version, "0.1.0");
        assert_eq!(restored.auto_update, AutoUpdatePreference::Always);
        assert_eq!(restored.last_check.as_deref(), Some("1706000000"));
        assert_eq!(restored.dismissed_release.as_deref(), Some("0.2.0"));
        assert_eq!(restored.etag_fae.as_deref(), Some("abc123"));
    }

    #[test]
    fn state_deserialize_from_empty_json() {
        // Missing fields should use defaults (via serde defaults).
        let json = r#"{"fae_version":"0.1.0"}"#;
        let state: UpdateState = serde_json::from_str(json).unwrap();
        assert_eq!(state.fae_version, "0.1.0");
    }

    #[test]
    fn state_file_path_is_some() {
        // Should succeed when HOME / LOCALAPPDATA is set.
        let path = UpdateState::state_file_path();
        assert!(path.is_some());
        let path_str = path.unwrap().to_string_lossy().to_string();
        assert!(path_str.contains("update-state.json"));
    }

    #[test]
    fn load_returns_default_when_no_file() {
        // If the file doesn't exist, we get defaults.
        let state = UpdateState::load();
        assert_eq!(state.fae_version, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn mark_checked_sets_timestamp() {
        let mut state = UpdateState::default();
        assert!(state.last_check.is_none());
        state.mark_checked();
        assert!(state.last_check.is_some());
        let ts: u64 = state.last_check.unwrap().parse().unwrap();
        assert!(ts > 0);
    }

    #[test]
    fn check_is_stale_when_no_check() {
        let state = UpdateState::default();
        assert!(state.check_is_stale(24));
    }

    #[test]
    fn check_is_stale_when_recent() {
        let mut state = UpdateState::default();
        state.mark_checked();
        assert!(!state.check_is_stale(24));
    }

    #[test]
    fn check_is_stale_when_old() {
        let mut state = UpdateState::default();
        // Set timestamp to 48 hours ago.
        let old = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (48 * 3600);
        state.last_check = Some(old.to_string());
        assert!(state.check_is_stale(24));
    }

    #[test]
    fn auto_update_preference_serde_values() {
        let ask: AutoUpdatePreference = serde_json::from_str(r#""ask""#).unwrap();
        assert_eq!(ask, AutoUpdatePreference::Ask);

        let always: AutoUpdatePreference = serde_json::from_str(r#""always""#).unwrap();
        assert_eq!(always, AutoUpdatePreference::Always);

        let never: AutoUpdatePreference = serde_json::from_str(r#""never""#).unwrap();
        assert_eq!(never, AutoUpdatePreference::Never);
    }

    #[test]
    fn check_is_stale_with_invalid_timestamp() {
        let state = UpdateState {
            last_check: Some("not-a-number".to_owned()),
            ..Default::default()
        };
        assert!(state.check_is_stale(24));
    }

    #[test]
    fn check_is_stale_with_zero_hours() {
        let mut state = UpdateState::default();
        state.mark_checked();
        // Even a just-checked state is stale with 0-hour threshold.
        assert!(state.check_is_stale(0));
    }

    #[test]
    fn state_pretty_json_format() {
        let state = UpdateState::default();
        let json = serde_json::to_string_pretty(&state).unwrap();
        // Should contain readable field names.
        assert!(json.contains("fae_version"));
        assert!(json.contains("auto_update"));
        assert!(json.contains("ask"));
    }

    #[test]
    fn state_preserves_etags() {
        let state = UpdateState {
            etag_fae: Some("W/\"abc123\"".to_owned()),
            ..Default::default()
        };

        let json = serde_json::to_string(&state).unwrap();
        let restored: UpdateState = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.etag_fae.as_deref(), Some("W/\"abc123\""));
    }

    #[test]
    fn state_dismissed_release_round_trip() {
        let state = UpdateState {
            dismissed_release: Some("0.5.0".to_owned()),
            ..Default::default()
        };
        let json = serde_json::to_string(&state).unwrap();
        let restored: UpdateState = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.dismissed_release.as_deref(), Some("0.5.0"));
    }
}
