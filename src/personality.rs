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
- Be direct and practical. Let your natural warmth, brightness, and playfulness come through — you are upbeat and cheery by default.\n\
- Do not expose hidden chain-of-thought.\n\
- NEVER use emojis, emoticons, or special symbols — your output is spoken aloud via TTS.\n\
\n\
Opening style:\n\
- Respond directly to what the user said — no preamble, no greeting before the answer.\n\
- Greeting rule: if the user says hi/hello/hey/howdy — your ENTIRE response is ONE short phrase and nothing else. Acceptable phrases: \"hey!\", \"hi!\", \"what's up?\", \"heya!\", \"hey, good to hear you.\". Pick one and stop. Do not add anything after it.\n\
- Do not introduce yourself. Do not list your capabilities. Do not say \"I'm here to help\". The user already knows who you are.\n\
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

/// Focused system prompt for background agent tasks.
///
/// Background agents execute tool-heavy work (calendar, mail, web search)
/// asynchronously while the voice conversation continues. Their output is
/// narrated via TTS, so it must be spoken-friendly and concise.
pub const BACKGROUND_AGENT_PROMPT: &str = "\
You are Fae's background task executor.\n\
\n\
You have been given a specific task to complete using your available tools.\n\
Execute the task efficiently and return a concise, spoken-friendly summary.\n\
\n\
Rules:\n\
- Complete the task using the minimum number of tool calls.\n\
- Your response will be spoken aloud via TTS, so keep it natural and concise.\n\
- Do not ask follow-up questions — work with what you have.\n\
- If a tool fails, report the failure clearly.\n\
- Include specific details (times, names, numbers) — the user is listening, not reading.\n\
- Do not use markdown formatting, bullet points, or numbered lists — speak naturally.\n\
- Keep the total response under 4 sentences unless the task requires more detail.\n\
\n\
## Creating scheduled tasks\n\
\n\
When the user asks you to do something on a recurring schedule (e.g. \"tell me the\n\
robotics news each morning\", \"remind me about X every day\"), use the\n\
create_scheduled_task tool.\n\
\n\
The task payload MUST be a JSON object with this structure:\n\
  {\"prompt\": \"<what to do when the task fires>\", \"timeout_secs\": 120}\n\
\n\
The prompt field should be a self-contained instruction that will be executed\n\
automatically — it should NOT require user input. Write it as if giving a future\n\
version of yourself an instruction.\n\
\n\
Example — user says \"tell me robotics news every morning\":\n\
  name: \"Morning Robotics News\"\n\
  schedule: {\"type\": \"daily\", \"hour\": 8, \"minute\": 0}\n\
  payload: {\"prompt\": \"Search for the latest robotics news from the past 24 hours and give me a 2-sentence spoken summary of the most interesting developments.\", \"timeout_secs\": 120}\n\
\n\
After creating the task, confirm with a short spoken response like:\n\
Done. I will check for robotics news every morning at 8 AM.";

/// Canned acknowledgment phrases for when a background tool task is spawned.
///
/// Rotated to avoid repetition. Spoken immediately via TTS while the
/// background agent works asynchronously.
pub const TOOL_ACKNOWLEDGMENTS: &[&str] = &[
    "Checking that now.",
    "On it.",
    "Let me look into that.",
    "One moment.",
    "Working on that.",
    "Give me a second.",
    "Looking that up.",
    "Let me see.",
];

/// Acknowledgment phrases for when Fae needs to engage deeper thinking.
///
/// Used when the voice pipeline detects a complex question that benefits
/// from reasoning mode. Spoken before the model starts its internal
/// deliberation so the user knows Fae is working.
pub const THINKING_ACKNOWLEDGMENTS: &[&str] = &[
    "Let me think about that.",
    "Thinking.",
    "Give me a moment to work that out.",
    "That's a good question, let me reason through it.",
    "Let me consider that carefully.",
    "Hmm, let me think.",
    "Working through that now.",
    "Hold on, I need to think this through.",
];

