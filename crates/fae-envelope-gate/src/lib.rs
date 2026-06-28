//! G5 peer-envelope gate (promoted from `phase0/g5-envelope-gate`, reviewed by
//! red-team/oracle in Phase 0). Untrusted Fae<->Fae input is parsed to a typed,
//! closed-`kind`, schema-versioned, signature-checked payload and audited BEFORE
//! any caller may use it. No free-form peer text reaches the LLM/memory/tools.
#![forbid(unsafe_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

// M6-A (2026-06-27): the gate is a dumb, schema-versioned, signature-checked
// CARRIER. It must stay schema-agnostic — it does not (and must not) depend on
// fae-daemon. M6-Intel adds one closed kind (`ConductorGateReceiptPrior`) and
// two narrow accessors on `AcceptedEnvelope` (`created_at_ms`, `prior_payload`)
// so fae-daemon can (a) enforce a TTL and (b) deserialize the carrier payload
// into its own `GateReceiptPriorPayload` with `deny_unknown_fields` on ITS
// side. The gate never learns the payload shape; the conductor owns it.

use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

pub const SUPPORTED_SCHEMA_VERSION: u16 = 1;

/// Hard ceiling on a raw peer envelope. Peer ingress is pre-authentication
/// (no token, no verified signature yet), so an oversized blob is rejected
/// **before** `serde_json` is allowed to allocate for it. Control envelopes
/// (direct messages, consent receipts, presence) are kilobytes; 64 KiB is
/// generous headroom.
pub const MAX_ENVELOPE_BYTES: usize = 64 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum GateError {
    #[error("envelope too large: {size} bytes > {max} limit")]
    TooLarge { size: usize, max: usize },
    #[error("invalid envelope JSON: {0}")]
    InvalidJson(serde_json::Error),
    #[error("unsupported schema version: {0}")]
    UnsupportedSchema(u16),
    #[error("signature verification failed")]
    SignatureRejected,
    #[error("audit write failed: {0}")]
    Audit(std::io::Error),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EnvelopeKind {
    DirectMessage,
    ConsentReceipt,
    ConsentRevocation,
    MemoryShareOffer,
    PresenceUpdate,
    /// M6-Intel (2026-06-27): a conductor shared-intelligence prior — a signed,
    /// scoped, TTL'd, aggregate gate-receipt exported from one node's routing
    /// telemetry. Backwards-compatible enum extension: old nodes that don't
    /// know this variant reject it as `InvalidJson` (the desired fail-closed
    /// behavior for a forward-rolling fleet). The gate stays schema-agnostic;
    /// fae-daemon owns the payload schema and deserialization.
    ConductorGateReceiptPrior,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PeerEnvelope {
    schema_version: u16,
    kind: EnvelopeKind,
    envelope_id: String,
    sender_id: String,
    created_at_ms: u64,
    payload: serde_json::Value,
    signature: SignatureProof,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SignatureProof {
    algorithm: String,
    public_key_id: String,
    signature_b64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GateDecision {
    Accepted,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuditRecord {
    pub event_type: String,
    pub envelope_id: String,
    pub sender_id: String,
    pub kind: Option<EnvelopeKind>,
    pub decision: GateDecision,
    pub reason: String,
}

pub trait SignatureVerifier {
    fn verify(&self, envelope: &PeerEnvelope) -> bool;
}

/// Accepts every signature. **Test-only** — gated behind `cfg(test)` and the
/// non-default `test-util` feature so it can never be constructed in a
/// production build and accidentally bypass the gate.
#[cfg(any(test, feature = "test-util"))]
#[derive(Debug, Clone, Copy)]
pub struct AcceptAllSignatureVerifier;

#[cfg(any(test, feature = "test-util"))]
impl SignatureVerifier for AcceptAllSignatureVerifier {
    fn verify(&self, _envelope: &PeerEnvelope) -> bool {
        true
    }
}

/// Rejects every signature. **Test-only** (see [`AcceptAllSignatureVerifier`]).
#[cfg(any(test, feature = "test-util"))]
#[derive(Debug, Clone, Copy)]
pub struct RejectAllSignatureVerifier;

#[cfg(any(test, feature = "test-util"))]
impl SignatureVerifier for RejectAllSignatureVerifier {
    fn verify(&self, _envelope: &PeerEnvelope) -> bool {
        false
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcceptedEnvelope {
    envelope: PeerEnvelope,
}

impl AcceptedEnvelope {
    pub fn envelope_id(&self) -> &str {
        &self.envelope.envelope_id
    }

    pub fn sender_id(&self) -> &str {
        &self.envelope.sender_id
    }

    pub fn kind(&self) -> &EnvelopeKind {
        &self.envelope.kind
    }

    /// The envelope's creation timestamp (millis since epoch). Part of the
    /// signed envelope, so not forgeable once signatures are real. M6-Intel
    /// uses this for its TTL gate (future-date check first, then age).
    pub fn created_at_ms(&self) -> u64 {
        self.envelope.created_at_ms
    }

    /// Read-only access to the carrier `payload`, as a `serde_json::Value`
    /// reference. M6-Intel (and any future kind owner) deserializes this into
    /// its OWN payload type on its side — the gate never learns the schema.
    /// Returns the payload for ANY accepted kind; callers must check [`kind()`]
    /// and deserialize defensively (`deny_unknown_fields` + size cap) before
    /// trusting the contents. This preserves the gate's schema-agnosticism and
    /// the dependency direction (fae-daemon → fae-envelope-gate, never back).
    ///
    /// [`kind()`]: AcceptedEnvelope::kind
    pub fn prior_payload(&self) -> Option<&serde_json::Value> {
        Some(&self.envelope.payload)
    }

    /// Peer text is exposed only for the policy-review layer. Callers must not
    /// treat this as LLM, memory, or tool input until a later policy decision
    /// explicitly upgrades it.
    pub fn peer_text_for_policy_review(&self) -> Option<&str> {
        self.envelope
            .payload
            .get("text")
            .and_then(serde_json::Value::as_str)
    }
}

/// Parse + gate, returning the accepted envelope *and* the audit row the caller
/// MUST persist. Crate-private on purpose: the only public entry is
/// [`gate_and_audit`], which guarantees the row is written before the accepted
/// data is handed back — there is no public path to accepted peer data that
/// skips the audit.
pub(crate) fn parse_and_gate(
    raw: &str,
    verifier: &dyn SignatureVerifier,
) -> Result<(AcceptedEnvelope, AuditRecord), GateError> {
    if raw.len() > MAX_ENVELOPE_BYTES {
        return Err(GateError::TooLarge {
            size: raw.len(),
            max: MAX_ENVELOPE_BYTES,
        });
    }
    let envelope = serde_json::from_str::<PeerEnvelope>(raw).map_err(GateError::InvalidJson)?;
    if envelope.schema_version != SUPPORTED_SCHEMA_VERSION {
        let version = envelope.schema_version;
        return Err(GateError::UnsupportedSchema(version));
    }
    if !verifier.verify(&envelope) {
        return Err(GateError::SignatureRejected);
    }

    let audit = accepted_audit(&envelope);
    Ok((AcceptedEnvelope { envelope }, audit))
}

/// Gates a raw peer envelope and writes an audit row for both accepted and
/// rejected inputs before returning to the caller. This is the preferred API
/// for callers that would otherwise risk using accepted data before audit.
pub fn gate_and_audit(
    raw: &str,
    verifier: &dyn SignatureVerifier,
    audit_path: &Path,
) -> Result<AcceptedEnvelope, GateError> {
    match parse_and_gate(raw, verifier) {
        Ok((accepted, audit)) => {
            append_audit_jsonl(audit_path, &audit)?;
            Ok(accepted)
        }
        Err(error) => {
            let audit = rejected_audit(raw, &error);
            append_audit_jsonl(audit_path, &audit)?;
            Err(error)
        }
    }
}

pub fn append_audit_jsonl(path: &Path, record: &AuditRecord) -> Result<(), GateError> {
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(GateError::Audit)?;
    serde_json::to_writer(&mut file, record).map_err(|error| {
        GateError::Audit(std::io::Error::new(std::io::ErrorKind::InvalidData, error))
    })?;
    file.write_all(b"\n").map_err(GateError::Audit)?;
    Ok(())
}

fn accepted_audit(envelope: &PeerEnvelope) -> AuditRecord {
    AuditRecord {
        event_type: "peer_envelope_ingress".to_owned(),
        envelope_id: envelope.envelope_id.clone(),
        sender_id: envelope.sender_id.clone(),
        kind: Some(envelope.kind.clone()),
        decision: GateDecision::Accepted,
        reason: "schema_and_signature_accepted_for_policy_review".to_owned(),
    }
}

fn rejected_audit(raw: &str, error: &GateError) -> AuditRecord {
    // Never re-parse oversized input on the audit path — that is the exact
    // allocation we just refused. Salvage sender/envelope ids only when small.
    let parsed = if raw.len() <= MAX_ENVELOPE_BYTES {
        serde_json::from_str::<serde_json::Value>(raw).ok()
    } else {
        None
    };
    let envelope_id = string_field(parsed.as_ref(), "envelope_id");
    let sender_id = string_field(parsed.as_ref(), "sender_id");
    let kind = parsed
        .as_ref()
        .and_then(|value| value.get("kind"))
        .and_then(|value| serde_json::from_value::<EnvelopeKind>(value.clone()).ok());

    AuditRecord {
        event_type: "peer_envelope_ingress".to_owned(),
        envelope_id: envelope_id.unwrap_or_else(|| "<unknown>".to_owned()),
        sender_id: sender_id.unwrap_or_else(|| "<unknown>".to_owned()),
        kind,
        decision: GateDecision::Rejected,
        reason: error_reason(error),
    }
}

fn string_field(value: Option<&serde_json::Value>, field: &str) -> Option<String> {
    value
        .and_then(|value| value.get(field))
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned)
}

fn error_reason(error: &GateError) -> String {
    match error {
        GateError::TooLarge { size, max } => format!("envelope_too_large:{size}>{max}"),
        GateError::InvalidJson(_) => "invalid_json_or_unknown_kind".to_owned(),
        GateError::UnsupportedSchema(version) => format!("unsupported_schema_version:{version}"),
        GateError::SignatureRejected => "signature_rejected".to_owned(),
        GateError::Audit(_) => "audit_error".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn valid_envelope_json() -> Result<String, serde_json::Error> {
        serde_json::to_string(&PeerEnvelope {
            schema_version: SUPPORTED_SCHEMA_VERSION,
            kind: EnvelopeKind::DirectMessage,
            envelope_id: "env-1".to_owned(),
            sender_id: "peer-1".to_owned(),
            created_at_ms: 1,
            payload: serde_json::json!({ "text": "hello" }),
            signature: SignatureProof {
                algorithm: "ml-dsa-65".to_owned(),
                public_key_id: "pk-1".to_owned(),
                signature_b64: "placeholder".to_owned(),
            },
        })
    }

    fn unique_audit_path() -> Result<std::path::PathBuf, std::time::SystemTimeError> {
        Ok(std::env::temp_dir().join(format!(
            "g5-envelope-audit-{}.jsonl",
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
        )))
    }

    #[test]
    fn rejects_unknown_kind() -> Result<(), Box<dyn std::error::Error>> {
        let raw = valid_envelope_json()?.replace("direct_message", "freeform_instruction");
        let result = parse_and_gate(&raw, &AcceptAllSignatureVerifier);
        assert!(matches!(result, Err(GateError::InvalidJson(_))));
        Ok(())
    }

    #[test]
    fn rejects_wrong_schema_version() -> Result<(), Box<dyn std::error::Error>> {
        let raw = valid_envelope_json()?.replace("\"schema_version\":1", "\"schema_version\":999");
        let result = parse_and_gate(&raw, &AcceptAllSignatureVerifier);
        assert!(matches!(result, Err(GateError::UnsupportedSchema(999))));
        Ok(())
    }

    #[test]
    fn rejects_signature_failure() -> Result<(), Box<dyn std::error::Error>> {
        let raw = valid_envelope_json()?;
        let result = parse_and_gate(&raw, &RejectAllSignatureVerifier);
        assert!(matches!(result, Err(GateError::SignatureRejected)));
        Ok(())
    }

    #[test]
    fn valid_inbound_envelope_is_audited() -> Result<(), Box<dyn std::error::Error>> {
        let raw = valid_envelope_json()?;
        let path = unique_audit_path()?;
        let accepted = gate_and_audit(&raw, &AcceptAllSignatureVerifier, &path)?;
        assert_eq!(accepted.envelope_id(), "env-1");

        let content = fs::read_to_string(&path)?;
        fs::remove_file(&path)?;
        assert!(content.contains("peer_envelope_ingress"));
        assert!(content.contains("env-1"));
        assert!(content.contains("accepted"));
        Ok(())
    }

    #[test]
    fn rejected_envelope_is_audited() -> Result<(), Box<dyn std::error::Error>> {
        let raw = valid_envelope_json()?;
        let path = unique_audit_path()?;
        let result = gate_and_audit(&raw, &RejectAllSignatureVerifier, &path);
        assert!(matches!(result, Err(GateError::SignatureRejected)));

        let content = fs::read_to_string(&path)?;
        fs::remove_file(&path)?;
        assert!(content.contains("peer_envelope_ingress"));
        assert!(content.contains("env-1"));
        assert!(content.contains("rejected"));
        assert!(content.contains("signature_rejected"));
        Ok(())
    }

    #[test]
    fn rejects_oversized_envelope_before_parsing() {
        // A blob over the cap is refused on size alone — serde never sees it.
        let raw = "x".repeat(MAX_ENVELOPE_BYTES + 1);
        let result = parse_and_gate(&raw, &AcceptAllSignatureVerifier);
        assert!(matches!(
            result,
            Err(GateError::TooLarge { size, max })
                if size == MAX_ENVELOPE_BYTES + 1 && max == MAX_ENVELOPE_BYTES
        ));
    }

    #[test]
    fn peer_text_is_only_available_for_policy_review() -> Result<(), Box<dyn std::error::Error>> {
        let raw = valid_envelope_json()?;
        let (accepted, _) = parse_and_gate(&raw, &AcceptAllSignatureVerifier)?;
        assert_eq!(accepted.peer_text_for_policy_review(), Some("hello"));
        Ok(())
    }

    // ── M6-A (2026-06-27): the new ConductorGateReceiptPrior kind + accessors ──

    fn prior_envelope_json(
        created_at_ms: u64,
        payload: serde_json::Value,
    ) -> Result<String, serde_json::Error> {
        serde_json::to_string(&PeerEnvelope {
            schema_version: SUPPORTED_SCHEMA_VERSION,
            kind: EnvelopeKind::ConductorGateReceiptPrior,
            envelope_id: "prior-1".to_owned(),
            sender_id: "peer-1".to_owned(),
            created_at_ms,
            payload,
            signature: SignatureProof {
                algorithm: "ml-dsa-65".to_owned(),
                public_key_id: "pk-1".to_owned(),
                signature_b64: "placeholder".to_owned(),
            },
        })
    }

    #[test]
    fn conductor_prior_kind_round_trips_through_gate() -> Result<(), Box<dyn std::error::Error>> {
        // The new kind is a first-class EnvelopeKind: it parses, is accepted by
        // the gate (signature permitting), and kind() reads back correctly.
        let payload = serde_json::json!({
            "topology": "direct",
            "privacy_lane": "owner_fleet",
            "success": true
        });
        let raw = prior_envelope_json(1_700_000_000_000, payload)?;
        let (accepted, _) = parse_and_gate(&raw, &AcceptAllSignatureVerifier)?;
        assert_eq!(accepted.kind(), &EnvelopeKind::ConductorGateReceiptPrior);
        assert_eq!(accepted.envelope_id(), "prior-1");
        assert_eq!(accepted.sender_id(), "peer-1");
        Ok(())
    }

    #[test]
    fn created_at_ms_accessor_returns_signed_timestamp() -> Result<(), Box<dyn std::error::Error>> {
        // The TTL gate (M6-C) depends on this being the envelope's signed
        // created_at_ms, surfaced verbatim.
        let raw = prior_envelope_json(1_700_000_000_000, serde_json::json!({}))?;
        let (accepted, _) = parse_and_gate(&raw, &AcceptAllSignatureVerifier)?;
        assert_eq!(accepted.created_at_ms(), 1_700_000_000_000);
        Ok(())
    }

    #[test]
    fn prior_payload_returns_read_only_carrier_value() -> Result<(), Box<dyn std::error::Error>> {
        // The accessor returns the carrier payload as a read-only Value, for
        // ANY accepted kind — the conductor owns deserialization on its side.
        // prior_payload() is &self.envelope.payload, which is non-optional, so
        // it always returns Some for an accepted envelope; assert the Option
        // itself equals Some(&payload) (no extraction/clone needed).
        let payload = serde_json::json!({
            "topology": "chain",
            "privacy_lane": "local_only",
            "success": false,
            "fallback": true
        });
        let raw = prior_envelope_json(1_700_000_000_000, payload.clone())?;
        let (accepted, _) = parse_and_gate(&raw, &AcceptAllSignatureVerifier)?;
        assert_eq!(
            accepted.prior_payload(),
            Some(&payload),
            "accessor must return the carrier payload verbatim, for an accepted envelope"
        );
        Ok(())
    }

    #[test]
    fn prior_payload_works_for_direct_message_kind_too() -> Result<(), Box<dyn std::error::Error>> {
        // The accessor is kind-agnostic by design (the gate is schema-agnostic);
        // it returns the payload regardless of kind. Callers check kind().
        let raw = valid_envelope_json()?;
        let (accepted, _) = parse_and_gate(&raw, &AcceptAllSignatureVerifier)?;
        let payload = accepted
            .prior_payload()
            .map(|v| v.get("text").and_then(|t| t.as_str()).unwrap_or(""));
        assert_eq!(payload, Some("hello"));
        Ok(())
    }

    #[test]
    fn conductor_prior_kind_with_unknown_variant_still_rejected(
    ) -> Result<(), Box<dyn std::error::Error>> {
        // Backwards-compat / forward-rolling-fleet guarantee: a completely
        // unknown kind string is rejected as InvalidJson (serde deny on the
        // closed enum). This is the fail-closed behavior the spec relies on.
        let raw = valid_envelope_json()?.replace("direct_message", "conductor_evil_prior");
        let result = parse_and_gate(&raw, &AcceptAllSignatureVerifier);
        assert!(matches!(result, Err(GateError::InvalidJson(_))));
        Ok(())
    }
}
