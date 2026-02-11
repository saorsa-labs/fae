//! Voice command detection for runtime model switching.
//!
//! Detects model-switch phrases in user transcriptions before they reach the LLM,
//! enabling hands-free model switching mid-conversation. Users can say things like
//! "Fae, switch to Claude" or "use the local model" and the command will be
//! intercepted and routed to the model switching logic.
//!
//! # Supported Commands
//!
//! | Phrase Pattern | Command |
//! |----------------|---------|
//! | "switch to {model}" | `SwitchModel` |
//! | "use {model}" | `SwitchModel` |
//! | "list models" | `ListModels` |
//! | "what model are you using" | `CurrentModel` |

/// A voice command detected from user speech.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VoiceCommand {
    /// Switch to a different model.
    SwitchModel {
        /// The target model to switch to.
        target: ModelTarget,
    },
    /// List all available models.
    ListModels,
    /// Query which model is currently active.
    CurrentModel,
}

/// Target specification for a model switch command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelTarget {
    /// Switch to a specific model by name (e.g., "gpt-4o").
    ByName(String),
    /// Switch to a model from a specific provider (e.g., "anthropic").
    ByProvider(String),
    /// Switch to the local on-device model.
    Local,
    /// Switch to the best available model (highest tier).
    Best,
}

/// Attempt to parse a transcription as a voice command.
///
/// Returns `Some(VoiceCommand)` if the text matches a known command pattern,
/// or `None` if it looks like normal conversation.
///
/// The parser is case-insensitive, strips an optional "fae" prefix, and
/// recognises common synonyms (e.g. "change to" = "switch to").
///
/// # Examples
///
/// ```
/// use fae::voice_command::{parse_voice_command, VoiceCommand, ModelTarget};
///
/// let cmd = parse_voice_command("switch to claude");
/// assert_eq!(cmd, Some(VoiceCommand::SwitchModel {
///     target: ModelTarget::ByProvider("anthropic".into()),
/// }));
///
/// assert_eq!(parse_voice_command("hello how are you"), None);
/// ```
pub fn parse_voice_command(text: &str) -> Option<VoiceCommand> {
    let text = text.trim().to_lowercase();
    if text.is_empty() {
        return None;
    }

    // Strip optional "fae" / "fae," / "hey fae" prefix.
    let stripped = strip_wake_prefix(&text);

    // --- List models ---
    if matches_any(stripped, &["list models", "show models", "available models", "what models"]) {
        return Some(VoiceCommand::ListModels);
    }

    // --- Current model ---
    if matches_any(
        stripped,
        &[
            "what model",
            "which model",
            "current model",
            "what model are you using",
            "which model are you using",
        ],
    ) {
        return Some(VoiceCommand::CurrentModel);
    }

    // --- Switch model ---
    if let Some(target_str) = extract_switch_target(stripped) {
        let target = parse_model_target(target_str);
        return Some(VoiceCommand::SwitchModel { target });
    }

    None
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Strip optional wake-word prefix ("fae", "hey fae", "fae,").
fn strip_wake_prefix(text: &str) -> &str {
    for prefix in &["hey fae ", "fae, ", "fae "] {
        if let Some(rest) = text.strip_prefix(prefix) {
            return rest.trim();
        }
    }
    text
}

/// Return `true` if `text` starts with any of the given `patterns`.
fn matches_any(text: &str, patterns: &[&str]) -> bool {
    patterns.iter().any(|p| text.starts_with(p))
}

/// Try to extract the model target string from a switch-style command.
///
/// Recognises: "switch to …", "change to …", "use …".
fn extract_switch_target(text: &str) -> Option<&str> {
    for prefix in &["switch to ", "change to ", "swap to "] {
        if let Some(rest) = text.strip_prefix(prefix) {
            let rest = rest.trim_start_matches("the ");
            return Some(rest.trim());
        }
    }
    // "use …" — but not "use the best" vs "use case" ambiguity
    if let Some(rest) = text.strip_prefix("use ") {
        let rest = rest.trim_start_matches("the ");
        // Require the remainder to look model-ish (contains "model", a known
        // provider, or "local"/"best"/"offline").
        if looks_like_model_ref(rest) {
            return Some(rest.trim());
        }
    }
    None
}

/// Heuristic: does `text` look like it refers to a model?
fn looks_like_model_ref(text: &str) -> bool {
    let keywords = [
        "model", "local", "best", "flagship", "offline",
        "claude", "anthropic", "gpt", "openai", "gemini", "google",
        "llama", "qwen", "mistral", "deepseek",
    ];
    keywords.iter().any(|k| text.contains(k))
}

/// Map the raw target text to a [`ModelTarget`] variant.
fn parse_model_target(text: &str) -> ModelTarget {
    let text = text.trim().trim_end_matches(" model").trim_end_matches(" please");

    match text {
        // Local
        "local" | "offline" | "on-device" | "on device" | "fae-qwen3" | "qwen" => {
            ModelTarget::Local
        }
        // Best
        "best" | "flagship" | "top" | "most capable" => ModelTarget::Best,
        // Known providers
        "claude" | "anthropic" => ModelTarget::ByProvider("anthropic".into()),
        "gpt" | "openai" | "chatgpt" => ModelTarget::ByProvider("openai".into()),
        "gemini" | "google" => ModelTarget::ByProvider("google".into()),
        "llama" | "meta" => ModelTarget::ByProvider("meta".into()),
        "mistral" => ModelTarget::ByProvider("mistral".into()),
        "deepseek" => ModelTarget::ByProvider("deepseek".into()),
        // Anything else — treat as model name
        other => ModelTarget::ByName(other.to_owned()),
    }
}

/// The provider key used for the local on-device model.
const LOCAL_PROVIDER: &str = "fae-local";

/// Resolve a [`ModelTarget`] to a candidate index.
///
/// Given a parsed voice-command target and the list of available model
/// candidates (already sorted by tier/priority), return the index of the
/// best matching candidate, or `None` if no candidate matches.
///
/// # Examples
///
/// ```
/// use fae::voice_command::{resolve_model_target, ModelTarget};
/// use fae::model_selection::ProviderModelRef;
///
/// let candidates = vec![
///     ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 0),
///     ProviderModelRef::new("fae-local".into(), "fae-qwen3".into(), 0),
/// ];
/// assert_eq!(resolve_model_target(&ModelTarget::Local, &candidates), Some(1));
/// assert_eq!(resolve_model_target(&ModelTarget::Best, &candidates), Some(0));
/// ```
pub fn resolve_model_target(
    target: &ModelTarget,
    candidates: &[crate::model_selection::ProviderModelRef],
) -> Option<usize> {
    if candidates.is_empty() {
        return None;
    }

    match target {
        ModelTarget::Best => Some(0), // candidates are pre-sorted by tier
        ModelTarget::Local => candidates
            .iter()
            .position(|c| c.provider == LOCAL_PROVIDER),
        ModelTarget::ByProvider(provider) => candidates.iter().position(|c| {
            c.provider.eq_ignore_ascii_case(provider)
        }),
        ModelTarget::ByName(name) => candidates.iter().position(|c| {
            c.model.to_lowercase().contains(&name.to_lowercase())
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // Switch commands
    // -----------------------------------------------------------------------

    #[test]
    fn switch_to_claude() {
        assert_eq!(
            parse_voice_command("switch to claude"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::ByProvider("anthropic".into()),
            })
        );
    }

    #[test]
    fn fae_switch_to_claude() {
        assert_eq!(
            parse_voice_command("fae switch to claude"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::ByProvider("anthropic".into()),
            })
        );
    }

    #[test]
    fn hey_fae_switch_to_openai() {
        assert_eq!(
            parse_voice_command("hey fae switch to openai"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::ByProvider("openai".into()),
            })
        );
    }

    #[test]
    fn use_the_local_model() {
        assert_eq!(
            parse_voice_command("use the local model"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::Local,
            })
        );
    }

    #[test]
    fn switch_to_gpt_4o() {
        assert_eq!(
            parse_voice_command("switch to gpt-4o"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::ByName("gpt-4o".into()),
            })
        );
    }

    #[test]
    fn use_the_best_model() {
        assert_eq!(
            parse_voice_command("use the best model"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::Best,
            })
        );
    }

    #[test]
    fn switch_to_flagship() {
        assert_eq!(
            parse_voice_command("switch to the flagship model"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::Best,
            })
        );
    }

    #[test]
    fn change_to_gemini() {
        assert_eq!(
            parse_voice_command("change to gemini"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::ByProvider("google".into()),
            })
        );
    }

    #[test]
    fn case_insensitive() {
        assert_eq!(
            parse_voice_command("FAE SWITCH TO CLAUDE"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::ByProvider("anthropic".into()),
            })
        );
    }

    #[test]
    fn switch_to_local_offline() {
        assert_eq!(
            parse_voice_command("switch to offline"),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::Local,
            })
        );
    }

    // -----------------------------------------------------------------------
    // Query commands
    // -----------------------------------------------------------------------

    #[test]
    fn what_model_are_you_using() {
        assert_eq!(
            parse_voice_command("what model are you using"),
            Some(VoiceCommand::CurrentModel)
        );
    }

    #[test]
    fn which_model() {
        assert_eq!(
            parse_voice_command("which model are you using"),
            Some(VoiceCommand::CurrentModel)
        );
    }

    #[test]
    fn current_model() {
        assert_eq!(
            parse_voice_command("current model"),
            Some(VoiceCommand::CurrentModel)
        );
    }

    #[test]
    fn list_models() {
        assert_eq!(
            parse_voice_command("list models"),
            Some(VoiceCommand::ListModels)
        );
    }

    #[test]
    fn show_models() {
        assert_eq!(
            parse_voice_command("show models"),
            Some(VoiceCommand::ListModels)
        );
    }

    #[test]
    fn fae_list_models() {
        assert_eq!(
            parse_voice_command("fae, list models"),
            Some(VoiceCommand::ListModels)
        );
    }

    // -----------------------------------------------------------------------
    // Non-commands (must return None)
    // -----------------------------------------------------------------------

    #[test]
    fn normal_conversation() {
        assert_eq!(parse_voice_command("hello how are you"), None);
    }

    #[test]
    fn empty_string() {
        assert_eq!(parse_voice_command(""), None);
    }

    #[test]
    fn whitespace_only() {
        assert_eq!(parse_voice_command("   "), None);
    }

    #[test]
    fn ambiguous_use() {
        // "use" without a model-ish target should not trigger
        assert_eq!(parse_voice_command("use the bathroom"), None);
    }

    // -----------------------------------------------------------------------
    // resolve_model_target
    // -----------------------------------------------------------------------

    fn test_candidates() -> Vec<crate::model_selection::ProviderModelRef> {
        vec![
            crate::model_selection::ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10),
            crate::model_selection::ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),
            crate::model_selection::ProviderModelRef::new("google".into(), "gemini-2.5-flash".into(), 0),
            crate::model_selection::ProviderModelRef::new("fae-local".into(), "fae-qwen3".into(), 0),
        ]
    }

    #[test]
    fn resolve_best() {
        let c = test_candidates();
        assert_eq!(resolve_model_target(&ModelTarget::Best, &c), Some(0));
    }

    #[test]
    fn resolve_local() {
        let c = test_candidates();
        assert_eq!(resolve_model_target(&ModelTarget::Local, &c), Some(3));
    }

    #[test]
    fn resolve_by_provider() {
        let c = test_candidates();
        assert_eq!(
            resolve_model_target(&ModelTarget::ByProvider("openai".into()), &c),
            Some(1)
        );
    }

    #[test]
    fn resolve_by_provider_case_insensitive() {
        let c = test_candidates();
        assert_eq!(
            resolve_model_target(&ModelTarget::ByProvider("Anthropic".into()), &c),
            Some(0)
        );
    }

    #[test]
    fn resolve_by_name_partial() {
        let c = test_candidates();
        assert_eq!(
            resolve_model_target(&ModelTarget::ByName("opus".into()), &c),
            Some(0)
        );
    }

    #[test]
    fn resolve_by_name_full() {
        let c = test_candidates();
        assert_eq!(
            resolve_model_target(&ModelTarget::ByName("gpt-4o".into()), &c),
            Some(1)
        );
    }

    #[test]
    fn resolve_no_match() {
        let c = test_candidates();
        assert_eq!(
            resolve_model_target(&ModelTarget::ByName("nonexistent-model".into()), &c),
            None
        );
    }

    #[test]
    fn resolve_empty_candidates() {
        assert_eq!(
            resolve_model_target(&ModelTarget::Best, &[]),
            None
        );
    }
}
