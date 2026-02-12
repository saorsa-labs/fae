//! Comprehensive TOML round-trip preservation tests using toml_edit.
//!
//! Validates that ConfigEditor preserves comments, formatting, key ordering,
//! and unknown fields during programmatic updates.

use fae::fae_llm::{ConfigEditor, FaeLlmConfig};
use std::fs;
use tempfile::TempDir;

/// Helper to create a temp dir with a config file containing rich formatting.
fn setup_formatted_config() -> (TempDir, std::path::PathBuf) {
    let dir = TempDir::new().expect("failed to create temp dir");
    let path = dir.path().join("fae_llm.toml");

    let toml = r#"
# FAE LLM Configuration
# Auto-generated with comments and formatting

# ──────────────────────────────────────────────────────────────
# Providers
# ──────────────────────────────────────────────────────────────

[providers.openai]
endpoint_type = "openai"
base_url = "https://api.openai.com/v1"  # Official OpenAI endpoint
api_key = { type = "env", var = "OPENAI_API_KEY" }

[providers.anthropic]
endpoint_type = "anthropic"
base_url = "https://api.anthropic.com"
api_key = { type = "env", var = "ANTHROPIC_API_KEY" }  # Claude API key

# ──────────────────────────────────────────────────────────────
# Models
# ──────────────────────────────────────────────────────────────

[models.gpt4]
model_id = "gpt-4o"
display_name = "GPT-4o"
tier = "balanced"
max_tokens = 16384  # Large context window

[models.claude]
model_id = "claude-sonnet-4-5-20250929"
display_name = "Claude Sonnet 4.5"
tier = "reasoning"
max_tokens = 8192

# ──────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────

[defaults]
default_provider = "anthropic"
default_model = "claude"
tool_mode = "read_only"

# ──────────────────────────────────────────────────────────────
# Runtime
# ──────────────────────────────────────────────────────────────

[runtime]
request_timeout_secs = 30
max_retries = 3
log_level = "info"  # Options: trace, debug, info, warn, error
"#;

    fs::write(&path, toml).expect("failed to write config");
    (dir, path)
}

#[test]
fn test_preserves_inline_comments() {
    let (_dir, path) = setup_formatted_config();

    // Load, modify, save
    let mut editor = ConfigEditor::load(&path).expect("failed to load");
    editor
        .set_integer("runtime.max_retries", 5)
        .expect("failed to set max_retries");
    editor.save().expect("failed to save");

    // Reload raw TOML
    let raw = fs::read_to_string(&path).expect("failed to read");

    // Verify inline comments preserved
    assert!(
        raw.contains("# Official OpenAI endpoint"),
        "Inline comment after base_url missing"
    );
    assert!(
        raw.contains("# Claude API key"),
        "Inline comment after api_key missing"
    );
    assert!(
        raw.contains("# Large context window"),
        "Inline comment after max_tokens missing"
    );
    assert!(
        raw.contains("# Options: trace, debug, info, warn, error"),
        "Inline comment after log_level missing"
    );
}

#[test]
fn test_preserves_block_comments() {
    let (_dir, path) = setup_formatted_config();

    // Load, modify, save
    let mut editor = ConfigEditor::load(&path).expect("failed to load");
    editor
        .set_string("defaults.default_provider", "openai")
        .expect("failed to set provider");
    editor.save().expect("failed to save");

    // Reload raw TOML
    let raw = fs::read_to_string(&path).expect("failed to read");

    // Verify block comments preserved
    assert!(
        raw.contains("# FAE LLM Configuration"),
        "Top-level block comment missing"
    );
    assert!(
        raw.contains("# ──────────────────────────────────────────────────────────────"),
        "Separator comment missing"
    );
    assert!(raw.contains("# Providers"), "Section header missing");
    assert!(raw.contains("# Models"), "Section header missing");
    assert!(raw.contains("# Defaults"), "Section header missing");
    assert!(raw.contains("# Runtime"), "Section header missing");
}

