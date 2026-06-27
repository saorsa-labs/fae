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

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;

/// Zero-width / invisible chars that survive NFKC and could split or hide a
/// protected token (e.g. `mod\u{200b}el_mode`). Stripped after NFKC in
/// [`canonicalize_config_key`]. Mirrors the prompt lint's `ZERO_WIDTH_CHARS`
/// (fae-daemon); duplicated here because fae-metaopt is a pure leaf and must
/// not import fae-daemon (the reverse-direction boundary guard is zero-refs).
const ZERO_WIDTH_CHARS: &[char] = &[
    '\u{200b}', // zero-width space
    '\u{200c}', // zero-width non-joiner
    '\u{200d}', // zero-width joiner
    '\u{feff}', // zero-width no-break space (BOM)
];

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
    // Strip zero-width / invisible chars AFTER NFKC — they survive NFKC and would
    // otherwise split or hide a protected token (e.g. `mod\u{200b}el_mode`).
    let chars: Vec<char> = nfkc
        .chars()
        .filter(|&ch| !ZERO_WIDTH_CHARS.contains(&ch))
        .collect();
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

// ════════════════════════════════════════════════════════════════════════════
// M3-B: the ConductorRecipe mutation surface (data + port) — DORMANT PLUMBING
// (spec §1.1, §1.3, §10). No daemon wiring; the port is None by default.
// The four ADR-008a Layer-1 constraints + the budget-fanout re-check are enforced
// by the daemon's `DaemonConductorRecipePort` adapter (M3-C, not yet built);
// these types are the data-only contract the adapter validates against.
// ════════════════════════════════════════════════════════════════════════════

/// A conductor topology the recipe surface can NAME. `star` / `debate` are
/// **deliberately absent** — unnameable at the type level + `deny_unknown_fields`
/// ⇒ serde fail-closed (ADR-008a constraint #3: no gated locality/topology).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum ConductorTopologyDto {
    Direct,
    Chain,
}

/// A recipe role the surface can NAME. Thinker / Worker / Verifier only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum ConductorRoleDto {
    Thinker,
    Worker,
    Verifier,
}

/// Add or remove a Verifier role (chain only). (ADR-008a op 3.)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum VerifierAction {
    Add,
    Remove,
}

/// A data-only spec for a role slot, carried by `SwitchTopology::chain_slots`
/// when transitioning direct → chain. Mirrors the daemon's `RoleSlot` minus
/// mutation internals. **The prompt body IS subject to the §5 prompt lint**
/// (v4 fix — v3 left it unlinted); the daemon adapter enforces that at
/// validate-time. All fields explicit + `deny_unknown_fields`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoleSlotSpec {
    pub role: ConductorRoleDto,
    pub worker: String,
    pub prompt_template_id: String,
    pub prompt_template: String,
    pub output_schema: Option<String>,
    pub required: bool,
}

/// A mutation a MetaOpt run may propose on a conductor recipe.
///
/// **DATA ONLY** — the daemon adapter interprets this against the live
/// `FaeConductorRecipe`. Maps to ADR-008a's five allowed operators. No variant
/// names `ModelMode` (constraint #4) and none names `star`/`debate` (constraint
/// #3); the protected-config-key denylist (above) closes the ConfigKnob path
/// (§3.1).
///
/// `SwitchTopology` carries `chain_slots` when transitioning **to chain** (a
/// direct recipe has only a Worker slot — the plan constructs the new slots);
/// it is `None` when transitioning **to direct** (v4 folded the construction
/// surface into topology transitions only — v3's standalone `SetRoleSlotPlan`
/// was too broad).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum ConductorRecipePatch {
    /// (ADR-008a op 1) Swap the worker in ONE role slot. `to_worker` must be
    /// same-or-lower trust tier AND provisioned.
    SwapWorker {
        recipe_id: String,
        role: ConductorRoleDto,
        to_worker: String,
    },
    /// (ADR-008a op 2) Switch topology `direct ↔ chain`. `chain_slots` MUST be
    /// `Some` with the full Thinker→Worker→Verifier plan when transitioning TO
    /// chain; `None` when transitioning TO direct.
    SwitchTopology {
        recipe_id: String,
        to: ConductorTopologyDto,
        chain_slots: Option<Vec<RoleSlotSpec>>,
    },
    /// (ADR-008a op 3) Add or remove a Verifier role (chain only).
    AdjustVerifier {
        recipe_id: String,
        action: VerifierAction,
        worker: Option<String>,
        prompt_template_id: Option<String>,
        output_schema: Option<String>,
    },
    /// (ADR-008a op 4) Mutate a role-conditioned prompt. Lint-gated (§5).
    MutateRolePrompt {
        recipe_id: String,
        role: ConductorRoleDto,
        new_prompt: String,
    },
    /// (ADR-008a op 5) Adjust budget. Downward always; upward within cap (§2.1).
    AdjustBudget {
        recipe_id: String,
        delta_micros_per_day: i64,
    },
}

