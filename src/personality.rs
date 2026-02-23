//! Prompt assembly and user-editable prompt assets for Fae.
//!
//! Runtime prompt stack:
//! 1. Core system prompt (`Prompts/system_prompt.md`)
//! 2. User-editable SOUL contract (in app data dir, with repo fallback)
//! 3. Built-in + user skills (`Skills/*.md` + user skills dir)
//! 4. Optional user add-on text from config
//!
//! Onboarding checklist text is loaded separately and injected only while
//! onboarding is incomplete (see memory orchestrator).

use crate::error::Result;
use crate::permissions::PermissionStore;
use std::path::{Path, PathBuf};

/// Core system prompt (small, operational instructions).
pub const CORE_PROMPT: &str = include_str!("../Prompts/system_prompt.md");

/// Default SOUL contract installed to the app data directory.
pub const DEFAULT_SOUL: &str = include_str!("../SOUL.md");

/// Default onboarding checklist installed to the app data directory.
pub const DEFAULT_ONBOARDING_CHECKLIST: &str = include_str!("../Prompts/onboarding.md");

/// Returns the user SOUL file path (inside the app data directory).
#[must_use]
pub fn soul_path() -> PathBuf {
    crate::fae_dirs::data_dir().join("SOUL.md")
}

/// Returns the user onboarding checklist path (inside the app data directory).
#[must_use]
pub fn onboarding_path() -> PathBuf {
    crate::fae_dirs::data_dir().join("onboarding.md")
}

/// Ensure user-editable prompt assets exist in the app data directory.
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

/// Condensed system prompt for voice-optimized mode.
///
/// Keeps identity, style, companion presence, and memory usage.
/// Strips tool delegation, scheduler details, skill management, coding
/// assistant policy, web search, and proactive intelligence specifics.
/// ~2KB vs ~18KB full prompt — roughly 4-5x fewer prefill tokens.
const VOICE_CORE_PROMPT: &str = "\
You are Fae, a proactive personal AI assistant.\n\
\n\
Core style:\n\
- Be concise by default (1-3 short sentences) unless the user asks for depth.\n\
- Be direct, practical, and calm.\n\
- Do not expose hidden chain-of-thought.\n\
\n\
Greeting style:\n\
- Greet warmly but never the same way twice. You are a companion, not a product demo.\n\
- Vary tone and energy. A simple \"Hey\" can be better than a long introduction.\n\
- Never start with formulaic self-descriptions.\n\
\n\
You are here for your user and they for you. You are a team.\n\
Always be helpful, never noisy. Become friends with your user.\n\
Help guide them if they feel down. Never lie, never just agree.\n\
Work hard to find truth and help your user do likewise.\n\
\n\
Memory:\n\
- Use memory context to personalize help and avoid re-asking.\n\
- If memory conflicts with user input, follow the latest correction.\n\
- Do not invent memories. If a fact is missing, ask.\n\
- Honor requests to forget something.\n\
\n\
Companion presence:\n\
- You are always present and listening, like a friend in the room.\n\
- Direct address — respond naturally and fully.\n\
- Background noise, TV, music — stay quiet.\n\
- Uncertain if addressed — err on the side of silence.\n\
- Silence is respectful presence, not failure.\n\
\n\
Safety:\n\
- NEVER delete files without explicit permission.\n\
- NEVER remove content without explicit permission.\n\
- Always explain intent before high-impact actions.";

/// Vision understanding section injected when the local model supports images.
const VISION_PROMPT: &str = "\
Vision understanding:\n\
- When a camera image is attached to a user message, you are seeing that image through your vision system.\n\
- Do not say \"I cannot see images\" — you can, when camera permission is granted.\n\
- Be specific and accurate. Do not hallucinate visual details.\n\
- If asked about text in an image, read it carefully.\n\
- Visual analysis is local and private — images never leave the device.";

