//! Centralized application directory paths for Fae.
//!
//! Provides a single source of truth for all filesystem paths used by the app.
//! Uses the [`dirs`] crate for platform-appropriate directory resolution, which
//! is sandbox-transparent on macOS (returns container-relative paths under App
//! Sandbox automatically).
//!
//! # Directory Layout
//!
//! | Purpose | macOS (sandbox) | Linux |
//! |---------|----------------|-------|
//! | App data | `~/Library/Application Support/fae/` | `~/.local/share/fae/` |
//! | Config | `~/Library/Application Support/fae/` | `~/.config/fae/` |
//! | Cache | `~/Library/Caches/fae/` | `~/.cache/fae/` |
//!
//! # Environment Overrides
//!
//! All paths can be overridden for testing or custom deployments:
//! - `FAE_DATA_DIR` — overrides [`data_dir`]
//! - `FAE_CONFIG_DIR` — overrides [`config_dir`]
//! - `FAE_CACHE_DIR` — overrides [`cache_dir`]

use std::path::PathBuf;

/// Application data root directory.
///
/// Used for persistent user data: memory records, SOUL.md, skills,
/// external API profiles, voice samples, logs, and diagnostics.
///
/// Resolves to `dirs::data_dir()/fae/` by default. Override with
/// the `FAE_DATA_DIR` environment variable.
#[must_use]
pub fn data_dir() -> PathBuf {
    if let Some(override_dir) = std::env::var_os("FAE_DATA_DIR") {
        return PathBuf::from(override_dir);
    }
    dirs::data_dir()
        .map(|d| d.join("fae"))
        .unwrap_or_else(|| PathBuf::from("/tmp/fae-data"))
}

/// Application config directory.
///
/// Used for `config.toml`, `scheduler.json`, and other configuration files.
///
/// Resolves to `dirs::config_dir()/fae/` by default. Override with
/// the `FAE_CONFIG_DIR` environment variable.
#[must_use]
pub fn config_dir() -> PathBuf {
    if let Some(override_dir) = std::env::var_os("FAE_CONFIG_DIR") {
        return PathBuf::from(override_dir);
    }
    dirs::config_dir()
        .map(|d| d.join("fae"))
        .unwrap_or_else(|| PathBuf::from("/tmp/fae-config"))
}

/// Application cache directory.
///
/// Used for downloaded model files and other expendable cached data.
///
/// Resolves to `dirs::cache_dir()/fae/` by default. Override with
/// the `FAE_CACHE_DIR` environment variable.
#[must_use]
pub fn cache_dir() -> PathBuf {
    if let Some(override_dir) = std::env::var_os("FAE_CACHE_DIR") {
        return PathBuf::from(override_dir);
    }
    dirs::cache_dir()
        .map(|d| d.join("fae"))
        .unwrap_or_else(|| PathBuf::from("/tmp/fae-cache"))
}

/// Log file directory (`data_dir()/logs/`).
#[must_use]
pub fn logs_dir() -> PathBuf {
    data_dir().join("logs")
}

/// User skills directory (`data_dir()/skills/`).
///
/// Override with `FAE_SKILLS_DIR` (checked by the skills module directly).
#[must_use]
pub fn skills_dir() -> PathBuf {
    data_dir().join("skills")
}

/// Memory data root directory.
///
/// Memory records, manifest, and indexes are stored here.
/// Currently the same as [`data_dir`].
#[must_use]
pub fn memory_dir() -> PathBuf {
    data_dir()
}

/// Main config file path (`config_dir()/config.toml`).
#[must_use]
pub fn config_file() -> PathBuf {
    config_dir().join("config.toml")
}

/// Scheduler state file path (`config_dir()/scheduler.json`).
#[must_use]
pub fn scheduler_file() -> PathBuf {
    config_dir().join("scheduler.json")
}

/// Diagnostics output directory (`data_dir()/diagnostics/`).
#[must_use]
pub fn diagnostics_dir() -> PathBuf {
    data_dir().join("diagnostics")
}

/// HuggingFace Hub cache directory (`cache_dir()/huggingface/`).
///
/// Set the `HF_HOME` environment variable to this path early in startup
/// so that the `hf-hub` crate stores models in a sandbox-accessible location.
#[must_use]
pub fn hf_cache_dir() -> PathBuf {
    cache_dir().join("huggingface")
}

/// External API profiles directory (`data_dir()/external_apis/`).
#[must_use]
pub fn external_apis_dir() -> PathBuf {
    data_dir().join("external_apis")
}

/// Wakeword recordings directory (`data_dir()/wakeword/`).
#[must_use]
pub fn wakeword_dir() -> PathBuf {
    data_dir().join("wakeword")
}

/// Ensure the `HF_HOME` environment variable points to [`hf_cache_dir`].
///
/// The `hf-hub` crate reads `HF_HOME` to locate its download cache.
/// Call this **once** early in startup (before any model download) so that
/// models are stored in a sandbox-safe location on macOS.
///
/// If `HF_HOME` is already set, this function is a no-op.
pub fn ensure_hf_home() {
    if std::env::var_os("HF_HOME").is_none() {
        let dir = hf_cache_dir();
        // SAFETY: Called once at startup before any threads spawn.
        unsafe { std::env::set_var("HF_HOME", &dir) };
    }
}

