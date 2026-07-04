//! Phase E — the peer-ingress trust verifier.
//!
//! [`FaeSenderVerifier`] implements the envelope gate's
//! [`SignatureVerifier`] trait. The trait hands the verifier the full
//! [`PeerEnvelope`] (pre-acceptance), so BOTH signature-shape checks and
//! sender-tier-by-kind enforcement live inside `verify()` — no restructuring
//! of the gate was needed. The tier rules are factored into [`TierPolicy`] so
//! the dispatcher ([`super::handler::dispatch`]) can re-check them as defense
//! in depth on already-accepted envelopes.
//!
//! ## v1 scope — shape only, NOT real ML-DSA
//!
//! v1 verifies `algorithm == "ml-dsa-65"` plus a non-empty, well-formed
//! `public_key_id` and `signature_b64` (base64 alphabet) — it does NOT perform
//! real ML-DSA-65 signature verification. The transport cross-check in
//! commit 2 leans on x0xd's own `verified: true` + `sender` fields from the
//! `/direct/events` SSE frame. **This impl is the reserved swap point**: when
//! real verification lands, it replaces the shape checks here (verify the
//! signature bytes against the pinned x0x machine key for `public_key_id`)
//! without touching the gate or the dispatcher.

use std::collections::HashSet;

use fae_envelope_gate::{EnvelopeKind, PeerEnvelope, SignatureVerifier};

/// Sender-tier policy: which sender may send which [`EnvelopeKind`].
///
/// | kind | permitted senders (v1) |
/// |------|------------------------|
/// | `SessionHandoff` | `owner_fleet` ONLY |
/// | `DirectMessage`, `PresenceUpdate`, `ConsentReceipt`, `ConsentRevocation` | `chat_allow` ∪ `owner_fleet` |
/// | `MemoryShareOffer`, `ConductorGateReceiptPrior` | nobody (not in the v1 action set) |
///
/// Agent ids are matched case-insensitively (normalised to lowercase both at
/// construction and at lookup).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TierPolicy {
    chat_allow: HashSet<String>,
    owner_fleet: HashSet<String>,
}

impl TierPolicy {
    pub fn new(chat_allow: HashSet<String>, owner_fleet: HashSet<String>) -> Self {
        Self {
            chat_allow: lowercase_all(chat_allow),
            owner_fleet: lowercase_all(owner_fleet),
        }
    }

    /// May `sender_id` send envelopes of `kind`?
    pub fn permits(&self, kind: &EnvelopeKind, sender_id: &str) -> bool {
        let sender = sender_id.to_ascii_lowercase();
        match kind {
            EnvelopeKind::SessionHandoff => self.owner_fleet.contains(&sender),
            EnvelopeKind::DirectMessage
            | EnvelopeKind::PresenceUpdate
            | EnvelopeKind::ConsentReceipt
            | EnvelopeKind::ConsentRevocation => {
                self.chat_allow.contains(&sender) || self.owner_fleet.contains(&sender)
            }
            // Not in the v1 action set — nobody may send these to us yet.
            EnvelopeKind::MemoryShareOffer | EnvelopeKind::ConductorGateReceiptPrior => false,
        }
    }
}

fn lowercase_all(ids: HashSet<String>) -> HashSet<String> {
    ids.into_iter().map(|id| id.to_ascii_lowercase()).collect()
}

/// The production verifier handed to `gate_and_audit` for peer ingress.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FaeSenderVerifier {
    policy: TierPolicy,
}

impl FaeSenderVerifier {
    pub fn new(chat_allow: HashSet<String>, owner_fleet: HashSet<String>) -> Self {
        Self {
            policy: TierPolicy::new(chat_allow, owner_fleet),
        }
    }

    /// The tier rules, for the dispatcher's defense-in-depth re-check.
    pub fn policy(&self) -> &TierPolicy {
        &self.policy
    }
}

impl SignatureVerifier for FaeSenderVerifier {
    fn verify(&self, envelope: &PeerEnvelope) -> bool {
        let signature = envelope.signature();
        if signature.algorithm() != "ml-dsa-65" {
            return false;
        }
        if signature.public_key_id().trim().is_empty() {
            return false;
        }
        if !is_base64_shaped(signature.signature_b64()) {
            return false;
        }
        self.policy.permits(envelope.kind(), envelope.sender_id())
    }
}

/// Shape check only (see module docs): non-empty, standard or url-safe base64
/// alphabet with optional `=` padding.
fn is_base64_shaped(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'-' | b'_' | b'='))
}

#[cfg(test)]
mod tests {
    use super::*;
    use fae_envelope_gate::{gate_and_audit, GateError, MAX_ENVELOPE_BYTES};
    use std::collections::HashSet;

