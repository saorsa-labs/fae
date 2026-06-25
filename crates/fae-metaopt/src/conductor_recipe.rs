//! M3 ConductorRecipe mutation surface — BLOCKER-1 denylist (M3-A slice).
//!
//! This module is the eventual home of the M3 `ConductorRecipePatch` data surface
//! (spec §1.1, lands in M3-B). **M3-A ships only the protected-config-key denylist
//! here** (spec §3.1): the [`is_protected_config_key`] predicate plus the key
//! canonicalizer it depends on. No DTOs, no port trait, no daemon wiring — those
//! are M3-B+.
//!
//! ## Why this ships first (BLOCKER-1 — hard precondition)
//!
//! [`crate::optimizer::MetaOptimizer::apply_change`]'s `ConfigAdjustment` arm
//! bounds-checks ONLY the keys in `ConfigBound::all()`; any other key is written
//! verbatim. That is a real latent hole: a hypothesis targeting `model_mode` (or
//! an obfuscated alias) bypasses `ConfigBound` and reaches `write_config`
//! unchecked. It is **not reachable today** — `fae-metaopt` is dormant/unwired
//! (zero refs from `fae-daemon`). It goes live the moment `fae-metaopt` is wired
//! into the daemon, so the denylist MUST exist first (M3 spec §3.1; execution-plan
//! sequencing decision 2026-06-24).
//!
//! The denylist is **general**: it protects any config key controlling egress /
//! safety posture, not only model mode. Future protected keys extend the alias /
//! substring lists without touching the `apply_change` call site. Layer 2 (the M2
//! §5 runtime gate pipeline) remains authoritative regardless — this is the
//! Layer 1 proposal-time closure.

use unicode_normalization::UnicodeNormalization;