impl ConductorRecipePatch {
    /// The recipe this patch targets. Batches require every patch to share this
    /// (§2.2: `PatchRejection::MixedRecipeIds`).
    pub fn recipe_id(&self) -> &str {
        match self {
            Self::SwapWorker { recipe_id, .. }
            | Self::SwitchTopology { recipe_id, .. }
            | Self::AdjustVerifier { recipe_id, .. }
            | Self::MutateRolePrompt { recipe_id, .. }
            | Self::AdjustBudget { recipe_id, .. } => recipe_id,
        }
    }
}

/// Why a patch / batch was rejected by Layer-1 validation (the daemon adapter).
/// Surfaced to the human reviewer; the patch is never applied on rejection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum PatchRejection {
    /// Post-state `privacy_lane` wider than current (constraint #1).
    LaneWidening,
    /// Post-state budget exceeds the worker's provisioned D2 ceiling (§2.1).
    BudgetAboveProvisionedCap,
    /// Recipe's `max_role_calls` cannot accommodate the post-state fanout (§2.1).
    FanoutExceedsRoleCallCap,
    /// Worst-case per-turn cost exceeds `max_cost_micros` (§2.1).
    BudgetExceedsCostCap,
    /// A worker in a multiplied-fanout chain has no pricing row (§2.1 fail-closed).
    UncostableWorkerInChain,
    /// A `to_worker` / chain-slot worker is not provisioned (registry + creds).
    UnprovisionedWorker,
    /// A `to_worker` is a higher trust tier than the slot's current worker.
    HigherTierWorker,
    /// A `MutateRolePrompt` failed the §5 deterministic prompt lint.
    PromptLintFailed(String),
    /// A batch mixed patches targeting different `recipe_id`s (§2.2).
    MixedRecipeIds,
    /// The projected post-state fails `validate_for(V1Safe)` (§2.2).
    InvalidPostState(String),
}

/// The projected post-state summary returned by `validate_patch` / `validate_batch`.
/// Counts + the topology + lane + budget ceiling — enough for a reviewer to see
/// what the patch WOULD do without applying. No prompt bodies, no worker secrets.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecipeSummary {
    pub recipe_id: String,
    pub version: u32,
    pub topology: ConductorTopologyDto,
    pub role_slot_count: u32,
    pub privacy_lane: String,
    pub budget_micros_per_day: u64,
}

/// Errors from the recipe port (apply / rollback / read). Distinct from
/// `PatchRejection` (a validate-time rejection) — these are port-transport +
/// CAS + persistence + revalidation failures.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RecipePortError {
    /// `apply_batch` CAS: the active version ≠ `expected_base_version`. No write
    /// (§2.2 v4 — closes the read-then-apply TOCTOU window).
    #[error("wrong base version: expected {expected}, actual {actual}")]
    WrongBaseVersion { expected: u32, actual: u32 },
    /// `rollback` CAS: the active version ≠ `expected_current_version`. No write
    /// — a rollback cannot clobber a concurrent writer's mutation (§4 v4).
    #[error("wrong current version: expected {expected}, actual {actual}")]
    WrongCurrentVersion { expected: u32, actual: u32 },
    /// `rollback` target failed CURRENT revalidation (§4 — a recipe valid when
    /// written may be unsafe now: worker de-provisioned, cap lowered, lane
    /// tightened). The recipe stays at its current version.
    #[error("rollback target invalid: {0}")]
    RollbackTargetInvalid(String),
    /// The recipe id does not resolve to an active recipe.
    #[error("recipe not found: {0}")]
    RecipeNotFound(String),
    /// A Layer-1 validator rejected the patch / batch (carries the [`PatchRejection`]).
    #[error("patch rejected: {0:?}")]
    PatchRejected(PatchRejection),
    /// The port's store I/O failed.
    #[error("recipe store error: {0}")]
    StoreError(String),
}

