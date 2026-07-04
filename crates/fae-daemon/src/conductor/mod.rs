//! Fae learned **conductor** — the multi-model orchestration brain.
//!
//! Steals the single Fugu insight (learn orchestration) and grafts it onto
//! Fae's existing safety substrate. Grounded in Sakana's two ICLR 2026 papers:
//!
//! - **TRINITY** (arxiv 2512.04695): a ~0.6B + 10K evolutionary coordinator that
//!   delegates one of **three roles — Thinker / Worker / Verifier** to a chosen
//!   model from a pool, turn by turn. No weight merging; no shared architecture.
//! - **Conductor** (arxiv 2512.04388): RL-trained topology + per-worker
//!   instruction design. Heavier; deferred (needs a consented eval corpus).
//!
//! Fae's path: extend the (to-be-ported, Rust-native) MetaOpt loop to **mutate
//! routing recipes** — which worker, which role, which topology — under the
//! existing fail-closed gate-receipt / rollback pattern. See
//! `docs/research/fae-learned-conductor-d1-d7-plan-2026-06-22.md` (v3).
//!
//! ## M0b scope (this module)
//!
//! **Behavior-free scaffolding.** Value types, telemetry event/receipt types,
//! the route-event store, and the privacy-critical request fingerprint (F-4).
//! Nothing here is wired into the agent loop yet — [`crate::offline_turn`] and
//! [`crate::session`] are untouched. M1 introduces the static
//! `ConductorRoutingPolicy`; M2 the reward signal; M3 the MetaOpt mutation
//! surface (which requires the ADR-008 amendment).
//!
//! ## Storage isolation
//!
//! The conductor store is an **append-only JSONL** primitive (mirroring the
//! daemon's audit log). It is isolated from Fae's durable memory store — route
//! telemetry, recipe candidates, and eval outcomes live here, never in personal
//! memory. Only user-visible durable facts may enter the memory store, through
//! the memory ingest gate with supersession lineage.
//!
//! ## Privacy (F-4)
//!
//! No user text is ever hashed or stored. The sole correlation key between a
//! turn and its route telemetry is a [`fingerprint::RequestFingerprint`] —
//! HMAC-SHA-256 of the opaque `request_id` with a per-install random key. It
//! cannot be correlated across installations and reveals nothing about content.
#![forbid(unsafe_code)]
// M0b scaffolding: the types below are not yet consumed by the agent loop.
// `dead_code` is expected until M1 wires the routing policy; removing this
// allow is itself an M1 acceptance criterion.
// M1 wires the runtime/policy/executor/telemetry. The dead-code allowance is
// REMOVED in M1 (spec §13.7 acceptance item) — each genuinely-staged M2/M3
// item below carries a targeted, dated `#[allow(dead_code)]` with the
// milestone that will consume it. Do NOT add new blanket allows.
#![allow(unused_imports)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod budget;
/// M4 — content-aware task classifier. The designated F-4/n boundary-crossing
/// surface: the ONE conductor component that reads prompt text. Emits labels only
/// (task_class + allowlisted predicates + source); everything else stays
/// content-blind. Wired into `session::build_turn_context` (M4-B). No
/// LLM/mistralrs/async/cloud — deterministic rule-based MVP; the trait is the
/// upgrade surface.
pub mod classifier;
/// ADR-014 cloud lane: [`cloud_provider::ProviderBackedCloudProvider`] drives a
/// real `fae_engine` `ProviderAdapter` (OpenRouter) to completion behind the
/// conductor egress gates. Replaces `MockCloudProvider` in production wiring
/// only when the `RemoteAllowed` lane is enabled (`FAE_PRIVACY_LANE=all` + the
/// OpenRouter env contract); default startup keeps the mock, unchanged.
pub mod cloud_provider;
pub mod error;
pub mod eval;
pub mod executor;
pub mod fingerprint;
/// M6-Intel: shared intelligence as signed candidate priors. M6-B surface is
/// the EXPORT sanitizer + unsigned-preview writer — projects a `RouteReceipt`
/// onto the §3.1 closed allowlist (total projection; denylisted fields
/// structurally absent), bounds + token-validates exported `String`s, buckets
/// latency, and emits a `PeerEnvelope`-shaped JSON the gate re-parses on import
/// (M6-C). Dormant: no production caller until M6-C/D. v1 is export-only +
/// import-rejects-all (no accepting unsigned priors); real ML-DSA-65 is M6-E.
/// Local file write only — no network egress, never `fae.db`.
#[allow(dead_code)] // M6-B dormant; callers land in M6-C (import) / M6-D (sink).
pub mod intel;
/// M4-C mesh delegation port — the `OwnerFleet` (same-owner x0x) rung of ADR-012's
/// trust gradient. The async-ready `ConductorMeshDelegationPort` + prompt-free
/// DTOs. Dormant in M4: M4-D will wire production to use
/// `UnavailableMeshDelegationPort` (fail-closed; defined here, not yet
/// constructed by runtime); tests inject `MockMeshDelegationPort`. Real
/// transport (REST to a localhost `x0x-computed` daemon) is M4-E, blocked on
/// x0x-compute's real backend. x0x types NEVER cross this boundary
/// (guard-mesh-boundary.sh).
#[allow(dead_code)] // M4-D executor dispatch + tests are the callers; not yet wired in production
pub mod mesh;
/// M3-C4 offline recipe-mutation CLI (`fae-daemon conductor metaopt-run --recipe`).
/// Matches the `--offline-turn` pattern: an early branch in `main.rs` dispatches
/// here. The ONLY production construction site for [`DaemonConductorRecipePort`]
/// (otherwise tests-only). Human-in-the-loop: apply requires `--yes`.
#[allow(dead_code)] // constructed via main.rs dispatch; not referenced elsewhere in the crate
pub mod metaopt_cli;
pub mod policy;
pub mod pricing;
/// M3 §5 deterministic prompt-mutation lint. Called by the recipe validator
/// (`recipe_mutation::apply_one`) when validating a `MutateRolePrompt` patch or
/// a `SwitchTopology` chain-slot prompt body.
pub mod prompt_lint;
pub mod prompts;
pub mod recipe;
/// M3-C2 daemon-side `ConductorRecipePort` adapter (Layer-1 validation +
/// M3-C3 CAS apply/rollback). Constructed by the offline CLI
/// ([`metaopt_cli`]) — still NOT wired into the executor / turn loop / scheduler.
/// The CI boundary guard keeps fae-metaopt reachable only via this module +
/// [`metaopt_cli`]. Mutation stays offline/CLI-only until the content-aware
/// classifier lands (hard gate).
pub mod recipe_mutation;
/// M2 reward aggregator (spec §7). **Capture is wired** (Stage A
/// `route_turn` → `capture_shadow`) and **the reward is now consumable**
/// (Stage C `ConductorRuntime::reward_snapshot` joins the live window and
/// calls `aggregate_reward`). The self-judgment-advisory-only invariant (F-10)
/// is structurally enforced + mutation-tested regardless.
// Stage C (2026-06-24) wired reward_snapshot → aggregate_reward has live
// call sites now. The module-level allow remains for SelfJudgment::new (model
// self-judgment injection is a future milestone; the snapshot surface passes
// self_judgment: None — F-10 honest).
#[allow(dead_code)]
pub mod reward;
/// M2 shadow router (spec §8). Decision-only + structurally no-egress (holds
/// no CloudProvider/AcpAgentRunner handle). **Per-turn shadow *capture* is now
/// wired** (Stage A of the M2-live-wiring milestone: `ConductorRuntime::
/// with_shadow` + `route_turn` → `capture_shadow`). **Promotion flagging**
/// (`score_policies`/`flag_promotion_candidates`/`PromotionCandidate`) remains
/// dormant until M3 candidates land.
#[allow(dead_code)] // TODO(M3): promotion flagging surfaces when candidate recipes land
pub mod shadow;
pub mod store;
pub mod telemetry;
pub mod workers;

