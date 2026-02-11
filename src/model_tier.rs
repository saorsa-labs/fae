//! Model tier registry for classifying LLM models by capability.
//!
//! Provides an embedded static tier list that maps known model IDs to
//! capability tiers. This is used to auto-select the best available model
//! at startup and to sort failover candidates intelligently.
//!
//! # Tier Hierarchy
//!
//! | Tier | Description | Examples |
//! |------|-------------|---------|
//! | `Flagship` | Top-tier flagship models | Claude Opus, GPT-4o, O3 |
//! | `Strong` | High-capability models | Claude Sonnet, Gemini Flash, Llama 405B |
//! | `Mid` | Mid-range models | Claude Haiku, GPT-4o-mini, Llama 70B |
//! | `Small` | Lightweight / local models | Qwen3-4B, Gemma, fae-qwen3 |
//! | `Unknown` | Unrecognised model IDs | Falls to lowest priority |
//!
//! # Examples
//!
//! ```
//! use fae::model_tier::{tier_for_model, tier_for_provider_model, ModelTier};
//!
//! assert_eq!(tier_for_model("claude-opus-4-20250514"), ModelTier::Flagship);
//! assert_eq!(tier_for_model("gpt-4o-mini"), ModelTier::Mid);
//! assert_eq!(tier_for_model("fae-qwen3"), ModelTier::Small);
//! assert_eq!(tier_for_model("totally-unknown-model"), ModelTier::Unknown);
//!
//! // Provider context can refine the result:
//! assert_eq!(
//!     tier_for_provider_model("fae-local", "fae-qwen3"),
//!     ModelTier::Small,
//! );
//! ```

use std::fmt;

// ---------------------------------------------------------------------------
// ModelTier enum
// ---------------------------------------------------------------------------

/// Capability tier for a language model.
///
/// Variants are ordered from most capable (`Flagship`) to least capable
/// (`Unknown`), so derived `Ord` gives the correct sort order for
/// "best model first" ranking.
///
/// # Examples
///
/// ```
/// use fae::model_tier::ModelTier;
///
/// // Flagship sorts before Strong:
/// assert!(ModelTier::Flagship < ModelTier::Strong);
/// assert_eq!(ModelTier::Flagship.rank(), 0);
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ModelTier {
    /// Top-tier flagship models (Claude Opus, GPT-4o, O-series reasoning).
    Flagship,
    /// High-capability models (Claude Sonnet, Gemini Flash, Llama 405B).
    Strong,
    /// Mid-range models (Claude Haiku, GPT-4o-mini, Llama 70B).
    Mid,
    /// Lightweight or local models (Qwen3-4B, Gemma, fae-qwen3).
    Small,
    /// Unrecognised model — defaults to lowest selection priority.
    Unknown,
}

impl ModelTier {
    /// Numeric rank where lower is better.
    ///
    /// | Tier | Rank |
    /// |------|------|
    /// | `Flagship` | 0 |
    /// | `Strong` | 1 |
    /// | `Mid` | 2 |
    /// | `Small` | 3 |
    /// | `Unknown` | 4 |
    ///
    /// # Examples
    ///
    /// ```
    /// use fae::model_tier::ModelTier;
    /// assert_eq!(ModelTier::Flagship.rank(), 0);
    /// assert_eq!(ModelTier::Unknown.rank(), 4);
    /// ```
    #[must_use]
    pub fn rank(&self) -> u8 {
        match self {
            Self::Flagship => 0,
            Self::Strong => 1,
            Self::Mid => 2,
            Self::Small => 3,
            Self::Unknown => 4,
        }
    }
}

impl fmt::Display for ModelTier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::Flagship => "flagship",
            Self::Strong => "strong",
            Self::Mid => "mid",
            Self::Small => "small",
            Self::Unknown => "unknown",
        };
        f.write_str(label)
    }
}

// ---------------------------------------------------------------------------
// Tier table
// ---------------------------------------------------------------------------

/// A single entry mapping a model-ID pattern to a tier.
struct TierEntry {
    pattern: &'static str,
    tier: ModelTier,
}

/// Provider-specific override (checked before the generic table).
struct ProviderOverride {
    provider: &'static str,
    pattern: &'static str,
    tier: ModelTier,
}

/// Provider-specific overrides — checked first.
static PROVIDER_OVERRIDES: &[ProviderOverride] = &[ProviderOverride {
    provider: "fae-local",
    pattern: "fae-qwen3",
    tier: ModelTier::Small,
}];

