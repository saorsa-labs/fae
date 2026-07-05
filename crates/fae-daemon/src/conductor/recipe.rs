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

use crate::conductor::budget::BudgetDimension;
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
    /// Genuinely zero egress — prompts never leave the device.
    LocalModel,
    /// ACP agent (Codex/Claude/Pi/Gemini/Copilot) driven via `fae-acp`. **The
    /// "local" here is the *process* (a local subprocess), NOT the *data*:**
    /// these are cloud-backed providers, so prompts may egress to OpenAI /
    /// Anthropic / Google after the PII membrane and D2 budget caps. D-M2-1 maps
    /// this locality to [`PrivacyLane::CloudBacked`]. *Local process ≠ local data.*
    CloudBackedAcp,
    /// Same-owner x0x peer (`delegate_to_mesh`, Tier 1). M4+.
    OwnerFleet,
    /// Cross-owner x0x peer under a capability grant. ADR-gated.
    TrustedPeer,
    /// Paid/external model provider. ADR-gated.
    RemoteProvider,
}

/// How sensitive the context is, and therefore how far it may travel.
/// Monotonically widening: `LocalOnly` ⊂ `CloudBacked` ⊂ `OwnerFleet` ⊂
/// `TrustedPeer` ⊂ `RemoteAllowed`. The v1 routing policy never widens a lane
/// beyond what the task requires, and never auto-widens via recipe mutation
/// (M3 guard).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyLane {
    /// Stays in the local process. Required for personal-data / credential /
    /// sensitive-content tasks.
    LocalOnly,
    /// May egress to a provisioned cloud-backed local ACP worker (Codex,
    /// Claude, Gemini, Copilot, etc.) after the PII membrane and budget caps.
    CloudBacked,
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
    #[allow(dead_code)] // TODO(M2): recipe validation on candidate load
    pub fn permits(self, other: PrivacyLane) -> bool {
        fn rank(lane: PrivacyLane) -> u8 {
            match lane {
                PrivacyLane::LocalOnly => 0,
                PrivacyLane::CloudBacked => 1,
                PrivacyLane::OwnerFleet => 2,
                PrivacyLane::TrustedPeer => 3,
                PrivacyLane::RemoteAllowed => 4,
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
///
/// `deny_unknown_fields` (F-15) closes a forward-compat serde hole: without it, an
/// unknown top-level field (`"star_mode": true`, `"debate_v2": ...`) is silently
/// accepted, and a future code change reading it would honor attacker/
/// mutation-injected metadata. Star/Debate topologies are already compile-time-
/// unreachable (the enum has only `Direct`/`Chain`); this is defense-in-depth at
/// the struct boundary so a crafted JSON can't smuggle unknown metadata either.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
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
#[allow(dead_code)] // TODO(M2): recipe validation on candidate load
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeProfile {
    /// M0–M3: local model + cloud-backed local ACP workers only; Direct/Chain
    /// only; LocalOnly/CloudBacked/OwnerFleet lanes only (OwnerFleet is
    /// permitted in recipes but not executed until M4). The default: rejects
    /// `RemoteProvider` workers and the `RemoteAllowed` lane.
    V1Safe,
    /// ADR-014 cloud lane. Additionally permits `RemoteProvider` workers and the
    /// `RemoteAllowed` privacy lane. Reachable only when the owner's mode cap
    /// (`ModelMode::AllAvailable`) AND this profile both permit — the default
    /// stays [`RecipeProfile::V1Safe`]. Locality/lane monotonicity
    /// (`privacy_lane.permits(locality_to_lane(w))`) still binds.
    V2RemoteAllowed,
}

impl RecipeProfile {
    /// The permissive ADR-014 profile constructor, for call sites that read
    /// intent-first (`RecipeProfile::v2_remote_allowed()`).
    #[allow(dead_code)] // TODO(M2): recipe validation on candidate load
    pub fn v2_remote_allowed() -> Self {
        RecipeProfile::V2RemoteAllowed
    }
}

impl FaeConductorRecipe {
    /// Validate against the v1 safe profile. Returns the first structural
    /// violation, or `Ok(())` if the recipe is deployable.
    #[allow(dead_code)] // TODO(M2): recipe validation on candidate load
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

        // Profile-scoped worker locality + privacy lane. Both profiles enforce
        // locality/lane monotonicity; V2 (ADR-014) additionally admits
        // `RemoteProvider` workers and the `RemoteAllowed` lane.
        for w in &self.allowed_workers {
            // D-M2-1: `CloudBackedAcp` is permitted only as a cloud-backed Tier B
            // worker. The PII membrane and D2 budget caps are the egress
            // floor/ceiling. V1 stays local-only in execution because
            // static-direct is hardcoded `LocalModel`; V2 unlocks RemoteProvider
            // for the ADR-014 cloud lane.
            let locality_permitted = match profile {
                RecipeProfile::V1Safe => matches!(
                    w.locality,
                    WorkerLocality::LocalModel | WorkerLocality::CloudBackedAcp
                ),
                RecipeProfile::V2RemoteAllowed => matches!(
                    w.locality,
                    WorkerLocality::LocalModel
                        | WorkerLocality::CloudBackedAcp
                        | WorkerLocality::OwnerFleet
                        | WorkerLocality::RemoteProvider
                ),
            };
            if !locality_permitted {
                return Err(ConductorRecipeError::WorkerLocalityNotPermitted(
                    w.id.clone(),
                    w.locality,
                ));
            }
            // CloudBacked is the M2 ACP lane; OwnerFleet is permitted in recipes
            // (so M4 can flip the switch). V1 stops at OwnerFleet; V2 additionally
            // permits RemoteAllowed. TrustedPeer stays ADR-gated for both.
            let lane_ok = match profile {
                RecipeProfile::V1Safe => matches!(
                    self.privacy_lane,
                    PrivacyLane::LocalOnly | PrivacyLane::CloudBacked | PrivacyLane::OwnerFleet
                ),
                RecipeProfile::V2RemoteAllowed => matches!(
                    self.privacy_lane,
                    PrivacyLane::LocalOnly
                        | PrivacyLane::CloudBacked
                        | PrivacyLane::OwnerFleet
                        | PrivacyLane::RemoteAllowed
                ),
            };
            if !lane_ok {
                return Err(ConductorRecipeError::WorkerExceedsPrivacyLane(
                    w.id.clone(),
                    self.privacy_lane,
                    w.locality,
                ));
            }
            // Even in a permitted recipe, a worker's locality must not exceed the
            // declared lane (monotonicity binds in both profiles).
            if !self.privacy_lane.permits(locality_to_lane(w.locality)) {
                return Err(ConductorRecipeError::WorkerExceedsPrivacyLane(
                    w.id.clone(),
                    self.privacy_lane,
                    w.locality,
                ));
            }
        }

        Ok(())
    }
}

#[allow(dead_code)] // TODO(M2): recipe validation on candidate load
pub(crate) fn locality_to_lane(l: WorkerLocality) -> PrivacyLane {
    match l {
        WorkerLocality::LocalModel => PrivacyLane::LocalOnly,
        WorkerLocality::CloudBackedAcp => PrivacyLane::CloudBacked,
        WorkerLocality::OwnerFleet => PrivacyLane::OwnerFleet,
        WorkerLocality::TrustedPeer => PrivacyLane::TrustedPeer,
        WorkerLocality::RemoteProvider => PrivacyLane::RemoteAllowed,
    }
}

// ────────────────────────── Turn context / decision ─────────────

/// UX W3 — an explicit, owner-initiated per-turn cloud routing hint carried on
/// `conversation.inject_text`. Only `Cloud` exists today; the policy honors it
/// **solely** when the privacy lane already permits `RemoteAllowed` AND a
/// `RemoteProvider` worker is registered for the turn — otherwise it is inert
/// and `LocalOnly` stays the default (fail-closed). Fae-*initiated* cloud
/// routing (the model choosing the cloud on its own) is a later phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteHint {
    /// The owner explicitly asked to route this turn to the cloud brain.
    Cloud,
}

/// Inputs to one conductor routing decision. Deliberately carries **no user
/// text** — correlation with telemetry is via `request_id` only (see
/// [`crate::conductor::fingerprint::RequestFingerprint`], F-4).
///
/// OWNED (no borrows) so the decision can move across `.await` boundaries.
#[derive(Debug, Clone)]
pub struct ConductorTurnContext {
    pub request_id: String,
    #[allow(dead_code)]
    // TODO(M2): richer classify() reads these; M1 policy is content-blind and inert
    pub task_class: ConductorTaskClass,
    #[allow(dead_code)] // TODO(M2): feature-gated routing
    pub feature_predicates: Vec<String>,
    #[allow(dead_code)] // TODO(M2): privacy-lane-aware routing
    pub privacy_lane: PrivacyLane,
    #[allow(dead_code)] // TODO(M2): worker selection
    pub available_workers: Vec<WorkerSelector>,
    /// Optional working directory for ACP runners.
    #[allow(dead_code)] // TODO(M2): ACP worker execution
    pub working_directory: Option<String>,
    /// Optional hard deadline (millis since epoch).
    #[allow(dead_code)] // TODO(M2): budget enforcement
    pub deadline_ms: Option<u64>,
    /// UX W3: optional explicit cloud routing hint (owner-initiated). `None` for
    /// every legacy turn — the policy stays `LocalOnly` unless this is
    /// `Some(RouteHint::Cloud)` AND both the lane and worker registration permit
    /// the remote lane.
    pub route_hint: Option<RouteHint>,
}

/// What approval gate, if any, a route decision must pass before execution.
///
/// This is the **F-7 autonomy seam**. M1 (on-device models only) always emits
/// [`ApprovalClass::None`] — there is genuinely no egress to gate. Keeping the
/// field in the decision type now means M2 wires approval into an existing
/// seam rather than retrofitting one onto every routing call site.
///
/// Tiering (F-7):
///
/// - **Tier A — Autonomous (`None`):** **on-device models only** (mistral.rs /
///   llama.cpp). Genuinely zero egress. *This is all of M1* — no approval surface
///   needed. (ACP agents are cloud-backed; cloud routing is INTENDED and
///   governed by the PII model, not prohibited — their tier is a G-M2-spec
///   decision, D-M2-1. "Local process ≠ local data.")
/// - **Tier B — Standing-grantable:** remote API / x0x peers / cloud-backed
///   ACP; per-class grant plus budget cap, revocable, auditable. *M2 spec.*
/// - **Tier C — Always per-turn:** sensitive-data lane, cross-owner, PII, or
///   anything outside a standing grant. *M2 spec.*
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum ApprovalClass {
    /// No approval needed (Tier A: on-device model only, genuinely zero egress).
    #[default]
    None,
    /// Per-turn approval required (Tier C: sensitive / cross-owner / PII, or
    /// anything not covered by a standing grant).
    #[allow(dead_code)] // TODO(M2): Tier C approval surface
    PerTurn,
    /// Covered by a standing, revocable grant (Tier B). `id` is the opaque
    /// grant identifier; the conductor resolves it against the grant ledger.
    /// M1 never emits this — present so the seam exists.
    #[allow(dead_code)] // TODO(M2): Tier B approval surface
    StandingGrant(String),
}

/// The conductor's decision for one turn. OWNED — safe to move across `.await`.
/// The executor resolves `recipe_id`/`worker_id` against the loaded recipe set
/// and worker registry, and computes the request fingerprint (HMAC of
/// `request_id` under the install key — F-4) during execution.
///
/// M1's `StaticDirectPolicy` always emits `direct` + `local-model` +
/// `ApprovalClass::None`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OwnedRouteDecision {
    /// Opaque; the executor HMACs it into the fingerprint. Never stored raw in
    /// telemetry (only its HMAC is).
    pub request_id: String,
    pub recipe_id: String,
    pub topology: ConductorTopology,
    pub worker_id: String,
    pub task_class: ConductorTaskClass,
    pub lane: PrivacyLane,
    pub approval: ApprovalClass,
    /// Short, static, audit-safe reason (e.g. `"static-direct-local"`).
    #[allow(dead_code)]
    // TODO(M2): surfaced in receipt.team_view; M1 receipts carry fallback_reason instead
    pub reason: String,
}