/// The port the daemon implements (`DaemonConductorRecipePort`, M3-C).
/// `fae-metaopt` calls it; `fae-metaopt` does **not** import `FaeConductorRecipe`.
///
/// Apply / rollback are **CAS at both ends** (§1.3, §2.2, §4):
/// - `apply_batch(recipe_id, expected_base_version, patches)` fails
///   `WrongBaseVersion` if the active version ≠ `expected_base_version` (no write).
/// - `rollback(recipe_id, expected_current_version, to_version)` only proceeds if
///   the active version matches `expected_current_version` (no clobber).
///
/// `apply_batch` impls MUST call `validate_batch` first (defense-in-depth).
#[async_trait]
pub trait ConductorRecipePort: Send + Sync {
    /// Validate a single patch against the four ADR-008a constraints WITHOUT
    /// applying. Returns the projected post-state summary or a rejection.
    async fn validate_patch(
        &self,
        patch: &ConductorRecipePatch,
    ) -> Result<RecipeSummary, PatchRejection>;

    /// Validate a BATCH atomically — the post-state after ALL patches applied.
    /// Used when a mutation needs multiple operators to stay valid (§2.2).
    async fn validate_batch(
        &self,
        patches: &[ConductorRecipePatch],
    ) -> Result<RecipeSummary, PatchRejection>;

    /// Apply a validated batch as ONE new recipe version (atomic). v4 CAS:
    /// `expected_base_version` must match the active version or the apply fails
    /// `Err(RecipePortError::WrongBaseVersion)` — no write. The impl MUST call
    /// `validate_batch` first. Returns the new version.
    async fn apply_batch(
        &self,
        recipe_id: &str,
        expected_base_version: u32,
        patches: &[ConductorRecipePatch],
    ) -> Result<u32, RecipePortError>;

    /// Roll back to a prior recipe version. Revalidates against the CURRENT
    /// registry/caps/profile before re-activation (MAJOR-5). v4 CAS: the rollback
    /// only proceeds if the active version matches `expected_current_version`.
    async fn rollback(
        &self,
        recipe_id: &str,
        expected_current_version: u32,
        to_version: u32,
    ) -> Result<(), RecipePortError>;

