//! Personality profile loading for Fae.
//!
//! The system prompt is assembled from four layers:
//!
//! 1. **Core prompt** ([`CORE_PROMPT`]) — minimal voice-assistant output rules.
//! 2. **Personality** — character definition loaded by name (see [`load_personality`]).
//! 3. **Skills** — behavioural guides for tool usage (see [`crate::skills`]).
//! 4. **User add-on** — optional free-text instructions from the user's config.
//!
//! Two built-in personalities ship with the binary:
//!
//! - `"default"` — core prompt only, no character overlay.
//! - `"fae"` — the full Fae identity profile ([`FAE_PERSONALITY`]).
//!
//! Additional profiles can be placed as `.md` files in `~/.fae/personalities/`.

use std::path::PathBuf;

/// Minimal voice-assistant behaviour rules.
///
/// This is always prepended to the assembled system prompt regardless of which
/// personality is selected.
pub const CORE_PROMPT: &str = "\
You are a voice assistant. Respond in 1-3 short sentences.\n\
Speak naturally. Do not use emojis, action descriptions, roleplay narration, or stage directions.\n\
Do not narrate your reasoning. If unsure, ask one focused question.\n\
If you do not know the answer, say so briefly.\n\
\n\
## Tools\n\
Depending on configuration, you may have tools such as: read, write, edit, bash (shell commands), and canvas tools.\n\
When you want to use a tool, tell the user what you want to do and ASK PERMISSION first.\n\
Example: \"May I check your desktop?\" — wait for yes, then USE THE TOOL.\n\
\n\
IMPORTANT: After the user says yes/go ahead, actually call the tool and report the result.\n\
\n\
## Tool Feedback\n\
When you use tools, give meaningful feedback:\n\
- For file listings: summarize, do not just list\n\
- For file contents: explain what it is in plain language\n\
- For commands: report the outcome\n\
- Use canvas for visual content when helpful\n\
Never dump raw output - always interpret for the user.\n\
\n\
## Important\n\
- Always ask before using tools\n\
- Wait for approval before acting\n\
- Report results after using tools in plain language\n\
- If asked to delete files or run dangerous commands, refuse and explain why\n\
";

/// The voice-optimized Fae identity profile, compiled into the binary from
/// `Personality/fae-identity-profile.md`.
///
/// This is the concise version used in the system prompt for voice assistant
/// interactions (78 lines, ~3000 chars).
pub const FAE_PERSONALITY: &str = include_str!("../Personality/system_prompt.md");

/// The full Fae identity reference document, compiled into the binary from
/// `Personality/fae-identity-full.md`.
///
/// This 291-line character bible contains the complete backstory, abilities,
/// vulnerabilities, and personality details. It is available for future use
/// (e.g. RAG, detailed character queries) but is **not** included in the
/// system prompt to keep token usage manageable.
pub const FAE_IDENTITY_REFERENCE: &str = include_str!("../Personality/fae-identity-full.md");

/// Returns the directory where user-created personality profiles are stored.
///
/// Defaults to `~/.fae/personalities/`.
pub fn personalities_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".fae").join("personalities")
    } else {
        PathBuf::from("/tmp/.fae/personalities")
    }
}

/// Lists all available personality names.
///
/// Always includes `"default"` and `"fae"`. Any `.md` files found in
/// [`personalities_dir`] are added by stem name (e.g. `pirate.md` → `"pirate"`).
pub fn list_personalities() -> Vec<String> {
    let mut names = vec!["default".to_owned(), "fae".to_owned()];
    let dir = personalities_dir();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("md")
                && let Some(stem) = path.file_stem().and_then(|s| s.to_str())
            {
                let name = stem.to_owned();
                if name != "default" && name != "fae" {
                    names.push(name);
                }
            }
        }
    }
    names
}

/// Loads the personality text for the given name.
///
/// - `"default"` returns an empty string (core prompt only).
/// - `"fae"` returns [`FAE_PERSONALITY`].
/// - Anything else looks up `~/.fae/personalities/{name}.md`.
///   If the file does not exist, falls back to `"fae"`.
pub fn load_personality(name: &str) -> String {
    match name {
        "default" => String::new(),
        "fae" => FAE_PERSONALITY.to_owned(),
        other => {
            let path = personalities_dir().join(format!("{other}.md"));
            std::fs::read_to_string(&path).unwrap_or_else(|_| FAE_PERSONALITY.to_owned())
        }
    }
}