    const CHAT_SENDER: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const FLEET_SENDER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const UNKNOWN_SENDER: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

    fn verifier() -> FaeSenderVerifier {
        FaeSenderVerifier::new(
            HashSet::from([CHAT_SENDER.to_owned()]),
            HashSet::from([FLEET_SENDER.to_owned()]),
        )
    }

    /// Raw envelope JSON in the gate's wire shape. The verifier trait only
    /// ever sees a `&PeerEnvelope` minted by the gate itself (fields are
    /// private, `parse_and_gate` is crate-private to the gate), so the
    /// accept/reject matrix is exercised end-to-end through `gate_and_audit`.
    fn envelope_json(kind: &str, sender: &str, algorithm: &str, signature_b64: &str) -> String {
        serde_json::json!({
            "schema_version": 1,
            "kind": kind,
            "envelope_id": "env-1",
            "sender_id": sender,
            "created_at_ms": 1_700_000_000_000_u64,
            "payload": { "text": "hello" },
            "signature": {
                "algorithm": algorithm,
                "public_key_id": "pk-1",
                "signature_b64": signature_b64,
            }
        })
        .to_string()
    }

    fn gate(raw: &str) -> Result<(), GateError> {
        let dir = tempfile::tempdir().unwrap();
        gate_and_audit(raw, &verifier(), &dir.path().join("audit.jsonl")).map(|_| ())
    }

    #[test]
    fn allowlisted_chat_sender_direct_message_accepted() {
        let raw = envelope_json("direct_message", CHAT_SENDER, "ml-dsa-65", "c2ln");
        assert!(gate(&raw).is_ok());
    }

    #[test]
    fn unknown_sender_rejected() {
        let raw = envelope_json("direct_message", UNKNOWN_SENDER, "ml-dsa-65", "c2ln");
        assert!(matches!(gate(&raw), Err(GateError::SignatureRejected)));
    }

    #[test]
    fn session_handoff_from_owner_fleet_accepted() {
        let raw = envelope_json("session_handoff", FLEET_SENDER, "ml-dsa-65", "c2ln");
        assert!(gate(&raw).is_ok());
    }

    #[test]
    fn session_handoff_from_chat_only_sender_rejected() {
        // Chat tier is NOT enough to hand a session over — owner fleet only.
        let raw = envelope_json("session_handoff", CHAT_SENDER, "ml-dsa-65", "c2ln");
        assert!(matches!(gate(&raw), Err(GateError::SignatureRejected)));
    }

    #[test]
    fn wrong_algorithm_rejected_even_for_fleet_sender() {
        let raw = envelope_json("direct_message", FLEET_SENDER, "ed25519", "c2ln");
        assert!(matches!(gate(&raw), Err(GateError::SignatureRejected)));
    }

    #[test]
    fn empty_or_malformed_signature_rejected() {
        let raw = envelope_json("direct_message", CHAT_SENDER, "ml-dsa-65", "");
        assert!(matches!(gate(&raw), Err(GateError::SignatureRejected)));

        let raw = envelope_json("direct_message", CHAT_SENDER, "ml-dsa-65", "not base64 !!");
        assert!(matches!(gate(&raw), Err(GateError::SignatureRejected)));
    }

    #[test]
    fn v1_out_of_scope_kinds_rejected_even_from_fleet() {
        for kind in ["memory_share_offer", "conductor_gate_receipt_prior"] {
            let raw = envelope_json(kind, FLEET_SENDER, "ml-dsa-65", "c2ln");
            assert!(
                matches!(gate(&raw), Err(GateError::SignatureRejected)),
                "{kind} must be rejected in v1"
            );
        }
    }

    #[test]
    fn fleet_sender_may_also_chat() {
        let raw = envelope_json("presence_update", FLEET_SENDER, "ml-dsa-65", "c2ln");
        assert!(gate(&raw).is_ok());
    }

    #[test]
    fn tier_policy_matches_case_insensitively() {
        let policy = TierPolicy::new(
            HashSet::from([CHAT_SENDER.to_ascii_uppercase()]),
            HashSet::new(),
        );
        assert!(policy.permits(&EnvelopeKind::DirectMessage, CHAT_SENDER));
        assert!(policy.permits(
            &EnvelopeKind::DirectMessage,
            &CHAT_SENDER.to_ascii_uppercase()
        ));
        assert!(!policy.permits(&EnvelopeKind::SessionHandoff, CHAT_SENDER));
    }

    #[test]
    fn envelope_fixtures_stay_under_gate_cap() {
        // Sanity: the verifier matrix above must be exercising the verifier,
        // not tripping the size gate first.
        let raw = envelope_json("direct_message", CHAT_SENDER, "ml-dsa-65", "c2ln");
        assert!(raw.len() < MAX_ENVELOPE_BYTES);
    }
}