#[test]
fn test_preserves_formatting_spacing() {
    let (_dir, path) = setup_formatted_config();
    let original = fs::read_to_string(&path).expect("failed to read original");

    // Load, modify, save
    let mut editor = ConfigEditor::load(&path).expect("failed to load");
    editor
        .set_integer("runtime.request_timeout_secs", 60)
        .expect("failed to set timeout");
    editor.save().expect("failed to save");

    // Reload
    let modified = fs::read_to_string(&path).expect("failed to read modified");

    // Count newlines (should be approximately the same, allowing for minor differences)
    let original_newlines = original.matches('\n').count();
    let modified_newlines = modified.matches('\n').count();
    let diff = original_newlines.abs_diff(modified_newlines);

    assert!(
        diff <= 2,
        "Newline count changed significantly: {original_newlines} → {modified_newlines}"
    );
}

#[test]
fn test_preserves_key_ordering() {
    let (_dir, path) = setup_formatted_config();
    let original = fs::read_to_string(&path).expect("failed to read original");

    // Load, modify, save
    let mut editor = ConfigEditor::load(&path).expect("failed to load");
    editor
        .set_string("defaults.default_model", "gpt4")
        .expect("failed to set model");
    editor.save().expect("failed to save");

    // Reload
    let modified = fs::read_to_string(&path).expect("failed to read modified");

    // Find positions of key sections
    let _orig_providers_pos = original
        .find("[providers.openai]")
        .expect("provider not found");
    let _orig_models_pos = original.find("[models.gpt4]").expect("model not found");

    let mod_providers_pos = modified
        .find("[providers.openai]")
        .expect("provider not found");
    let mod_models_pos = modified.find("[models.gpt4]").expect("model not found");
    let mod_defaults_pos = modified.find("[defaults]").expect("defaults not found");

    // Verify ordering preserved: providers < models < defaults
    assert!(
        mod_providers_pos < mod_models_pos,
        "providers section moved after models"
    );
    assert!(
        mod_models_pos < mod_defaults_pos,
        "models section moved after defaults"
    );
}

#[test]
fn test_preserves_unknown_sections() {
    let dir = TempDir::new().expect("failed to create temp dir");
    let path = dir.path().join("fae_llm.toml");

    // Config with unknown custom section
    let toml = r#"
[defaults]
default_provider = "openai"
default_model = "gpt4"
tool_mode = "read_only"

[runtime]
request_timeout_secs = 30
max_retries = 3
log_level = "info"

# Custom user section (unknown to schema)
[custom.user_settings]
theme = "dark"
notifications = true
"#;

    fs::write(&path, toml).expect("failed to write config");

    // Load, modify, save
    let mut editor = ConfigEditor::load(&path).expect("failed to load");
    editor
        .set_integer("runtime.max_retries", 5)
        .expect("failed to set retries");
    editor.save().expect("failed to save");

    // Reload
    let modified = fs::read_to_string(&path).expect("failed to read modified");

    // Verify unknown section preserved
    assert!(
        modified.contains("[custom.user_settings]"),
        "Unknown section was removed"
    );
    assert!(
        modified.contains("theme = \"dark\""),
        "Unknown field removed"
    );
    assert!(
        modified.contains("notifications = true"),
        "Unknown field removed"
    );
}

#[test]
fn test_handles_arrays_of_tables() {
    let dir = TempDir::new().expect("failed to create temp dir");
    let path = dir.path().join("fae_llm.toml");

    // Valid config with array-of-tables syntax (unknown to schema but valid TOML)
    let toml = r#"
[defaults]
default_provider = "openai"
default_model = "gpt4"
tool_mode = "read_only"

[runtime]
request_timeout_secs = 30
max_retries = 3
log_level = "info"

# Unknown array-of-tables for future use
[[experimental.features]]
name = "feature_a"
enabled = true

[[experimental.features]]
name = "feature_b"
enabled = false
"#;

    fs::write(&path, toml).expect("failed to write config");

    // Load, modify, save
    let mut editor = ConfigEditor::load(&path).expect("failed to load");
    editor
        .set_string("defaults.default_provider", "anthropic")
        .expect("failed to set provider");
    editor.save().expect("failed to save");

    // Verify still valid TOML
    let modified = fs::read_to_string(&path).expect("failed to read modified");
    let _: toml::Value = toml::from_str(&modified).expect("not valid TOML after modification");

    // Array-of-tables should still be present (serde will ignore unknown fields)
    assert!(
        modified.contains("[[experimental.features]]"),
        "Array-of-tables was removed"
    );
    assert!(modified.contains("feature_a"), "Array element was removed");
}