/// Assembles the full system prompt from core prompt, personality, skills,
/// and user add-on.
///
/// Empty sections are skipped so the result never contains double blank lines
/// between layers.
pub fn assemble_prompt(personality_name: &str, user_add_on: &str) -> String {
    let personality = load_personality(personality_name);
    let skills = crate::skills::load_all_skills();
    let add_on = user_add_on.trim();

    let mut parts: Vec<&str> = Vec::with_capacity(4);
    parts.push(CORE_PROMPT);
    let personality_trimmed = personality.trim();
    if !personality_trimmed.is_empty() {
        parts.push(personality_trimmed);
    }
    let skills_trimmed = skills.trim();
    if !skills_trimmed.is_empty() {
        parts.push(skills_trimmed);
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
    fn core_prompt_is_nonempty() {
        assert!(!CORE_PROMPT.is_empty());
    }

    #[test]
    fn fae_personality_is_nonempty() {
        assert!(!FAE_PERSONALITY.is_empty());
        assert!(FAE_PERSONALITY.contains("Fae"));
    }

    #[test]
    fn list_includes_builtins() {
        let names = list_personalities();
        assert!(names.contains(&"default".to_owned()));
        assert!(names.contains(&"fae".to_owned()));
    }

    #[test]
    fn load_default_returns_empty() {
        assert!(load_personality("default").is_empty());
    }

    #[test]
    fn load_fae_returns_identity() {
        let text = load_personality("fae");
        assert!(!text.is_empty());
        assert!(text.contains("Fae"));
    }

    #[test]
    fn load_missing_falls_back_to_fae() {
        let text = load_personality("nonexistent_profile_xyz");
        assert_eq!(text, FAE_PERSONALITY);
    }

    #[test]
    fn assemble_core_only() {
        let prompt = assemble_prompt("default", "");
        // Core + skills (no personality for "default")
        assert!(prompt.starts_with(CORE_PROMPT));
        assert!(prompt.contains("Canvas"));
    }

    #[test]
    fn assemble_fae_no_addon() {
        let prompt = assemble_prompt("fae", "");
        assert!(prompt.starts_with(CORE_PROMPT));
        assert!(prompt.contains("Fae"));
        // Skills appear after personality
        assert!(prompt.contains("Canvas"));
    }

    #[test]
    fn assemble_with_addon() {
        let prompt = assemble_prompt("default", "Be formal.");
        assert!(prompt.starts_with(CORE_PROMPT));
        assert!(prompt.contains("Canvas"));
        assert!(prompt.ends_with("Be formal."));
    }

    #[test]
    fn assemble_fae_with_addon() {
        let prompt = assemble_prompt("fae", "  Be formal.  ");
        assert!(prompt.starts_with(CORE_PROMPT));
        assert!(prompt.contains("Fae"));
        assert!(prompt.contains("Canvas"));
        assert!(prompt.ends_with("Be formal."));
    }

    #[test]
    fn assemble_whitespace_addon_is_skipped() {
        let prompt = assemble_prompt("fae", "   ");
        // Should be same as no add-on
        let no_addon = assemble_prompt("fae", "");
        assert_eq!(prompt, no_addon);
    }

    #[test]
    fn assemble_skills_between_personality_and_addon() {
        let prompt = assemble_prompt("fae", "Be formal.");
        // Verify ordering: personality before skills, skills before add-on
        let fae_pos = prompt.find("Fae");
        let canvas_pos = prompt.find("Canvas");
        let addon_pos = prompt.find("Be formal.");
        assert!(fae_pos.is_some());
        assert!(canvas_pos.is_some());
        assert!(addon_pos.is_some());
        assert!(fae_pos < canvas_pos);
        assert!(canvas_pos < addon_pos);
    }

    #[test]
    fn personalities_dir_is_under_fae() {
        let dir = personalities_dir();
        let dir_str = dir.to_string_lossy();
        assert!(dir_str.contains(".fae"));
        assert!(dir_str.ends_with("personalities"));
    }

    // --- Personality Enhancement Tests ---

    #[test]
    fn fae_personality_contains_identity() {
        let prompt = assemble_prompt("fae", "");
        assert!(prompt.contains("Fae"), "prompt should mention Fae identity");
        assert!(
            prompt.contains("AI assistant"),
            "prompt should mention AI assistant"
        );
    }

    #[test]
    fn fae_personality_contains_tool_instructions() {
        let prompt = assemble_prompt("fae", "");
        assert!(prompt.contains("bash"), "prompt should mention bash tool");
        assert!(
            prompt.contains("read") || prompt.contains("Read"),
            "prompt should mention read tool"
        );
    }

    #[test]
    fn fae_personality_has_response_style() {
        let prompt = assemble_prompt("fae", "");
        assert!(
            prompt.contains("1-3 sentences") || prompt.contains("short"),
            "prompt should specify short responses"
        );
    }

    #[test]
    fn fae_identity_reference_is_nonempty() {
        assert!(
            !FAE_IDENTITY_REFERENCE.is_empty(),
            "full identity reference should not be empty"
        );
        assert!(
            FAE_IDENTITY_REFERENCE.len() > FAE_PERSONALITY.len(),
            "full reference ({} bytes) should be longer than voice-optimized profile ({} bytes)",
            FAE_IDENTITY_REFERENCE.len(),
            FAE_PERSONALITY.len()
        );
    }

    #[test]
    fn fae_personality_is_voice_optimized() {
        assert!(
            FAE_PERSONALITY.len() < 5000,
            "voice-optimized profile should be under 5000 chars, got {}",
            FAE_PERSONALITY.len()
        );
    }
}