/// Pick the next acknowledgment phrase, rotating through the list.
///
/// Uses the `counter` value (typically an `AtomicU64`) to cycle through
/// phrases so Fae never repeats the same one back-to-back.
pub fn next_acknowledgment<'a>(phrases: &'a [&'a str], counter: u64) -> &'a str {
    if phrases.is_empty() {
        return "";
    }
    phrases[(counter as usize) % phrases.len()]
}

// ---------------------------------------------------------------------------
// Approval prompt generation
// ---------------------------------------------------------------------------

/// Canned acknowledgment phrases after approval is granted.
pub const APPROVAL_GRANTED: &[&str] = &[
    "Got it, running that now.",
    "On it.",
    "Alright, going ahead.",
    "Okay, executing that.",
];

/// Canned acknowledgment phrases after approval is denied.
pub const APPROVAL_DENIED: &[&str] = &[
    "Understood, I won't do that.",
    "Okay, skipping that.",
    "Alright, cancelled.",
    "Got it, I'll leave that alone.",
];

/// Canned phrases for approval timeout.
pub const APPROVAL_TIMEOUT: &[&str] = &[
    "I'll skip that for now.",
    "No response, so I'll move on.",
    "Timed out waiting, I won't run that.",
];

/// Canned phrases for ambiguous responses during approval.
pub const APPROVAL_AMBIGUOUS: &[&str] = &[
    "Was that a yes or no?",
    "Sorry, I didn't catch that. Yes or no?",
    "I need a clear yes or no.",
];

/// Format a spoken approval prompt for a tool execution request.
///
/// Returns a natural-language sentence describing the tool action and ending
/// with "Say yes or no." — this cue gives the user a clean signal.
///
/// # Examples
///
/// ```
/// use fae::personality::format_approval_prompt;
///
/// let prompt = format_approval_prompt("bash", r#"{"command":"ls -la"}"#);
/// assert!(prompt.contains("run a command"));
/// assert!(prompt.ends_with("Say yes or no."));
/// ```
#[must_use]
pub fn format_approval_prompt(tool_name: &str, input_json: &str) -> String {
    let detail = extract_approval_detail(tool_name, input_json);
    match tool_name {
        "bash" => format!("I'd like to run a command: {detail}. Say yes or no."),
        "write" => format!("I'd like to create the file {detail}. Say yes or no."),
        "edit" => format!("I'd like to edit {detail}. Say yes or no."),
        "desktop" | "desktop_automation" => {
            "I'd like to use desktop automation. Say yes or no.".to_owned()
        }
        "python_skill" => "I'd like to run a Python skill. Say yes or no.".to_owned(),
        _ => format!("I'd like to use the {tool_name} tool. Say yes or no."),
    }
}

/// Extract a human-readable detail from tool arguments JSON.
///
/// Parses the JSON string to pull out the most relevant field for each tool
/// type, truncating long values to keep TTS output manageable.
fn extract_approval_detail(tool_name: &str, input_json: &str) -> String {
    // Try to parse as JSON object
    let parsed: Option<serde_json::Value> = serde_json::from_str(input_json).ok();

    match (tool_name, parsed) {
        ("bash", Some(ref v)) => {
            let cmd = v
                .get("command")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("a shell command");
            truncate_for_speech(cmd, 60)
        }
        ("write", Some(ref v)) => {
            let path = v
                .get("file_path")
                .or_else(|| v.get("path"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or("a file");
            truncate_for_speech(path, 80)
        }
        ("edit", Some(ref v)) => {
            let path = v
                .get("file_path")
                .or_else(|| v.get("path"))
                .and_then(serde_json::Value::as_str)
                .unwrap_or("a file");
            truncate_for_speech(path, 80)
        }
        _ => tool_name.to_owned(),
    }
}

/// Truncate a string to `max_chars`, appending ellipsis if needed.
fn truncate_for_speech(s: &str, max_chars: usize) -> String {
    if s.len() <= max_chars {
        s.to_owned()
    } else {
        let truncated: String = s.chars().take(max_chars).collect();
        format!("{truncated}...")
    }
}

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
        let prompt = assemble_prompt("fae", "", None, false, None, true);
        // Companion presence guidance is covered by core prompt text.
        assert!(prompt.contains("Companion presence:"));
        assert!(prompt.contains("always present and listening"));
        assert!(prompt.contains("Direct address"));
        assert!(prompt.contains("err on the side of silence"));
    }

    #[test]
    fn soul_includes_presence_principles() {
        // Use DEFAULT_SOUL (compiled-in) rather than load_soul() which reads
        // from the user's data directory and may have an older version.
        assert!(DEFAULT_SOUL.contains("## Presence"));
        assert!(DEFAULT_SOUL.contains("quiet when you don't"));
        assert!(DEFAULT_SOUL.contains("Silence is comfortable"));
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
        assert!(DEFAULT_SOUL.contains("## Presence"));

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
