//! Conductor recipe + routing types.
//!
//! A [`FaeConductorRecipe`] is the unit a learned-conductor policy produces and
//! the MetaOpt loop mutates: which workers may participate, which topology,
//! which roles (Thinker/Worker/Verifier), and the budget/stop/aggregation
//! policies. It is pure data — never source-code mutation — so it can be
//! serialized, audited, rolled back, and (eventually) shared as a candidate
//! prior over x0x.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::conductor::error::ConductorError;

// ───────────────────────────── Enums ─────────────────────────────

/// Coarse task taxonomy used to key recipes. Derived per turn by the (M1)
/// routing policy; stored in telemetry so recipes can be evaluated per class.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConductorTaskClass {
    Chat,
    Coding,
    CodeReview,
    Reasoning,
    Research,
    Planning,
    PersonalData,
    ToolUse,
    /// Task did not match any known class. Recipes keyed on `Unknown` form the
    /// safe fallback; the routing policy must always have one.
    Unknown,
}

/// The three roles a coordinator may delegate, per TRINITY (arxiv 2512.04695).
///
/// - **Thinker** decomposes the problem and identifies needed tools/models.
/// - **Worker** performs the main task work using the best-fit lane.
/// - **Verifier** checks the Worker output for correctness, safety, and
///   preference-fit, and decides whether to answer or continue.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConductorRole {
    Thinker,
    Worker,
    Verifier,
}

/// v1 topology set. `Star`/`Debate` are **intentionally absent** — they are
/// unreachable at compile time (F-15) and rejected fail-closed on
/// deserialization (serde errors on unknown variants). Enabling them is a
/// deliberate M3+ change gated on eval evidence + owner approval.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConductorTopology {
    /// One worker, one role-conditioned prompt, one answer.
    Direct,
    /// Thinker → Worker → Verifier. Stops on budget exhaustion or Verifier
    /// approval; falls back to a safe local answer if the Verifier rejects.
    Chain,
}

/// Where a worker runs. Drives egress/privacy gating and (later) the x0x
/// transport selection. `OwnerFleet` is x0x same-owner; `TrustedPeer` and
/// `RemoteProvider` are ADR-gated and rejected by the v1 safe profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkerLocality {
    /// On-device model via the Rust engine (mistral.rs / llama.cpp sidecar).
    LocalModel,
    /// Local ACP agent (Codex/Claude/Pi/Gemini/Copilot) via `fae-acp`.
    LocalAcp,
    /// Same-owner x0x peer (`delegate_to_mesh`, Tier 1). M4+.
    OwnerFleet,
    /// Cross-owner x0x peer under a capability grant. ADR-gated.
    TrustedPeer,
    /// Paid/external model provider. ADR-gated.
    RemoteProvider,
}

/// How sensitive the context is, and therefore how far it may travel.
/// Monotonically widening: `LocalOnly` ⊂ `OwnerFleet` ⊂ `TrustedPeer` ⊂
/// `RemoteAllowed`. The v1 routing policy never widens a lane beyond what the
/// task requires, and never auto-widens via recipe mutation (M3 guard).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyLane {
    /// Stays in the local process. Required for personal-data / credential /
    /// sensitive-content tasks.
    LocalOnly,
    /// May cross to same-owner x0x peers. M4+.
    OwnerFleet,
    /// May cross to an explicitly-granted trusted peer. ADR-gated.
    TrustedPeer,
    /// May leave to a remote/paid provider. ADR-gated.
    RemoteAllowed,
}

impl PrivacyLane {
    /// True if `other` is at least as permissive as `self`. Used to guard
    /// against widening: a mutation may narrow but never silently widen.
    pub fn permits(self, other: PrivacyLane) -> bool {
        fn rank(lane: PrivacyLane) -> u8 {
            match lane {
                PrivacyLane::LocalOnly => 0,
                PrivacyLane::OwnerFleet => 1,
                PrivacyLane::TrustedPeer => 2,
                PrivacyLane::RemoteAllowed => 3,
            }
        }
        rank(other) <= rank(self)
    }
}

// ──────────────────────────── Sub-policies ──────────────────────

