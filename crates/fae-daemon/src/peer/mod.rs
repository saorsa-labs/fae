//! Phase E — x0x peer messaging.
//!
//! Commit 1 landed the pure, transport-free trust core:
//!
//! - [`config`] — env + x0x-data-dir discovery (`FAE_X0X_*`); returns `None`
//!   (ingress off) on ANY missing/invalid required piece, never an error.
//! - [`verifier`] — [`fae_envelope_gate::SignatureVerifier`] impl enforcing
//!   algorithm + signature shape + sender-tier-by-kind ([`verifier::TierPolicy`]).
//! - [`handoff`] — the `session_handoff` payload schema (`deny_unknown_fields`),
//!   decode from an accepted envelope, and a 64 KiB-capped envelope builder.
//! - [`handler`] — pure per-kind dispatch to a [`handler::PeerEventSink`].
//!
//! Commit 2 adds the live surface:
//!
//! - [`x0x_client`] — the x0xd REST/SSE client ([`x0x_client::X0xPeerClient`]).
//! - [`PeerIngress`] — the SINGLE governed inbound entry point: an SSE task that
//!   transport-pre-checks, runs every peer envelope through
//!   `fae_envelope_gate::gate_and_audit` BEFORE any other processing,
//!   cross-checks the transport sender against the signed sender, then dispatches
//!   onto the daemon event bus. Reconnects with jittered exponential backoff.
//! - [`PeerOutbound`] — the outbound side used by the `peer.*` control-plane
//!   commands (send a direct message, hand a session to an owner-fleet node,
//!   record an owner consent decision).
//!
//! Real ML-DSA-65 envelope signing/verification (2026-07-15) replaces the v1
//! placeholder: outbound envelopes are signed through x0xd's
//! `POST /agent/sign` (the daemon never holds key material) and inbound
//! signatures are verified locally in [`verifier`] via [`signing`] — strict by
//! default, with `FAE_X0X_ALLOW_UNSIGNED` as the flag-and-quarantine interop
//! path for pre-signing peers. See `signing.rs` for the key model, canonical
//! bytes, DST, and the pubkey→sender binding.

pub mod allowlist;
pub mod config;
pub mod handler;
pub mod handoff;
pub mod signing;
pub mod verifier;
pub mod x0x_client;

pub use config::PeerConfig;
pub use x0x_client::{DirectEventFrame, X0xPeerClient};

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fae_control_plane::{Command, Scope, PROTOCOL_VERSION};
use fae_engine::{ProviderAdapter, TtsAdapter};
use fae_envelope_gate::{
    append_audit_jsonl, envelope_signing_bytes, gate_and_audit, AuditRecord, EnvelopeKind,
    GateDecision, MAX_ENVELOPE_BYTES, SUPPORTED_SCHEMA_VERSION,
};
use futures_util::StreamExt;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

use crate::agents::AgentSessionRegistry;
use crate::events::{EventBus, PlaybackRegistry};
use crate::session::SessionBackends;

use handler::{DispatchOutcome, PeerEvent, PeerEventSink};
use handoff::{HandoffEnvelopeSpec, SessionHandoffPayload};
use verifier::FaeSenderVerifier;

/// Monotonic nonce so two envelopes minted in the same millisecond get distinct
/// ids.
static ENVELOPE_NONCE: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

fn next_envelope_id(prefix: &str) -> String {
    let nonce = ENVELOPE_NONCE.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}-{}-{nonce}", now_ms())
}

// ─────────────────────────────── Outbound ────────────────────────────────

/// The outbound peer surface, shared (behind `Arc`) by the `peer.*` control-plane
/// commands and the ingress auto-reply. Holds its own x0xd client so outbound
/// sends never queue behind the long-lived inbound SSE stream.
pub struct PeerOutbound {
    client: X0xPeerClient,
    own_agent_id: String,
    owner_fleet: HashSet<String>,
    audit_path: PathBuf,
}

impl PeerOutbound {
    pub fn new(
        client: X0xPeerClient,
        own_agent_id: String,
        owner_fleet: HashSet<String>,
        audit_path: PathBuf,
    ) -> PeerOutbound {
        PeerOutbound {
            client,
            own_agent_id,
            owner_fleet: owner_fleet
                .into_iter()
                .map(|id| id.to_ascii_lowercase())
                .collect(),
            audit_path,
        }
    }

    /// Wrap `text` in a `direct_message` envelope and send it to `to_agent_id`.
    ///
    /// This is the single chokepoint for ALL outbound peer text (the guest
    /// `auto_reply` routes through it), so the PII egress membrane is enforced here:
    /// credential-shaped text is NEVER sent to an external peer, even if the model
    /// reproduced a secret. Fail closed — audit + refuse rather than leak.
    pub async fn send_direct_message(&self, to_agent_id: &str, text: &str) -> Result<(), String> {
        if fae_pii_membrane::should_block_remote_egress(text) {
            let record = AuditRecord {
                event_type: "peer_egress_blocked".to_owned(),
                envelope_id: next_envelope_id("egress-block"),
                sender_id: self.own_agent_id.clone(),
                kind: None,
                decision: GateDecision::Rejected,
                reason: "pii_membrane_blocked_outbound".to_owned(),
            };
            if let Err(error) = append_audit_jsonl(&self.audit_path, &record) {
                tracing::warn!("peer egress-block audit append failed: {error}");
            }
            return Err("outbound message blocked by PII egress membrane".to_owned());
        }
        let envelope_id = next_envelope_id("dm");
        let created_at_ms = now_ms();
        let payload = serde_json::json!({ "text": text });
        let signature = self
            .sign_envelope_fields(
                &EnvelopeKind::DirectMessage,
                &envelope_id,
                created_at_ms,
                &payload,
            )
            .await?;
        let raw = serialize_signed_envelope(
            "direct_message",
            &envelope_id,
            &self.own_agent_id,
            created_at_ms,
            &payload,
            &signature,
        )?;
        self.client
            .direct_send(to_agent_id, &raw)
            .await
            .map_err(|error| error.to_string())
    }

    /// Sign one envelope's canonical bytes with this node's x0xd-held
    /// ML-DSA-65 identity (`POST /agent/sign`), fail-closed on any response
    /// that is not a scheme/context/identity-exact signature by US. See
    /// `signing.rs` for the canonical-bytes + DST construction the receiving
    /// verifier reproduces.
    async fn sign_envelope_fields(
        &self,
        kind: &EnvelopeKind,
        envelope_id: &str,
        created_at_ms: u64,
        payload: &serde_json::Value,
    ) -> Result<signing::EnvelopeSignature, String> {
        let bytes = envelope_signing_bytes(
            SUPPORTED_SCHEMA_VERSION,
            kind,
            envelope_id,
            &self.own_agent_id,
            created_at_ms,
            payload,
        );
        if bytes.len() > MAX_ENVELOPE_BYTES {
            // Also x0xd's own /agent/sign cap — reject before the network.
            return Err(format!(
                "envelope signing payload is {} bytes (cap {MAX_ENVELOPE_BYTES})",
                bytes.len()
            ));
        }
        let response = self
            .client
            .agent_sign(signing::PEER_ENVELOPE_SIGN_CONTEXT, &bytes)
            .await
            .map_err(|error| format!("x0xd envelope signing failed: {error}"))?;
        signing::validate_sign_response(&response, &self.own_agent_id)
    }

