//! Telemetry + receipt types.
//!
//! [`ConductorRouteEvent`] is the row written to the conductor store per route
//! decision/role-call. [`RouteReceipt`] is the human/audit-facing summary. Both
//! **exclude raw prompts, raw memory, raw file contents, and secrets** — only
//! hashes/aggregates/opaque tokens are carried (F-4, oracle risk #1).

use serde::{Deserialize, Serialize};

use crate::conductor::fingerprint::RequestFingerprint;
use crate::conductor::recipe::{
    ConductorRole, ConductorTaskClass, ConductorTopology, PrivacyLane, WorkerLocality,
};

/// One routable target, flattened for telemetry/receipts. `LocalModel` etc. map
/// 1:1 to [`WorkerLocality`]; kept as a separate enum so telemetry has a stable
/// shape even if `WorkerLocality` grows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TargetKind {
    LocalModel,
    LocalAcp,
    OwnerFleet,
    TrustedPeer,
    RemoteProvider,
}

impl From<WorkerLocality> for TargetKind {
    fn from(l: WorkerLocality) -> Self {
        match l {
            WorkerLocality::LocalModel => TargetKind::LocalModel,
            WorkerLocality::LocalAcp => TargetKind::LocalAcp,
            WorkerLocality::OwnerFleet => TargetKind::OwnerFleet,
            WorkerLocality::TrustedPeer => TargetKind::TrustedPeer,
            WorkerLocality::RemoteProvider => TargetKind::RemoteProvider,
        }
    }
}

/// A measured latency/cost outcome for one role-call. `None` fields mean "not
/// measured for this event" (e.g. latency unknown for a deferred mesh call).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConductorRouteEvent {
    /// Opaque per-install correlation token (F-4). Joins to other events for
    /// the same owner turn. **Never** a hash of user text.
    pub request_fingerprint: RequestFingerprint,
    pub task_class: ConductorTaskClass,
    /// Recipe that governed this turn (`None` for pre-M1 instrumentation-only
    /// events where no recipe was active).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipe_id: Option<String>,
    pub topology: ConductorTopology,
    /// Role for this specific event (`None` for a turn-level aggregate event).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<ConductorRole>,
    /// Stable worker id, or `None` for a local-answer event.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worker_id: Option<String>,
    pub target_kind: TargetKind,
    pub privacy_lane: PrivacyLane,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_micros: Option<u64>,
    pub success: bool,
    pub fallback_used: bool,
    /// Measured eval delta (M2), if this event was scored. Absent pre-M2.
    ///
    /// *M2 invariant:* values written here MUST NOT encode user query content —
    /// only aggregate scores/deltas (e.g. `"routing_acc:+0.08"`). The conductor
    /// store is isolated from personal memory; this field must not become a
    /// side-channel for prompts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eval_delta: Option<String>,
    /// Implicit user signal (M2): "praise" / "correction" / "abandonment" …
    ///
    /// *M2 invariant:* enum-like tokens only, never user text or paraphrases.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_signal: Option<String>,
    /// Millis since epoch.
    pub timestamp_ms: u64,
}

impl ConductorRouteEvent {
    /// Build a minimal turn-level event (no role/worker detail). M0b uses this
    /// shape; M1 fills role/worker as the executor runs.
    pub fn turn_level(
        request_fingerprint: RequestFingerprint,
        task_class: ConductorTaskClass,
        topology: ConductorTopology,
        target_kind: TargetKind,
        privacy_lane: PrivacyLane,
        timestamp_ms: u64,
    ) -> Self {
        Self {
            request_fingerprint,
            task_class,
            recipe_id: None,
            topology,
            role: None,
            worker_id: None,
            target_kind,
            privacy_lane,
            latency_ms: None,
            cost_micros: None,
            success: true,
            fallback_used: false,
            eval_delta: None,
            user_signal: None,
            timestamp_ms,
        }
    }
}

/// Human/audit-facing receipt for a route. Surfaces in the opt-in "team view"
/// Audit-facing per-turn receipt. One written per `inject_text` after
/// execution. Joins to [`ConductorRouteEvent`] via `request_fingerprint`.
/// Excludes raw prompt/memory/secrets; the only payload-derived value is
/// `payload_hash` (SHA-256 of the *outbound* payload, M2), never the input.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteReceipt {
    /// Opaque per-install correlation token (F-4). Joins to the route event.
    pub request_fingerprint: RequestFingerprint,
    pub recipe_id: String,
    pub topology: ConductorTopology,
    pub worker_id: String,
    pub target_kind: TargetKind,
    pub privacy_lane: PrivacyLane,
    /// Roles executed, in order (M2 chain). `None` for direct topology.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub roles: Option<Vec<ConductorRole>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_micros: Option<u64>,
    pub success: bool,
    pub fallback: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback_reason: Option<String>,
    /// SHA-256 of the outbound payload (not the payload). M2.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload_hash: Option<String>,
    /// *M2 invariant:* aggregate scores only, never query content.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eval_delta: Option<String>,
    /// *M2 invariant:* enum-like tokens only, never user text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_signal: Option<String>,
    /// Millis since epoch.
    pub timestamp_ms: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fp() -> RequestFingerprint {
        RequestFingerprint("a".repeat(64))
    }

    #[test]
    fn event_roundtrip() {
        let e = ConductorRouteEvent::turn_level(
            fp(),
            ConductorTaskClass::Chat,
            ConductorTopology::Direct,
            TargetKind::LocalModel,
            PrivacyLane::LocalOnly,
            1_700_000_000_000,
        );
        let json = serde_json::to_string(&e).expect("ser in test");
        let back: ConductorRouteEvent = serde_json::from_str(&json).expect("de in test");
        assert_eq!(e, back);
    }

    #[test]
    fn receipt_roundtrip() {
        let r = RouteReceipt {
            request_fingerprint: fp(),
            recipe_id: "fae.static-direct.v1".into(),
            topology: ConductorTopology::Chain,
            worker_id: "local-model".into(),
            target_kind: TargetKind::LocalModel,
            privacy_lane: PrivacyLane::LocalOnly,
            roles: Some(vec![ConductorRole::Thinker, ConductorRole::Worker]),
            latency_ms: Some(450),
            cost_micros: Some(1200),
            success: true,
            fallback: false,
            fallback_reason: None,
            payload_hash: Some("deadbeef".into()),
            eval_delta: None,
            user_signal: None,
            timestamp_ms: 1,
        };
        let json = serde_json::to_string(&r).expect("ser in test");
        let back: RouteReceipt = serde_json::from_str(&json).expect("de in test");
        assert_eq!(r, back);
    }
}
