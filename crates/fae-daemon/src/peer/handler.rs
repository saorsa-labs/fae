//! Phase E — pure per-kind dispatch for accepted peer envelopes.
//!
//! [`dispatch`] turns an already-gated [`AcceptedEnvelope`] into exactly one
//! [`PeerEvent`] on a [`PeerEventSink`], or a [`DispatchOutcome::Rejected`].
//! It is deliberately pure (no I/O, no network, no auto-reply — commit 2 wires
//! the real EventBus behind the sink and adds auto-reply on top).
//!
//! The [`TierPolicy`] check here is defense in depth: [`super::verifier`]
//! already enforced sender tier at gate time, but dispatch re-checks so a
//! future ingress path with a different verifier (or a policy hot-reload
//! between gate and dispatch) cannot skip tier rules.

use fae_envelope_gate::{AcceptedEnvelope, EnvelopeKind};

use super::handoff::{self, SessionHandoffPayload};
use super::verifier::TierPolicy;

/// Events the peer lane surfaces to the daemon. Commit 2 maps these onto the
/// real EventBus; in commit 1 they exist so dispatch is testable in isolation.
#[derive(Debug, Clone, PartialEq)]
pub enum PeerEvent {
    /// An allowlisted peer sent us a chat message.
    Message {
        sender: String,
        text: String,
        envelope_id: String,
        flagged: bool,
    },
    /// An allowlisted peer updated its presence.
    Presence { sender: String, status: String },
    /// A consent receipt/revocation arrived (kind = the snake_case kind name).
    ConsentRequest { sender: String, kind: String },
    /// An owner-fleet node offered to hand its live session over.
    HandoffOffer {
        sender: String,
        payload: SessionHandoffPayload,
        flagged: bool,
    },
    /// Informational only — logged, never acted on (v1: `memory_share_offer`,
    /// `conductor_gate_receipt_prior`).
    InfoOnly { kind: String, sender: String },
}

/// A minimal seam so commit 2 can wire the real EventBus without touching the
/// dispatch logic. `&self` on purpose: sinks are shared, not consumed.
pub trait PeerEventSink {
    fn publish(&self, event: PeerEvent);
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DispatchOutcome {
    /// An actionable event was published to the sink.
    Published,
    /// An informational-only event was published; no action was or will be
    /// taken on it.
    InfoOnly,
    /// The envelope was dropped (reason is audit-friendly snake_case).
    Rejected(String),
}

/// Route one accepted envelope. Exactly one sink publish on `Published` /
/// `InfoOnly`; zero on `Rejected`.
pub fn dispatch(
    accepted: &AcceptedEnvelope,
    policy: &TierPolicy,
    flagged: bool,
    sink: &dyn PeerEventSink,
) -> DispatchOutcome {
    let kind = accepted.kind();
    let sender = accepted.sender_id().to_owned();

    // Info-only kinds first: they carry no action in v1, so they bypass the
    // actionable-tier check (which rejects them) and are surfaced for logging
    // regardless of which verifier accepted them.
    if matches!(
        kind,
        EnvelopeKind::MemoryShareOffer | EnvelopeKind::ConductorGateReceiptPrior
    ) {
        sink.publish(PeerEvent::InfoOnly {
            kind: kind_name(kind).to_owned(),
            sender,
        });
        return DispatchOutcome::InfoOnly;
    }

    // Defense-in-depth tier re-check for every actionable kind.
    if !policy.permits(kind, accepted.sender_id()) {
        return DispatchOutcome::Rejected(format!(
            "sender_not_permitted_for_kind:{}",
            kind_name(kind)
        ));
    }

    match kind {
        EnvelopeKind::DirectMessage => match accepted.peer_text_for_policy_review() {
            Some(text) if !text.trim().is_empty() => {
                sink.publish(PeerEvent::Message {
                    sender,
                    text: text.to_owned(),
                    envelope_id: accepted.envelope_id().to_owned(),
                    flagged,
                });
                DispatchOutcome::Published
            }
            _ => DispatchOutcome::Rejected("direct_message_missing_text".to_owned()),
        },
        EnvelopeKind::PresenceUpdate => match presence_status(accepted) {
            Some(status) => {
                sink.publish(PeerEvent::Presence { sender, status });
                DispatchOutcome::Published
            }
            None => DispatchOutcome::Rejected("presence_update_missing_status".to_owned()),
        },
        EnvelopeKind::ConsentReceipt | EnvelopeKind::ConsentRevocation => {
            sink.publish(PeerEvent::ConsentRequest {
                sender,
                kind: kind_name(kind).to_owned(),
            });
            DispatchOutcome::Published
        }
        EnvelopeKind::SessionHandoff => match handoff::decode(accepted) {
            Ok(payload) => {
                sink.publish(PeerEvent::HandoffOffer {
                    sender,
                    payload,
                    flagged,
                });
                DispatchOutcome::Published
            }
            Err(reason) => DispatchOutcome::Rejected(format!("session_handoff_invalid:{reason}")),
        },
        // Handled above; kept for exhaustiveness so a future kind forces a
        // conscious routing decision here at compile time.
        EnvelopeKind::MemoryShareOffer | EnvelopeKind::ConductorGateReceiptPrior => {
            DispatchOutcome::Rejected("unreachable_info_only_kind".to_owned())
        }
    }
}

fn presence_status(accepted: &AcceptedEnvelope) -> Option<String> {
    accepted
        .prior_payload()?
        .get("status")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|status| !status.is_empty())
        .map(ToOwned::to_owned)
}