    /// Hand a live session to an owner-fleet node. The target MUST be in the
    /// owner-fleet allowlist — the receiving node's gate is owner-fleet-only for
    /// `session_handoff`, so sending to anyone else would only be rejected there;
    /// we reject here first, loudly.
    pub async fn send_handoff(
        &self,
        to_agent_id: &str,
        snapshot: SessionHandoffPayload,
    ) -> Result<(), String> {
        if !self.owner_fleet.contains(&to_agent_id.to_ascii_lowercase()) {
            return Err(format!(
                "handoff target {to_agent_id} is not in the owner fleet allowlist"
            ));
        }
        let envelope_id = next_envelope_id("handoff");
        let created_at_ms = now_ms();
        // Two-phase build: fit the tail under the gate cap using EXACT-length
        // placeholders for the (constant-size) key + signature fields, sign
        // the fitted payload's canonical bytes, then serialize with the real
        // values — byte-identical length, so the fit still holds.
        let pk_placeholder = "A".repeat(signing::base64_len(signing::ML_DSA_65_PUBLIC_KEY_LEN));
        let sig_placeholder = "A".repeat(signing::base64_len(signing::ML_DSA_65_SIGNATURE_LEN));
        let sizing_spec = HandoffEnvelopeSpec {
            envelope_id: &envelope_id,
            sender_id: &self.own_agent_id,
            created_at_ms,
            public_key_id: &pk_placeholder,
            signature_b64: &sig_placeholder,
        };
        let fitted = handoff::fit_payload(&sizing_spec, &snapshot)?;
        let payload_value = serde_json::to_value(&fitted)
            .map_err(|error| format!("serialize session_handoff payload: {error}"))?;
        let signature = self
            .sign_envelope_fields(
                &EnvelopeKind::SessionHandoff,
                &envelope_id,
                created_at_ms,
                &payload_value,
            )
            .await?;
        let signed_spec = HandoffEnvelopeSpec {
            public_key_id: &signature.public_key_b64,
            signature_b64: &signature.signature_b64,
            ..sizing_spec
        };
        let raw = handoff::serialize_envelope(&signed_spec, &fitted)?;
        if raw.len() > MAX_ENVELOPE_BYTES {
            // Structurally unreachable (placeholder lengths are exact) — but
            // an oversized envelope must fail loud here, never at the peer.
            return Err(format!(
                "signed session_handoff envelope is {} bytes (cap {MAX_ENVELOPE_BYTES})",
                raw.len()
            ));
        }
        self.client
            .direct_send(to_agent_id, &raw)
            .await
            .map_err(|error| error.to_string())
    }

    /// Record an owner consent decision (accept/deny) against a pending
    /// envelope. v1: this appends a decision line to the peer audit log — the
    /// allowlist itself is config-file-based (`FAE_X0X_ALLOW`/`FAE_X0X_OWNER_FLEET`),
    /// so an accept does not mutate the live allowlist; it is the durable,
    /// auditable record the owner will act on to edit the config.
    pub fn record_consent(&self, envelope_id: &str, accept: bool) -> Result<(), String> {
        let record = AuditRecord {
            event_type: "peer_consent_decision".to_owned(),
            envelope_id: envelope_id.to_owned(),
            sender_id: self.own_agent_id.clone(),
            kind: None,
            decision: if accept {
                GateDecision::Accepted
            } else {
                GateDecision::Rejected
            },
            reason: if accept {
                "owner_consent_granted"
            } else {
                "owner_consent_denied"
            }
            .to_owned(),
        };
        append_audit_jsonl(&self.audit_path, &record).map_err(|error| error.to_string())
    }
}

/// Serialize a fully-signed peer envelope in the gate's wire shape, failing if
/// it would exceed the gate cap (a `direct_message` is kilobytes; a text over
/// the cap is a caller error, never emitted as a gate-rejectable blob). The
/// signature's `public_key_id` carries the base64 raw ML-DSA-65 public key —
/// the sender-binding carrier the receiving verifier checks (see `signing.rs`).
fn serialize_signed_envelope(
    kind: &str,
    envelope_id: &str,
    sender_id: &str,
    created_at_ms: u64,
    payload: &serde_json::Value,
    signature: &signing::EnvelopeSignature,
) -> Result<String, String> {
    let envelope = serde_json::json!({
        "schema_version": SUPPORTED_SCHEMA_VERSION,
        "kind": kind,
        "envelope_id": envelope_id,
        "sender_id": sender_id,
        "created_at_ms": created_at_ms,
        "payload": payload,
        "signature": {
            "algorithm": signing::ENVELOPE_SIGN_ALGORITHM,
            "public_key_id": signature.public_key_b64,
            "signature_b64": signature.signature_b64,
        }
    });
    let raw = serde_json::to_string(&envelope).map_err(|error| error.to_string())?;
    if raw.len() > MAX_ENVELOPE_BYTES {
        return Err(format!(
            "{kind} envelope is {} bytes (cap {MAX_ENVELOPE_BYTES})",
            raw.len()
        ));
    }
    Ok(raw)
}

// ──────────────────────────── Event-bus sink ─────────────────────────────

/// Publishes dispatched [`PeerEvent`]s onto the daemon event bus as `peer.*`
/// events, scoped `ConversationRead` — the same subscribe grant the orb host
/// already holds for the conversation stream, mirroring how the conductor's
/// fallback surfaces onto that stream.
struct EventBusPeerSink {
    events: EventBus,
}

impl PeerEventSink for EventBusPeerSink {
    fn publish(&self, event: PeerEvent) {
        let (name, payload) = peer_event_to_wire(&event);
        self.events.publish(name, Scope::ConversationRead, payload);
    }
}

/// Map a dispatched peer event to its wire `(event_name, payload)`. Pure, so the
/// mapping is unit-testable without a live bus.
fn peer_event_to_wire(event: &PeerEvent) -> (&'static str, serde_json::Value) {
    match event {
        PeerEvent::Message {
            sender,
            text,
            envelope_id,
            flagged,
        } => (
            "peer.message",
            serde_json::json!({ "sender": sender, "text": text, "envelope_id": envelope_id, "flagged": flagged }),
        ),
        PeerEvent::Presence { sender, status } => (
            "peer.presence",
            serde_json::json!({ "sender": sender, "status": status }),
        ),
        PeerEvent::ConsentRequest { sender, kind } => (
            "peer.consent",
            serde_json::json!({ "sender": sender, "kind": kind }),
        ),
        PeerEvent::HandoffOffer {
            sender,
            payload,
            flagged,
        } => (
            "peer.handoff_offer",
            serde_json::json!({
                "sender": sender,
                "flagged": flagged,
                "source_machine": payload.source_machine,
                "pending_turn": payload.pending_turn,
                "conversation_tail": payload.conversation_tail,
                "tail_len": payload.conversation_tail.len(),
            }),
        ),
        PeerEvent::InfoOnly { kind, sender } => (
            "peer.info",
            serde_json::json!({ "sender": sender, "kind": kind }),
        ),
    }
}

// ─────────────────────────────── Ingress ─────────────────────────────────

/// The non-outbound backends the ingress needs — enough to run a tool-less
/// guest auto-reply turn through the exact same `inject_text_core` path a live
/// owner turn uses, and to publish `peer.*` events.
pub struct PeerIngressDeps {
    pub engine: Arc<dyn ProviderAdapter>,
    pub tts: Arc<dyn TtsAdapter>,
    pub audio: Arc<fae_audio::AudioManager>,
    pub events: EventBus,
    pub playbacks: PlaybackRegistry,
    pub agents: AgentSessionRegistry,
    /// `<fae data dir>/peer_envelope_audit.jsonl` — the same path the gate writes
    /// accept/reject rows to; the supervisor appends transport-level drops here
    /// too so one file is the complete peer-ingress audit trail.
    pub audit_path: PathBuf,
    /// `<fae data dir>/peer_allowlist.json` — the owner-granted live allowlist
    /// ([`allowlist`]). Unioned with the env lists and re-read whenever its
    /// fingerprint changes, so a consent grant goes live without a restart.
    pub allowlist_path: PathBuf,
}

