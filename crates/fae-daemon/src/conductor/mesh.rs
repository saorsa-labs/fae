//! Conductor mesh delegation port — the `OwnerFleet` (same-owner x0x) rung of
//! ADR-012's trust gradient.
//!
//! ## What this is (M4-C, F-13)
//!
//! The conductor's view of delegating a task-scoped prompt slice to a provisioned
//! same-owner peer running a heavier model (`delegate_to_mesh`). This is the port
//! the executor's dispatch split calls when a route's lane is `PrivacyLane::OwnerFleet`.
//!
//! ## What this is NOT
//!
//! - **Not wired to real transport (M4 is dormant).** M4-D will wire production
//!   to use [`UnavailableMeshDelegationPort`] (fail-closed); it is not yet
//!   constructed by runtime. Real transport (REST to a localhost `x0x-computed`
//!   daemon) is M4-E, blocked on x0x-compute gaining a
//!   real model backend (its `SkeletonRuntimeAdapter` is a deterministic stub
//!   today — see `docs/architecture/conductor-m4-f14-x0x-api-snapshot.md`).
//! - **Not an x0x dependency.** [`ConductorMeshDelegationPort`] and its DTOs are
//!   pure conductor types. x0x/x0x-compute types NEVER cross this boundary; the
//!   DTO translation happens in a future adapter behind this port (boundary-
//!   enforced: see `scripts/ci/guard-mesh-boundary.sh`).
//! - **Not a new egress path.** The executor calls `delegate` ONLY after the §5
//!   gate pipeline (mode cap → membrane → budget → provisioning/standing grant)
//!   has cleared the route. The port receives the post-membrane slice, nothing
//!   else — it never reads `fae.db`/`MemoryOrchestrator`.
//!
//! ## Telemetry safety
//!
//! [`MeshDelegationOutcome`] is the prompt-free projection (ids + outcome kind +
//! latency). The transient `answer` is returned to the user via the normal
//! completion path; it is NEVER persisted in conductor telemetry (mirrors the
//! `RecipeMutationRecord` F-4 discipline).
//!
//! ## Metadata hygiene
//!
//! `MeshDelegationRequest::mesh_request_id` is a FRESH per-delegation correlation
//! id — NOT the conductor's stable `request_id`, which would let a peer correlate
//! turns across time (see the M4 spec §6.1). No raw session/user identifiers
//! cross the mesh boundary.

use std::future::Future;
use std::pin::Pin;

/// A fresh, per-delegation correlation id — opaque to the peer, with no
/// cross-turn meaning (NOT the conductor's stable `request_id`). Keeps a peer
/// from correlating turns across time. Telemetry correlates via the existing
/// HMAC `RequestFingerprint` on the conductor side, not this id.
pub type MeshRequestId = String;

/// The conductor's request to delegate a task-scoped prompt slice to a
/// provisioned same-owner peer.
///
/// The slice is `prompt_from_command(cmd)` today — NOT durable recalled
/// memory. Sending recalled context across the mesh boundary is BLOCKED until
/// explicit per-call minimization rules exist (ADR-012 principle 3 enforcement
/// note).
#[derive(Debug, Clone)]
pub struct MeshDelegationRequest {
    /// Fresh per-delegation id (see module docs + spec §6.1). Never the
    /// conductor `request_id`.
    pub mesh_request_id: MeshRequestId,
    /// Which provisioned `OwnerFleet` worker the route targeted.
    pub peer_worker_id: String,
    /// The task-scoped prompt slice, post-membrane (the §5.3 gate has already
    /// cleared it). The only user content that crosses the mesh boundary.
    pub prompt_slice: String,
    pub max_output_tokens: u32,
    pub timeout_ms: u64,
}

/// The prompt-free outcome projection. `answer` is transient response data
/// returned to the user via the normal completion path; it is NEVER persisted in
/// conductor telemetry (ids/labels/latency only — mirrors F-4 discipline).
#[derive(Debug, Clone)]
pub struct MeshDelegationOutcome {
    /// Echoes the request's `mesh_request_id` (NOT the conductor `request_id`).
    pub mesh_request_id: MeshRequestId,
    pub peer_worker_id: String,
    /// Transient answer; `None` on any failure. Returned to the user, never
    /// persisted in telemetry.
    pub answer: Option<String>,
    pub latency_ms: u64,
    pub outcome_kind: MeshOutcomeKind,
}

