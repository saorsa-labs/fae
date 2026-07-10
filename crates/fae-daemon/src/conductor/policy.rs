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
    PrivacyLane, RouteHint, WorkerLocality,
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

    /// ADR-014: map the owner's `FAE_PRIVACY_LANE` selector to the mode cap.
    /// `local`→PureLocal, `fleet`→LocalSymphony, `all`→AllAvailable (the only
    /// value that permits the `RemoteAllowed` cloud lane). Missing OR unknown
    /// fails closed to PureLocal — the local-only default.
    pub fn from_privacy_lane(value: Option<&str>) -> Self {
        match value.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
            Some("local") => Self::PureLocal,
            Some("fleet") => Self::LocalSymphony,
            Some("all") => Self::AllAvailable,
            _ => Self::PureLocal,
        }
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

/// W3: the widest [`PrivacyLane`] the mode permits — the inverse of
/// [`mode_permits_lane`]. Used by `inject_text` to set the turn context's
/// `privacy_lane` from the startup `ModelMode`, so the policy's cloud-hint
/// path can actually reach `RemoteAllowed` when the owner opted in.
pub fn model_mode_to_lane(mode: ModelMode) -> PrivacyLane {
    match mode {
        ModelMode::PureLocal => PrivacyLane::LocalOnly,
        ModelMode::LocalSymphony => PrivacyLane::OwnerFleet,
        ModelMode::AllAvailable => PrivacyLane::RemoteAllowed,
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
        // UX W3 — honor an explicit owner cloud hint ONLY when BOTH preconditions
        // hold: the turn's privacy lane already permits `RemoteAllowed`, AND a
        // vetted `RemoteProvider` worker is registered for the turn. Any missing
        // precondition (no hint, narrower lane, no remote worker) falls through
        // to today's `LocalOnly` decision — the default stays local-always
        // (fail-closed). W3 wiring: inject_text now sets the lane from the
        // runtime's ModelMode and populates available_workers from the registry,
        // so this path is reachable when the owner opts in (FAE_PRIVACY_LANE=all).
        if ctx.route_hint == Some(RouteHint::Cloud)
            && ctx.privacy_lane == PrivacyLane::RemoteAllowed
        {
            if let Some(worker) = ctx
                .available_workers
                .iter()
                .find(|w| w.locality == WorkerLocality::RemoteProvider)
            {
                return OwnedRouteDecision {
                    request_id: ctx.request_id.clone(),
                    recipe_id: STATIC_DIRECT_RECIPE_ID.to_string(),
                    topology: ConductorTopology::Direct,
                    worker_id: worker.id.clone(),
                    task_class: Self::classify(ctx),
                    lane: PrivacyLane::RemoteAllowed,
                    approval: ApprovalClass::StandingGrant(
                        "remote_provider_provisioned".to_string(),
                    ),
                    reason: "route-hint-cloud".to_string(),
                };
            }
        }
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
            route_hint: None,
        }
    }

    /// A vetted OpenRouter remote-provider worker selector, for the cloud-hint
    /// tests. Mirrors the id shape `cloud:openrouter/<model>`.
    fn remote_worker() -> crate::conductor::recipe::WorkerSelector {
        crate::conductor::recipe::WorkerSelector {
            id: crate::conductor::workers::openrouter_worker_id("openai/gpt-4.1-mini"),
            kind: "remote".to_string(),
            locality: WorkerLocality::RemoteProvider,
            capabilities: Vec::new(),
            provider: Some("openrouter".to_string()),
            model: Some("openai/gpt-4.1-mini".to_string()),
            trust_scope: None,
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
    fn cloud_hint_honored_only_when_lane_and_worker_permit() {
        let p = StaticDirectPolicy;
        // All preconditions met: hint=cloud + RemoteAllowed lane + a registered
        // RemoteProvider worker ⇒ the RemoteAllowed decision to the cloud worker.
        let mut c = ctx("r");
        c.route_hint = Some(RouteHint::Cloud);
        c.privacy_lane = PrivacyLane::RemoteAllowed;
        c.available_workers = vec![remote_worker()];
        let d = p.decide(&c);
        assert_eq!(d.lane, PrivacyLane::RemoteAllowed);
        assert_eq!(d.worker_id, remote_worker().id);
        assert!(d.worker_id.starts_with("cloud:openrouter/"));
        assert_eq!(d.reason, "route-hint-cloud");
    }

    #[test]
    fn cloud_hint_ignored_when_lane_is_local() {
        // The lane fails closed: even with a hint + a remote worker, a narrower
        // lane keeps the turn local (byte-identical to today).
        let p = StaticDirectPolicy;
        let mut c = ctx("r");
        c.route_hint = Some(RouteHint::Cloud);
        c.privacy_lane = PrivacyLane::LocalOnly;
        c.available_workers = vec![remote_worker()];
        let d = p.decide(&c);
        assert_eq!(d.lane, PrivacyLane::LocalOnly);
        assert_eq!(d.worker_id, LOCAL_MODEL_WORKER_ID);
        assert_eq!(d.reason, "static-direct-local");
    }

    #[test]
    fn cloud_hint_ignored_when_no_remote_worker_registered() {
        // The lane permits remote but no RemoteProvider worker is registered ⇒
        // local. There is no path by which an unregistered endpoint becomes
        // routable.
        let p = StaticDirectPolicy;
        let mut c = ctx("r");
        c.route_hint = Some(RouteHint::Cloud);
        c.privacy_lane = PrivacyLane::RemoteAllowed;
        c.available_workers = Vec::new();
        let d = p.decide(&c);
        assert_eq!(d.lane, PrivacyLane::LocalOnly);
        assert_eq!(d.worker_id, LOCAL_MODEL_WORKER_ID);
    }

    #[test]
    fn absent_hint_is_byte_identical_local() {
        // No hint at all ⇒ today's static-direct-local decision, regardless of a
        // widened lane / registered worker.
        let p = StaticDirectPolicy;
        let mut c = ctx("r");
        c.privacy_lane = PrivacyLane::RemoteAllowed;
        c.available_workers = vec![remote_worker()];
        let d = p.decide(&c);
        assert_eq!(d.lane, PrivacyLane::LocalOnly);
        assert_eq!(d.worker_id, LOCAL_MODEL_WORKER_ID);
        assert_eq!(d.reason, "static-direct-local");
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

    #[test]
    fn privacy_lane_maps_to_mode_cap_and_fails_closed() {
        // ADR-014: local/fleet/all → the mode cap; anything else (incl. absent
        // and unknown) fails closed to pure-local.
        assert_eq!(
            ModelMode::from_privacy_lane(Some("local")),
            ModelMode::PureLocal
        );
        assert_eq!(
            ModelMode::from_privacy_lane(Some("fleet")),
            ModelMode::LocalSymphony
        );
        assert_eq!(
            ModelMode::from_privacy_lane(Some("all")),
            ModelMode::AllAvailable
        );
        assert_eq!(
            ModelMode::from_privacy_lane(Some("  ALL  ")),
            ModelMode::AllAvailable
        );
        // Fail-closed: absent and unknown both resolve to pure-local (no cloud).
        assert_eq!(ModelMode::from_privacy_lane(None), ModelMode::PureLocal);
        assert_eq!(
            ModelMode::from_privacy_lane(Some("cloud")),
            ModelMode::PureLocal
        );
        assert_eq!(
            ModelMode::from_privacy_lane(Some("remote")),
            ModelMode::PureLocal
        );
    }

    #[test]
    fn model_mode_to_lane_maps_each_mode_to_widest_permitted_lane() {
        assert_eq!(
            model_mode_to_lane(ModelMode::PureLocal),
            PrivacyLane::LocalOnly
        );
        assert_eq!(
            model_mode_to_lane(ModelMode::LocalSymphony),
            PrivacyLane::OwnerFleet
        );
        assert_eq!(
            model_mode_to_lane(ModelMode::AllAvailable),
            PrivacyLane::RemoteAllowed
        );
    }

    /// SECURITY CONDITION 1: default/unset mode resolves to LocalOnly — no
    /// config means never-remote, provably. If someone changes the ModelMode
    /// default or the mapping, this test fails.
    #[test]
    fn default_mode_maps_to_local_only_never_remote() {
        assert_eq!(
            model_mode_to_lane(ModelMode::default()),
            PrivacyLane::LocalOnly
        );
        // Also verify via the env path: absent env → default → PureLocal → LocalOnly
        assert_eq!(
            model_mode_to_lane(ModelMode::from_env_value(None)),
            PrivacyLane::LocalOnly
        );
        assert_eq!(
            model_mode_to_lane(ModelMode::from_env_value(Some("garbage"))),
            PrivacyLane::LocalOnly
        );
    }
}