/// Returns `true` if the app is running inside a macOS App Sandbox container.
///
/// macOS automatically sets the `APP_SANDBOX_CONTAINER_ID` environment variable
/// when an app runs under App Sandbox.
#[must_use]
pub fn is_sandboxed() -> bool {
    std::env::var_os("APP_SANDBOX_CONTAINER_ID").is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_dir_is_nonempty() {
        let dir = data_dir();
        assert!(!dir.as_os_str().is_empty());
    }

    #[test]
    fn data_dir_contains_fae() {
        let dir = data_dir();
        let s = dir.to_string_lossy();
        assert!(s.contains("fae"), "data_dir should contain 'fae': {s}");
    }

    #[test]
    fn config_dir_is_nonempty() {
        let dir = config_dir();
        assert!(!dir.as_os_str().is_empty());
    }

    #[test]
    fn config_dir_contains_fae() {
        let dir = config_dir();
        let s = dir.to_string_lossy();
        assert!(s.contains("fae"), "config_dir should contain 'fae': {s}");
    }

    #[test]
    fn cache_dir_is_nonempty() {
        let dir = cache_dir();
        assert!(!dir.as_os_str().is_empty());
    }

    #[test]
    fn cache_dir_contains_fae() {
        let dir = cache_dir();
        let s = dir.to_string_lossy();
        assert!(s.contains("fae"), "cache_dir should contain 'fae': {s}");
    }

    #[test]
    fn config_file_ends_with_config_toml() {
        let path = config_file();
        let s = path.to_string_lossy();
        assert!(s.ends_with("config.toml"), "config_file: {s}");
    }

    #[test]
    fn scheduler_file_ends_with_scheduler_json() {
        let path = scheduler_file();
        let s = path.to_string_lossy();
        assert!(s.ends_with("scheduler.json"), "scheduler_file: {s}");
    }

    #[test]
    fn logs_dir_is_subpath_of_data_dir() {
        let logs = logs_dir();
        let data = data_dir();
        assert!(
            logs.starts_with(&data),
            "logs_dir ({}) should start with data_dir ({})",
            logs.display(),
            data.display()
        );
    }

    #[test]
    fn skills_dir_is_subpath_of_data_dir() {
        let skills = skills_dir();
        let data = data_dir();
        assert!(
            skills.starts_with(&data),
            "skills_dir ({}) should start with data_dir ({})",
            skills.display(),
            data.display()
        );
    }

    #[test]
    fn diagnostics_dir_is_subpath_of_data_dir() {
        let diag = diagnostics_dir();
        let data = data_dir();
        assert!(
            diag.starts_with(&data),
            "diagnostics_dir ({}) should start with data_dir ({})",
            diag.display(),
            data.display()
        );
    }

    #[test]
    fn hf_cache_dir_is_subpath_of_cache_dir() {
        let hf = hf_cache_dir();
        let cache = cache_dir();
        assert!(
            hf.starts_with(&cache),
            "hf_cache_dir ({}) should start with cache_dir ({})",
            hf.display(),
            cache.display()
        );
    }

    #[test]
    fn is_sandboxed_returns_false_in_tests() {
        // In test environment, there's no sandbox container.
        assert!(!is_sandboxed());
    }

    #[test]
    fn data_dir_override_via_env() {
        let key = "FAE_DATA_DIR";
        let original = std::env::var_os(key);

        // SAFETY: Tests run single-threaded per module.
        unsafe { std::env::set_var(key, "/custom/data") };
        let result = data_dir();
        assert_eq!(result, PathBuf::from("/custom/data"));

        // Restore.
        match original {
            Some(val) => unsafe { std::env::set_var(key, val) },
            None => unsafe { std::env::remove_var(key) },
        }
    }

    #[test]
    fn config_dir_override_via_env() {
        let key = "FAE_CONFIG_DIR";
        let original = std::env::var_os(key);

        unsafe { std::env::set_var(key, "/custom/config") };
        let result = config_dir();
        assert_eq!(result, PathBuf::from("/custom/config"));

        match original {
            Some(val) => unsafe { std::env::set_var(key, val) },
            None => unsafe { std::env::remove_var(key) },
        }
    }

    #[test]
    fn cache_dir_override_via_env() {
        let key = "FAE_CACHE_DIR";
        let original = std::env::var_os(key);

        unsafe { std::env::set_var(key, "/custom/cache") };
        let result = cache_dir();
        assert_eq!(result, PathBuf::from("/custom/cache"));

        match original {
            Some(val) => unsafe { std::env::set_var(key, val) },
            None => unsafe { std::env::remove_var(key) },
        }
    }

    #[test]
    fn external_apis_dir_is_subpath_of_data_dir() {
        let apis = external_apis_dir();
        let data = data_dir();
        assert!(
            apis.starts_with(&data),
            "external_apis_dir ({}) should start with data_dir ({})",
            apis.display(),
            data.display()
        );
    }

    #[test]
    fn wakeword_dir_is_subpath_of_data_dir() {
        let ww = wakeword_dir();
        let data = data_dir();
        assert!(
            ww.starts_with(&data),
            "wakeword_dir ({}) should start with data_dir ({})",
            ww.display(),
            data.display()
        );
    }

    #[test]
    fn memory_dir_equals_data_dir() {
        assert_eq!(memory_dir(), data_dir());
    }

    #[test]
    fn ensure_hf_home_sets_env_when_absent() {
        let key = "HF_HOME";
        let original = std::env::var_os(key);

        // Clear to test the set path.
        unsafe { std::env::remove_var(key) };
        ensure_hf_home();
        let val = std::env::var_os(key);
        assert!(val.is_some(), "HF_HOME should be set after ensure_hf_home");
        let path = PathBuf::from(val.clone().unwrap_or_default());
        assert!(
            path.to_string_lossy().contains("huggingface"),
            "HF_HOME should point to huggingface dir: {}",
            path.display()
        );

        // Restore.
        match original {
            Some(v) => unsafe { std::env::set_var(key, v) },
            None => unsafe { std::env::remove_var(key) },
        }
    }
}