/// The kind's snake_case wire name (matches the gate's serde encoding).
fn kind_name(kind: &EnvelopeKind) -> &'static str {
    match kind {
        EnvelopeKind::DirectMessage => "direct_message",
        EnvelopeKind::ConsentReceipt => "consent_receipt",
        EnvelopeKind::ConsentRevocation => "consent_revocation",
        EnvelopeKind::MemoryShareOffer => "memory_share_offer",
        EnvelopeKind::PresenceUpdate => "presence_update",
        EnvelopeKind::ConductorGateReceiptPrior => "conductor_gate_receipt_prior",
        EnvelopeKind::SessionHandoff => "session_handoff",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fae_envelope_gate::{gate_and_audit, AcceptAllSignatureVerifier};
    use std::cell::RefCell;
    use std::collections::HashSet;

    const CHAT_SENDER: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const FLEET_SENDER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const UNKNOWN_SENDER: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

    /// Records every published event; dispatch must publish at most one.
    #[derive(Default)]
    struct RecordingSink {
        events: RefCell<Vec<PeerEvent>>,
    }

    impl PeerEventSink for RecordingSink {
        fn publish(&self, event: PeerEvent) {
            self.events.borrow_mut().push(event);
        }
    }

    fn policy() -> TierPolicy {
        TierPolicy::new(
            HashSet::from([CHAT_SENDER.to_owned()]),
            HashSet::from([FLEET_SENDER.to_owned()]),
        )
    }

    /// Accepted envelopes can only be minted by the gate. Tests use the gate's
    /// test-util AcceptAllSignatureVerifier so dispatch can be probed with
    /// kinds/senders the production verifier would refuse (that refusal has
    /// its own matrix in verifier.rs — here we prove dispatch's OWN guards).
    fn accepted(kind: &str, sender: &str, payload: serde_json::Value) -> AcceptedEnvelope {
        let raw = serde_json::json!({
            "schema_version": 1,
            "kind": kind,
            "envelope_id": "env-1",
            "sender_id": sender,
            "created_at_ms": 1_700_000_000_000_u64,
            "payload": payload,
            "signature": {
                "algorithm": "ml-dsa-65",
                "public_key_id": "pk-1",
                "signature_b64": "c2ln",
            }
        })
        .to_string();
        let dir = tempfile::tempdir().unwrap();
        gate_and_audit(
            &raw,
            &AcceptAllSignatureVerifier,
            &dir.path().join("audit.jsonl"),
        )
        .unwrap()
    }

    #[test]
    fn direct_message_from_chat_sender_publishes_message() {
        let sink = RecordingSink::default();
        let envelope = accepted(
            "direct_message",
            CHAT_SENDER,
            serde_json::json!({ "text": "hello fae" }),
        );
        assert_eq!(
            dispatch(&envelope, &policy(), false, &sink),
            DispatchOutcome::Published
        );
        assert_eq!(
            *sink.events.borrow(),
            vec![PeerEvent::Message {
                sender: CHAT_SENDER.to_owned(),
                text: "hello fae".to_owned(),
                envelope_id: "env-1".to_owned(),
                flagged: false,
            }]
        );
    }

    #[test]
    fn direct_message_from_unknown_sender_rejected_with_no_events() {
        let sink = RecordingSink::default();
        let envelope = accepted(
            "direct_message",
            UNKNOWN_SENDER,
            serde_json::json!({ "text": "hello" }),
        );
        assert_eq!(
            dispatch(&envelope, &policy(), false, &sink),
            DispatchOutcome::Rejected("sender_not_permitted_for_kind:direct_message".to_owned())
        );
        assert!(sink.events.borrow().is_empty(), "rejects must not publish");
    }

    #[test]
    fn direct_message_missing_text_rejected() {
        let sink = RecordingSink::default();
        let envelope = accepted("direct_message", CHAT_SENDER, serde_json::json!({}));
        assert_eq!(
            dispatch(&envelope, &policy(), false, &sink),
            DispatchOutcome::Rejected("direct_message_missing_text".to_owned())
        );
        assert!(sink.events.borrow().is_empty());
    }

    #[test]
    fn presence_update_publishes_presence() {
        let sink = RecordingSink::default();
        let envelope = accepted(
            "presence_update",
            CHAT_SENDER,
            serde_json::json!({ "status": "online" }),
        );
        assert_eq!(
            dispatch(&envelope, &policy(), false, &sink),
            DispatchOutcome::Published
        );
        assert_eq!(
            *sink.events.borrow(),
            vec![PeerEvent::Presence {
                sender: CHAT_SENDER.to_owned(),
                status: "online".to_owned(),
            }]
        );
    }

    #[test]
    fn presence_update_missing_status_rejected() {
        let sink = RecordingSink::default();
        let envelope = accepted("presence_update", CHAT_SENDER, serde_json::json!({}));
        assert_eq!(
            dispatch(&envelope, &policy(), false, &sink),
            DispatchOutcome::Rejected("presence_update_missing_status".to_owned())
        );
        assert!(sink.events.borrow().is_empty());
    }

    #[test]
    fn consent_kinds_publish_consent_request() {
        for kind in ["consent_receipt", "consent_revocation"] {
            let sink = RecordingSink::default();
            let envelope = accepted(kind, CHAT_SENDER, serde_json::json!({}));
            assert_eq!(
                dispatch(&envelope, &policy(), false, &sink),
                DispatchOutcome::Published
            );
            assert_eq!(
                *sink.events.borrow(),
                vec![PeerEvent::ConsentRequest {
                    sender: CHAT_SENDER.to_owned(),
                    kind: kind.to_owned(),
                }]
            );
        }
    }

    #[test]
    fn session_handoff_from_fleet_publishes_handoff_offer() {
        let sink = RecordingSink::default();
        let payload = serde_json::json!({
            "source_machine": "study-mac",
            "conversation_tail": [{ "role": "user", "text": "hello" }],
            "pending_turn": "and then?",
            "created_at_ms": 1_700_000_000_000_i64
        });
        let envelope = accepted("session_handoff", FLEET_SENDER, payload);
        assert_eq!(
            dispatch(&envelope, &policy(), false, &sink),
            DispatchOutcome::Published
        );
        let events = sink.events.borrow();
        match events.as_slice() {
            [PeerEvent::HandoffOffer {
                sender, payload, ..
            }] => {
                assert_eq!(sender, FLEET_SENDER);
                assert_eq!(payload.source_machine, "study-mac");
                assert_eq!(payload.pending_turn.as_deref(), Some("and then?"));
                assert_eq!(payload.conversation_tail.len(), 1);
            }
            other => panic!("expected exactly one HandoffOffer, got {other:?}"),
        }
    }

    #[test]
    fn session_handoff_from_chat_only_sender_rejected_by_dispatch_too() {
        // Even if a (mis)configured verifier accepted it, dispatch's tier
        // re-check keeps handoff owner-fleet-only.
        let sink = RecordingSink::default();
        let envelope = accepted("session_handoff", CHAT_SENDER, serde_json::json!({}));
        assert_eq!(
            dispatch(&envelope, &policy(), false, &sink),
            DispatchOutcome::Rejected("sender_not_permitted_for_kind:session_handoff".to_owned())
        );
        assert!(sink.events.borrow().is_empty());
    }

    #[test]
    fn session_handoff_with_invalid_payload_rejected() {
        let sink = RecordingSink::default();
        let envelope = accepted(
            "session_handoff",
            FLEET_SENDER,
            serde_json::json!({ "wrong": "shape" }),
        );
        match dispatch(&envelope, &policy(), false, &sink) {
            DispatchOutcome::Rejected(reason) => {
                assert!(reason.starts_with("session_handoff_invalid:"), "{reason}");
            }
            other => panic!("expected Rejected, got {other:?}"),
        }
        assert!(sink.events.borrow().is_empty());
    }

    #[test]
    fn info_only_kinds_publish_info_only_and_take_no_action() {
        for kind in ["memory_share_offer", "conductor_gate_receipt_prior"] {
            let sink = RecordingSink::default();
            // Even an UNKNOWN sender: info-only is log-and-drop, never action.
            let envelope = accepted(kind, UNKNOWN_SENDER, serde_json::json!({ "text": "hi" }));
            assert_eq!(
                dispatch(&envelope, &policy(), false, &sink),
                DispatchOutcome::InfoOnly
            );
            assert_eq!(
                *sink.events.borrow(),
                vec![PeerEvent::InfoOnly {
                    kind: kind.to_owned(),
                    sender: UNKNOWN_SENDER.to_owned(),
                }],
                "{kind} must surface ONLY an InfoOnly event — no Message, no action"
            );
        }
    }
}
