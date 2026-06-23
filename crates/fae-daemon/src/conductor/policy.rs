//! The routing policy: pure, synchronous, side-effect-free, INFALLIBLE.
//!
//! Computes nothing that can fail — no I/O, no CSPRNG, no HMAC. The fingerprint
//! is computed in the executor (which is async and `Result`-friendly and holds
//! the install key), keeping the policy genuinely pure. This separation is the
//! v1 M2 fix: an infallible `decide()` cannot legally `unwrap` a fallible HMAC.
//!
//! M1 has exactly one impl, `StaticDirectPolicy`, which always emits `direct` +
//! `local-model` + `ApprovalClass::None`. The trait exists so M3 (MetaOpt
//! mutation) can swap impls without touching the wiring.

use crate::conductor::recipe::{
    ApprovalClass, ConductorTaskClass, ConductorTopology, ConductorTurnContext, OwnedRouteDecision,
    PrivacyLane,
};
use crate::conductor::workers::LOCAL_MODEL_WORKER_ID;

/// Decide a route from context alone. Pure + infallible by construction.
pub trait ConductorRoutingPolicy: Send + Sync {
    fn decide(&self, ctx: &ConductorTurnContext) -> OwnedRouteDecision;
}

/// Operator-selected model availability mode for the conductor egress gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ModelMode {
    /// Only on-device local model routes may execute.
    #[default]
    PureLocal,
    /// On-device local model routes plus same-owner fleet routes may execute.
    LocalSymphony,
    /// All lanes are eligible; later gates still fail closed on privacy/budget/approval.
    AllAvailable,
}

impl ModelMode {
    /// Parse the environment-facing spelling. Unknown or absent values are not
    /// accepted here; callers choose the safe default.
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "pure-local" | "pure_local" | "local" => Some(Self::PureLocal),
            "local-symphony" | "local_symphony" | "symphony" => Some(Self::LocalSymphony),
            "all-available" | "all_available" | "all" => Some(Self::AllAvailable),
            _ => None,
        }
    }

    /// Parse an optional environment value, defaulting safely to pure-local.
    pub fn from_env_value(value: Option<&str>) -> Self {
        value.and_then(Self::parse).unwrap_or(Self::PureLocal)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::PureLocal => "pure-local",
            Self::LocalSymphony => "local-symphony",
            Self::AllAvailable => "all-available",
        }
    }
}

/// Stage-1 lane cap. Pure-local permits LocalOnly only; local-symphony permits
/// LocalOnly + OwnerFleet; all-available permits every lane.
pub fn mode_permits_lane(mode: ModelMode, lane: PrivacyLane) -> bool {
    match mode {
        ModelMode::PureLocal => lane == PrivacyLane::LocalOnly,
        ModelMode::LocalSymphony => {
            matches!(lane, PrivacyLane::LocalOnly | PrivacyLane::OwnerFleet)
        }
        ModelMode::AllAvailable => true,
    }
}

/// The single M1 recipe id (direct topology, local-model worker).
pub const STATIC_DIRECT_RECIPE_ID: &str = "fae.static-direct.v1";

/// M1's only policy. Content-blind: it does not read prompt text at all.
/// `classify()` is a placeholder over non-content metadata; in M1 it is inert
/// because the policy always returns `direct` regardless of `task_class`.
#[derive(Debug, Clone, Default)]
pub struct StaticDirectPolicy;

impl StaticDirectPolicy {
    /// Coarse classifier over **non-content metadata only**. Reads no prompt
    /// text. In M1 the result is inert (the policy returns `direct` for every
    /// task class); the classification is emitted in telemetry so M2/M3 can
    /// learn from it.
    fn classify(ctx: &ConductorTurnContext) -> ConductorTaskClass {
        // Honor the caller's hint if present; otherwise default to Unknown.
        // No prompt content is inspected.
        ctx.task_class
    }
}

impl ConductorRoutingPolicy for StaticDirectPolicy {
    fn decide(&self, ctx: &ConductorTurnContext) -> OwnedRouteDecision {
        OwnedRouteDecision {
            request_id: ctx.request_id.clone(),
            recipe_id: STATIC_DIRECT_RECIPE_ID.to_string(),
            topology: ConductorTopology::Direct,
            worker_id: LOCAL_MODEL_WORKER_ID.to_string(),
            task_class: Self::classify(ctx),
            lane: PrivacyLane::LocalOnly,
            approval: ApprovalClass::None,
            reason: "static-direct-local".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conductor::recipe::PrivacyLane;

    fn ctx(request_id: &str) -> ConductorTurnContext {
        ConductorTurnContext {
            request_id: request_id.to_string(),
            task_class: ConductorTaskClass::Unknown,
            feature_predicates: Vec::new(),
            privacy_lane: PrivacyLane::LocalOnly,
            available_workers: Vec::new(),
            working_directory: None,
            deadline_ms: None,
        }
    }

    #[test]
    fn static_policy_always_returns_direct_local_none() {
        let p = StaticDirectPolicy;
        for id in ["req-1", "req-2", "anything"] {
            let d = p.decide(&ctx(id));
            assert_eq!(d.topology, ConductorTopology::Direct);
            assert_eq!(d.worker_id, LOCAL_MODEL_WORKER_ID);
            assert_eq!(d.recipe_id, STATIC_DIRECT_RECIPE_ID);
            assert_eq!(d.approval, ApprovalClass::None);
            assert_eq!(d.request_id, id);
        }
    }

    #[test]
    fn static_policy_is_content_blind() {
        // The policy reads no prompt text; only request_id + task_class
        // metadata. Changing the context's task_class does not change the
        // worker/topology decision in M1 (always direct + local-model).
        let p = StaticDirectPolicy;
        let mut a = ctx("r");
        a.task_class = ConductorTaskClass::Coding;
        let d_a = p.decide(&a);
        let d_b = p.decide(&ctx("r"));
        assert_eq!(d_a.worker_id, d_b.worker_id);
        assert_eq!(d_a.topology, d_b.topology);
        assert_eq!(d_a.lane, PrivacyLane::LocalOnly);
    }

    #[test]
    fn model_mode_defaults_safely_and_caps_lanes() {
        assert_eq!(ModelMode::from_env_value(None), ModelMode::PureLocal);
        assert_eq!(
            ModelMode::from_env_value(Some("unknown")),
            ModelMode::PureLocal
        );
        assert_eq!(
            ModelMode::parse("all-available"),
            Some(ModelMode::AllAvailable)
        );

        assert!(mode_permits_lane(
            ModelMode::PureLocal,
            PrivacyLane::LocalOnly
        ));
        assert!(!mode_permits_lane(
            ModelMode::PureLocal,
            PrivacyLane::CloudBacked
        ));
        assert!(mode_permits_lane(
            ModelMode::LocalSymphony,
            PrivacyLane::OwnerFleet
        ));
        assert!(!mode_permits_lane(
            ModelMode::LocalSymphony,
            PrivacyLane::CloudBacked
        ));
        assert!(mode_permits_lane(
            ModelMode::AllAvailable,
            PrivacyLane::RemoteAllowed
        ));
    }
}
