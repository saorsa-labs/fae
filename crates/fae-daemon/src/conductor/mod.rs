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
#![allow(dead_code)]
#![allow(unused_imports)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod error;
pub mod executor;
pub mod fingerprint;
pub mod policy;
pub mod prompts;
pub mod recipe;
pub mod store;
pub mod telemetry;
pub mod workers;

pub use error::ConductorError;
pub use executor::{route_turn, ConductorRuntime, SharedConductorRuntime};
pub use fingerprint::{InstallKey, RequestFingerprint};
pub use policy::{ConductorRoutingPolicy, StaticDirectPolicy, STATIC_DIRECT_RECIPE_ID};
pub use recipe::{
    AggregationPolicy, ApprovalClass, BudgetPolicy, ConductorRecipeError, ConductorRole,
    ConductorTaskClass, ConductorTopology, ConductorTurnContext, EscalationPolicy,
    FaeConductorRecipe, OwnedRouteDecision, PrivacyLane, RecipeSet, RoleSlot, RouteFailure,
    StopPolicy, WorkerLocality, WorkerSelector,
};
pub use store::ConductorStore;
pub use telemetry::{ConductorRouteEvent, RouteReceipt, TargetKind};
pub use workers::{WorkerRegistry, LOCAL_MODEL_WORKER_ID};

/// Supported topology set for v1. Star/Debate are intentionally absent — they
/// are compile-time-unreachable (F-15 enforcement, stronger than a runtime
/// assert) and fail-closed on deserialization (serde rejects unknown variants).
pub const SUPPORTED_TOPOLOGIES: &[ConductorTopology] =
    &[ConductorTopology::Direct, ConductorTopology::Chain];
