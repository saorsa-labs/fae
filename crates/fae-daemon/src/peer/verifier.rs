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
//! ## Real ML-DSA-65 verification (strict by default)
//!
//! `verify()` performs REAL cryptographic verification via
//! [`super::signing::verify_envelope_signature`]: the envelope's embedded
//! public key must derive the claimed `sender_id` (the x0x agent-id binding —
//! see `signing.rs` module docs) and the ML-DSA-65 signature must verify over
//! the canonical signing bytes. This is defense in depth ON TOP of x0xd's own
//! transport verification (`verified: true` on the SSE frame, checked
//! pre-gate) and the transport-sender cross-check (post-gate).
//!
//! ## Interop: `allow_unsigned` (default FALSE — strict)
//!
//! Pre-signing Fae peers emit placeholder signatures. With
//! `FAE_X0X_ALLOW_UNSIGNED=1` the verifier falls back to the historical shape
//! checks (algorithm + non-empty `public_key_id` + base64-alphabet
//! `signature_b64`) so those envelopes still pass the gate — but the ingress
//! recomputes the cryptographic verdict post-acceptance and FLAGS anything
//! unverified (auto-reply suppressed, `signature_unverified` audit row). In
//! strict mode an invalid/missing/placeholder signature is rejected outright
//! (audited by the gate as `signature_rejected`).

use std::collections::HashSet;

use fae_envelope_gate::{EnvelopeKind, PeerEnvelope, SignatureVerifier};

use super::signing;

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
    /// Interop escape hatch (`FAE_X0X_ALLOW_UNSIGNED`) — see module docs.
    /// FALSE (strict) unless the owner explicitly opts in.
    allow_unsigned: bool,
}