/// The peer-ingress supervisor: connect the SSE stream, gate every frame, and
/// reconnect forever with backoff until cancelled.
pub struct PeerIngress;

impl PeerIngress {
    /// Spawn the ingress task. Mirrors the toolhost cancel pattern: the task
    /// runs until `cancel` fires (or the process exits). Returns the join handle.
    pub fn spawn(
        cfg: PeerConfig,
        deps: PeerIngressDeps,
        outbound: Arc<PeerOutbound>,
        cancel: CancellationToken,
    ) -> JoinHandle<()> {
        tokio::spawn(run_ingress(cfg, deps, outbound, cancel))
    }
}

async fn run_ingress(
    cfg: PeerConfig,
    deps: PeerIngressDeps,
    outbound: Arc<PeerOutbound>,
    cancel: CancellationToken,
) {
    // Sender trust = env lists ∪ the owner's file-backed grants
    // (`peer_allowlist.json`). The watcher re-reads the file when it changes,
    // so a `peer_grant` takes effect on the NEXT inbound frame — no daemon
    // restart. Env-only remains the fail-closed floor when the file is
    // missing or malformed.
    let env_sets = allowlist::AllowlistSets {
        chat_allow: cfg.chat_allow.clone(),
        owner_fleet: cfg.owner_fleet.clone(),
    };
    let mut allowlist_watcher = allowlist::AllowlistWatcher::new(deps.allowlist_path.clone());
    let mut verifier = effective_verifier(&env_sets, allowlist_watcher.sets(), cfg.allow_unsigned);
    if cfg.allow_unsigned {
        tracing::warn!(
            "peer ingress running with FAE_X0X_ALLOW_UNSIGNED=1: unsigned/placeholder \
             envelopes are accepted-but-FLAGGED (interop mode for pre-signing peers)"
        );
    }
    let client = match X0xPeerClient::new(cfg.base_url.clone(), cfg.token.clone()) {
        Ok(client) => client,
        Err(error) => {
            tracing::warn!("peer ingress not started: client build failed: {error}");
            return;
        }
    };
    let sink = EventBusPeerSink {
        events: deps.events.clone(),
    };
    let mut backoff = BackoffState::new();

    tracing::info!("peer ingress starting (base {})", cfg.base_url);
    loop {
        if cancel.is_cancelled() {
            break;
        }
        let connect = tokio::select! {
            _ = cancel.cancelled() => break,
            connect = client.direct_events() => connect,
        };
        match connect {
            Ok(stream) => {
                backoff.reset();
                tokio::pin!(stream);
                loop {
                    let next = tokio::select! {
                        _ = cancel.cancelled() => return,
                        next = stream.next() => next,
                    };
                    let Some(frame) = next else {
                        // Stream ended (peer disconnect / server restart) →
                        // fall through to backoff + reconnect.
                        break;
                    };
                    if allowlist_watcher.reload_if_changed() {
                        verifier = effective_verifier(
                            &env_sets,
                            allowlist_watcher.sets(),
                            cfg.allow_unsigned,
                        );
                        tracing::info!("peer allowlist reloaded from file");
                    }
                    handle_frame(&frame, &verifier, &cfg, &deps, &outbound, &sink).await;
                }
            }
            Err(error) => {
                tracing::warn!("peer ingress connect failed: {error}");
            }
        }
        let delay = backoff.next_delay();
        tokio::select! {
            _ = cancel.cancelled() => break,
            _ = tokio::time::sleep(delay) => {}
        }
    }
    tracing::info!("peer ingress stopped");
}

/// Build the verifier from env grants ∪ file grants — the single place the
/// two trust sources are merged, so they cannot drift apart. `allow_unsigned`
/// passes through unchanged (a file grant never relaxes signature policy).
fn effective_verifier(
    env: &allowlist::AllowlistSets,
    file: &allowlist::AllowlistSets,
    allow_unsigned: bool,
) -> FaeSenderVerifier {
    let merged = env.union_with(file);
    FaeSenderVerifier::new(merged.chat_allow, merged.owner_fleet, allow_unsigned)
}

/// Process ONE inbound frame through the full membrane: transport pre-check →
/// gate → sender cross-check → dispatch → optional auto-reply.
async fn handle_frame(
    frame: &DirectEventFrame,
    verifier: &FaeSenderVerifier,
    cfg: &PeerConfig,
    deps: &PeerIngressDeps,
    outbound: &Arc<PeerOutbound>,
    sink: &EventBusPeerSink,
) {
    // (a) Transport pre-check: x0xd must have verified the sender's transport
    // signature. Anything else is dropped BEFORE the gate ever sees it.
    if !frame_passes_transport_precheck(frame) {
        tracing::warn!(sender = %frame.sender, "peer frame dropped: transport verified=false");
        append_rejected(
            &deps.audit_path,
            "<unknown>",
            &frame.sender,
            "transport_unverified",
        );
        return;
    }

    // (b) THE GATE — runs before any other processing. `gate_and_audit` writes
    // the accept/reject audit row itself.
    let accepted = match gate_and_audit(&frame.payload_raw, verifier, &deps.audit_path) {
        Ok(accepted) => accepted,
        Err(error) => {
            tracing::warn!(sender = %frame.sender, "peer envelope gated out: {error}");
            return;
        }
    };

    // (c) Cross-check: the signed sender inside the (now accepted) envelope MUST
    // match the transport-attested sender. A mismatch means a signature that
    // verified for one identity is being relayed under another — drop it.
    if !sender_cross_check_ok(accepted.sender_id(), &frame.sender) {
        tracing::warn!(
            envelope_sender = %accepted.sender_id(),
            transport_sender = %frame.sender,
            "peer envelope dropped: sender cross-check mismatch"
        );
        append_rejected(
            &deps.audit_path,
            accepted.envelope_id(),
            &frame.sender,
            "transport_sender_mismatch",
        );
        return;
    }

    // (d) Cryptographic verdict for FLAGGING. In strict mode the gate already
    // rejected anything unverifiable, so this is deterministically true; in
    // permissive interop mode (`FAE_X0X_ALLOW_UNSIGNED=1`) a placeholder/
    // unsigned envelope reaches here unverified and is quarantined exactly
    // like a transport-flagged one — accepted, surfaced with `flagged: true`,
    // ZERO automated downstream — plus an explicit unverified audit row.
    let signature_verified = signing::verify_envelope_signature(
        accepted.signature(),
        &accepted.signing_bytes(),
        accepted.sender_id(),
    );
    if !signature_verified {
        append_audit_accepted(
            &deps.audit_path,
            accepted.envelope_id(),
            &frame.sender,
            "signature_unverified_accepted_permissive",
        );
        tracing::warn!(
            sender = %frame.sender,
            "peer envelope accepted WITHOUT signature verification (allow_unsigned interop) — flagged"
        );
    }

    // (e) Dispatch onto the event bus. The flag travels with the event so the
    // owner surface (Swift) can mark the message and the handoff alert.
    let kind = accepted.kind().clone();
    // FAIL-CLOSED (#44): absent/empty trust_decision is a downgrade, not a
    // pass — is_flagged() flags it; effective_flag then ORs in the
    // cryptographic verdict, so the final flag = (transport trust verdict says
    // flag) OR (signature not verified). trust_verdict() supplies the distinct
    // audit reason for the quarantine row.
    let flagged = effective_flag(is_flagged(frame), signature_verified);
    let outcome = handler::dispatch(&accepted, verifier.policy(), flagged, sink);

    // INVARIANT: flagged ⇒ zero automated downstream (no LLM, no tools, no
    // capabilities). Any future peer capability path MUST check `is_flagged`
    // and deny. Today this suppresses auto-reply for flagged DirectMessages
    // and propagates the flag on HandoffOffers (the owner sees the flag in the
    // accept alert); the quarantine audit row records the decision.
    if flagged {
        // Transport reason wins when the transport flagged; a purely
        // signature-driven flag (transport clean, signature unverified) falls
        // back to the standard reason — the dedicated
        // "signature_unverified_accepted_permissive" row was already written
        // in step (d) above.
        let reason = trust_verdict(frame).unwrap_or("flagged_envelope_quarantined_no_auto_reply");
        append_quarantined(
            &deps.audit_path,
            accepted.envelope_id(),
            &frame.sender,
            reason,
        );
        tracing::info!(
            sender = %frame.sender,
            reason = reason,
            "peer envelope flagged by transport: quarantined, auto-reply suppressed"
        );
    }

    // Auto-reply: only for an accepted, dispatched, UNFLAGGED direct message,
    // only when the owner opted in. Routed as a tool-less GUEST turn through
    // inject_text_core. A flagged envelope is quarantined — no LLM turn over
    // content the trust layer just flagged (prompt-injection / resource-burn
    // / reply-mediated social-engineering surface for zero owner benefit).
    if should_auto_reply(cfg.auto_reply, flagged, kind, &outcome) {
        if let Some(text) = accepted.peer_text_for_policy_review() {
            let text = text.to_owned();
            auto_reply(deps, outbound, &frame.sender, &text).await;
        }
    }
}