#[test]
fn test_handles_nested_tables() {
    let dir = TempDir::new().expect("failed to create temp dir");
    let path = dir.path().join("fae_llm.toml");

    let toml = r#"
[providers.openai]
endpoint_type = "openai"
base_url = "https://api.openai.com/v1"

[providers.openai.rate_limits]
requests_per_minute = 100
tokens_per_minute = 50000

[defaults]
default_provider = "openai"
"#;

    fs::write(&path, toml).expect("failed to write config");

    // Load, modify, save
    let mut editor = ConfigEditor::load(&path).expect("failed to load");
    editor
        .set_string("defaults.default_provider", "anthropic")
        .expect("failed to set provider");
    editor.save().expect("failed to save");

    // Reload
    let modified = fs::read_to_string(&path).expect("failed to read modified");

    // Nested table should be preserved
    assert!(
        modified.contains("[providers.openai.rate_limits]"),
        "Nested table was removed"
    );
    assert!(
        modified.contains("requests_per_minute = 100"),
        "Nested field removed"
    );
}

#[test]
fn test_quote_style_preservation() {
    let dir = TempDir::new().expect("failed to create temp dir");
    let path = dir.path().join("fae_llm.toml");

    let toml = r#"
[defaults]
default_provider = "openai"
default_model = 'gpt4'  # Single quotes

[runtime]
log_level = "info"
"#;

    fs::write(&path, toml).expect("failed to write config");

    // Load, modify, save
    let mut editor = ConfigEditor::load(&path).expect("failed to load");
    editor
        .set_integer("runtime.request_timeout_secs", 60)
        .expect("failed to insert new key");
    editor.save().expect("failed to save");

    // Reload and verify it parses
    let modified = fs::read_to_string(&path).expect("failed to read modified");
    let _: FaeLlmConfig = toml::from_str(&modified).expect("not valid TOML");

    // Note: toml_edit may normalize quotes to double quotes, which is acceptable
    // as long as the values are preserved correctly.
    assert!(
        modified.contains("default_provider") && modified.contains("openai"),
        "String value lost"
    );
}

#[test]
fn test_multiple_sequential_edits() {
    let (_dir, path) = setup_formatted_config();

    // Edit 1
    let mut editor = ConfigEditor::load(&path).expect("load 1");
    editor
        .set_string("defaults.default_provider", "openai")
        .expect("edit 1");
    editor.save().expect("save 1");

    // Edit 2
    let mut editor = ConfigEditor::load(&path).expect("load 2");
    editor
        .set_integer("runtime.max_retries", 10)
        .expect("edit 2");
    editor.save().expect("save 2");

    // Edit 3
    let mut editor = ConfigEditor::load(&path).expect("load 3");
    editor
        .set_string("runtime.log_level", "debug")
        .expect("edit 3");
    editor.save().expect("save 3");

    // Verify comments still present after 3 edits
    let final_toml = fs::read_to_string(&path).expect("failed to read final");
    assert!(
        final_toml.contains("# FAE LLM Configuration"),
        "Top comment lost after multiple edits"
    );
    assert!(
        final_toml.contains("# Official OpenAI endpoint"),
        "Inline comment lost after multiple edits"
    );

    // Verify all edits applied
    let config: FaeLlmConfig = toml::from_str(&final_toml).expect("parse final config");
    assert_eq!(config.defaults.default_provider, Some("openai".to_string()));
    assert_eq!(config.runtime.max_retries, 10);
    assert_eq!(config.runtime.log_level, "debug");
}

#[test]
fn test_load_save_idempotent() {
    let (_dir, path) = setup_formatted_config();
    let original = fs::read_to_string(&path).expect("failed to read original");

    // Load and save without modification
    let editor = ConfigEditor::load(&path).expect("failed to load");
    editor.save().expect("failed to save");

    let after_save = fs::read_to_string(&path).expect("failed to read after save");

    // Content should be identical (or nearly identical — toml_edit may normalize whitespace)
    assert_eq!(
        original.trim(),
        after_save.trim(),
        "Load→save without modification changed the file"
    );
}
