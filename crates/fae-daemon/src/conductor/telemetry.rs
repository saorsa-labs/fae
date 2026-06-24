//! Telemetry + receipt types.
//!
//! [`ConductorRouteEvent`] is the row written to the conductor store per route
//! decision/role-call. [`RouteReceipt`] is the human/audit-facing summary. Both
//! **exclude raw prompts, raw memory, raw file contents, and secrets** — only
//! hashes/aggregates/opaque tokens are carried (F-4, oracle risk #1).

use serde::{Deserialize, Serialize};

use crate::conductor::fingerprint::RequestFingerprint;
use crate::conductor::recipe::{
    ApprovalClass, ConductorRole, ConductorTaskClass, ConductorTopology, PrivacyLane,
    WorkerLocality,
};

/// One routable target, flattened for telemetry/receipts. `LocalModel` etc. map
/// 1:1 to [`WorkerLocality`]; kept as a separate enum so telemetry has a stable
/// shape even if `WorkerLocality` grows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TargetKind {
    LocalModel,
    CloudBackedAcp,
    OwnerFleet,
    TrustedPeer,
    RemoteProvider,
}

impl From<WorkerLocality> for TargetKind {
    fn from(l: WorkerLocality) -> Self {
        match l {
            WorkerLocality::LocalModel => TargetKind::LocalModel,
            WorkerLocality::CloudBackedAcp => TargetKind::CloudBackedAcp,
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
    #[allow(dead_code)] // exercised in unit tests; M2 eval aggregation uses it directly
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

// --- M2 feedback signal (§7) ---
//
// Explicit user feedback joined to receipts on `request_fingerprint` at reward
// scoring time. **M2 invariant (carried from ConductorRouteEvent): enum-like
// tokens only, never user text or paraphrases.** A rating is a bounded int,
// not prose. This keeps the isolated conductor store a non-side-channel for
// personal content.

/// Explicit user feedback for a routed turn. Late-arriving (the receipt is
/// written at turn-end, before feedback exists); appended to a separate
/// feedback log and joined to receipts on `request_fingerprint` at reward
/// scoring time (§7 MAJOR-4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UserSignal {
    /// User accepted the response as-is. Positive signal.
    Accept,
    /// User rejected the response. Strong negative signal.
    Reject,
    /// User edited the response. Mild negative signal (the route's output was
    /// close but not right).
    Edit,
    /// User-supplied rating, `0..=5`. Neutral-to-positive depending on value.
    Rating(u8),
}

impl UserSignal {
    /// True if this signal is an explicit negative (reject or edit).
    #[allow(dead_code)] // TODO(M2, 2026-06-23): surfaced in team-view / reward explainability
    pub fn is_negative(self) -> bool {
        matches!(self, Self::Reject | Self::Edit)
    }
}

/// One row of the feedback log (`conductor_feedback.jsonl`). Joins to
/// [`RouteReceipt`] / [`ConductorRouteEvent`] on `request_fingerprint`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedbackRecord {
    pub request_fingerprint: RequestFingerprint,
    pub signal: UserSignal,
    /// Millis since epoch.
    pub timestamp_ms: u64,
}

// --- M2 shadow-router records (§8) ---
//
// Persisted to the isolated conductor store (`conductor_shadow.jsonl`) by the
// shadow router. These live here (not in `shadow.rs`) so `store.rs` can persist
// them without a module cycle — telemetry owns all persisted conductor records.
// **M2 invariant:** enum-like tokens + routing decisions only, never user text.

/// The corpus entry a shadow turn matched, if any. Used to score deployed +
/// candidate decisions against ground truth.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CorpusMatch {
    pub corpus_version: String,
    pub entry_id: String,
}

/// Telemetry-safe snapshot of a route decision, omitting the raw
/// `request_id` (F-4). The full [`OwnedRouteDecision`] carries the opaque
/// `request_id` because the executor HMACs it into the fingerprint during
/// execution — but that id is **never** persisted raw. Correlation across
/// persisted records is via [`RequestFingerprint`] only. Built at the
/// shadow-capture boundary ([`ShadowRouter::evaluate_record`]) from a borrow of
/// the live decision, so no raw id is ever serialized to the conductor store.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TelemetryRouteDecision {
    pub recipe_id: String,
    pub topology: ConductorTopology,
    pub worker_id: String,
    pub task_class: ConductorTaskClass,
    pub lane: PrivacyLane,
    pub approval: ApprovalClass,
    /// Short, static, audit-safe reason (e.g. `"static-direct-local"`).
    pub reason: String,
}

