//! Dormant MetaOpt primitive for M3 groundwork.
//!
//! This crate is a faithful Rust port of Fae's Swift MetaOpt optimizer primitive:
//! typed hypotheses, hill-climbing keep/discard decisions, budget-limited benchmark
//! runs, and rollback seams for every mutable surface. It is intentionally unwired:
//! no daemon, scheduler, conductor, memory-store, or LLM provider integration exists
//! here. M3 will supply real trait implementations after the ADR-008 amendment lands.

#![forbid(unsafe_code)]
// TODO(M3): MetaOpt primitive staged for M3 integration. Gated on ADR-008 amendment for the ConductorRecipe surface. No caller exists yet.
#![allow(dead_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod conductor_recipe;
pub mod optimizer;
pub mod traits;
pub mod types;

pub use conductor_recipe::{
    is_protected_config_key, ConductorRecipePatch, ConductorRecipePort, ConductorRoleDto,
    ConductorTopologyDto, PatchRejection, RecipePortError, RecipeSummary, RoleSlotSpec,
    VerifierAction,
};
pub use optimizer::MetaOptimizer;
pub use traits::{
    BenchmarkRunner, ConfigPort, DirectivePort, HypothesisContext, HypothesisSource,
    ImprovementStore, MemorySeedId, MemorySeedPort, SkillPort,
};
pub use types::{
    ConfigBound, DimensionScores, EvalDimension, FeedbackEvent, MetaOptBudget, MetaOptChange,
    MetaOptDecision, MetaOptError, MetaOptHypothesis, MetaOptResult, MetaOptSummary,
    MetaOptSurface,
};