/// What happened on the peer side. The executor maps every non-`Completed`
/// variant to fail-closed direct-local (the user still gets an answer via the
/// local model; the mesh route is marked as a fallback).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshOutcomeKind {
    /// The peer completed the inference and returned an answer.
    Completed,
    /// No peer reachable / peer not provisioned / daemon not running.
    PeerUnreachable,
    /// The call exceeded `timeout_ms` (the peer may still be computing).
    Timeout,
    /// The peer refused (ACL / capability / policy denial).
    Denied,
    /// Any other transport error (malformed response, HTTP non-2xx, connection
    /// reset). Includes "no port configured" — the fail-closed production
    /// default M4-D wires (`UnavailableMeshDelegationPort`).
    TransportError,
}

impl MeshOutcomeKind {
    /// True iff this outcome represents a failure (the executor must fail-closed).
    #[must_use]
    pub const fn is_failure(self) -> bool {
        !matches!(self, Self::Completed)
    }

    /// A short, prompt-free label for telemetry (e.g. "mesh_timeout").
    #[must_use]
    pub const fn as_label(self) -> &'static str {
        match self {
            Self::Completed => "mesh_completed",
            Self::PeerUnreachable => "mesh_peer_unreachable",
            Self::Timeout => "mesh_timeout",
            Self::Denied => "mesh_denied",
            Self::TransportError => "mesh_transport_error",
        }
    }
}

/// The conductor's view of mesh delegation. x0x/x0x-compute types NEVER cross
/// this boundary.
///
/// Async-ready (returns a boxed `Future`) so the future REST-to-localhost-daemon
/// adapter does not require a trait redesign. M4-D will wire production to use
/// [`UnavailableMeshDelegationPort`] (fail-closed; not yet constructed by
/// runtime); tests inject
/// [`MockMeshDelegationPort`].
///
/// Contract: the caller (executor) has ALREADY run the §5 gate pipeline; this
/// receives only the slice that cleared egress gating.
pub trait ConductorMeshDelegationPort: Send + Sync {
    /// Delegate a task-scoped prompt slice to a provisioned same-owner peer.
    fn delegate<'a>(
        &'a self,
        request: MeshDelegationRequest,
    ) -> Pin<Box<dyn Future<Output = MeshDelegationOutcome> + Send + 'a>>;
}

// ── Implementations ─────────────────────────────────────────────────────────

/// The dormant production default: no transport configured. Every call fails
/// closed (`TransportError`), so an `OwnerFleet` route under `local-symphony`
/// with no port degrades to direct-local exactly as if the peer were
/// unreachable. M4-D will wire this as the production default on
/// `ConductorRuntime` (it is not yet wired). This is the same posture as M3
/// (mutation unreachable from a running daemon).
#[derive(Debug, Default, Clone, Copy)]
pub struct UnavailableMeshDelegationPort;

impl ConductorMeshDelegationPort for UnavailableMeshDelegationPort {
    fn delegate<'a>(
        &'a self,
        request: MeshDelegationRequest,
    ) -> Pin<Box<dyn Future<Output = MeshDelegationOutcome> + Send + 'a>> {
        Box::pin(async move {
            // No transport configured — fail closed immediately. The executor
            // turns this into a fail-closed-direct fallback, so the user still
            // gets an answer via the local model; the mesh route is marked.
            MeshDelegationOutcome {
                mesh_request_id: request.mesh_request_id,
                peer_worker_id: request.peer_worker_id,
                answer: None,
                latency_ms: 0,
                outcome_kind: MeshOutcomeKind::TransportError,
            }
        })
    }
}