/// Failure to route — the executor fails closed to `direct`-local (never aborts
/// the user's turn) and logs the reason in the receipt's `fallback` field.
#[derive(Debug, Clone)]
pub enum RouteFailure {
    /// Recipe id not found in the loaded set.
    InvalidRecipe { recipe_id: String },
    /// Worker id not in the vetted registry.
    WorkerUnavailable { worker_id: String },
    /// Recipe requested chain but `chain_enabled` is false (or similar).
    RecipeDisabled { recipe_id: String, reason: String },
    /// The operator-selected model mode does not permit this privacy lane.
    ModeBlocked { mode: String, lane: PrivacyLane },
    /// A non-`None` approval class reached the executor in M1 (defense-in-depth;
    /// unreachable, since the static policy emits `None`).
    UnexpectedApproval { approval: ApprovalClass },
    /// A cloud-bound route was blocked by the PII egress membrane
    /// (`crates/fae-pii-membrane`). Carries **structured labels only — never user
    /// text** — so the failure is safe to surface in telemetry/receipts without
    /// leaking the secret it detected. Dead in M1 (no cloud-bound path exists:
    /// `StaticDirectPolicy` emits `LocalModel` only); constructed when M2
    /// cloud-routing + the membrane wiring land (see D-M2-1 / D-M2-4).
    #[allow(dead_code)] // TODO(M2): constructed when cloud egress membrane wiring lands
    PrivacyBlocked { level: String, labels: Vec<String> },
    /// A cloud-bound route exceeded a D2 budget cap. Carries structured numeric
    /// fields only — never user text — so receipts/telemetry can safely surface
    /// the reason.
    #[allow(dead_code)] // TODO(M2, 2026-06-23): constructed when BudgetGovernor wiring lands
    BudgetExceeded {
        dimension: BudgetDimension,
        limit: u64,
        attempted: u64,
        used: u64,
        window_ms: u64,
    },
    /// A mesh-delegated (`OwnerFleet`) route failed at the peer. M4: carries
    /// the worker id + the prompt-free outcome label (`mesh_timeout`,
    /// `mesh_peer_unreachable`, etc.) — never user text. Every non-`Completed`
    /// `MeshOutcomeKind` maps here and fail-closes to direct-local.
    #[allow(dead_code)] // M4-D: constructed by the mesh dispatch path
    MeshDelegationFailed {
        worker_id: String,
        outcome_label: String,
    },
}