/// Canonicalize a config key for protected-key matching (M3 spec §3.1).
///
/// Pipeline: Unicode **NFKC** → split on separators (`-`, `_`, `.`, any
/// whitespace) **and camelCase / acronym boundaries** → lowercase each token →
/// join with a single `_`. This collapses obfuscation variants to one canonical
/// form: `model-mode`, `availability.mode`, `modelMode`, `FAE_MODEL_MODE`, and
/// fullwidth `ｍｏｄｅｌ－ｍｏｄｅ` all reduce to a form containing `model_mode`.
///
/// Boundary rule for an uppercase letter: start a new token when the previous
/// letter is lowercase/digit (camelCase: `modelMode`) OR when the previous
/// letter is uppercase and the next is lowercase (acronym end: `HTMLElement` →
/// `html_element`). Consecutive capitals with no following lowercase stay
/// grouped (`FAE` → `fae`, `MODEL` → `model`) so all-caps runs are not shattered.
///
/// Non-ASCII uppercase is not treated as a boundary: NFKC folds fullwidth /
/// compatibility forms to ASCII, and the protected keys are ASCII, so this is
/// sufficient for the threat model.
pub(crate) fn canonicalize_config_key(key: &str) -> String {
    let nfkc: String = key.nfkc().collect();
    let chars: Vec<char> = nfkc.chars().collect();
    let mut tokens: Vec<String> = Vec::new();
    let mut current = String::new();
    // Last non-separator ORIGINAL char (case preserved). Reset on a separator so a
    // fresh token never inherits a boundary decision from across a separator.
    let mut prev_orig: Option<char> = None;

    for (i, &ch) in chars.iter().enumerate() {
        if ch == '-' || ch == '_' || ch == '.' || ch.is_whitespace() {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
            prev_orig = None;
            continue;
        }
        if ch.is_ascii_uppercase() {
            let prev_was_lower =
                prev_orig.is_some_and(|p| p.is_ascii_lowercase() || p.is_ascii_digit());
            let next_is_lower = chars.get(i + 1).is_some_and(|c| c.is_ascii_lowercase());
            if !current.is_empty() && (prev_was_lower || next_is_lower) {
                tokens.push(std::mem::take(&mut current));
            }
            current.push(ch.to_ascii_lowercase());
        } else {
            current.push(ch.to_ascii_lowercase());
        }
        prev_orig = Some(ch);
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens.join("_")
}

/// Canonical protected-key substrings. Any key whose canonical form CONTAINS one
/// of these is rejected — the broad net. It catches `model_mode` in any position
/// (`fae_model_mode`, `conductor_model_mode`, `my_model_mode_flag`, …) without
/// alias-list growth. Conservative reject is correct for M3 (spec §11 Q2).
const PROTECTED_KEY_SUBSTRINGS: &[&str] = &["model_mode", "availability_mode"];

/// Explicit protected-key aliases (defense-in-depth). All current entries also
/// contain a protected substring, so the substring net already catches them; the
/// list documents intent and is the extension point for future protected keys
/// whose spelling is not a substring match.
const PROTECTED_KEY_ALIASES: &[&str] = &[
    "model_mode",
    "availability_mode",
    "fae_model_mode",
    "conductor_model_mode",
];

/// Is `key` a protected config key that MetaOpt must never write?
///
/// Returns `true` iff the canonicalized key matches a protected alias OR contains
/// a protected substring. Called at the top of the `ConfigAdjustment` arm in
/// [`crate::optimizer::MetaOptimizer::apply_change`] before any bounds lookup or
/// write — a protected key yields
/// [`MetaOptError::ProtectedConfigKey`](crate::types::MetaOptError::ProtectedConfigKey)
/// with no write performed.
///
/// (BLOCKER-1, M3 spec §3.1.)
pub fn is_protected_config_key(key: &str) -> bool {
    let canon = canonicalize_config_key(key);
    PROTECTED_KEY_SUBSTRINGS
        .iter()
        .any(|needle| canon.contains(needle))
        || PROTECTED_KEY_ALIASES.iter().any(|alias| *alias == canon)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── canonicalization ──

    #[test]
    fn canonicalizes_separator_variants_to_one_form() {
        assert_eq!(canonicalize_config_key("model_mode"), "model_mode");
        assert_eq!(canonicalize_config_key("model-mode"), "model_mode");
        assert_eq!(canonicalize_config_key("model.mode"), "model_mode");
        assert_eq!(canonicalize_config_key("model mode"), "model_mode");
        assert_eq!(canonicalize_config_key("modelMode"), "model_mode");
    }

    #[test]
    fn canonicalizes_compound_and_prefixed_keys() {
        assert_eq!(canonicalize_config_key("FAE_MODEL_MODE"), "fae_model_mode");
        assert_eq!(
            canonicalize_config_key("conductorModelMode"),
            "conductor_model_mode"
        );
        assert_eq!(
            canonicalize_config_key("availability.mode"),
            "availability_mode"
        );
        assert_eq!(
            canonicalize_config_key("AvailabilityMode"),
            "availability_mode"
        );
        assert_eq!(
            canonicalize_config_key("memory.maxRecallResults"),
            "memory_max_recall_results"
        );
    }

    #[test]
    fn nfkc_folds_fullwidth_obfuscation() {
        // Fullwidth ASCII (U+FF21–FF5A) NFKC-folds to ASCII, so a fullwidth
        // `ｍｏｄｅｌ－ｍｏｄｅ` collapses to the canonical protected form.
        assert_eq!(
            canonicalize_config_key("ｍｏｄｅｌ－ｍｏｄｅ"),
            "model_mode"
        );
        assert_eq!(
            canonicalize_config_key("ｍｏｄｅｌ＿ｍｏｄｅ"),
            "model_mode"
        );
    }

    #[test]
    fn collapses_repeated_and_mixed_separators() {
        assert_eq!(canonicalize_config_key("model__mode"), "model_mode");
        assert_eq!(canonicalize_config_key("model-.mode"), "model_mode");
        assert_eq!(canonicalize_config_key("model-_mode"), "model_mode");
    }

    #[test]
    fn non_protected_knobs_canonicalize_without_matching() {
        assert_eq!(
            canonicalize_config_key("llm.temperature"),
            "llm_temperature"
        );
        assert_eq!(canonicalize_config_key("llm-top-p"), "llm_top_p");
        assert_eq!(canonicalize_config_key("temperature"), "temperature");
    }

    // ── is_protected_config_key ──

    #[test]
    fn rejects_protected_aliases_and_their_variants() {
        for key in [
            "model_mode",
            "model-mode",
            "model.mode",
            "modelMode",
            "MODEL_MODE",
            "fae_model_mode",
            "FAE-MODEL-MODE",
            "conductor_model_mode",
            "conductorModelMode",
            "availability_mode",
            "availability.mode",
            "AvailabilityMode",
        ] {
            assert!(is_protected_config_key(key), "expected protected: {key:?}");
        }
    }

    #[test]
    fn rejects_substring_occurrences_anywhere() {
        // The substring net catches protected-pattern keys in any position.
        assert!(is_protected_config_key("my_model_mode_flag"));
        assert!(is_protected_config_key(
            "runtime_availability_mode_override"
        ));
        assert!(is_protected_config_key("x.model_mode.y"));
        assert!(is_protected_config_key("setModelModeFor"));
    }

    #[test]
    fn rejects_fullwidth_obfuscated_protected_keys() {
        assert!(is_protected_config_key("ｍｏｄｅｌ－ｍｏｄｅ"));
        assert!(is_protected_config_key("ｍｏｄｅｌ＿ｍｏｄｅ"));
    }

    #[test]
    fn allows_unrelated_knobs() {
        assert!(!is_protected_config_key("llm.temperature"));
        assert!(!is_protected_config_key("memory.maxRecallResults"));
        assert!(!is_protected_config_key("llm-top-p"));
        assert!(!is_protected_config_key("temperature"));
    }

    #[test]
    fn bare_model_without_mode_is_not_protected() {
        // `model` alone (no `_mode`) is not the egress knob — not protected.
        assert!(!is_protected_config_key("model"));
        assert!(!is_protected_config_key("model_name"));
        assert!(!is_protected_config_key("modelPath"));
        assert!(!is_protected_config_key("models"));
    }

    #[test]
    fn empty_key_is_not_protected() {
        assert!(!is_protected_config_key(""));
    }
}