/// Test-only helpers (mock port) for M4-D executor tests. Lives behind
/// `#[cfg(test)]` so it can never leak into a production build.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use std::future::Future;
    use std::pin::Pin;

    /// A deterministic mock that returns a configured outcome — the ONLY way to
    /// exercise the happy path / failure mapping in tests. Never constructed by
    /// `ConductorRuntime::production` (M4-D will wire that to
    /// `UnavailableMeshDelegationPort`).
    pub(crate) struct MockMeshDelegationPort {
        outcome_kind: MeshOutcomeKind,
        answer: Option<String>,
        /// Number of times `delegate` was called (for the F-2 "mesh port not
        /// invoked when the membrane blocks" proof in M4-D).
        pub calls: std::sync::atomic::AtomicUsize,
    }

    impl MockMeshDelegationPort {
        #[must_use]
        pub(crate) fn completed(answer: impl Into<String>) -> Self {
            Self {
                outcome_kind: MeshOutcomeKind::Completed,
                answer: Some(answer.into()),
                calls: std::sync::atomic::AtomicUsize::new(0),
            }
        }

        #[must_use]
        pub(crate) fn failing(kind: MeshOutcomeKind) -> Self {
            debug_assert!(kind.is_failure());
            Self {
                outcome_kind: kind,
                answer: None,
                calls: std::sync::atomic::AtomicUsize::new(0),
            }
        }

        pub(crate) fn call_count(&self) -> usize {
            self.calls.load(std::sync::atomic::Ordering::SeqCst)
        }
    }

    impl ConductorMeshDelegationPort for MockMeshDelegationPort {
        fn delegate<'a>(
            &'a self,
            request: MeshDelegationRequest,
        ) -> Pin<Box<dyn Future<Output = MeshDelegationOutcome> + Send + 'a>> {
            self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let answer = self.answer.clone();
            let kind = self.outcome_kind;
            Box::pin(async move {
                MeshDelegationOutcome {
                    mesh_request_id: request.mesh_request_id,
                    peer_worker_id: request.peer_worker_id,
                    answer,
                    latency_ms: if kind == MeshOutcomeKind::Completed {
                        10
                    } else {
                        0
                    },
                    outcome_kind: kind,
                }
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The fail-closed production-default implementation ALWAYS fails closed — an
    /// OwnerFleet route with no port configured (once M4-D wires it) degrades to
    /// direct-local. No real transport is ever reached from production.
    #[tokio::test]
    async fn unavailable_port_always_fails_closed() {
        let port = UnavailableMeshDelegationPort;
        let req = MeshDelegationRequest {
            mesh_request_id: "mesh-req-1".to_string(),
            peer_worker_id: "fleet:peer".to_string(),
            prompt_slice: "hello".to_string(),
            max_output_tokens: 128,
            timeout_ms: 5000,
        };
        let outcome = port.delegate(req).await;
        assert_eq!(outcome.outcome_kind, MeshOutcomeKind::TransportError);
        assert!(outcome.outcome_kind.is_failure());
        assert!(outcome.answer.is_none());
        assert_eq!(outcome.mesh_request_id, "mesh-req-1");
        assert_eq!(outcome.peer_worker_id, "fleet:peer");
    }

    #[test]
    fn outcome_kind_is_failure_and_labels() {
        assert!(!MeshOutcomeKind::Completed.is_failure());
        assert!(MeshOutcomeKind::PeerUnreachable.is_failure());
        assert!(MeshOutcomeKind::Timeout.is_failure());
        assert!(MeshOutcomeKind::Denied.is_failure());
        assert!(MeshOutcomeKind::TransportError.is_failure());

        assert_eq!(MeshOutcomeKind::Completed.as_label(), "mesh_completed");
        assert_eq!(MeshOutcomeKind::Timeout.as_label(), "mesh_timeout");
        assert_eq!(MeshOutcomeKind::Denied.as_label(), "mesh_denied");
        assert_eq!(
            MeshOutcomeKind::PeerUnreachable.as_label(),
            "mesh_peer_unreachable"
        );
        assert_eq!(
            MeshOutcomeKind::TransportError.as_label(),
            "mesh_transport_error"
        );
    }

    use super::test_support::MockMeshDelegationPort;

    #[tokio::test]
    async fn mock_completed_returns_answer_and_counts() {
        let port = MockMeshDelegationPort::completed("peer answered");
        let req = MeshDelegationRequest {
            mesh_request_id: "m1".to_string(),
            peer_worker_id: "fleet:p".to_string(),
            prompt_slice: "do the thing".to_string(),
            max_output_tokens: 64,
            timeout_ms: 1000,
        };
        let outcome = port.delegate(req).await;
        assert_eq!(outcome.outcome_kind, MeshOutcomeKind::Completed);
        assert_eq!(outcome.answer.as_deref(), Some("peer answered"));
        assert_eq!(port.call_count(), 1);
    }

    #[tokio::test]
    async fn mock_failing_returns_no_answer() {
        let port = MockMeshDelegationPort::failing(MeshOutcomeKind::Timeout);
        let req = MeshDelegationRequest {
            mesh_request_id: "m2".to_string(),
            peer_worker_id: "fleet:p".to_string(),
            prompt_slice: "x".to_string(),
            max_output_tokens: 64,
            timeout_ms: 1000,
        };
        let outcome = port.delegate(req).await;
        assert_eq!(outcome.outcome_kind, MeshOutcomeKind::Timeout);
        assert!(outcome.answer.is_none());
    }
}