impl FaeSenderVerifier {
    pub fn new(
        chat_allow: HashSet<String>,
        owner_fleet: HashSet<String>,
        allow_unsigned: bool,
    ) -> Self {
        Self {
            policy: TierPolicy::new(chat_allow, owner_fleet),
            allow_unsigned,
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
        // Hygiene bar in BOTH modes (matches the historical v1 shape checks).
        if signature.algorithm() != signing::ENVELOPE_SIGN_ALGORITHM {
            return false;
        }
        if signature.public_key_id().trim().is_empty() {
            return false;
        }
        if !is_base64_shaped(signature.signature_b64()) {
            return false;
        }
        // Real ML-DSA-65 verification over the canonical signing bytes,
        // binding the embedded public key to the claimed sender. In strict
        // mode (default) failure REJECTS; in permissive interop mode the
        // envelope may proceed unverified — the ingress recomputes this exact
        // predicate and flags it (no auto-reply, audit row).
        if !self.allow_unsigned
            && !signing::verify_envelope_signature(
                signature,
                &envelope.signing_bytes(),
                envelope.sender_id(),
            )
        {
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
    use super::super::signing::test_support::TestIdentity;
    use super::*;
    use fae_envelope_gate::{
        envelope_signing_bytes, gate_and_audit, GateError, MAX_ENVELOPE_BYTES,
        SUPPORTED_SCHEMA_VERSION,
    };
    use std::collections::HashSet;

    const CHAT_SENDER: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const FLEET_SENDER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const UNKNOWN_SENDER: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

    /// Permissive-interop verifier (`allow_unsigned = true`) — the tier-policy
    /// matrix below predates real signing and exercises the tier axis with
    /// shape-only placeholder signatures, exactly the pre-signing-peer case
    /// the permissive mode exists for.
    fn verifier() -> FaeSenderVerifier {
        FaeSenderVerifier::new(
            HashSet::from([CHAT_SENDER.to_owned()]),
            HashSet::from([FLEET_SENDER.to_owned()]),
            true,
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

    // ── strict mode: REAL ML-DSA-65 end-to-end through the gate ──

    /// Build a fully-signed `direct_message` envelope for `identity` in the
    /// gate's wire shape — the same canonical bytes + DST + ML-DSA-65 flow the
    /// outbound builders use, so this proves builder/verifier symmetry with
    /// real crypto and no mocks.
    fn signed_envelope_json(identity: &TestIdentity, text: &str) -> String {
        let payload = serde_json::json!({ "text": text });
        let bytes = envelope_signing_bytes(
            SUPPORTED_SCHEMA_VERSION,
            &EnvelopeKind::DirectMessage,
            "env-signed-1",
            &identity.agent_id,
            1_700_000_000_000,
            &payload,
        );
        let signature_b64 = identity.sign_signing_bytes(&bytes);
        serde_json::json!({
            "schema_version": SUPPORTED_SCHEMA_VERSION,
            "kind": "direct_message",
            "envelope_id": "env-signed-1",
            "sender_id": identity.agent_id,
            "created_at_ms": 1_700_000_000_000_u64,
            "payload": payload,
            "signature": {
                "algorithm": "ml-dsa-65",
                "public_key_id": identity.public_key_b64,
                "signature_b64": signature_b64,
            }
        })
        .to_string()
    }

    fn strict_verifier_for(identity: &TestIdentity) -> FaeSenderVerifier {
        FaeSenderVerifier::new(
            HashSet::from([identity.agent_id.clone()]),
            HashSet::new(),
            false,
        )
    }

    fn strict_gate(raw: &str, verifier: &FaeSenderVerifier) -> Result<(), GateError> {
        let dir = tempfile::tempdir().unwrap();
        gate_and_audit(raw, verifier, &dir.path().join("audit.jsonl")).map(|_| ())
    }

    #[test]
    fn strict_mode_accepts_a_really_signed_envelope() {
        let identity = TestIdentity::generate();
        let raw = signed_envelope_json(&identity, "hello peer");
        assert!(strict_gate(&raw, &strict_verifier_for(&identity)).is_ok());
    }

    #[test]
    fn strict_mode_rejects_placeholder_signature() {
        let identity = TestIdentity::generate();
        let raw = signed_envelope_json(&identity, "hello");
        // Swap the real signature for the historical placeholder.
        let mut envelope: serde_json::Value = serde_json::from_str(&raw).unwrap();
        envelope["signature"]["signature_b64"] = "cGxhY2Vob2xkZXI=".into();
        let raw = envelope.to_string();
        assert!(matches!(
            strict_gate(&raw, &strict_verifier_for(&identity)),
            Err(GateError::SignatureRejected)
        ));
    }

    #[test]
    fn strict_mode_rejects_tampered_payload() {
        let identity = TestIdentity::generate();
        let raw = signed_envelope_json(&identity, "hello peer");
        let tampered = raw.replace("hello peer", "wire funds now");
        assert!(matches!(
            strict_gate(&tampered, &strict_verifier_for(&identity)),
            Err(GateError::SignatureRejected)
        ));
    }

    #[test]
    fn strict_mode_rejects_wrong_key_and_unbound_key() {
        let signer = TestIdentity::generate();
        let victim = TestIdentity::generate();
        // A valid envelope signed by `signer` but claiming `victim`'s
        // (allowlisted) sender id: the pk→sender binding must refuse it.
        let raw =
            signed_envelope_json(&signer, "hello").replace(&signer.agent_id, &victim.agent_id);
        assert!(matches!(
            strict_gate(&raw, &strict_verifier_for(&victim)),
            Err(GateError::SignatureRejected)
        ));
    }

    #[test]
    fn permissive_mode_accepts_placeholder_but_crypto_verdict_is_false() {
        // The interop contract: permissive gate-accepts a placeholder envelope
        // (tier permitting), and the post-gate crypto recheck the ingress uses
        // for flagging reports it unverified.
        let raw = envelope_json("direct_message", CHAT_SENDER, "ml-dsa-65", "c2ln");
        let dir = tempfile::tempdir().unwrap();
        let accepted = gate_and_audit(&raw, &verifier(), &dir.path().join("audit.jsonl")).unwrap();
        assert!(!signing::verify_envelope_signature(
            accepted.signature(),
            &accepted.signing_bytes(),
            accepted.sender_id()
        ));

        // And a REALLY signed envelope in permissive mode verifies true.
        let identity = TestIdentity::generate();
        let permissive = FaeSenderVerifier::new(
            HashSet::from([identity.agent_id.clone()]),
            HashSet::new(),
            true,
        );
        let raw = signed_envelope_json(&identity, "hello");
        let dir = tempfile::tempdir().unwrap();
        let accepted = gate_and_audit(&raw, &permissive, &dir.path().join("audit.jsonl")).unwrap();
        assert!(signing::verify_envelope_signature(
            accepted.signature(),
            &accepted.signing_bytes(),
            accepted.sender_id()
        ));
    }

    #[test]
    fn envelope_fixtures_stay_under_gate_cap() {
        // Sanity: the verifier matrix above must be exercising the verifier,
        // not tripping the size gate first.
        let raw = envelope_json("direct_message", CHAT_SENDER, "ml-dsa-65", "c2ln");
        assert!(raw.len() < MAX_ENVELOPE_BYTES);
    }
}