/// A routable worker descriptor. Uniform across local models, local ACP agents,
/// and (later) x0x peers, so the routing policy scores them identically.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct WorkerSelector {
    /// Stable id (e.g. `local:qwen3-4b`, `acp:codex`, later `x0x:<agent_id>`).
    pub id: String,
    /// Discriminator for telemetry/routing; does not drive execution directly.
    pub kind: String,
    pub locality: WorkerLocality,
    /// Advertised capability tags (e.g. `["coding","reasoning"]`).
    pub capabilities: Vec<String>,
    /// Provider/model name when applicable (`None` for x0x peers).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Trust scope id when applicable (`None` for local workers).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trust_scope: Option<String>,
}

/// One role slot in a recipe's topology.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RoleSlot {
    pub role: ConductorRole,
    pub worker: WorkerSelector,
    /// Identifier for the prompt template (mutated by MetaOpt in M3).
    pub prompt_template_id: String,
    /// The template body, role-conditioned (Conductor's targeted instructions).
    pub prompt_template: String,
    /// Expected output schema id (used by the executor to parse/validate).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_schema: Option<String>,
    /// If false, the executor may skip this slot when the worker is unavailable.
    #[serde(default = "default_true")]
    pub required: bool,
}

fn default_true() -> bool {
    true
}

/// Per-recipe resource budget. Enforced by the executor (M1); mutations capped
/// by the guardrail profile (M3).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct BudgetPolicy {
    /// Maximum conductor turns for one owner turn.
    pub max_turns: u32,
    /// Maximum total role (worker) invocations.
    pub max_role_calls: u32,
    /// Hard wall-clock timeout per owner turn.
    #[serde(with = "millis")]
    pub timeout: Duration,
    /// Optional token cap (sum across workers). `None` = uncapped.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    /// Optional spend cap in micro-currency (sum across paid workers).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_cost_micros: Option<u64>,
}

/// When/how the conductor may escalate from local to a heavier worker.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct EscalationPolicy {
    /// Confidence below which the conductor considers escalating.
    pub min_confidence_to_stay_local: f64,
    pub allow_acp: bool,
    /// Mesh (same-owner x0x) escalation. `false` until M4.
    pub allow_mesh: bool,
}

/// How worker outputs are combined into a final answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AggregationMode {
    /// Use the first answer (direct topology).
    FirstAnswer,
    /// Verifier-approved synthesis (chain topology).
    VerifiedSynthesis,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AggregationPolicy {
    pub mode: AggregationMode,
    /// If true, the chain's final answer requires an explicit Verifier pass.
    pub require_verifier_approval: bool,
}

/// When the conductor stops looping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct StopPolicy {
    pub stop_after_verifier: bool,
    pub stop_on_budget_exhaustion: bool,
    /// Max Verifier-driven correction loops before forcing a final answer.
    pub max_correction_loops: u32,
}

/// serde Duration ↔ millis helper (JSON-friendly).
mod millis {
    use serde::{Deserialize, Deserializer, Serializer};
    use std::time::Duration;

    pub fn serialize<S: Serializer>(d: &Duration, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_u64(d.as_millis() as u64)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Duration, D::Error> {
        let ms = u64::deserialize(d)?;
        Ok(Duration::from_millis(ms))
    }
}

// ──────────────────────────── The recipe ────────────────────────

/// A complete, serializable routing recipe. Pure data — the unit MetaOpt
/// mutates (M3) and the gate evaluates (M2).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FaeConductorRecipe {
    pub id: String,
    pub version: u32,
    pub task_class: ConductorTaskClass,
    /// Feature predicates (e.g. `["has_codeblock","len>2000"]`) that must all
    /// match for this recipe to be eligible. Match semantics defined by M1.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub feature_predicates: Vec<String>,
    pub allowed_workers: Vec<WorkerSelector>,
    pub privacy_lane: PrivacyLane,
    pub topology: ConductorTopology,
    pub role_slots: Vec<RoleSlot>,
    pub budget: BudgetPolicy,
    pub escalation: EscalationPolicy,
    pub aggregation: AggregationPolicy,
    pub stop: StopPolicy,
}