/// Static tier table ordered from most-specific to least-specific within
/// each tier. **Order matters** — the first match wins, so narrower
/// patterns (e.g. `gpt-4o-mini*`) must precede broader ones (`gpt-4o*`).
static TIER_TABLE: &[TierEntry] = &[
    // ── Flagship ──────────────────────────────────────────────
    TierEntry {
        pattern: "claude-opus-*",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "claude-4-opus*",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "o1-*",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "o3-*",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "o1",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "o3",
        tier: ModelTier::Flagship,
    },
    // gpt-4o-mini must be matched BEFORE gpt-4o
    TierEntry {
        pattern: "gpt-4o-mini*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "gpt-4o*",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "gpt-4-turbo*",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "gemini-*-pro",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "gemini-*-pro-*",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "gemini-ultra*",
        tier: ModelTier::Flagship,
    },
    TierEntry {
        pattern: "deepseek-r1*",
        tier: ModelTier::Flagship,
    },
    // ── Strong ────────────────────────────────────────────────
    TierEntry {
        pattern: "claude-sonnet-*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "claude-4-sonnet*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "claude-3-5-sonnet*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "claude-3-sonnet*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "gpt-4",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "gpt-4-0*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "gpt-4-1*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "gemini-*-flash*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "llama-3*-405b*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "llama-3.1-405b*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "qwen3-235b*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "command-r-plus*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "mistral-large*",
        tier: ModelTier::Strong,
    },
    TierEntry {
        pattern: "deepseek-v3*",
        tier: ModelTier::Strong,
    },
    // ── Mid ───────────────────────────────────────────────────
    TierEntry {
        pattern: "claude-haiku-*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "claude-3-5-haiku*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "claude-3-haiku*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "gpt-3.5*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "llama-3*-70b*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "llama-3.1-70b*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "qwen3-32b*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "qwen3-14b*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "mixtral*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "command-r",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "command-r-*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "phi-4*",
        tier: ModelTier::Mid,
    },
    TierEntry {
        pattern: "mistral-medium*",
        tier: ModelTier::Mid,
    },
    // ── Small ─────────────────────────────────────────────────
    TierEntry {
        pattern: "llama-3*-8b*",
        tier: ModelTier::Small,
    },
    TierEntry {
        pattern: "llama-3.2-*b*",
        tier: ModelTier::Small,
    },
    TierEntry {
        pattern: "qwen3-4b*",
        tier: ModelTier::Small,
    },
    TierEntry {
        pattern: "qwen3-1.7b*",
        tier: ModelTier::Small,
    },
    TierEntry {
        pattern: "qwen3-0.6b*",
        tier: ModelTier::Small,
    },
    TierEntry {
        pattern: "phi-3-mini*",
        tier: ModelTier::Small,
    },
    TierEntry {
        pattern: "phi-3*",
        tier: ModelTier::Small,
    },
    TierEntry {
        pattern: "gemma-*",
        tier: ModelTier::Small,
    },
    TierEntry {
        pattern: "mistral-7b*",
        tier: ModelTier::Small,
    },
    TierEntry {
        pattern: "fae-qwen3",
        tier: ModelTier::Small,
    },
];

// ---------------------------------------------------------------------------
// Pattern matching
// ---------------------------------------------------------------------------

/// Normalise a model ID for comparison: lowercase and trimmed.
fn normalize_model_id(id: &str) -> String {
    id.trim().to_lowercase()
}

