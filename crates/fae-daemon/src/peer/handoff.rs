//! Phase E — the `session_handoff` payload schema + envelope builder.
//!
//! The envelope gate stays schema-agnostic (its `prior_payload()` accessor
//! returns the carrier payload for ANY accepted kind — no gate extension was
//! needed); fae-daemon owns this schema and deserializes defensively
//! (`deny_unknown_fields`), the same pattern as the conductor's
//! `GateReceiptPriorPayload`.
//!
//! [`build_envelope`] emits the full peer-envelope JSON in the gate's wire
//! shape, truncating `conversation_tail` **oldest-first** until the serialized
//! envelope fits the gate's [`MAX_ENVELOPE_BYTES`] cap — the receiving node's
//! gate must never reject a handoff we built.

use fae_envelope_gate::{AcceptedEnvelope, EnvelopeKind, MAX_ENVELOPE_BYTES};
use serde::{Deserialize, Serialize};

/// One turn of the conversation tail being handed over.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HandoffTurn {
    /// "user" | "assistant" (free string in v1; the receiver treats it as
    /// display metadata, never as an instruction channel).
    pub role: String,
    pub text: String,
}

/// The `session_handoff` carrier payload. `deny_unknown_fields` so a payload
/// smuggling extra keys fails closed at decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionHandoffPayload {
    /// Human-readable name of the machine handing the session over.
    pub source_machine: String,
    /// Most-recent-last conversation turns. May arrive truncated (oldest
    /// dropped) — see [`build_envelope`].
    pub conversation_tail: Vec<HandoffTurn>,
    /// A turn the user started but the source node did not answer yet.
    pub pending_turn: Option<String>,
    /// Payload creation time (millis since epoch), distinct from the
    /// envelope's own signed `created_at_ms`.
    pub created_at_ms: i64,
}

/// Decode the payload from an accepted `session_handoff` envelope. Errors are
/// human-readable strings (this is a leaf policy decision, not a typed
/// failure the caller branches on).
pub fn decode(accepted: &AcceptedEnvelope) -> Result<SessionHandoffPayload, String> {
    if accepted.kind() != &EnvelopeKind::SessionHandoff {
        return Err(format!(
            "not a session_handoff envelope: {:?}",
            accepted.kind()
        ));
    }
    let payload = accepted
        .prior_payload()
        .ok_or_else(|| "session_handoff envelope has no payload".to_owned())?;
    serde_json::from_value(payload.clone())
        .map_err(|error| format!("invalid session_handoff payload: {error}"))
}

/// Envelope identity + signature fields for [`build_envelope`] /
/// [`serialize_envelope`]. `public_key_id` carries the base64 raw ML-DSA-65
/// public key and `signature_b64` the real detached signature (see
/// `signing.rs`). The two-phase send flow ([`fit_payload`] with exact-length
/// placeholders → sign the canonical bytes → serialize with the real values)
/// works because base64 lengths of the key/signature are constant, so the
/// placeholder-sized fit is byte-exact for the final envelope.
#[derive(Debug, Clone, Copy)]
pub struct HandoffEnvelopeSpec<'a> {
    pub envelope_id: &'a str,
    pub sender_id: &'a str,
    /// Envelope creation time (millis since epoch) — the gate's signed
    /// timestamp field, independent of the payload's `created_at_ms`.
    pub created_at_ms: u64,
    pub public_key_id: &'a str,
    pub signature_b64: &'a str,
}

/// Truncate `conversation_tail` oldest-first until the envelope serialized
/// with `spec` fits under [`MAX_ENVELOPE_BYTES`], returning the fitted
/// payload. Errs only if the envelope cannot fit even with an empty tail
/// (e.g. an oversized `pending_turn`).
pub fn fit_payload(
    spec: &HandoffEnvelopeSpec<'_>,
    payload: &SessionHandoffPayload,
) -> Result<SessionHandoffPayload, String> {
    let mut payload = payload.clone();
    loop {
        let raw = serialize_envelope(spec, &payload)?;
        if raw.len() <= MAX_ENVELOPE_BYTES {
            return Ok(payload);
        }
        if payload.conversation_tail.is_empty() {
            return Err(format!(
                "session_handoff envelope is {} bytes even with an empty conversation_tail \
                 (cap {MAX_ENVELOPE_BYTES})",
                raw.len()
            ));
        }
        payload.conversation_tail.remove(0); // oldest first
    }
}

