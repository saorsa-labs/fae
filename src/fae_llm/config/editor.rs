//! Round-trip TOML editing using `toml_edit`.
//!
//! Preserves comments, formatting, and unknown fields when modifying
//! config values programmatically.

use crate::fae_llm::error::FaeLlmError;
use std::path::Path;

use super::types::FaeLlmConfig;

/// A config editor that preserves comments and formatting during edits.
///
/// Wraps a `toml_edit::DocumentMut` for round-trip safe editing, and a
/// deserialized `FaeLlmConfig` for typed access.
pub struct ConfigEditor {
    doc: toml_edit::DocumentMut,
    path: std::path::PathBuf,
}

impl ConfigEditor {
    /// Load a config file for editing.
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` if the file cannot be read or parsed.
    pub fn load(path: &Path) -> Result<Self, FaeLlmError> {
        let contents = std::fs::read_to_string(path).map_err(|e| {
            FaeLlmError::ConfigError(format!(
                "failed to read config file '{}': {e}",
                path.display()
            ))
        })?;
        let doc: toml_edit::DocumentMut = contents.parse().map_err(|e| {
            FaeLlmError::ConfigError(format!(
                "failed to parse config file '{}': {e}",
                path.display()
            ))
        })?;
        Ok(Self {
            doc,
            path: path.to_path_buf(),
        })
    }

    /// Get a string value by dotted key path (e.g. "defaults.default_provider").
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` if the key path doesn't exist or isn't a string.
    pub fn get_string(&self, key_path: &str) -> Result<String, FaeLlmError> {
        let item = self.resolve_key(key_path)?;
        item.as_str()
            .map(|s| s.to_string())
            .ok_or_else(|| FaeLlmError::ConfigError(format!("key '{key_path}' is not a string")))
    }

    /// Get an integer value by dotted key path.
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` if the key path doesn't exist or isn't an integer.
    pub fn get_integer(&self, key_path: &str) -> Result<i64, FaeLlmError> {
        let item = self.resolve_key(key_path)?;
        item.as_integer()
            .ok_or_else(|| FaeLlmError::ConfigError(format!("key '{key_path}' is not an integer")))
    }

    /// Set a string value by dotted key path, preserving surrounding formatting.
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` if the parent table cannot be navigated.
    pub fn set_string(&mut self, key_path: &str, value: &str) -> Result<(), FaeLlmError> {
        self.set_value(key_path, toml_edit::value(value))
    }

    /// Set an integer value by dotted key path, preserving surrounding formatting.
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` if the parent table cannot be navigated.
    pub fn set_integer(&mut self, key_path: &str, value: i64) -> Result<(), FaeLlmError> {
        self.set_value(key_path, toml_edit::value(value))
    }

    /// Set a boolean value by dotted key path.
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` if the parent table cannot be navigated.
    pub fn set_bool(&mut self, key_path: &str, value: bool) -> Result<(), FaeLlmError> {
        self.set_value(key_path, toml_edit::value(value))
    }