/// The loaded recipe set, keyed by id. The executor looks up `recipe_id`
/// here before executing; a miss is a [`RouteFailure::InvalidRecipe`] that
/// fails closed to direct-local (spec §5.4).
/// The loaded recipe set, keyed by id. The executor looks up `recipe_id`
/// here before executing; a miss is a [`RouteFailure::InvalidRecipe`] that
/// fails closed to direct-local (spec §5.4).
#[derive(Debug, Clone, Default)]
pub struct RecipeSet {
    recipes: std::collections::HashMap<String, FaeConductorRecipe>,
}

impl RecipeSet {
    /// Build from an iterator of `(id, recipe)`. Later duplicates win.
    #[allow(dead_code)] // TODO(M2): M1 loads no candidate recipes; static-direct is hardcoded in the policy
    pub fn from_iter<I: IntoIterator<Item = (String, FaeConductorRecipe)>>(iter: I) -> Self {
        Self {
            recipes: iter.into_iter().collect(),
        }
    }

    /// Look up a recipe by id.
    pub fn get(&self, id: &str) -> Option<&FaeConductorRecipe> {
        self.recipes.get(id)
    }

    /// Number of loaded recipes.
    #[allow(dead_code)] // exercised in unit tests; M2 recipe loading surfaces it in runtime.status
    pub fn len(&self) -> usize {
        self.recipes.len()
    }