/// Check whether `model_id` matches a glob-style `pattern`.
///
/// Supported patterns:
/// - `"exact"` — exact equality
/// - `"prefix*"` — starts-with
/// - `"*suffix"` — ends-with
/// - `"a*b*c"` — multiple wildcards (each `*` matches zero or more chars)
fn matches_pattern(model_id: &str, pattern: &str) -> bool {
    let model_id = normalize_model_id(model_id);
    let pattern = pattern.trim().to_lowercase();

    if !pattern.contains('*') {
        return model_id == pattern;
    }

    let segments: Vec<&str> = pattern.split('*').collect();
    let mut remaining = model_id.as_str();

    for (i, segment) in segments.iter().enumerate() {
        if segment.is_empty() {
            continue;
        }

        if i == 0 {
            // First segment must be a prefix.
            if !remaining.starts_with(segment) {
                return false;
            }
            remaining = &remaining[segment.len()..];
        } else if i == segments.len() - 1 {
            // Last segment must be a suffix of whatever remains.
            if !remaining.ends_with(segment) {
                return false;
            }
        } else {
            // Middle segments must appear in order.
            match remaining.find(segment) {
                Some(pos) => remaining = &remaining[pos + segment.len()..],
                None => return false,
            }
        }
    }

    true
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Look up the capability tier for a model ID.
///
/// The lookup is case-insensitive and uses glob-style pattern matching
/// against an embedded tier table. Returns [`ModelTier::Unknown`] when no
/// pattern matches.
///
/// # Examples
///
/// ```
/// use fae::model_tier::{tier_for_model, ModelTier};
///
/// assert_eq!(tier_for_model("claude-opus-4-20250514"), ModelTier::Flagship);
/// assert_eq!(tier_for_model("gpt-4o-mini"), ModelTier::Mid);
/// assert_eq!(tier_for_model("some-custom-model"), ModelTier::Unknown);
/// ```
#[must_use]
pub fn tier_for_model(model_id: &str) -> ModelTier {
    let normalised = normalize_model_id(model_id);

    for entry in TIER_TABLE {
        if matches_pattern(&normalised, entry.pattern) {
            return entry.tier;
        }
    }

    ModelTier::Unknown
}

/// Look up the capability tier using both provider and model ID.
///
/// Provider-specific overrides are checked first (e.g. `fae-local` models
/// are always [`ModelTier::Small`]). Falls back to [`tier_for_model`] for
/// generic ID-based lookup.
///
/// # Examples
///
/// ```
/// use fae::model_tier::{tier_for_provider_model, ModelTier};
///
/// assert_eq!(
///     tier_for_provider_model("fae-local", "fae-qwen3"),
///     ModelTier::Small,
/// );
/// assert_eq!(
///     tier_for_provider_model("anthropic", "claude-opus-4-20250514"),
///     ModelTier::Flagship,
/// );
/// ```
#[must_use]
pub fn tier_for_provider_model(provider: &str, model_id: &str) -> ModelTier {
    let norm_provider = provider.trim().to_lowercase();
    let norm_model = normalize_model_id(model_id);

    for ov in PROVIDER_OVERRIDES {
        if norm_provider == ov.provider && matches_pattern(&norm_model, ov.pattern) {
            return ov.tier;
        }
    }

    tier_for_model(&norm_model)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    // ── ModelTier enum ────────────────────────────────────────

    #[test]
    fn test_tier_ordering() {
        assert!(ModelTier::Flagship < ModelTier::Strong);
        assert!(ModelTier::Strong < ModelTier::Mid);
        assert!(ModelTier::Mid < ModelTier::Small);
        assert!(ModelTier::Small < ModelTier::Unknown);
    }

    #[test]
    fn test_tier_display() {
        assert_eq!(ModelTier::Flagship.to_string(), "flagship");
        assert_eq!(ModelTier::Strong.to_string(), "strong");
        assert_eq!(ModelTier::Mid.to_string(), "mid");
        assert_eq!(ModelTier::Small.to_string(), "small");
        assert_eq!(ModelTier::Unknown.to_string(), "unknown");
    }

    #[test]
    fn test_tier_rank() {
        assert_eq!(ModelTier::Flagship.rank(), 0);
        assert_eq!(ModelTier::Strong.rank(), 1);
        assert_eq!(ModelTier::Mid.rank(), 2);
        assert_eq!(ModelTier::Small.rank(), 3);
        assert_eq!(ModelTier::Unknown.rank(), 4);
    }

    #[test]
    fn test_tier_clone_copy() {
        let tier = ModelTier::Flagship;
        let cloned = tier;
        assert_eq!(tier, cloned);
    }

    // ── Pattern matching ──────────────────────────────────────

    #[test]
    fn test_exact_match() {
        assert!(matches_pattern("gpt-4o", "gpt-4o"));
        assert!(!matches_pattern("gpt-4o-mini", "gpt-4o"));
    }

    #[test]
    fn test_prefix_match() {
        assert!(matches_pattern("claude-opus-4-20250514", "claude-opus-*"));
        assert!(matches_pattern("claude-opus-4", "claude-opus-*"));
        assert!(!matches_pattern("claude-sonnet-4", "claude-opus-*"));
    }

    #[test]
    fn test_suffix_match() {
        assert!(matches_pattern("qwen3-4b-instruct", "*-instruct"));
        assert!(!matches_pattern("qwen3-4b", "*-instruct"));
    }

    #[test]
    fn test_contains_match() {
        assert!(matches_pattern("gemini-2.0-pro-exp", "gemini-*-pro-*"));
        assert!(!matches_pattern("gemini-2.0-flash-exp", "gemini-*-pro-*"));
    }

    #[test]
    fn test_case_insensitive() {
        assert!(matches_pattern("GPT-4o", "gpt-4o"));
        assert!(matches_pattern("Claude-Opus-4", "claude-opus-*"));
    }

    // ── tier_for_model ────────────────────────────────────────

    #[test]
    fn test_flagship_models() {
        assert_eq!(
            tier_for_model("claude-opus-4-20250514"),
            ModelTier::Flagship
        );
        assert_eq!(tier_for_model("gpt-4o"), ModelTier::Flagship);
        assert_eq!(tier_for_model("gpt-4o-2024-11-20"), ModelTier::Flagship);
        assert_eq!(tier_for_model("gpt-4-turbo"), ModelTier::Flagship);
        assert_eq!(tier_for_model("o1-preview"), ModelTier::Flagship);
        assert_eq!(tier_for_model("o3-mini"), ModelTier::Flagship);
        assert_eq!(tier_for_model("deepseek-r1"), ModelTier::Flagship);
    }

    #[test]
    fn test_strong_models() {
        assert_eq!(
            tier_for_model("claude-sonnet-4-20250514"),
            ModelTier::Strong
        );
        assert_eq!(
            tier_for_model("claude-3-5-sonnet-20241022"),
            ModelTier::Strong
        );
        assert_eq!(tier_for_model("gpt-4"), ModelTier::Strong);
        assert_eq!(tier_for_model("gemini-2.0-flash"), ModelTier::Strong);
        assert_eq!(
            tier_for_model("gemini-2.0-flash-thinking-exp"),
            ModelTier::Strong
        );
        assert_eq!(tier_for_model("mistral-large-latest"), ModelTier::Strong);
        assert_eq!(tier_for_model("deepseek-v3"), ModelTier::Strong);
    }

    #[test]
    fn test_mid_models() {
        assert_eq!(tier_for_model("gpt-4o-mini"), ModelTier::Mid);
        assert_eq!(tier_for_model("gpt-4o-mini-2024-07-18"), ModelTier::Mid);
        assert_eq!(tier_for_model("claude-haiku-3-20240307"), ModelTier::Mid);
        assert_eq!(tier_for_model("claude-3-5-haiku-20241022"), ModelTier::Mid);
        assert_eq!(tier_for_model("gpt-3.5-turbo"), ModelTier::Mid);
        assert_eq!(tier_for_model("llama-3.1-70b-instruct"), ModelTier::Mid);
        assert_eq!(tier_for_model("qwen3-32b"), ModelTier::Mid);
        assert_eq!(tier_for_model("phi-4"), ModelTier::Mid);
    }

    #[test]
    fn test_small_models() {
        assert_eq!(tier_for_model("llama-3.2-8b"), ModelTier::Small);
        assert_eq!(tier_for_model("qwen3-4b-instruct"), ModelTier::Small);
        assert_eq!(tier_for_model("phi-3-mini-4k"), ModelTier::Small);
        assert_eq!(tier_for_model("gemma-2b"), ModelTier::Small);
        assert_eq!(tier_for_model("fae-qwen3"), ModelTier::Small);
        assert_eq!(tier_for_model("mistral-7b-instruct"), ModelTier::Small);
    }

    #[test]
    fn test_unknown_models() {
        assert_eq!(tier_for_model("totally-custom-model"), ModelTier::Unknown);
        assert_eq!(tier_for_model("my-finetuned-llm"), ModelTier::Unknown);
        assert_eq!(tier_for_model(""), ModelTier::Unknown);
    }

    // ── tier_for_provider_model ───────────────────────────────

    #[test]
    fn test_provider_override() {
        assert_eq!(
            tier_for_provider_model("fae-local", "fae-qwen3"),
            ModelTier::Small,
        );
    }

    #[test]
    fn test_provider_fallback_to_generic() {
        assert_eq!(
            tier_for_provider_model("anthropic", "claude-opus-4-20250514"),
            ModelTier::Flagship,
        );
        assert_eq!(
            tier_for_provider_model("openai", "gpt-4o"),
            ModelTier::Flagship,
        );
    }

    #[test]
    fn test_provider_case_insensitive() {
        assert_eq!(
            tier_for_provider_model("FAE-LOCAL", "fae-qwen3"),
            ModelTier::Small,
        );
    }

    // ── Edge cases ────────────────────────────────────────────

    #[test]
    fn test_gpt4o_mini_before_gpt4o() {
        // gpt-4o-mini must match Mid, not Flagship
        assert_eq!(tier_for_model("gpt-4o-mini"), ModelTier::Mid);
        assert_eq!(tier_for_model("gpt-4o"), ModelTier::Flagship);
    }

    #[test]
    fn test_sorting_by_tier() {
        // Simulate candidate sorting use case
        let mut models = [
            ("fae-qwen3", tier_for_model("fae-qwen3")),
            ("gpt-4o", tier_for_model("gpt-4o")),
            ("claude-haiku-3", tier_for_model("claude-haiku-3")),
            ("claude-sonnet-4", tier_for_model("claude-sonnet-4")),
            ("unknown-model", tier_for_model("unknown-model")),
        ];
        models.sort_by_key(|(_, tier)| *tier);

        assert_eq!(models[0].0, "gpt-4o");
        assert_eq!(models[1].0, "claude-sonnet-4");
        // Haiku is mid, fae-qwen3 is small, unknown is unknown
        assert_eq!(models[2].0, "claude-haiku-3");
        assert_eq!(models[3].0, "fae-qwen3");
        assert_eq!(models[4].0, "unknown-model");
    }
}