/// Transport pre-check predicate (extracted for unit testing).
fn frame_passes_transport_precheck(frame: &DirectEventFrame) -> bool {
    frame.verified
}

/// Sender cross-check predicate (extracted for unit testing). Case-insensitive:
/// x0x agent ids are hex, compared without case sensitivity throughout.
fn sender_cross_check_ok(envelope_sender: &str, transport_sender: &str) -> bool {
    envelope_sender.eq_ignore_ascii_case(transport_sender)
}

/// Classify x0xd's transport trust metadata. Returns the quarantine audit
/// reason when the envelope should be flagged, or `None` when the verdict is
/// a clean accept.
///
/// FAIL-CLOSED (#44): an absent or empty `trust_decision` is a downgrade —
/// it is quarantined with the distinct reason `trust_metadata_missing_downgraded`
/// rather than silently passing. Only an explicit, case-insensitive `"accept"`
/// clears the flag. Any other value (including `"accept_with_flag"`, `"rejected"`,
/// or any unknown future string) quarantines with the standard reason.
///
/// This composes independently with envelope-gate ML-DSA signature
/// verification: transport trust metadata and cryptographic signature
/// verification are two separate defence layers. A signature-accepted envelope
/// with missing transport trust metadata is still quarantined here.
fn trust_verdict(frame: &DirectEventFrame) -> Option<&'static str> {
    if frame.trust_decision.is_empty() {
        tracing::warn!(
            sender = %frame.sender,
            "peer frame trust_decision absent — downgrading to flagged (fail-closed, #44)"
        );
        return Some("trust_metadata_missing_downgraded");
    }
    if frame.trust_decision.eq_ignore_ascii_case("accept") {
        return None;
    }
    Some("flagged_envelope_quarantined_no_auto_reply")
}

/// True when the envelope should be quarantined. Thin wrapper over
/// [`trust_verdict`] for call sites that only need a bool.
fn is_flagged(frame: &DirectEventFrame) -> bool {
    trust_verdict(frame).is_some()
}

/// Combine the transport trust verdict with the cryptographic signature
/// verdict into the single quarantine flag. Extracted for testability:
/// an envelope is flagged when EITHER x0xd flagged the transport OR the
/// envelope signature did not verify (permissive interop mode only — strict
/// mode rejects unverified envelopes at the gate).
fn effective_flag(transport_flagged: bool, signature_verified: bool) -> bool {
    transport_flagged || !signature_verified
}

/// The auto-reply guard, extracted for testability. INVARIANT: flagged ⇒ no
/// auto-reply. If someone removes `!flagged` from this predicate, the
/// `flagged_suppresses_auto_reply` test fails.
fn should_auto_reply(
    auto_reply_enabled: bool,
    flagged: bool,
    kind: EnvelopeKind,
    outcome: &DispatchOutcome,
) -> bool {
    auto_reply_enabled
        && !flagged
        && kind == EnvelopeKind::DirectMessage
        && matches!(outcome, DispatchOutcome::Published)
}

/// Append an Accepted row with a caller-supplied quarantine reason when a
/// flagged envelope is quarantined (auto-reply suppressed). Mirrors
/// [`append_rejected`]'s shape but records that the envelope was
/// accepted-but-quarantined for the audit trail. The `reason` is the
/// [`trust_verdict`] return value — either
/// `"trust_metadata_missing_downgraded"` (absent/empty field, #44) or
/// `"flagged_envelope_quarantined_no_auto_reply"` (explicit non-accept /
/// signature-only flag). Best-effort: a failed write is logged, never fatal.
fn append_quarantined(audit_path: &Path, envelope_id: &str, sender_id: &str, reason: &str) {
    append_audit_accepted(audit_path, envelope_id, sender_id, reason);
}

/// Append an Accepted row with an explicit `reason` for accepted-but-noted
/// events outside the gate (quarantine, permissive-mode unverified
/// signatures). Best-effort: a failed write is logged, never fatal.
fn append_audit_accepted(audit_path: &Path, envelope_id: &str, sender_id: &str, reason: &str) {
    let record = AuditRecord {
        event_type: "peer_envelope_ingress".to_owned(),
        envelope_id: envelope_id.to_owned(),
        sender_id: sender_id.to_owned(),
        kind: None,
        decision: GateDecision::Accepted,
        reason: reason.to_owned(),
    };
    if let Err(error) = append_audit_jsonl(audit_path, &record) {
        tracing::warn!("peer audit append failed ({reason}): {error}");
    }
}

/// Append a clearly-marked rejected row to the peer audit log for a drop that
/// happens OUTSIDE the gate (transport pre-check / sender cross-check), so the
/// audit file remains the complete record. Best-effort: a failed audit write is
/// logged, never fatal.
fn append_rejected(audit_path: &Path, envelope_id: &str, sender_id: &str, reason: &str) {
    let record = AuditRecord {
        event_type: "peer_envelope_ingress".to_owned(),
        envelope_id: envelope_id.to_owned(),
        sender_id: sender_id.to_owned(),
        kind: None,
        decision: GateDecision::Rejected,
        reason: reason.to_owned(),
    };
    if let Err(error) = append_audit_jsonl(audit_path, &record) {
        tracing::warn!("peer audit append failed ({reason}): {error}");
    }
}