    /// Whether the set is empty.
    #[allow(dead_code)] // exercised in unit tests; M2 recipe loading surfaces it
    pub fn is_empty(&self) -> bool {
        self.recipes.is_empty()
    }
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
    fn v2_permits_remote_workers() {
        // ADR-014: the V2 profile admits a RemoteProvider worker on the
        // RemoteAllowed lane. The default (V1) still rejects it (asserted by
        // `v1_rejects_remote_workers`), so the two profiles diverge exactly here.
        let mut r = direct_recipe();
        let mut remote = local_worker("cloud:openrouter/openai/gpt-4.1-mini");
        remote.locality = WorkerLocality::RemoteProvider;
        r.allowed_workers = vec![remote.clone()];
        r.role_slots[0].worker = remote;
        r.privacy_lane = PrivacyLane::RemoteAllowed;

        // Same recipe: rejected by V1, accepted by V2.
        assert!(matches!(
            r.validate_for(RecipeProfile::V1Safe),
            Err(ConductorRecipeError::WorkerLocalityNotPermitted(_, _))
        ));
        assert!(r.validate_for(RecipeProfile::v2_remote_allowed()).is_ok());
    }

    #[test]
    fn v2_still_enforces_lane_monotonicity() {
        // A RemoteProvider worker on a narrower (CloudBacked) lane must still be
        // rejected — V2 loosens the permitted set, not the monotonicity floor.
        let mut r = direct_recipe();
        let mut remote = local_worker("cloud:openrouter/openai/gpt-4.1-mini");
        remote.locality = WorkerLocality::RemoteProvider;
        r.allowed_workers = vec![remote.clone()];
        r.role_slots[0].worker = remote;
        r.privacy_lane = PrivacyLane::CloudBacked;
        assert!(matches!(
            r.validate_for(RecipeProfile::V2RemoteAllowed),
            Err(ConductorRecipeError::WorkerExceedsPrivacyLane(_, _, _))
        ));
    }

