//! Skill loading for Fae.
//!
//! Skills are concise behavioural guides that tell the LLM **when** and **how**
//! to use specific tool categories. They are injected into the system prompt
//! between the personality layer and the user add-on.
//!
//! Two sources of skills exist:
//!
//! 1. **Built-in skills** — compiled into the binary (e.g. [`CANVAS_SKILL`]).
//! 2. **User skills** — `.md` files in [`skills_dir`] (`~/.fae/skills/`).

use std::path::PathBuf;

/// The built-in canvas skill, compiled from `Skills/canvas.md`.
pub const CANVAS_SKILL: &str = include_str!("../Skills/canvas.md");

/// The built-in Pi coding agent skill, compiled from `Skills/pi.md`.
pub const PI_SKILL: &str = include_str!("../Skills/pi.md");

/// Returns the directory where user-created skills are stored.
///
/// Defaults to `~/.fae/skills/`.
pub fn skills_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".fae").join("skills")
    } else {
        PathBuf::from("/tmp/.fae/skills")
    }
}

/// Lists all available skill names.
///
/// Always includes `"canvas"` (built-in). Any `.md` files found in
/// [`skills_dir`] are added by stem name (e.g. `custom.md` → `"custom"`).
pub fn list_skills() -> Vec<String> {
    let mut names = vec!["canvas".to_owned(), "pi".to_owned()];
    let dir = skills_dir();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("md")
                && let Some(stem) = path.file_stem().and_then(|s| s.to_str())
            {
                let name = stem.to_owned();
                if name != "canvas" && name != "pi" {
                    names.push(name);
                }
            }
        }
    }
    names
}

/// Loads and concatenates all skills into one string.
///
/// Returns the built-in canvas skill followed by the contents of each `.md`
/// file in [`skills_dir`]. Missing directory is silently ignored.
pub fn load_all_skills() -> String {
    let mut parts: Vec<String> = vec![CANVAS_SKILL.to_owned(), PI_SKILL.to_owned()];
    let dir = skills_dir();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        let mut paths: Vec<_> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("md"))
            .collect();
        // Sort for deterministic ordering
        paths.sort();
        for path in paths {
            if let Ok(content) = std::fs::read_to_string(&path) {
                let trimmed = content.trim();
                if !trimmed.is_empty() {
                    parts.push(trimmed.to_owned());
                }
            }
        }
    }
    parts.join("\n\n")
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn canvas_skill_is_nonempty() {
        assert!(!CANVAS_SKILL.is_empty());
        assert!(CANVAS_SKILL.contains("Canvas"));
    }

    #[test]
    fn canvas_skill_mentions_canvas_render() {
        assert!(CANVAS_SKILL.contains("canvas_render"));
    }

    #[test]
    fn pi_skill_is_nonempty() {
        assert!(!PI_SKILL.is_empty());
        assert!(PI_SKILL.contains("pi_delegate"));
    }

    #[test]
    fn pi_skill_mentions_coding_tasks() {
        assert!(PI_SKILL.contains("coding"));
    }

    #[test]
    fn list_includes_canvas_builtin() {
        let names = list_skills();
        assert!(names.contains(&"canvas".to_owned()));
    }

    #[test]
    fn list_includes_pi_builtin() {
        let names = list_skills();
        assert!(names.contains(&"pi".to_owned()));
    }

    #[test]
    fn load_all_includes_canvas() {
        let all = load_all_skills();
        assert!(all.contains("Canvas"));
        assert!(all.contains("canvas_render"));
    }

    #[test]
    fn load_all_includes_pi() {
        let all = load_all_skills();
        assert!(all.contains("pi_delegate"));
    }

    #[test]
    fn skills_dir_is_under_fae() {
        let dir = skills_dir();
        let dir_str = dir.to_string_lossy();
        assert!(dir_str.contains(".fae"));
        assert!(dir_str.ends_with("skills"));
    }

    #[test]
    fn missing_skills_dir_does_not_crash() {
        // load_all_skills should work even if ~/.fae/skills/ doesn't exist
        let all = load_all_skills();
        assert!(!all.is_empty());
    }
}