/// Validation errors. Kept as a distinct enum so the gate (M2) and MetaOpt
/// (M3) can pattern-match on the specific failure.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ConductorRecipeError {
    #[error("topology {0:?} requires at least one role slot")]
    NoRoleSlots(ConductorTopology),
    #[error("chain topology requires exactly Thinker,Worker,Verifier in order; got {0}")]
    InvalidChainRoles(String),
    #[error("budget must be positive (turns/role-calls/timeout); got turns={turns} role_calls={role_calls} timeout_ms={timeout_ms}")]
    NonPositiveBudget {
        turns: u32,
        role_calls: u32,
        timeout_ms: u64,
    },
    #[error("worker {0} has locality {1:?} not permitted by the v1 safe profile")]
    WorkerLocalityNotPermitted(String, WorkerLocality),
    #[error("worker {0} exceeds privacy lane {1:?} (locality {2:?})")]
    WorkerExceedsPrivacyLane(String, PrivacyLane, WorkerLocality),
}

/// v1 safe profile. Recipes that validate against this are the only ones the
/// M1 static policy may deploy. Loosening it (to permit OwnerFleet/TrustedPeer/
/// RemoteProvider workers, or Star/Debate topologies) is a deliberate,
/// milestone-gated change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeProfile {
    /// M0–M3: local model + local ACP workers only; Direct/Chain only;
    /// LocalOnly/OwnerFleet lanes only (OwnerFleet is permitted in recipes but
    /// not executed until M4).
    V1Safe,
}

impl FaeConductorRecipe {
    /// Validate against the v1 safe profile. Returns the first structural
    /// violation, or `Ok(())` if the recipe is deployable.
    pub fn validate(&self) -> Result<(), ConductorRecipeError> {
        self.validate_for(RecipeProfile::V1Safe)
    }

    pub fn validate_for(&self, profile: RecipeProfile) -> Result<(), ConductorRecipeError> {
        if self.role_slots.is_empty() {
            return Err(ConductorRecipeError::NoRoleSlots(self.topology));
        }

        // Topology-specific role shape.
        match self.topology {
            ConductorTopology::Direct => {
                // Direct needs at least one worker slot.
            }
            ConductorTopology::Chain => {
                let expected = [
                    ConductorRole::Thinker,
                    ConductorRole::Worker,
                    ConductorRole::Verifier,
                ];
                let got: Vec<ConductorRole> = self.role_slots.iter().map(|s| s.role).collect();
                if got.len() != expected.len()
                    || got.iter().zip(expected.iter()).any(|(g, e)| g != e)
                {
                    return Err(ConductorRecipeError::InvalidChainRoles(format!("{got:?}")));
                }
            }
        }

        // Budget sanity.
        let timeout_ms = self.budget.timeout.as_millis() as u64;
        if self.budget.max_turns == 0 || self.budget.max_role_calls == 0 || timeout_ms == 0 {
            return Err(ConductorRecipeError::NonPositiveBudget {
                turns: self.budget.max_turns,
                role_calls: self.budget.max_role_calls,
                timeout_ms,
            });
        }

        // v1 safe profile: worker locality + privacy lane.
        if profile == RecipeProfile::V1Safe {
            for w in &self.allowed_workers {
                if !matches!(
                    w.locality,
                    WorkerLocality::LocalModel | WorkerLocality::LocalAcp
                ) {
                    return Err(ConductorRecipeError::WorkerLocalityNotPermitted(
                        w.id.clone(),
                        w.locality,
                    ));
                }
                // OwnerFleet is permitted in recipes (so M4 can flip the switch)
                // but TrustedPeer/RemoteAllowed are not yet.
                let lane_ok = matches!(
                    self.privacy_lane,
                    PrivacyLane::LocalOnly | PrivacyLane::OwnerFleet
                );
                if !lane_ok {
                    return Err(ConductorRecipeError::WorkerExceedsPrivacyLane(
                        w.id.clone(),
                        self.privacy_lane,
                        w.locality,
                    ));
                }
                // Even in a permitted recipe, a worker's locality must not
                // exceed the declared lane.
                if !self.privacy_lane.permits(locality_to_lane(w.locality)) {
                    return Err(ConductorRecipeError::WorkerExceedsPrivacyLane(
                        w.id.clone(),
                        self.privacy_lane,
                        w.locality,
                    ));
                }
            }
        }

        Ok(())
    }
}

fn locality_to_lane(l: WorkerLocality) -> PrivacyLane {
    match l {
        WorkerLocality::LocalModel | WorkerLocality::LocalAcp => PrivacyLane::LocalOnly,
        WorkerLocality::OwnerFleet => PrivacyLane::OwnerFleet,
        WorkerLocality::TrustedPeer => PrivacyLane::TrustedPeer,
        WorkerLocality::RemoteProvider => PrivacyLane::RemoteAllowed,
    }
}