pub use budget::{
    ActualCost, BudgetDimension, BudgetGovernor, BudgetLimits, BudgetVerdict, CostEstimate,
    DEFAULT_DAILY_WINDOW_MS,
};
pub use cloud_provider::ProviderBackedCloudProvider;
pub use error::ConductorError;
pub use eval::{is_improvement, score, Corpus, RoutingScore, RoutingScorer};
pub use executor::{route_turn, ConductorEgress, ConductorRuntime};
pub use fingerprint::{InstallKey, RequestFingerprint};
pub use policy::{
    mode_permits_lane, ConductorRoutingPolicy, ModelMode, StaticDirectPolicy,
    STATIC_DIRECT_RECIPE_ID,
};
pub use pricing::{ProviderPricing, ProviderPricingTable};
pub use recipe::{
    AggregationPolicy, ApprovalClass, BudgetPolicy, ConductorRecipeError, ConductorRole,
    ConductorTaskClass, ConductorTopology, ConductorTurnContext, EscalationPolicy,
    FaeConductorRecipe, OwnedRouteDecision, PrivacyLane, RecipeSet, RoleSlot, RouteFailure,
    StopPolicy, WorkerLocality, WorkerSelector,
};
pub use reward::{
    aggregate_reward, OutcomeMetrics, Reward, RewardComponents, RewardRoutingSource, RewardSignals,
    RewardSnapshot, RewardSnapshotBaseline, RewardSnapshotWindow, SelfJudgment,
};
pub use shadow::{NamedPolicy, PromotionCandidate, ShadowRouter};
pub use store::ConductorStore;
pub use telemetry::{
    CandidateDecision, ConductorRouteEvent, CorpusMatch, FeedbackRecord, RouteReceipt,
    ShadowTurnRecord, TargetKind, UserSignal,
};
pub use workers::{WorkerRegistry, LOCAL_MODEL_WORKER_ID};

/// Supported topology set for v1. Star/Debate are intentionally absent — they
/// are compile-time-unreachable (F-15 enforcement, stronger than a runtime
/// assert) and fail-closed on deserialization (serde rejects unknown variants).
/// Consumed once the daemon exposes a runtime.status conductor surface (M2).
#[allow(dead_code)] // TODO(M2): runtime.status conductor surface
pub const SUPPORTED_TOPOLOGIES: &[ConductorTopology] =
    &[ConductorTopology::Direct, ConductorTopology::Chain];
