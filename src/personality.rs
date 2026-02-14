//! Prompt assembly and user-editable prompt assets for Fae.
//!
//! Runtime prompt stack:
//! 1. Core system prompt (`Prompts/system_prompt.md`)
//! 2. User-editable SOUL contract (`~/.fae/SOUL.md`, with repo fallback)
//! 3. Optional user add-on text from config
//!
//! Onboarding checklist text is loaded separately and injected only while
//! onboarding is incomplete (see memory orchestrator).

use crate::error::Result;
use std::path::{Path, PathBuf};

/// Core system prompt (small, operational instructions).
pub const CORE_PROMPT: &str = include_str!("../Prompts/system_prompt.md");

/// Default SOUL contract installed to `~/.fae/SOUL.md`.
pub const DEFAULT_SOUL: &str = include_str!("../SOUL.md");

/// Default onboarding checklist installed to `~/.fae/onboarding.md`.
pub const DEFAULT_ONBOARDING_CHECKLIST: &str = include_str!("../Prompts/onboarding.md");

/// Returns `~/.fae` (or `/tmp/.fae` fallback).
#[must_use]
pub fn fae_home_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".fae")
    } else {
        PathBuf::from("/tmp/.fae")
    }
}

/// Returns the user SOUL file path (`~/.fae/SOUL.md`).
#[must_use]
pub fn soul_path() -> PathBuf {
    fae_home_dir().join("SOUL.md")
}

/// Returns the user onboarding checklist path (`~/.fae/onboarding.md`).
#[must_use]
pub fn onboarding_path() -> PathBuf {
    fae_home_dir().join("onboarding.md")
}

/// Ensure user-editable prompt assets exist in `~/.fae/`.
///
/// Existing files are never overwritten.
pub fn ensure_prompt_assets() -> Result<()> {
    ensure_file_exists(&soul_path(), DEFAULT_SOUL)?;
    ensure_file_exists(&onboarding_path(), DEFAULT_ONBOARDING_CHECKLIST)?;
    Ok(())
}

fn ensure_file_exists(path: &Path, default_content: &str) -> Result<()> {
    if path.exists() {
        return Ok(());
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, default_content)?;
    Ok(())
}

/// Load SOUL text from user file, falling back to repository default.
#[must_use]
pub fn load_soul() -> String {
    std::fs::read_to_string(soul_path()).unwrap_or_else(|_| DEFAULT_SOUL.to_owned())
}

/// Load onboarding checklist from user file, falling back to repository default.
#[must_use]
pub fn load_onboarding_checklist() -> String {
    std::fs::read_to_string(onboarding_path())
        .unwrap_or_else(|_| DEFAULT_ONBOARDING_CHECKLIST.to_owned())
}

/// Assemble the active system prompt.
///
/// `personality_name` is ignored and retained only for backward compatibility.
#[must_use]
pub fn assemble_prompt(_personality_name: &str, user_add_on: &str) -> String {
    let soul = load_soul();
    let add_on = user_add_on.trim();

    let mut parts: Vec<&str> = Vec::with_capacity(3);
    parts.push(CORE_PROMPT.trim());

    let soul_trimmed = soul.trim();
    if !soul_trimmed.is_empty() {
        parts.push(soul_trimmed);
    }

    if !add_on.is_empty() {
        parts.push(add_on);
    }

    parts.join("\n\n")
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn core_prompt_nonempty() {
        assert!(!CORE_PROMPT.trim().is_empty());
    }

    #[test]
    fn defaults_nonempty() {
        assert!(!DEFAULT_SOUL.trim().is_empty());
        assert!(!DEFAULT_ONBOARDING_CHECKLIST.trim().is_empty());
    }

    #[test]
    fn assemble_includes_core_and_soul() {
        let prompt = assemble_prompt("fae", "");
        assert!(prompt.contains("You are Fae"));
        assert!(prompt.starts_with(CORE_PROMPT.trim()));
    }

    #[test]
    fn assemble_appends_user_add_on() {
        let prompt = assemble_prompt("any", "Be extra concise.");
        assert!(prompt.ends_with("Be extra concise."));
    }
}