impl From<&crate::conductor::recipe::OwnedRouteDecision> for TelemetryRouteDecision {
    fn from(d: &crate::conductor::recipe::OwnedRouteDecision) -> Self {
        Self {
            recipe_id: d.recipe_id.clone(),
            topology: d.topology,
            worker_id: d.worker_id.clone(),
            task_class: d.task_class,
            lane: d.lane,
            approval: d.approval.clone(),
            reason: d.reason.clone(),
        }
    }
}

/// One candidate's decision for a turn, plus whether it matched the corpus's
/// ideal route. The decision is **never executed** (shadow = decision only).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CandidateDecision {
    /// The candidate policy id. **Token only — never user text.**
    pub candidate_id: String,
    /// The decision the candidate *would have* made. **Never executed.**
    /// Telemetry-safe: no raw `request_id` (F-4).
    pub decision: TelemetryRouteDecision,
    /// True if this decision matched the corpus's `ideal_route` (when matched).
    pub matched_ideal: bool,
}

/// One turn's shadow record, written to the isolated conductor store. This is
/// the row the reward aggregator's live window reads (§7). Joins to receipts /
/// events on `request_fingerprint`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShadowTurnRecord {
    pub request_fingerprint: RequestFingerprint,
    /// The deployed policy's decision (the one actually executed through §5).
    /// Telemetry-safe: no raw `request_id` (F-4) — correlation is via
    /// `request_fingerprint` only.
    pub deployed_decision: TelemetryRouteDecision,
    /// Whether the deployed decision matched the corpus ideal (when matched).
    pub deployed_matched_ideal: bool,
    /// Each candidate's decision (never executed) + match outcome.
    pub candidates: Vec<CandidateDecision>,
    /// The corpus entry this turn matched, if any (`None` ⇒ no ground truth).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub corpus_match: Option<CorpusMatch>,
    /// Millis since epoch.
    pub timestamp_ms: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fp() -> RequestFingerprint {
        RequestFingerprint("a".repeat(64))
    }

    // F-4 regression (oracle ea2dc52c BLOCKER-1): a ShadowTurnRecord built from
    // an OwnedRouteDecision carrying a sentinel raw request_id must NOT leak that
    // id when serialized. Correlation is via request_fingerprint only. Mutation
    // contract: if TelemetryRouteDecision is reverted to embed the raw
    // OwnedRouteDecision (or re-adds a request_id field), this fails.
    #[test]
    fn shadow_record_serialization_omits_raw_request_id() {
        use crate::conductor::recipe::{
            ApprovalClass, ConductorTaskClass, ConductorTopology, OwnedRouteDecision, PrivacyLane,
        };
        let raw = OwnedRouteDecision {
            request_id: "SENTINEL-RAW-ID-NEVER-PERSIST".to_owned(),
            recipe_id: "fae.static-direct.v1".to_owned(),
            topology: ConductorTopology::Direct,
            worker_id: "local-model".to_owned(),
            task_class: ConductorTaskClass::Unknown,
            lane: PrivacyLane::LocalOnly,
            approval: ApprovalClass::None,
            reason: "static-direct-local".to_owned(),
        };
        let record = ShadowTurnRecord {
            request_fingerprint: fp(),
            deployed_decision: TelemetryRouteDecision::from(&raw),
            deployed_matched_ideal: false,
            candidates: vec![CandidateDecision {
                candidate_id: "cand".to_owned(),
                decision: TelemetryRouteDecision::from(&raw),
                matched_ideal: false,
            }],
            corpus_match: None,
            timestamp_ms: 1_700_000_000_000,
        };
        let json = serde_json::to_string(&record).expect("ser in test");
        assert!(
            !json.contains("SENTINEL-RAW-ID-NEVER-PERSIST"),
            "raw request_id leaked into serialized ShadowTurnRecord: {json}"
        );
        assert!(
            !json.contains("request_id"),
            "no request_id key at all: {json}"
        );
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