/// Run the peer's text as a tool-less guest turn through the exact governed
/// `inject_text_core` path (NaN-retry + generating events included), then send
/// the reply back wrapped in a `direct_message` envelope. Best-effort: any
/// failure warns and drops — a peer never gets a partial or errored reply.
async fn auto_reply(
    deps: &PeerIngressDeps,
    outbound: &Arc<PeerOutbound>,
    sender: &str,
    text: &str,
) {
    // A tool-less turn is simply an inject_text payload with NO `tools` key:
    // `parse_chat_request` yields an empty tool set, so the model has zero tool
    // access — the guest contract. `conductor: None` runs `inject_text_core`
    // directly (no routing telemetry for a guest turn).
    let backends = SessionBackends {
        engine: deps.engine.as_ref(),
        asr_fallback: None,
        tts: deps.tts.as_ref(),
        audio: deps.audio.as_ref(),
        events: &deps.events,
        playbacks: &deps.playbacks,
        agents: &deps.agents,
        conductor: None,
        acp_runner: &crate::session::REAL_ACP_RUNNER,
        peer: None,
    };
    const GUEST_SYSTEM: &str = "You are replying to a message from an EXTERNAL PEER over the x0x \
network — a guest, not your owner. You have NO tools and NO owner privileges. Reply briefly and \
helpfully in plain text.";
    let cmd = Command {
        v: PROTOCOL_VERSION,
        request_id: next_envelope_id("peer-auto"),
        command: "conversation.inject_text".to_owned(),
        payload: serde_json::json!({ "text": text, "system": GUEST_SYSTEM }),
    };
    match crate::session::inject_text_core(&backends, &cmd).await {
        Ok(value) => {
            let reply = value
                .get("text")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .trim()
                .to_owned();
            if reply.is_empty() {
                tracing::warn!("peer auto-reply produced empty text; not sending");
                return;
            }
            if let Err(error) = outbound.send_direct_message(sender, &reply).await {
                tracing::warn!("peer auto-reply send failed: {error}");
            }
        }
        Err(error) => tracing::warn!("peer auto-reply generation failed: {error}"),
    }
}

// ─────────────────────────────── Backoff ─────────────────────────────────

/// Exponential backoff base 2s, doubling, capped at 60s: `[2,4,8,16,32,60,60,…]`.
/// Pure and deterministic — the sequence is unit-tested; jitter is layered on in
/// [`BackoffState::next_delay`].
fn backoff_base_secs(attempt: u32) -> u64 {
    let shift = attempt.min(5);
    (2u64 << shift).min(60)
}

struct BackoffState {
    attempt: u32,
}

impl BackoffState {
    fn new() -> BackoffState {
        BackoffState { attempt: 0 }
    }

    fn reset(&mut self) {
        self.attempt = 0;
    }

    /// Next delay: the deterministic base plus up to ~25% jitter (so a fleet of
    /// nodes reconnecting after the same x0xd blip does not thundering-herd).
    fn next_delay(&mut self) -> Duration {
        let base_secs = backoff_base_secs(self.attempt);
        self.attempt = self.attempt.saturating_add(1);
        // Jitter fraction in [0, 250) permille of the base ⇒ up to ~25%.
        let jitter_permille = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| u64::from(d.subsec_nanos()))
            % 250;
        let base_ms = base_secs.saturating_mul(1000);
        let jitter_ms = base_secs.saturating_mul(jitter_permille); // base*permille = base_ms*permille/1000
        Duration::from_millis(base_ms.saturating_add(jitter_ms))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fae_envelope_gate::gate_and_audit;
    use x0x_client::TransportTrustLevel;

    const OWN: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const FLEET: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    // ── transport pre-check + sender cross-check ──

    #[test]
    fn transport_precheck_rejects_unverified() {
        let unverified = DirectEventFrame {
            sender: OWN.to_owned(),
            verified: false,
            trust_decision: "rejected".to_owned(),
            trust_level: TransportTrustLevel::Untrusted,
            payload_raw: "{}".to_owned(),
        };
        assert!(!frame_passes_transport_precheck(&unverified));

        let verified = DirectEventFrame {
            verified: true,
            ..unverified
        };
        assert!(frame_passes_transport_precheck(&verified));
    }

    #[test]
    fn sender_cross_check_is_case_insensitive_and_rejects_mismatch() {
        assert!(sender_cross_check_ok(OWN, OWN));
        assert!(sender_cross_check_ok(&OWN.to_ascii_uppercase(), OWN));
        assert!(!sender_cross_check_ok(OWN, FLEET));
    }

    // ── backoff sequence ──

    #[test]
    fn backoff_base_sequence_doubles_and_caps_at_60() {
        let seq: Vec<u64> = (0..8).map(backoff_base_secs).collect();
        assert_eq!(seq, vec![2, 4, 8, 16, 32, 60, 60, 60]);
    }

    #[test]
    fn backoff_next_delay_stays_within_base_plus_quarter() {
        let mut backoff = BackoffState::new();
        let first = backoff.next_delay();
        // Base 2s, jitter < 25% ⇒ [2000, 2500) ms.
        assert!(first >= Duration::from_millis(2000), "{first:?}");
        assert!(first < Duration::from_millis(2500), "{first:?}");
        backoff.reset();
        assert!(backoff.next_delay() >= Duration::from_millis(2000));
    }

    // ── outbound envelope builders round-trip through the REAL gate ──

    /// Sign envelope fields exactly as `sign_envelope_fields` does, but with a
    /// local test identity standing in for x0xd (same canonical bytes, same
    /// DST, same ML-DSA-65 — see `signing::test_support`).
    fn locally_signed(
        identity: &signing::test_support::TestIdentity,
        kind: &EnvelopeKind,
        envelope_id: &str,
        created_at_ms: u64,
        payload: &serde_json::Value,
    ) -> signing::EnvelopeSignature {
        let bytes = envelope_signing_bytes(
            SUPPORTED_SCHEMA_VERSION,
            kind,
            envelope_id,
            &identity.agent_id,
            created_at_ms,
            payload,
        );
        signing::EnvelopeSignature {
            public_key_b64: identity.public_key_b64.clone(),
            signature_b64: identity.sign_signing_bytes(&bytes),
        }
    }

    /// The critical builder↔verifier symmetry proof: an envelope serialized by
    /// the outbound path with a REAL ML-DSA-65 signature is accepted by the
    /// STRICT gate verifier (no allow_unsigned, no mocks).
    #[test]
    fn built_signed_direct_message_is_accepted_by_the_strict_gate() {
        let identity = signing::test_support::TestIdentity::generate();
        let payload = serde_json::json!({ "text": "hello peer" });
        let signature = locally_signed(
            &identity,
            &EnvelopeKind::DirectMessage,
            "dm-test-1",
            1_700_000_000_000,
            &payload,
        );
        let raw = serialize_signed_envelope(
            "direct_message",
            "dm-test-1",
            &identity.agent_id,
            1_700_000_000_000,
            &payload,
            &signature,
        )
        .unwrap();

        let strict = FaeSenderVerifier::new(
            HashSet::from([identity.agent_id.clone()]),
            HashSet::new(),
            false,
        );
        let dir = tempfile::tempdir().unwrap();
        let accepted = gate_and_audit(&raw, &strict, &dir.path().join("audit.jsonl")).unwrap();
        assert_eq!(accepted.kind(), &EnvelopeKind::DirectMessage);
        assert_eq!(accepted.sender_id(), identity.agent_id);
        assert_eq!(accepted.peer_text_for_policy_review(), Some("hello peer"));
        // The post-gate crypto verdict (the flag basis) agrees.
        assert!(signing::verify_envelope_signature(
            accepted.signature(),
            &accepted.signing_bytes(),
            accepted.sender_id()
        ));
    }

