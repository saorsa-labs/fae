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
    /// Request help with model switching commands.
    Help,
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

    // --- Help ---
    if matches_any(
        stripped,
        &[
            "help",
            "help me",
            "what can i say",
            "what can you do",
            "model commands",
            "model help",
        ],
    ) {
        return Some(VoiceCommand::Help);
    }

    // --- List models ---
    if matches_any(
        stripped,
        &[
            "list models",
            "show models",
            "available models",
            "what models",
        ],
    ) {
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
        "model",
        "local",
        "best",
        "flagship",
        "offline",
        "claude",
        "anthropic",
        "gpt",
        "openai",
        "gemini",
        "google",
        "llama",
        "qwen",
        "mistral",
        "deepseek",
    ];
    keywords.iter().any(|k| text.contains(k))
}

/// Map the raw target text to a [`ModelTarget`] variant.
fn parse_model_target(text: &str) -> ModelTarget {
    let text = text
        .trim()
        .trim_end_matches(" model")
        .trim_end_matches(" please");

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
        ModelTarget::Local => candidates.iter().position(|c| c.provider == LOCAL_PROVIDER),
        ModelTarget::ByProvider(provider) => candidates
            .iter()
            .position(|c| c.provider.eq_ignore_ascii_case(provider)),
        ModelTarget::ByName(name) => candidates
            .iter()
            .position(|c| c.model.to_lowercase().contains(&name.to_lowercase())),
    }
}

// ---------------------------------------------------------------------------
// TTS acknowledgment helpers
// ---------------------------------------------------------------------------

/// Acknowledgment for a successful model switch.
pub fn switch_acknowledgment(model_name: &str) -> String {
    format!("Switching to {model_name}.")
}

/// Acknowledgment when the requested model is already active.
pub fn already_using_acknowledgment(model_name: &str) -> String {
    format!("I'm already using {model_name}.")
}

/// Response when the requested model cannot be found.
pub fn model_not_found_response(target: &str) -> String {
    format!("I couldn't find a model matching {target}.")
}

/// Response listing all available models and the current one.
pub fn list_models_response(models: &[String], current_idx: usize) -> String {
    if models.is_empty() {
        return "I don't have any models configured.".to_owned();
    }
    let list = models.join(", ");
    let current = models
        .get(current_idx)
        .map_or("unknown", |s| s.as_str());
    format!("I have access to {list}. Currently using {current}.")
}

/// Response stating which model is currently active.
pub fn current_model_response(model_name: &str) -> String {
    format!("I'm currently using {model_name}.")
}