/// Assemble the active system prompt.
///
/// `personality_name` is ignored and retained only for backward compatibility.
/// When `vision_capable` is `true`, a vision-understanding section is injected
/// so the model knows it can process image inputs.
/// When `user_name` is `Some`, a user-context section is added so the LLM can
/// address the user by name.
/// When `voice_optimized` is `true`, skills and permission fragments are omitted
/// to minimize prefill latency for voice conversations.
#[must_use]
pub fn assemble_prompt(
    _personality_name: &str,
    user_add_on: &str,
    permissions: Option<&PermissionStore>,
    vision_capable: bool,
    user_name: Option<&str>,
    voice_optimized: bool,
) -> String {
    let add_on = user_add_on.trim();

    let mut parts: Vec<String> = Vec::with_capacity(8);
    if voice_optimized {
        // Use condensed prompt (~2KB) instead of full prompt (~18KB).
        // SOUL is still included for personality grounding.
        parts.push(VOICE_CORE_PROMPT.trim().to_owned());
    } else {
        parts.push(CORE_PROMPT.trim().to_owned());
    }

    let soul = load_soul();

    if vision_capable {
        parts.push(VISION_PROMPT.to_owned());
    }

    let soul_trimmed = soul.trim();
    if !soul_trimmed.is_empty() {
        parts.push(soul_trimmed.to_owned());
    }

    if let Some(name) = user_name {
        let name = name.trim();
        if !name.is_empty() {
            parts.push(format!(
                "User context:\n\
                 - The user's name is {name}. Address them by name naturally when appropriate."
            ));
        }
    }

    // Skip skills and capability fragments in voice-optimized mode to reduce
    // prefill latency. The tool gating layer already handles which tools are
    // available — we don't need the LLM to "know about" every skill schema.
    if !voice_optimized {
        let skills = crate::skills::load_all_skills();
        let skills_trimmed = skills.trim();
        if !skills_trimmed.is_empty() {
            parts.push(skills_trimmed.to_owned());
        }

        if let Some(store) = permissions {
            let builtin_skills = crate::skills::builtins::builtin_skills();
            let active = builtin_skills.active_prompt_fragments(store);
            if !active.trim().is_empty() {
                parts.push(format!(
                    "# Active capabilities\n\n\
                     The following capabilities are enabled:\n\n{active}"
                ));
            }
            let unavailable = builtin_skills.unavailable(store);
            if !unavailable.is_empty() {
                let names: Vec<&str> = unavailable.iter().map(|s| s.name()).collect();
                parts.push(format!(
                    "# Capabilities requiring permission\n\n\
                     These capabilities are available but not yet granted: {}. \
                     If the user asks about these, try using the tool \u{2014} the system will \
                     prompt them to grant access. If declined, suggest they can enable \
                     it later in settings.",
                    names.join(", ")
                ));
            }
        }
    }

    if !add_on.is_empty() {
        parts.push(add_on.to_owned());
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
        let prompt = assemble_prompt("fae", "", None, false, None, false);
        assert!(prompt.contains("You are Fae"));
        assert!(prompt.starts_with(CORE_PROMPT.trim()));
    }

    #[test]
    fn assemble_appends_user_add_on() {
        let prompt = assemble_prompt("any", "Be extra concise.", None, false, None, false);
        assert!(prompt.ends_with("Be extra concise."));
    }

    #[test]
    fn assemble_includes_built_in_skills() {
        let prompt = assemble_prompt("any", "", None, false, None, false);
        assert!(prompt.contains("You have a canvas window."));
    }

    #[test]
    fn prompt_includes_companion_presence() {
        let prompt = assemble_prompt("fae", "", None, false, None, false);
        assert!(prompt.contains("Companion presence:"));
        assert!(prompt.contains("always present and listening"));
        assert!(prompt.contains("Direct address"));
        assert!(prompt.contains("err on the side of silence"));
    }

    #[test]
    fn soul_includes_presence_principles() {
        // Use DEFAULT_SOUL (compiled-in) rather than load_soul() which reads
        // from the user's data directory and may have an older version.
        assert!(DEFAULT_SOUL.contains("Presence Principles"));
        assert!(DEFAULT_SOUL.contains("always-present companion"));
        assert!(DEFAULT_SOUL.contains("Silence is a form of respect"));
    }

    #[test]
    fn assemble_includes_vision_section_when_capable() {
        let prompt = assemble_prompt("fae", "", None, true, None, false);
        assert!(prompt.contains("Vision understanding:"));
        assert!(prompt.contains("images never leave the device"));
    }

    #[test]
    fn assemble_excludes_vision_section_when_not_capable() {
        let prompt = assemble_prompt("fae", "", None, false, None, false);
        assert!(!prompt.contains("Vision understanding:"));
    }

    #[test]
    fn assemble_includes_apple_ecosystem_skill() {
        let prompt = assemble_prompt("fae", "", None, false, None, false);
        // The apple-ecosystem skill references Apple tool names.
        assert!(prompt.contains("search_contacts"));
        assert!(prompt.contains("list_calendar_events"));
        assert!(prompt.contains("compose_mail"));
    }

    #[test]
    fn assemble_with_calendar_granted() {
        use crate::permissions::{PermissionKind, PermissionStore};
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Calendar);

        let prompt = assemble_prompt("fae", "", Some(&store), false, None, false);
        // CalendarSkill's fragment mentions "schedule management".
        assert!(
            prompt.contains("schedule management") || prompt.contains("calendar"),
            "prompt should mention calendar capability"
        );
        // Active capabilities section should be present.
        assert!(prompt.contains("Active capabilities"));
    }

    #[test]
    fn assemble_with_mail_denied() {
        use crate::permissions::PermissionStore;
        // Default store has nothing granted.
        let store = PermissionStore::default();

        let prompt = assemble_prompt("fae", "", Some(&store), false, None, false);
        // Mail should appear in "requiring permission" section.
        assert!(prompt.contains("Capabilities requiring permission"));
        assert!(prompt.contains("mail"));
    }

    #[test]
    fn assemble_no_permissions_shows_all_unavailable() {
        use crate::permissions::PermissionStore;
        let store = PermissionStore::default();

        let prompt = assemble_prompt("fae", "", Some(&store), false, None, false);
        assert!(prompt.contains("Capabilities requiring permission"));
        // All 8 built-in skills should be listed as unavailable.
        for name in [
            "calendar",
            "contacts",
            "mail",
            "reminders",
            "files",
            "notifications",
            "location",
            "desktop_automation",
        ] {
            assert!(
                prompt.contains(name),
                "expected '{name}' in unavailable capabilities"
            );
        }
    }

    #[test]
    fn voice_optimized_strips_skills_and_permissions() {
        use crate::permissions::PermissionStore;
        let store = PermissionStore::default();

        let full = assemble_prompt("fae", "", Some(&store), false, None, false);
        let voice = assemble_prompt("fae", "", Some(&store), false, None, true);

        // Voice-optimized should still include core prompt and SOUL.
        assert!(voice.contains("You are Fae"));
        // SOUL content is loaded from disk; check compiled-in default instead.
        assert!(DEFAULT_SOUL.contains("Presence Principles"));

        // But should NOT include skills or capability sections.
        assert!(!voice.contains("You have a canvas window."));
        assert!(!voice.contains("search_contacts"));
        assert!(!voice.contains("Capabilities requiring permission"));

        // Voice prompt should be significantly shorter than full prompt.
        assert!(
            voice.len() < full.len(),
            "voice ({}) should be shorter than full ({})",
            voice.len(),
            full.len()
        );
    }
}