    /// The active recipe's summary (version is the CAS base for apply / rollback).
    async fn current_recipe_summary(
        &self,
        recipe_id: &str,
    ) -> Result<RecipeSummary, RecipePortError>;
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
    fn canonicalize_strips_zero_width_in_protected_keys() {
        // Zero-width chars (U+200B/C/D, U+FEFF) survive NFKC. Without stripping
        // they would split `model_mode` into `mod` + `el_mode` (or similar),
        // letting an obfuscated protected key slip past the denylist. Each form
        // here MUST canonicalize to a form containing `model_mode` / the alias,
        // and is_protected_config_key MUST return true.
        assert_eq!(canonicalize_config_key("mod\u{200b}el_mode"), "model_mode");
        assert_eq!(canonicalize_config_key("model_\u{200b}mode"), "model_mode");
        assert_eq!(canonicalize_config_key("\u{feff}model_mode"), "model_mode");
        assert_eq!(
            canonicalize_config_key("availability\u{200d}_mode"),
            "availability_mode"
        );
        // Uppercase + zero-width (case + invisibles together).
        assert_eq!(canonicalize_config_key("MODEL\u{200c}_MODE"), "model_mode");
        // The denylist catches every obfuscated protected form.
        assert!(is_protected_config_key("mod\u{200b}el_mode"));
        assert!(is_protected_config_key("fae\u{200d}_model_mode"));
        assert!(is_protected_config_key("availability\u{feff}_mode"));
        // And a non-protected key is still NOT protected after stripping.
        assert!(!is_protected_config_key("max\u{200b}_turns"));
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

    // ── M3-B: DTO serde + deny_unknown_fields (constraint #3: star/debate unnameable) ──

    #[test]
    fn topology_dto_round_trips_direct_and_chain() -> Result<(), serde_json::Error> {
        for topo in [ConductorTopologyDto::Direct, ConductorTopologyDto::Chain] {
            let json = serde_json::to_string(&topo)?;
            let back: ConductorTopologyDto = serde_json::from_str(&json)?;
            assert_eq!(back, topo);
        }
        Ok(())
    }

    #[test]
    fn topology_dto_rejects_star_and_debate() {
        // star / debate are ABSENT from the DTO + deny_unknown_fields ⇒ serde
        // fail-closed. ADR-008a constraint #3: gated topology is unnameable.
        for forbidden in ["star", "debate", "Star", "remote_allowed"] {
            let json = format!("\"{forbidden}\"");
            let result: Result<ConductorTopologyDto, _> = serde_json::from_str(&json);
            assert!(result.is_err(), "topology DTO must reject {forbidden:?}");
        }
    }

    #[test]
    fn role_dto_rejects_unknown_roles() -> Result<(), serde_json::Error> {
        for forbidden in ["oracle", "planner", ""] {
            let json = format!("\"{forbidden}\"");
            let result: Result<ConductorRoleDto, _> = serde_json::from_str(&json);
            assert!(result.is_err(), "role DTO must reject {forbidden:?}");
        }
        // The three allowed roles round-trip.
        for role in [
            ConductorRoleDto::Thinker,
            ConductorRoleDto::Worker,
            ConductorRoleDto::Verifier,
        ] {
            let json = serde_json::to_string(&role)?;
            let back: ConductorRoleDto = serde_json::from_str(&json)?;
            assert_eq!(back, role);
        }
        Ok(())
    }

    #[test]
    fn patch_round_trips_each_operator() -> Result<(), serde_json::Error> {
        let patches = vec![
            ConductorRecipePatch::SwapWorker {
                recipe_id: "r1".to_owned(),
                role: ConductorRoleDto::Worker,
                to_worker: "w-b".to_owned(),
            },
            ConductorRecipePatch::SwitchTopology {
                recipe_id: "r1".to_owned(),
                to: ConductorTopologyDto::Direct,
                chain_slots: None,
            },
            ConductorRecipePatch::AdjustVerifier {
                recipe_id: "r1".to_owned(),
                action: VerifierAction::Add,
                worker: Some("w-v".to_owned()),
                prompt_template_id: Some("p".to_owned()),
                output_schema: None,
            },
            ConductorRecipePatch::MutateRolePrompt {
                recipe_id: "r1".to_owned(),
                role: ConductorRoleDto::Thinker,
                new_prompt: "think harder".to_owned(),
            },
            ConductorRecipePatch::AdjustBudget {
                recipe_id: "r1".to_owned(),
                delta_micros_per_day: -100,
            },
        ];
        for patch in &patches {
            let json = serde_json::to_string(patch)?;
            let back: ConductorRecipePatch = serde_json::from_str(&json)?;
            assert_eq!(&back, patch);
            // Every patch reports its recipe_id.
            assert_eq!(patch.recipe_id(), "r1");
        }
        Ok(())
    }

    #[test]
    fn patch_dto_rejects_unknown_op_variant() {
        // deny_unknown_fields on the internally-tagged enum ⇒ an unknown `op` is
        // rejected. No op can name a forbidden topology/role/model_mode.
        let json = r#"{"op":"override_model_mode","recipe_id":"r1"}"#;
        let result: Result<ConductorRecipePatch, _> = serde_json::from_str(json);
        assert!(result.is_err(), "patch must reject unknown op");
    }

    #[test]
    fn patch_dto_rejects_unknown_field_within_op() {
        // A SwapWorker carrying an extra `privacy_lane` field is rejected — no
        // smuggled lane widening via an unrecognized field.
        let json = r#"{"op":"swap_worker","recipe_id":"r1","role":"worker","to_worker":"w","privacy_lane":"remote_allowed"}"#;
        let result: Result<ConductorRecipePatch, _> = serde_json::from_str(json);
        assert!(result.is_err(), "patch must reject unknown field");
    }

    #[test]
    fn role_slot_spec_rejects_unknown_field() {
        let json = r#"{"role":"worker","worker":"w","prompt_template_id":"p","prompt_template":"x","required":true,"secret":"leak"}"#;
        let result: Result<RoleSlotSpec, _> = serde_json::from_str(json);
        assert!(result.is_err(), "RoleSlotSpec must reject unknown field");
    }
}
