//! The networked-tool egress gate (ADR-013 Vision A, A2; oracle BLOCKER-1).
//!
//! The seam is a trait so production can wire a conductor-backed adapter while
//! tests inject fakes. The gate is consulted ONLY for `Networked` tools; it
//! MUST check **all three** equivalents of `assert_agent_egress_gates`
//! (`session.rs`): mode/lane, PII, and provisioning — never the PII scan alone.
//! A clean `fetch_url`/`web_search` input with no sentinel would otherwise be
//! allowed even when cloud egress is disabled or the worker is unprovisioned.
//!
//! **A2 posture (fail-closed):** there are no real networked tools yet
//! (`web_search`/`fetch_url` land via P7 skills on A2.5). So the production
//! default is [`DisabledGate`] — every networked tool denies with
//! [`EgressDenyReason::Disabled`] until the full conductor-backed 3-gate
//! adapter is wired. Tests use [`FakeEgressGate`] to prove each deny path
//! (mode-off, unprovisioned, privacy) fires when an adapter reports it.

use async_trait::async_trait;
use serde_json::Value;

/// The outcome of gating one networked-tool call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EgressDecision {
    /// All three gates (mode + PII + provisioning) passed; the call may run.
    Allow,
    /// At least one gate blocked the call.
    Deny(EgressDenyReason),
}

/// Why a networked tool was blocked. Mirrors the three gates plus the A2
/// fail-closed default.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EgressDenyReason {
    /// The cloud/remote lane is not permitted under the current model mode.
    ModeBlocked,
    /// The remote worker is not provisioned (or is the wrong locality).
    NotProvisioned,
    /// A sentinel/secret was detected in the bounded extracted field.
    PrivacyBlocked,
    /// A2 default: networked tools are not enabled yet (no adapter wired).
    Disabled,
}

impl EgressDenyReason {
    /// Short static wire label for the audit row.
    #[must_use]
    pub fn as_label(&self) -> &'static str {
        match self {
            Self::ModeBlocked => "egress_mode_blocked",
            Self::NotProvisioned => "egress_not_provisioned",
            Self::PrivacyBlocked => "egress_privacy_blocked",
            Self::Disabled => "egress_disabled",
        }
    }
}

/// The egress gate. Consulted for `Networked`-class tools only.
///
/// Production adapter (deferred to when real networked tools exist, A2.5/P7):
/// extract the bounded known fields (`url`/`query`) from `input`, then run
/// `mode_permits_lane` + `fae_pii_membrane::{should_block_remote_egress, scan}`
/// + `workers.is_provisioned` + locality — mirroring `assert_agent_egress_gates`
/// but on tool-shaped fields, not a prompt blob.
#[async_trait]
pub trait ToolEgressGate: Send + Sync {
    /// Gate one networked-tool call. Returning `Allow` is the ONLY path by
    /// which a networked tool may execute.
    async fn check_network_tool(&self, tool: &str, input: &Value) -> EgressDecision;
}

/// The A2 production default: every networked tool is denied (`Disabled`).
///
/// This is the fail-closed posture until the conductor-backed 3-gate adapter
/// is wired (when real `web_search`/`fetch_url` tools arrive, A2.5/P7). It is
/// intentionally non-empty: the gate MUST exist and be consulted from day one
/// so the wiring is structural, not a caller convention.
#[derive(Default, Clone, Copy)]
pub struct DisabledGate;

#[async_trait]
impl ToolEgressGate for DisabledGate {
    async fn check_network_tool(&self, _tool: &str, _input: &Value) -> EgressDecision {
        EgressDecision::Deny(EgressDenyReason::Disabled)
    }
}

// ---------------------------------------------------------------------------
// test support
// ---------------------------------------------------------------------------

/// A configurable gate for tests. Returns a fixed decision regardless of input
/// so each deny path can be exercised in isolation.
#[cfg(test)]
#[derive(Clone)]
pub struct FakeEgressGate {
    decision: EgressDecision,
}

#[cfg(test)]
impl FakeEgressGate {
    #[must_use]
    pub fn allow() -> Self {
        Self {
            decision: EgressDecision::Allow,
        }
    }

    #[must_use]
    pub fn deny(reason: EgressDenyReason) -> Self {
        Self {
            decision: EgressDecision::Deny(reason),
        }
    }
}

#[cfg(test)]
#[async_trait]
impl ToolEgressGate for FakeEgressGate {
    async fn check_network_tool(&self, _tool: &str, _input: &Value) -> EgressDecision {
        self.decision.clone()
    }
}