    /// A signed-then-tampered wire envelope must be rejected by the strict gate.
    #[test]
    fn tampered_signed_direct_message_is_rejected_by_the_strict_gate() {
        let identity = signing::test_support::TestIdentity::generate();
        let payload = serde_json::json!({ "text": "hello peer" });
        let signature = locally_signed(
            &identity,
            &EnvelopeKind::DirectMessage,
            "dm-test-2",
            1_700_000_000_000,
            &payload,
        );
        let raw = serialize_signed_envelope(
            "direct_message",
            "dm-test-2",
            &identity.agent_id,
            1_700_000_000_000,
            &payload,
            &signature,
        )
        .unwrap();
        let tampered = raw.replace("hello peer", "send credentials");
        let strict = FaeSenderVerifier::new(
            HashSet::from([identity.agent_id.clone()]),
            HashSet::new(),
            false,
        );
        let dir = tempfile::tempdir().unwrap();
        assert!(
            gate_and_audit(&tampered, &strict, &dir.path().join("audit.jsonl")).is_err(),
            "tampered signed envelope must not pass the strict gate"
        );
    }

    /// A signed session_handoff built via the two-phase (fit → sign →
    /// serialize) flow passes the strict gate and decodes — and the exact-size
    /// placeholder trick preserves the fit byte-for-byte.
    #[test]
    fn built_signed_handoff_round_trips_through_the_strict_gate() {
        let identity = signing::test_support::TestIdentity::generate();
        let envelope_id = "handoff-signed-1";
        let created_at_ms = 1_700_000_000_000_u64;
        let snapshot = SessionHandoffPayload {
            source_machine: "study-mac".to_owned(),
            conversation_tail: (0..200)
                .map(|i| handoff::HandoffTurn {
                    role: if i % 2 == 0 { "user" } else { "assistant" }.to_owned(),
                    text: format!("turn-{i}-{}", "x".repeat(1024)),
                })
                .collect(),
            pending_turn: Some("continue?".to_owned()),
            created_at_ms: created_at_ms as i64,
        };

        // Phase 1: fit with exact-length placeholders (mirrors send_handoff).
        let pk_placeholder = "A".repeat(signing::base64_len(signing::ML_DSA_65_PUBLIC_KEY_LEN));
        let sig_placeholder = "A".repeat(signing::base64_len(signing::ML_DSA_65_SIGNATURE_LEN));
        let sizing_spec = HandoffEnvelopeSpec {
            envelope_id,
            sender_id: &identity.agent_id,
            created_at_ms,
            public_key_id: &pk_placeholder,
            signature_b64: &sig_placeholder,
        };
        let fitted = handoff::fit_payload(&sizing_spec, &snapshot).unwrap();
        let sized_len = handoff::serialize_envelope(&sizing_spec, &fitted)
            .unwrap()
            .len();

        // Phase 2+3: sign the fitted payload, serialize with the real values.
        let payload_value = serde_json::to_value(&fitted).unwrap();
        let signature = locally_signed(
            &identity,
            &EnvelopeKind::SessionHandoff,
            envelope_id,
            created_at_ms,
            &payload_value,
        );
        let signed_spec = HandoffEnvelopeSpec {
            public_key_id: &signature.public_key_b64,
            signature_b64: &signature.signature_b64,
            ..sizing_spec
        };
        let raw = handoff::serialize_envelope(&signed_spec, &fitted).unwrap();
        assert_eq!(
            raw.len(),
            sized_len,
            "real key/signature must be byte-identical in length to the sizing placeholders"
        );
        assert!(raw.len() <= MAX_ENVELOPE_BYTES);

        let strict = FaeSenderVerifier::new(
            HashSet::new(),
            HashSet::from([identity.agent_id.clone()]),
            false,
        );
        let dir = tempfile::tempdir().unwrap();
        let accepted = gate_and_audit(&raw, &strict, &dir.path().join("audit.jsonl")).unwrap();
        assert_eq!(accepted.kind(), &EnvelopeKind::SessionHandoff);
        let decoded = handoff::decode(&accepted).unwrap();
        assert_eq!(decoded, fitted);
    }

    // ── flag combination: transport verdict ∨ unverified signature ──

    #[test]
    fn effective_flag_ors_transport_and_signature_verdicts() {
        // Clean transport + verified signature ⇒ unflagged.
        assert!(!effective_flag(false, true));
        // Transport flag alone ⇒ flagged.
        assert!(effective_flag(true, true));
        // Unverified signature alone (permissive interop) ⇒ flagged.
        assert!(effective_flag(false, false));
        // Both ⇒ flagged.
        assert!(effective_flag(true, false));
    }

    #[test]
    fn send_handoff_rejects_target_not_in_owner_fleet() {
        // No network is touched: the fleet check returns before direct_send.
        let outbound = PeerOutbound::new(
            X0xPeerClient::new("http://127.0.0.1:1", "tok").unwrap(),
            OWN.to_owned(),
            HashSet::from([FLEET.to_owned()]),
            std::env::temp_dir().join("unused-audit.jsonl"),
        );
        let snapshot = SessionHandoffPayload {
            source_machine: "study-mac".to_owned(),
            conversation_tail: Vec::new(),
            pending_turn: None,
            created_at_ms: now_ms() as i64,
        };
        let stranger = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        let result = tokio_test_block(outbound.send_handoff(stranger, snapshot));
        assert!(result.is_err(), "non-fleet target must be rejected");
        assert!(result.unwrap_err().contains("owner fleet"));
    }

    #[test]
    fn record_consent_appends_a_decision_row() {
        let dir = tempfile::tempdir().unwrap();
        let audit = dir.path().join("peer_envelope_audit.jsonl");
        let outbound = PeerOutbound::new(
            X0xPeerClient::new("http://127.0.0.1:1", "tok").unwrap(),
            OWN.to_owned(),
            HashSet::new(),
            audit.clone(),
        );
        outbound.record_consent("env-42", true).unwrap();
        let content = std::fs::read_to_string(&audit).unwrap();
        assert!(content.contains("peer_consent_decision"));
        assert!(content.contains("env-42"));
        assert!(content.contains("owner_consent_granted"));
    }

    // ── S-H3: PII egress membrane on outbound peer text ──

    #[test]
    fn send_direct_message_blocks_credential_shaped_egress() {
        // The membrane check runs BEFORE any network send (the client points at a
        // dead address, never contacted). This is the exact path `auto_reply` uses,
        // so a guest auto-reply carrying a credential shape is blocked here too.
        let dir = tempfile::tempdir().unwrap();
        let audit = dir.path().join("peer_envelope_audit.jsonl");
        let outbound = PeerOutbound::new(
            X0xPeerClient::new("http://127.0.0.1:1", "tok").unwrap(),
            OWN.to_owned(),
            HashSet::new(),
            audit.clone(),
        );
        // Credential shape built by concatenation so no secret-shaped literal is committed.
        let secret_reply = format!("sure, the key is {}{}", "sk-", "abcdefghijklmnopqrstuvwx");
        let result = tokio_test_block(outbound.send_direct_message("peer-1", &secret_reply));
        assert!(
            result.is_err(),
            "credential-shaped egress must be blocked before send"
        );
        let err = result.unwrap_err();
        assert!(
            err.contains("membrane") || err.contains("blocked"),
            "unexpected error: {err}"
        );
        let content = std::fs::read_to_string(&audit).unwrap();
        assert!(
            content.contains("peer_egress_blocked"),
            "egress block must be audited"
        );
    }