    /// Save the edited document back to disk atomically.
    ///
    /// The raw TOML text (with comments preserved) is written to a temp file
    /// and atomically renamed. Then the typed config is re-parsed to ensure
    /// the written document is valid.
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` on write or parse failure.
    pub fn save(&self) -> Result<(), FaeLlmError> {
        let toml_text = self.doc.to_string();

        // Validate that the document still parses as FaeLlmConfig
        let _config: FaeLlmConfig = toml::from_str(&toml_text)
            .map_err(|e| FaeLlmError::ConfigError(format!("edited config is invalid: {e}")))?;

        // Write via atomic persist (use the raw text, not serialized config,
        // to preserve comments)
        let tmp_path = self.path.with_extension("toml.tmp");
        std::fs::write(&tmp_path, toml_text.as_bytes())
            .map_err(|e| FaeLlmError::ConfigError(format!("failed to write temp file: {e}")))?;
        std::fs::rename(&tmp_path, &self.path)
            .map_err(|e| FaeLlmError::ConfigError(format!("failed to rename temp file: {e}")))
    }

    /// Save the edited document to a different path.
    pub fn save_to(&self, path: &Path) -> Result<(), FaeLlmError> {
        let toml_text = self.doc.to_string();
        let _config: FaeLlmConfig = toml::from_str(&toml_text)
            .map_err(|e| FaeLlmError::ConfigError(format!("edited config is invalid: {e}")))?;
        let tmp_path = path.with_extension("toml.tmp");
        std::fs::write(&tmp_path, toml_text.as_bytes())
            .map_err(|e| FaeLlmError::ConfigError(format!("failed to write temp file: {e}")))?;
        std::fs::rename(&tmp_path, path)
            .map_err(|e| FaeLlmError::ConfigError(format!("failed to rename temp file: {e}")))
    }

    /// Get the raw TOML text (with comments preserved).
    pub fn to_toml_string(&self) -> String {
        self.doc.to_string()
    }

    // ── Internal helpers ──

    fn resolve_key(&self, key_path: &str) -> Result<&toml_edit::Item, FaeLlmError> {
        let parts: Vec<&str> = key_path.split('.').collect();
        let mut current: &toml_edit::Item = self.doc.as_item();

        for part in &parts {
            current = current
                .get(part)
                .ok_or_else(|| FaeLlmError::ConfigError(format!("key '{key_path}' not found")))?;
        }
        Ok(current)
    }

    fn set_value(&mut self, key_path: &str, value: toml_edit::Item) -> Result<(), FaeLlmError> {
        let parts: Vec<&str> = key_path.split('.').collect();
        if parts.is_empty() {
            return Err(FaeLlmError::ConfigError("empty key path".into()));
        }

        let last = parts[parts.len() - 1];
        let parents = &parts[..parts.len() - 1];

        let mut current: &mut toml_edit::Item = self.doc.as_item_mut();
        for part in parents {
            // Create intermediate tables if they don't exist
            if current.get(part).is_none() {
                current[part] = toml_edit::Item::Table(toml_edit::Table::new());
            }
            current = &mut current[part];
        }

        current[last] = value;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_test_toml(dir: &tempfile::TempDir, content: &str) -> std::path::PathBuf {
        let path = dir.path().join("config.toml");
        std::fs::write(&path, content).unwrap_or_default();
        path
    }

    fn make_test_dir() -> tempfile::TempDir {
        match tempfile::tempdir() {
            Ok(d) => d,
            Err(_) => unreachable!("tempdir creation should not fail"),
        }
    }

    #[test]
    fn load_and_get_string() {
        let dir = make_test_dir();
        let path = write_test_toml(
            &dir,
            r#"
[defaults]
default_provider = "openai"
"#,
        );

        let editor = ConfigEditor::load(&path);
        assert!(editor.is_ok());
        let editor = match editor {
            Ok(e) => e,
            Err(_) => unreachable!(),
        };

        let val = editor.get_string("defaults.default_provider");
        assert!(val.is_ok());
        assert_eq!(val.unwrap_or_default(), "openai");
    }

    #[test]
    fn load_and_get_integer() {
        let dir = make_test_dir();
        let path = write_test_toml(
            &dir,
            r#"
[runtime]
request_timeout_secs = 60
"#,
        );

        let editor = ConfigEditor::load(&path);
        assert!(editor.is_ok());
        let editor = match editor {
            Ok(e) => e,
            Err(_) => unreachable!(),
        };

        let val = editor.get_integer("runtime.request_timeout_secs");
        assert!(val.is_ok());
        assert_eq!(val.unwrap_or(0), 60);
    }

    #[test]
    fn set_string_preserves_comments() {
        let dir = make_test_dir();
        let original = r#"# This is a comment
[defaults]
# Provider to use by default
default_provider = "openai"
"#;
        let path = write_test_toml(&dir, original);

        let editor = ConfigEditor::load(&path);
        assert!(editor.is_ok());
        let mut editor = match editor {
            Ok(e) => e,
            Err(_) => unreachable!(),
        };

        let result = editor.set_string("defaults.default_provider", "anthropic");
        assert!(result.is_ok());

        let output = editor.to_toml_string();
        assert!(output.contains("# This is a comment"));
        assert!(output.contains("# Provider to use by default"));
        assert!(output.contains("\"anthropic\""));
        assert!(!output.contains("\"openai\""));
    }

    #[test]
    fn set_integer_and_save() {
        let dir = make_test_dir();
        let path = write_test_toml(
            &dir,
            r#"
[runtime]
request_timeout_secs = 30
max_retries = 3
"#,
        );

        let editor = ConfigEditor::load(&path);
        assert!(editor.is_ok());
        let mut editor = match editor {
            Ok(e) => e,
            Err(_) => unreachable!(),
        };

        let _ = editor.set_integer("runtime.request_timeout_secs", 120);
        let save_result = editor.save();
        assert!(save_result.is_ok());

        // Re-load and verify
        let editor2 = ConfigEditor::load(&path);
        assert!(editor2.is_ok());
        let editor2 = match editor2 {
            Ok(e) => e,
            Err(_) => unreachable!(),
        };
        let val = editor2.get_integer("runtime.request_timeout_secs");
        assert_eq!(val.unwrap_or(0), 120);
    }

    #[test]
    fn get_missing_key_returns_error() {
        let dir = make_test_dir();
        let path = write_test_toml(&dir, "[runtime]\n");

        let editor = ConfigEditor::load(&path);
        assert!(editor.is_ok());
        let editor = match editor {
            Ok(e) => e,
            Err(_) => unreachable!(),
        };

        let result = editor.get_string("defaults.nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn round_trip_preserves_unknown_keys() {
        let dir = make_test_dir();
        let original = r#"
[runtime]
request_timeout_secs = 30
max_retries = 3
log_level = "info"
custom_unknown_key = "preserved"
"#;
        let path = write_test_toml(&dir, original);

        let editor = ConfigEditor::load(&path);
        assert!(editor.is_ok());
        let mut editor = match editor {
            Ok(e) => e,
            Err(_) => unreachable!(),
        };

        let _ = editor.set_integer("runtime.max_retries", 5);

        let output = editor.to_toml_string();
        assert!(output.contains("custom_unknown_key"));
        assert!(output.contains("\"preserved\""));
    }
}