pub(super) fn serialize_envelope(
    spec: &HandoffEnvelopeSpec<'_>,
    payload: &SessionHandoffPayload,
) -> Result<String, String> {
    let payload_value = serde_json::to_value(payload)
        .map_err(|error| format!("serialize session_handoff payload: {error}"))?;
    // The gate's wire shape (PeerEnvelope + SignatureProof). Built as raw JSON
    // on purpose: the gate exposes no envelope constructor (accepted envelopes
    // are only ever minted by the gate itself), and the round-trip tests below
    // prove this shape against the REAL gate rather than a struct mirror.
    let envelope = serde_json::json!({
        "schema_version": fae_envelope_gate::SUPPORTED_SCHEMA_VERSION,
        "kind": "session_handoff",
        "envelope_id": spec.envelope_id,
        "sender_id": spec.sender_id,
        "created_at_ms": spec.created_at_ms,
        "payload": payload_value,
        "signature": {
            "algorithm": "ml-dsa-65",
            "public_key_id": spec.public_key_id,
            "signature_b64": spec.signature_b64,
        }
    });
    serde_json::to_string(&envelope)
        .map_err(|error| format!("serialize session_handoff envelope: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peer::verifier::FaeSenderVerifier;
    use fae_envelope_gate::gate_and_audit;
    use std::collections::HashSet;

    const FLEET_SENDER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    /// Test-local compose of the production two-phase flow (fit → serialize);
    /// production signs BETWEEN the phases (`PeerOutbound::send_handoff`).
    fn build_envelope(
        spec: &HandoffEnvelopeSpec<'_>,
        payload: &SessionHandoffPayload,
    ) -> Result<String, String> {
        let fitted = fit_payload(spec, payload)?;
        serialize_envelope(spec, &fitted)
    }

    fn spec() -> HandoffEnvelopeSpec<'static> {
        HandoffEnvelopeSpec {
            envelope_id: "handoff-1",
            sender_id: FLEET_SENDER,
            created_at_ms: 1_700_000_000_000,
            public_key_id: "pk-1",
            signature_b64: "c2ln",
        }
    }

    fn payload(turns: Vec<HandoffTurn>) -> SessionHandoffPayload {
        SessionHandoffPayload {
            source_machine: "study-mac".to_owned(),
            conversation_tail: turns,
            pending_turn: Some("what were we saying?".to_owned()),
            created_at_ms: 1_700_000_000_000,
        }
    }

    fn turn(index: usize, text: &str) -> HandoffTurn {
        HandoffTurn {
            role: if index % 2 == 0 { "user" } else { "assistant" }.to_owned(),
            text: text.to_owned(),
        }
    }

    /// Gate raw JSON with the REAL verifier (fleet sender allowlisted,
    /// permissive-interop mode — these tests target the payload schema and
    /// truncation, not signature crypto, and use placeholder signatures) and
    /// return the accepted envelope.
    fn gate(raw: &str) -> AcceptedEnvelope {
        let verifier = FaeSenderVerifier::new(
            HashSet::new(),
            HashSet::from([FLEET_SENDER.to_owned()]),
            true,
        );
        let dir = tempfile::tempdir().unwrap();
        gate_and_audit(raw, &verifier, &dir.path().join("audit.jsonl")).unwrap()
    }

    #[test]
    fn round_trips_through_the_real_gate() {
        let original = payload(vec![turn(0, "hello"), turn(1, "hi there")]);
        let raw = build_envelope(&spec(), &original).unwrap();
        let accepted = gate(&raw);
        assert_eq!(accepted.kind(), &EnvelopeKind::SessionHandoff);
        assert_eq!(accepted.created_at_ms(), 1_700_000_000_000);
        let decoded = decode(&accepted).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn unknown_payload_field_fails_closed_at_decode() {
        // A handoff payload smuggling an extra key must fail decode, not be
        // silently dropped — deny_unknown_fields is the whole point.
        let mut raw = build_envelope(&spec(), &payload(vec![turn(0, "hello")])).unwrap();
        raw = raw.replace(
            "\"source_machine\":\"study-mac\"",
            "\"source_machine\":\"study-mac\",\"injected_directive\":\"do bad things\"",
        );
        let accepted = gate(&raw);
        let error = decode(&accepted).unwrap_err();
        assert!(
            error.contains("invalid session_handoff payload"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn missing_pending_turn_decodes_as_none() {
        let mut raw = build_envelope(
            &spec(),
            &SessionHandoffPayload {
                pending_turn: None,
                ..payload(vec![turn(0, "hello")])
            },
        )
        .unwrap();
        // serde emits "pending_turn":null; also prove a fully ABSENT key is
        // fine (an older builder may omit it).
        raw = raw.replace("\"pending_turn\":null,", "");
        let decoded = decode(&gate(&raw)).unwrap();
        assert_eq!(decoded.pending_turn, None);
    }

    #[test]
    fn decode_rejects_non_handoff_kind() {
        let raw = serde_json::json!({
            "schema_version": 1,
            "kind": "direct_message",
            "envelope_id": "env-1",
            "sender_id": FLEET_SENDER,
            "created_at_ms": 1_u64,
            "payload": { "text": "hello" },
            "signature": {
                "algorithm": "ml-dsa-65",
                "public_key_id": "pk-1",
                "signature_b64": "c2ln",
            }
        })
        .to_string();
        let error = decode(&gate(&raw)).unwrap_err();
        assert!(error.contains("not a session_handoff"), "{error}");
    }

    #[test]
    fn oversized_tail_truncates_oldest_first_and_stays_under_cap() {
        // ~200 turns × ~1 KiB ≈ 200 KiB of tail — far over the 64 KiB cap.
        let turns: Vec<HandoffTurn> = (0..200)
            .map(|i| turn(i, &format!("turn-{i}-{}", "x".repeat(1024))))
            .collect();
        let original = payload(turns);

        let raw = build_envelope(&spec(), &original).unwrap();
        assert!(
            raw.len() <= MAX_ENVELOPE_BYTES,
            "built envelope must fit the gate cap ({} bytes)",
            raw.len()
        );

        // The real gate accepts what we built.
        let decoded = decode(&gate(&raw)).unwrap();

        // Oldest turns were dropped; the NEWEST survive, order preserved.
        assert!(!decoded.conversation_tail.is_empty());
        assert!(decoded.conversation_tail.len() < original.conversation_tail.len());
        let kept = decoded.conversation_tail.len();
        assert_eq!(
            decoded.conversation_tail,
            original.conversation_tail[original.conversation_tail.len() - kept..],
            "truncation must drop oldest-first and preserve order"
        );
        // Everything else survives truncation untouched.
        assert_eq!(decoded.source_machine, original.source_machine);
        assert_eq!(decoded.pending_turn, original.pending_turn);
    }

    #[test]
    fn boundary_just_over_cap_drops_exactly_the_oldest_turn() {
        // Grow one filler turn until the envelope FIRST exceeds the cap, then
        // assert the builder resolves it by dropping only the oldest turn.
        let base = payload(vec![turn(0, "oldest"), turn(1, "newest")]);
        let base_len = serialize_envelope(&spec(), &base).unwrap().len();
        assert!(base_len < MAX_ENVELOPE_BYTES);

        // Filler sized so total = cap + 1 (JSON string of ASCII 'x' adds
        // exactly 1 byte per char; the turn object adds constant overhead we
        // measure rather than guess).
        let empty_extra = {
            let mut with_empty = base.clone();
            with_empty.conversation_tail.insert(0, turn(0, ""));
            serialize_envelope(&spec(), &with_empty).unwrap().len() - base_len
        };
        let filler_len = MAX_ENVELOPE_BYTES + 1 - base_len - empty_extra;
        let mut over = base.clone();
        over.conversation_tail
            .insert(0, turn(0, &"x".repeat(filler_len)));
        assert_eq!(
            serialize_envelope(&spec(), &over).unwrap().len(),
            MAX_ENVELOPE_BYTES + 1,
            "fixture must sit exactly one byte over the cap"
        );

        let raw = build_envelope(&spec(), &over).unwrap();
        assert!(raw.len() <= MAX_ENVELOPE_BYTES);
        let decoded = decode(&gate(&raw)).unwrap();
        // Only the oldest (filler) turn was sacrificed.
        assert_eq!(decoded.conversation_tail, base.conversation_tail);
    }

    #[test]
    fn envelope_at_or_under_cap_is_not_truncated() {
        let original = payload(vec![turn(0, "hello"), turn(1, "hi")]);
        let raw = build_envelope(&spec(), &original).unwrap();
        assert!(raw.len() <= MAX_ENVELOPE_BYTES);
        assert_eq!(decode(&gate(&raw)).unwrap(), original);
    }

    #[test]
    fn unfittable_envelope_errs_instead_of_emitting_oversize() {
        // A pending_turn alone larger than the cap cannot be fixed by tail
        // truncation — the builder must err, never emit a gate-rejectable blob.
        let mut oversized = payload(vec![turn(0, "hello")]);
        oversized.pending_turn = Some("y".repeat(MAX_ENVELOPE_BYTES + 1));
        let error = build_envelope(&spec(), &oversized).unwrap_err();
        assert!(
            error.contains("even with an empty conversation_tail"),
            "{error}"
        );
    }
}