    #[test]
    fn membrane_does_not_over_block_benign_text() {
        // The gate `send_direct_message` applies must let ordinary replies through
        // (only credential shapes are blocked). This guards against an over-broad
        // membrane that would silence normal peer conversation. Asserted on the
        // exact predicate the send path uses, so no network/timer is required.
        assert!(!fae_pii_membrane::should_block_remote_egress(
            "The weather in Edinburgh is mild today."
        ));
        assert!(!fae_pii_membrane::should_block_remote_egress(
            "Sure, I can help summarise that document for you."
        ));
    }

    // ── event-bus mapping ──

    #[test]
    fn peer_events_map_to_stable_wire_names() {
        let (name, payload) = peer_event_to_wire(&PeerEvent::Message {
            sender: OWN.to_owned(),
            text: "hi".to_owned(),
            envelope_id: "env-1".to_owned(),
            flagged: false,
        });
        assert_eq!(name, "peer.message");
        assert_eq!(payload["text"], "hi");

        let (name, payload) = peer_event_to_wire(&PeerEvent::HandoffOffer {
            sender: FLEET.to_owned(),
            payload: SessionHandoffPayload {
                source_machine: "study-mac".to_owned(),
                conversation_tail: vec![
                    handoff::HandoffTurn {
                        role: "user".to_owned(),
                        text: "what were we saying?".to_owned(),
                    },
                    handoff::HandoffTurn {
                        role: "assistant".to_owned(),
                        text: "about the garden.".to_owned(),
                    },
                ],
                pending_turn: Some("and then?".to_owned()),
                created_at_ms: 0,
            },
            flagged: false,
        });
        assert_eq!(name, "peer.handoff_offer");
        // #17: the wire event must carry the full tail, not just tail_len — the
        // Swift client hydrates the restored conversation from it.
        assert_eq!(payload["tail_len"], 2);
        let tail = payload["conversation_tail"]
            .as_array()
            .expect("conversation_tail is an array on the wire");
        assert_eq!(tail.len(), 2);
        assert_eq!(tail[0]["role"], "user");
        assert_eq!(tail[0]["text"], "what were we saying?");
        assert_eq!(tail[1]["text"], "about the garden.");
    }

    /// #17 end-to-end + security: the tail on the wire comes ONLY from an
    /// envelope that passed the real `gate_and_audit` accept path, and it is
    /// inherently ≤ 64 KiB because the gate rejects any oversized raw frame
    /// before it can ever become an `AcceptedEnvelope`.
    #[test]
    fn accepted_handoff_wire_event_carries_the_bounded_tail() {
        // A tail far larger than the cap; the builder truncates oldest-first to
        // fit MAX_ENVELOPE_BYTES, then the gate accepts what we built.
        let turns: Vec<handoff::HandoffTurn> = (0..200)
            .map(|i| handoff::HandoffTurn {
                role: if i % 2 == 0 { "user" } else { "assistant" }.to_owned(),
                text: format!("turn-{i}-{}", "x".repeat(1024)),
            })
            .collect();
        let source = SessionHandoffPayload {
            source_machine: "study-mac".to_owned(),
            conversation_tail: turns,
            pending_turn: Some("continue?".to_owned()),
            created_at_ms: 1_700_000_000_000,
        };
        let spec = HandoffEnvelopeSpec {
            envelope_id: "handoff-wire-1",
            sender_id: FLEET,
            created_at_ms: 1_700_000_000_000,
            public_key_id: "pk-1",
            signature_b64: "c2ln",
        };
        let fitted = handoff::fit_payload(&spec, &source).expect("envelope fits the cap");
        let raw = handoff::serialize_envelope(&spec, &fitted).expect("serialize fitted envelope");
        assert!(raw.len() <= MAX_ENVELOPE_BYTES);

        // ── ACCEPT PATH: only a gated envelope yields the payload we surface.
        let verifier =
            FaeSenderVerifier::new(HashSet::new(), HashSet::from([FLEET.to_owned()]), true);
        let dir = tempfile::tempdir().unwrap();
        let accepted = gate_and_audit(&raw, &verifier, &dir.path().join("audit.jsonl")).unwrap();
        assert_eq!(accepted.kind(), &EnvelopeKind::SessionHandoff);
        let payload = handoff::decode(&accepted).expect("decode accepted handoff");

        let (name, wire) = peer_event_to_wire(&PeerEvent::HandoffOffer {
            sender: accepted.sender_id().to_owned(),
            payload: payload.clone(),
            flagged: false,
        });
        assert_eq!(name, "peer.handoff_offer");
        let tail = wire["conversation_tail"].as_array().expect("tail present");
        assert!(!tail.is_empty(), "accepted handoff surfaces its tail");
        assert_eq!(wire["tail_len"].as_u64(), Some(tail.len() as u64));
        // The newest turns survived truncation; the tail on the wire is bounded
        // because the whole envelope that carried it was ≤ 64 KiB.
        let serialized = serde_json::to_string(&wire).unwrap();
        assert!(
            serialized.len() <= MAX_ENVELOPE_BYTES,
            "wire tail must stay within the gate cap ({} bytes)",
            serialized.len()
        );
        assert_eq!(tail.len(), payload.conversation_tail.len());
    }

    /// #17 security invariant: a raw frame over the cap is rejected by the gate
    /// BEFORE parsing, so it never becomes an `AcceptedEnvelope` — there is no
    /// path for its (un-gated) tail to reach the wire event.
    #[test]
    fn rejected_oversized_handoff_never_reaches_the_wire() {
        // A raw envelope one byte over the cap — the gate must refuse it.
        let oversized = "x".repeat(MAX_ENVELOPE_BYTES + 1);
        let verifier =
            FaeSenderVerifier::new(HashSet::new(), HashSet::from([FLEET.to_owned()]), true);
        let dir = tempfile::tempdir().unwrap();
        let result = gate_and_audit(&oversized, &verifier, &dir.path().join("audit.jsonl"));
        assert!(
            result.is_err(),
            "an oversized frame must never yield an AcceptedEnvelope"
        );
        // Because there is no AcceptedEnvelope, dispatch never runs and no
        // HandoffOffer (hence no tail) can be published — proven structurally:
        // peer_event_to_wire is only reachable from a dispatched PeerEvent, and
        // PeerEvent::HandoffOffer is only constructed in handler::dispatch from
        // handoff::decode(&AcceptedEnvelope).
    }

    #[test]
    fn append_rejected_writes_a_rejected_row() {
        let dir = tempfile::tempdir().unwrap();
        let audit = dir.path().join("audit.jsonl");
        append_rejected(&audit, "<unknown>", OWN, "transport_unverified");
        let content = std::fs::read_to_string(&audit).unwrap();
        assert!(content.contains("transport_unverified"));
        assert!(content.contains("rejected"));
    }

    // ── trust_decision quarantine (#4) ──