    #[test]
    fn privacy_lane_permits_is_monotone() {
        assert!(PrivacyLane::LocalOnly.permits(PrivacyLane::LocalOnly));
        assert!(!PrivacyLane::LocalOnly.permits(PrivacyLane::CloudBacked));
        assert!(PrivacyLane::CloudBacked.permits(PrivacyLane::LocalOnly));
        assert!(PrivacyLane::CloudBacked.permits(PrivacyLane::CloudBacked));
        assert!(!PrivacyLane::CloudBacked.permits(PrivacyLane::OwnerFleet));
        assert!(PrivacyLane::OwnerFleet.permits(PrivacyLane::CloudBacked));
        assert!(PrivacyLane::RemoteAllowed.permits(PrivacyLane::LocalOnly));
        assert!(PrivacyLane::RemoteAllowed.permits(PrivacyLane::RemoteAllowed));
    }

    #[test]
    fn cloud_backed_acp_maps_to_cloud_backed_lane() {
        let mut r = direct_recipe();
        let mut acp = local_worker("acp:codex");
        acp.locality = WorkerLocality::CloudBackedAcp;
        r.allowed_workers = vec![acp.clone()];
        r.role_slots[0].worker = acp;
        r.privacy_lane = PrivacyLane::LocalOnly;
        assert!(matches!(
            r.validate(),
            Err(ConductorRecipeError::WorkerExceedsPrivacyLane(_, _, _))
        ));

        r.privacy_lane = PrivacyLane::CloudBacked;
        assert!(r.validate().is_ok());
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
        // F-15: star/debate fail-closed on deserialization (enum level).
        let bad = r#"{"topology":"star"}"#;
        assert!(serde_json::from_str::<ConductorTopology>(bad).is_err());
    }

    #[test]
    fn serde_recipe_rejects_star_topology() {
        // F-15: a FULL recipe carrying topology="star" must fail at the recipe
        // struct boundary (not just the enum). Generates a valid recipe JSON via
        // to_value, mutates topology, then deserializes — exercises the struct.
        let mut v = serde_json::to_value(direct_recipe()).expect("serialize in test");
        v["topology"] = serde_json::json!("star");
        let err = serde_json::from_value::<FaeConductorRecipe>(v);
        assert!(err.is_err(), "star topology must be rejected: {err:?}");
    }

    #[test]
    fn serde_recipe_rejects_debate_topology() {
        // F-15: debate topology rejected at the recipe struct boundary.
        let mut v = serde_json::to_value(direct_recipe()).expect("serialize in test");
        v["topology"] = serde_json::json!("debate");
        let err = serde_json::from_value::<FaeConductorRecipe>(v);
        assert!(err.is_err(), "debate topology must be rejected: {err:?}");
    }

    #[test]
    fn serde_recipe_rejects_unknown_field() {
        // F-15: the deny_unknown_fields proof. A valid recipe plus one extra
        // top-level field must fail — serde's forward-compat default would
        // otherwise silently accept attacker/mutation-injected metadata.
        let mut v = serde_json::to_value(direct_recipe()).expect("serialize in test");
        v["star_mode"] = serde_json::json!(true);
        let err = serde_json::from_value::<FaeConductorRecipe>(v);
        assert!(
            err.is_err(),
            "unknown top-level field must be rejected: {err:?}"
        );
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