// ────────────────────────── Turn context / decision ─────────────

/// Inputs to one conductor routing decision. Deliberately carries **no user
/// text** — correlation with telemetry is via `request_id` only (see
/// [`crate::conductor::fingerprint::RequestFingerprint`], F-4).
#[derive(Debug, Clone)]
pub struct ConductorTurnContext<'a> {
    pub request_id: &'a str,
    pub task_class: ConductorTaskClass,
    pub feature_predicates: &'a [String],
    pub privacy_lane: PrivacyLane,
    pub available_workers: &'a [WorkerSelector],
    /// Optional working directory for ACP runners.
    pub working_directory: Option<&'a str>,
    /// Optional hard deadline (millis since epoch).
    pub deadline_ms: Option<u64>,
}

/// What approval gate, if any, a route decision must pass before execution.
///
/// This is the **F-7 autonomy seam**. M1 (local + local-ACP only) always
/// emits [`ApprovalClass::None`] — there is no egress to gate. Keeping the
/// field in the decision type now means M2 wires approval into an existing
/// seam rather than retrofitting one onto every routing call site.
///
/// Tiering (F-7):
///
/// - **Tier A — Autonomous (`None`):** local models + local ACP agents; zero
///   egress, zero cost. *This is all of M1* — no approval surface needed.
/// - **Tier B — Standing-grantable:** remote API / x0x peers; per-class grant
///   plus budget cap, revocable, auditable. *M2 spec.*
/// - **Tier C — Always per-turn:** sensitive-data lane, cross-owner, PII, or
///   anything outside a standing grant. *M2 spec.*
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum ApprovalClass {
    /// No approval needed (Tier A: local / local-ACP, zero egress).
    #[default]
    None,
    /// Per-turn approval required (Tier C: sensitive / cross-owner / PII, or
    /// anything not covered by a standing grant).
    PerTurn,
    /// Covered by a standing, revocable grant (Tier B). `id` is the opaque
    /// grant identifier; the conductor resolves it against the grant ledger.
    /// M1 never emits this — present so the seam exists.
    StandingGrant(String),
}