    #[test]
    fn is_flagged_fail_closed_unknown_and_non_accept_verdicts_quarantine() {
        let base = DirectEventFrame {
            sender: OWN.to_owned(),
            verified: true,
            trust_decision: String::new(),
            trust_level: TransportTrustLevel::Untrusted,
            payload_raw: "{}".to_owned(),
        };

        // FAIL-CLOSED (#44): empty/absent trust_decision ⇒ flagged with the
        // distinct "trust_metadata_missing_downgraded" reason. Previously this
        // was treated as clean; the hardening closed the permissive gap.
        assert!(is_flagged(&base));
        assert_eq!(
            trust_verdict(&base),
            Some("trust_metadata_missing_downgraded"),
            "absent trust_decision must produce the distinct downgrade reason"
        );

        // Explicit "accept" ⇒ clean.
        let clean = DirectEventFrame {
            trust_decision: "accept".to_owned(),
            ..base.clone()
        };
        assert!(!is_flagged(&clean));

        // Case-insensitive "ACCEPT" ⇒ clean (no case-bypass).
        let upper = DirectEventFrame {
            trust_decision: "ACCEPT".to_owned(),
            ..base.clone()
        };
        assert!(!is_flagged(&upper));

        // "accept_with_flag" ⇒ flagged.
        let flagged = DirectEventFrame {
            trust_decision: "accept_with_flag".to_owned(),
            ..base.clone()
        };
        assert!(is_flagged(&flagged));

        // FAIL-CLOSED: "rejected" ⇒ flagged.
        let rejected = DirectEventFrame {
            trust_decision: "rejected".to_owned(),
            ..base.clone()
        };
        assert!(is_flagged(&rejected));

        // FAIL-CLOSED: any unknown future verdict ⇒ flagged.
        let unknown = DirectEventFrame {
            trust_decision: "probation".to_owned(),
            ..base
        };
        assert!(is_flagged(&unknown));
    }

    /// I1: the behavioral test. If someone deletes `!flagged` from
    /// `should_auto_reply`, this test fails.
    #[test]
    fn flagged_suppresses_auto_reply_even_when_all_other_conditions_met() {
        use handler::DispatchOutcome;

        // Flagged ⇒ NO auto-reply, even with auto_reply enabled + Published DM.
        assert!(!should_auto_reply(
            true,
            true,
            EnvelopeKind::DirectMessage,
            &DispatchOutcome::Published
        ));

        // Unflagged + all conditions ⇒ auto-reply fires (baseline).
        assert!(should_auto_reply(
            true,
            false,
            EnvelopeKind::DirectMessage,
            &DispatchOutcome::Published
        ));

        // Auto-reply disabled ⇒ never fires regardless of flag.
        assert!(!should_auto_reply(
            false,
            false,
            EnvelopeKind::DirectMessage,
            &DispatchOutcome::Published
        ));
    }

    #[test]
    fn append_quarantined_writes_an_accepted_row() {
        let dir = tempfile::tempdir().unwrap();
        let audit = dir.path().join("audit.jsonl");
        append_quarantined(
            &audit,
            "env-flag-1",
            OWN,
            "flagged_envelope_quarantined_no_auto_reply",
        );
        let content = std::fs::read_to_string(&audit).unwrap();
        assert!(content.contains("flagged_envelope_quarantined_no_auto_reply"));
        assert!(
            content.contains("accepted"),
            "quarantine is an Accepted decision"
        );
        assert!(content.contains("env-flag-1"));
    }

    #[test]
    fn missing_trust_decision_logs_distinct_downgrade_reason() {
        // (#44): when trust_decision is absent/empty, the audit row must carry
        // "trust_metadata_missing_downgraded" so ops can distinguish a metadata
        // gap from an explicit non-accept verdict.
        let dir = tempfile::tempdir().unwrap();
        let audit = dir.path().join("audit.jsonl");
        append_quarantined(
            &audit,
            "env-downgrade-1",
            OWN,
            "trust_metadata_missing_downgraded",
        );
        let content = std::fs::read_to_string(&audit).unwrap();
        assert!(
            content.contains("trust_metadata_missing_downgraded"),
            "absent trust_decision must log the distinct downgrade reason (#44)"
        );
        assert!(
            content.contains("accepted"),
            "downgraded quarantine is still an Accepted gate decision"
        );
        assert!(content.contains("env-downgrade-1"));
    }

    #[test]
    fn sig_verified_with_missing_transport_trust_is_still_flagged() {
        // Defense in depth (#44): REAL ML-DSA signature verification and
        // transport trust metadata are independent checks — a
        // cryptographically verified envelope whose SSE frame is missing
        // trust_decision must still be quarantined. The two layers are NOT
        // equivalent or substitutable.

        // A genuinely signed envelope, accepted by the STRICT gate, whose
        // signature verifies through the real signing::verify path.
        let identity = signing::test_support::TestIdentity::generate();
        let payload = serde_json::json!({ "text": "hello peer" });
        let signature = locally_signed(
            &identity,
            &EnvelopeKind::DirectMessage,
            "dm-44-1",
            1_700_000_000_000,
            &payload,
        );
        let raw = serialize_signed_envelope(
            "direct_message",
            "dm-44-1",
            &identity.agent_id,
            1_700_000_000_000,
            &payload,
            &signature,
        )
        .unwrap();
        let strict = FaeSenderVerifier::new(
            HashSet::from([identity.agent_id.clone()]),
            HashSet::new(),
            false,
        );
        let dir = tempfile::tempdir().unwrap();
        let accepted = gate_and_audit(&raw, &strict, &dir.path().join("audit.jsonl")).unwrap();
        let signature_verified = signing::verify_envelope_signature(
            accepted.signature(),
            &accepted.signing_bytes(),
            accepted.sender_id(),
        );
        assert!(signature_verified, "the real ML-DSA verify path must pass");

        // The SSE frame that carried it: transport-verified but with ABSENT
        // trust_decision metadata.
        let frame = DirectEventFrame {
            sender: identity.agent_id.clone(),
            verified: true,                // transport signature accepted
            trust_decision: String::new(), // but trust metadata absent
            trust_level: TransportTrustLevel::Untrusted,
            payload_raw: raw,
        };

        // The exact ingress composition: effective_flag(transport, crypto).
        assert!(
            effective_flag(is_flagged(&frame), signature_verified),
            "a signature-verified envelope with absent trust_decision must still flag (#44)"
        );
        assert_eq!(
            trust_verdict(&frame),
            Some("trust_metadata_missing_downgraded"),
            "missing trust_decision must produce the distinct downgrade audit reason"
        );
    }

    #[test]
    fn flagged_message_carries_flag_and_envelope_id_on_wire() {
        let (name, payload) = peer_event_to_wire(&PeerEvent::Message {
            sender: OWN.to_owned(),
            text: "flagged content".to_owned(),
            envelope_id: "env-42".to_owned(),
            flagged: true,
        });
        assert_eq!(name, "peer.message");
        assert_eq!(payload["text"], "flagged content");
        assert_eq!(payload["envelope_id"], "env-42");
        assert_eq!(
            payload["flagged"].as_bool(),
            Some(true),
            "flagged messages must carry flagged=true on the wire"
        );
    }

    #[test]
    fn unflagged_message_has_flag_false_on_wire() {
        let (_name, payload) = peer_event_to_wire(&PeerEvent::Message {
            sender: OWN.to_owned(),
            text: "clean".to_owned(),
            envelope_id: "env-43".to_owned(),
            flagged: false,
        });
        assert_eq!(payload["flagged"].as_bool(), Some(false));
    }

    #[test]
    fn flagged_handoff_carries_flag_on_wire() {
        let (_name, payload) = peer_event_to_wire(&PeerEvent::HandoffOffer {
            sender: FLEET.to_owned(),
            payload: SessionHandoffPayload {
                source_machine: "study-mac".to_owned(),
                conversation_tail: Vec::new(),
                pending_turn: None,
                created_at_ms: 0,
            },
            flagged: true,
        });
        assert_eq!(
            payload["flagged"].as_bool(),
            Some(true),
            "flagged handoffs must carry flagged=true on the wire"
        );
    }

    /// Minimal single-future block-on for the two sync-looking async unit tests
    /// above (they never actually await I/O — the paths under test return before
    /// any network call).
    fn tokio_test_block<F: std::future::Future>(fut: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(fut)
    }
}