/// Help response listing available model switching commands.
pub fn help_response() -> String {
    "You can say: switch to Claude, use the local model, list models, or what model are you using.".to_owned()
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

    #[test]
    fn help_command() {
        assert_eq!(parse_voice_command("help"), Some(VoiceCommand::Help));
    }

    #[test]
    fn help_me() {
        assert_eq!(
            parse_voice_command("help me"),
            Some(VoiceCommand::Help)
        );
    }

    #[test]
    fn what_can_i_say() {
        assert_eq!(
            parse_voice_command("what can i say"),
            Some(VoiceCommand::Help)
        );
    }

    #[test]
    fn model_commands() {
        assert_eq!(
            parse_voice_command("model commands"),
            Some(VoiceCommand::Help)
        );
    }

    #[test]
    fn fae_help() {
        assert_eq!(
            parse_voice_command("fae, help"),
            Some(VoiceCommand::Help)
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
            crate::model_selection::ProviderModelRef::new(
                "anthropic".into(),
                "claude-opus-4".into(),
                10,
            ),
            crate::model_selection::ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),
            crate::model_selection::ProviderModelRef::new(
                "google".into(),
                "gemini-2.5-flash".into(),
                0,
            ),
            crate::model_selection::ProviderModelRef::new(
                "fae-local".into(),
                "fae-qwen3".into(),
                0,
            ),
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
        assert_eq!(resolve_model_target(&ModelTarget::Best, &[]), None);
    }

    // -----------------------------------------------------------------------
    // Integration: parse → resolve end-to-end
    // -----------------------------------------------------------------------

    /// Parse a voice command then resolve it against real candidates.
    fn parse_and_resolve(text: &str) -> Option<usize> {
        let cmd = parse_voice_command(text)?;
        match cmd {
            VoiceCommand::SwitchModel { target } => {
                resolve_model_target(&target, &test_candidates())
            }
            _ => None,
        }
    }

    #[test]
    fn end_to_end_switch_to_claude_resolves() {
        assert_eq!(parse_and_resolve("switch to claude"), Some(0));
    }

    #[test]
    fn end_to_end_switch_to_openai_resolves() {
        assert_eq!(parse_and_resolve("fae switch to openai"), Some(1));
    }

    #[test]
    fn end_to_end_switch_to_local_resolves() {
        assert_eq!(parse_and_resolve("use the local model"), Some(3));
    }

    #[test]
    fn end_to_end_switch_to_best_resolves() {
        assert_eq!(parse_and_resolve("switch to the best model"), Some(0));
    }

    #[test]
    fn end_to_end_switch_by_name_partial() {
        // "gemini" resolves by provider
        assert_eq!(parse_and_resolve("change to gemini"), Some(2));
    }

    #[test]
    fn end_to_end_switch_by_model_name() {
        assert_eq!(parse_and_resolve("switch to gpt-4o"), Some(1));
    }

    #[test]
    fn end_to_end_non_command_returns_none() {
        assert_eq!(parse_and_resolve("hello how are you"), None);
    }

    #[test]
    fn end_to_end_list_models_not_switch() {
        // ListModels should not resolve to a candidate index
        let cmd = parse_voice_command("list models");
        assert_eq!(cmd, Some(VoiceCommand::ListModels));
        // parse_and_resolve returns None for non-switch commands
        assert_eq!(parse_and_resolve("list models"), None);
    }

    #[test]
    fn end_to_end_current_model_not_switch() {
        assert_eq!(
            parse_voice_command("what model are you using"),
            Some(VoiceCommand::CurrentModel)
        );
        assert_eq!(parse_and_resolve("what model are you using"), None);
    }

    // -----------------------------------------------------------------------
    // Edge cases
    // -----------------------------------------------------------------------

    #[test]
    fn very_long_input_no_crash() {
        let long = "a ".repeat(10_000);
        assert_eq!(parse_voice_command(&long), None);
    }

    #[test]
    fn unicode_input_no_crash() {
        assert_eq!(parse_voice_command("切り替えてクロード"), None);
    }

    #[test]
    fn numbers_only() {
        assert_eq!(parse_voice_command("12345"), None);
    }

    #[test]
    fn switch_with_extra_whitespace() {
        assert_eq!(
            parse_voice_command("  switch to claude  "),
            Some(VoiceCommand::SwitchModel {
                target: ModelTarget::ByProvider("anthropic".into()),
            })
        );
    }

    #[test]
    fn multiple_synonyms_same_result() {
        let expected = Some(VoiceCommand::SwitchModel {
            target: ModelTarget::ByProvider("anthropic".into()),
        });
        assert_eq!(parse_voice_command("switch to claude"), expected);
        assert_eq!(parse_voice_command("change to claude"), expected);
        assert_eq!(parse_voice_command("fae switch to anthropic"), expected);
    }

    // -----------------------------------------------------------------------
    // TTS acknowledgment helpers
    // -----------------------------------------------------------------------

    #[test]
    fn switch_acknowledgment_formats_correctly() {
        assert_eq!(
            switch_acknowledgment("openai/gpt-4o"),
            "Switching to openai/gpt-4o."
        );
    }

    #[test]
    fn already_using_acknowledgment_formats_correctly() {
        assert_eq!(
            already_using_acknowledgment("anthropic/claude-opus-4"),
            "I'm already using anthropic/claude-opus-4."
        );
    }

    #[test]
    fn model_not_found_response_formats_correctly() {
        assert_eq!(
            model_not_found_response("gemini"),
            "I couldn't find a model matching gemini."
        );
    }

    #[test]
    fn list_models_response_multiple_models() {
        let models = vec![
            "anthropic/claude-opus-4".to_owned(),
            "openai/gpt-4o".to_owned(),
        ];
        let response = list_models_response(&models, 0);
        assert!(response.contains("anthropic/claude-opus-4, openai/gpt-4o"));
        assert!(response.contains("Currently using anthropic/claude-opus-4"));
    }

    #[test]
    fn list_models_response_empty() {
        let response = list_models_response(&[], 0);
        assert_eq!(response, "I don't have any models configured.");
    }

    #[test]
    fn current_model_response_formats_correctly() {
        assert_eq!(
            current_model_response("local/qwen3-4b"),
            "I'm currently using local/qwen3-4b."
        );
    }

    #[test]
    fn help_response_lists_commands() {
        let response = help_response();
        assert!(response.contains("switch to"));
        assert!(response.contains("local model"));
        assert!(response.contains("list models"));
        assert!(response.contains("what model"));
    }

    // -----------------------------------------------------------------------
    // End-to-end integration: parse → resolve → switch/query
    // -----------------------------------------------------------------------

    #[test]
    fn e2e_switch_to_claude_changes_active_model() {
        use crate::model_selection::ProviderModelRef;
        use crate::pi::engine::PiLlm;

        let candidates = vec![
            ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10),
        ];
        let (mut pi, _rx) = PiLlm::test_instance(candidates);

        // Parse voice input.
        let cmd = parse_voice_command("switch to claude").expect("should parse");
        let target = match &cmd {
            VoiceCommand::SwitchModel { target } => target,
            _ => panic!("expected SwitchModel"),
        };

        // Execute switch.
        let result = pi.switch_model_by_voice(target);
        assert!(result.is_ok(), "got err: {result:?}");
        assert_eq!(pi.active_model_index(), 1);
        assert_eq!(pi.current_model_name(), "anthropic/claude-opus-4");
    }

    #[test]
    fn e2e_what_model_produces_current_response() {
        use crate::model_selection::ProviderModelRef;
        use crate::pi::engine::PiLlm;

        let candidates = vec![
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10),
        ];
        let (pi, _rx) = PiLlm::test_instance(candidates);

        let cmd = parse_voice_command("what model are you using").expect("should parse");
        assert_eq!(cmd, VoiceCommand::CurrentModel);

        let response = current_model_response(&pi.current_model_name());
        assert!(response.contains("anthropic/claude-opus-4"), "got: {response}");
    }

    #[test]
    fn e2e_list_models_returns_all_candidates() {
        use crate::model_selection::ProviderModelRef;
        use crate::pi::engine::PiLlm;

        let candidates = vec![
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10),
            ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),
            ProviderModelRef::new("local".into(), "qwen3-4b".into(), 0),
        ];
        let (pi, _rx) = PiLlm::test_instance(candidates);

        let cmd = parse_voice_command("list models").expect("should parse");
        assert_eq!(cmd, VoiceCommand::ListModels);

        let names = pi.list_model_names();
        let response = list_models_response(&names, pi.active_model_index());
        assert!(response.contains("anthropic/claude-opus-4"), "got: {response}");
        assert!(response.contains("openai/gpt-4o"), "got: {response}");
        assert!(response.contains("local/qwen3-4b"), "got: {response}");
        assert!(response.contains("Currently using anthropic/claude-opus-4"), "got: {response}");
    }
}