/// The conductor's routing decision for one turn. M1's static policy produces
/// the first two variants; `MeshDelegate` and `FallbackLocal` are emitted but
/// deferred (mesh) or last-resort (fallback).
#[derive(Debug, Clone)]
pub enum ConductorRouteDecision<'a> {
    /// Answer locally, no delegation.
    LocalAnswer { recipe_id: &'a str, reason: String },
    /// Run a one-shot agent (ACP) under the given recipe/worker.
    AgentRun {
        recipe: &'a FaeConductorRecipe,
        worker: &'a WorkerSelector,
        /// The approval gate this run must pass before execution. M1 always
        /// emits [`ApprovalClass::None`]; M2 introduces the higher tiers.
        approval: ApprovalClass,
    },
    /// Mesh delegation is the right call but is not executable yet (pre-M4).
    /// Logged + falls back to local.
    MeshDeferred { recipe_id: &'a str, reason: String },
    /// No eligible worker; fall back to a safe local answer.
    FallbackLocal { reason: String },
}

// Convenience for error conversion at module boundaries.
impl From<ConductorRecipeError> for ConductorError {
    fn from(e: ConductorRecipeError) -> Self {
        ConductorError::Recipe(e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local_worker(id: &str) -> WorkerSelector {
        WorkerSelector {
            id: id.to_string(),
            kind: "local_model".to_string(),
            locality: WorkerLocality::LocalModel,
            capabilities: vec!["chat".to_string()],
            provider: None,
            model: None,
            trust_scope: None,
        }
    }

    fn base_budget() -> BudgetPolicy {
        BudgetPolicy {
            max_turns: 3,
            max_role_calls: 3,
            timeout: Duration::from_millis(30_000),
            max_tokens: None,
            max_cost_micros: None,
        }
    }

    fn direct_recipe() -> FaeConductorRecipe {
        let w = local_worker("local:tiny");
        FaeConductorRecipe {
            id: "r-direct".to_string(),
            version: 1,
            task_class: ConductorTaskClass::Chat,
            feature_predicates: vec![],
            allowed_workers: vec![w.clone()],
            privacy_lane: PrivacyLane::LocalOnly,
            topology: ConductorTopology::Direct,
            role_slots: vec![RoleSlot {
                role: ConductorRole::Worker,
                worker: w,
                prompt_template_id: "direct-worker".to_string(),
                prompt_template: "Answer concisely.".to_string(),
                output_schema: None,
                required: true,
            }],
            budget: base_budget(),
            escalation: EscalationPolicy {
                min_confidence_to_stay_local: 0.5,
                allow_acp: true,
                allow_mesh: false,
            },
            aggregation: AggregationPolicy {
                mode: AggregationMode::FirstAnswer,
                require_verifier_approval: false,
            },
            stop: StopPolicy {
                stop_after_verifier: true,
                stop_on_budget_exhaustion: true,
                max_correction_loops: 0,
            },
        }
    }

    #[test]
    fn direct_recipe_validates() {
        assert!(direct_recipe().validate().is_ok());
    }

    #[test]
    fn empty_role_slots_rejected() {
        let mut r = direct_recipe();
        r.role_slots.clear();
        assert!(r.validate().is_err());
    }

    #[test]
    fn chain_requires_three_roles_in_order() {
        let w = local_worker("local:tiny");
        let mut r = direct_recipe();
        r.topology = ConductorTopology::Chain;
        // Missing Verifier.
        r.role_slots = vec![
            RoleSlot {
                role: ConductorRole::Thinker,
                worker: w.clone(),
                prompt_template_id: "t".into(),
                prompt_template: "t".into(),
                output_schema: None,
                required: true,
            },
            RoleSlot {
                role: ConductorRole::Worker,
                worker: w.clone(),
                prompt_template_id: "w".into(),
                prompt_template: "w".into(),
                output_schema: None,
                required: true,
            },
        ];
        match r.validate() {
            Err(ConductorRecipeError::InvalidChainRoles(_)) => {}
            other => panic!("expected InvalidChainRoles, got {other:?}"),
        }

        // Correct order passes.
        r.role_slots.push(RoleSlot {
            role: ConductorRole::Verifier,
            worker: w,
            prompt_template_id: "v".into(),
            prompt_template: "v".into(),
            output_schema: None,
            required: true,
        });
        assert!(r.validate().is_ok());
    }

    #[test]
    fn zero_budget_rejected() {
        let mut r = direct_recipe();
        r.budget.max_turns = 0;
        assert!(matches!(
            r.validate(),
            Err(ConductorRecipeError::NonPositiveBudget { .. })
        ));
    }

    #[test]
    fn v1_rejects_remote_workers() {
        let mut r = direct_recipe();
        let mut remote = local_worker("remote:gpt");
        remote.locality = WorkerLocality::RemoteProvider;
        r.allowed_workers.push(remote);
        assert!(matches!(
            r.validate(),
            Err(ConductorRecipeError::WorkerLocalityNotPermitted(_, _))
        ));
    }

    #[test]
    fn privacy_lane_permits_is_monotone() {
        assert!(PrivacyLane::LocalOnly.permits(PrivacyLane::LocalOnly));
        assert!(!PrivacyLane::LocalOnly.permits(PrivacyLane::OwnerFleet));
        assert!(PrivacyLane::RemoteAllowed.permits(PrivacyLane::LocalOnly));
        assert!(PrivacyLane::RemoteAllowed.permits(PrivacyLane::RemoteAllowed));
    }

    #[test]
    fn serde_roundtrip_preserves_recipe() {
        let r = direct_recipe();
        let json = serde_json::to_string(&r).expect("serialize in test");
        let back: FaeConductorRecipe = serde_json::from_str(&json).expect("deserialize in test");
        assert_eq!(r, back);
    }

    #[test]
    fn serde_rejects_unknown_topology() {
        // F-15: star/debate fail-closed on deserialization.
        let bad = r#"{"topology":"star"}"#;
        assert!(serde_json::from_str::<ConductorTopology>(bad).is_err());
    }

    #[test]
    fn approval_class_seam_defaults_to_none() {
        // F-7: M1 (local + local-ACP) must never gate. The seam exists so M2
        // can wire Tier B/C without touching routing call sites.
        assert_eq!(ApprovalClass::default(), ApprovalClass::None);
        // The higher tiers are constructible now (seam exists), but no M1
        // policy path emits them.
        assert_ne!(ApprovalClass::PerTurn, ApprovalClass::None);
        assert_ne!(
            ApprovalClass::StandingGrant("g_x0x_baseline".to_string()),
            ApprovalClass::None
        );
    }
}
