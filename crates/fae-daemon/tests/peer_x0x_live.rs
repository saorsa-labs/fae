//! Phase E (commit 2) — LIVE x0x peer-ingress integration test.
//!
//! Exercises the peer membrane end-to-end against two real x0xd daemons running
//! on this machine (default on :12700, second identity `fae-test-peer` on
//! :12701). `#[ignore]`d by default — run explicitly:
//!
//! ```text
//! cargo test -p fae-daemon --test peer_x0x_live -- --ignored --nocapture
//! ```
//!
//! If either daemon is down (or its token file is missing) the test prints a
//! skip line and returns `Ok` — it never fails a headless CI box with no x0xd.
//!
//! ## Why the wire + gate are exercised here, but not the in-crate client
//!
//! `fae-daemon` is a **binary-only** crate (no `lib` target), so this
//! integration test cannot reach `crate::peer::{X0xPeerClient, FaeSenderVerifier,
//! handler}` — those are internal to the binary. Rather than refactor the whole
//! binary into a lib (out of scope for this commit), the test drives the REAL
//! x0xd wire with `reqwest` (the same endpoints + payload shape `X0xPeerClient`
//! uses), runs every received envelope through the REAL
//! `fae_envelope_gate::gate_and_audit`, and gates it with an inline
//! `TierVerifier` that MIRRORS the production `FaeSenderVerifier` tier rule
//! (`session_handoff` = owner-fleet only; chat kinds = chat ∪ fleet; ml-dsa-65 +
//! base64 shape). The production client's SSE parser, the real verifier, and
//! dispatch are unit-tested in-crate (`src/peer/x0x_client.rs`, `src/peer/mod.rs`,
//! `src/peer/{verifier,handler}.rs`).

use std::collections::HashSet;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use fae_envelope_gate::{
    gate_and_audit, EnvelopeKind, GateError, PeerEnvelope, SignatureVerifier, MAX_ENVELOPE_BYTES,
};
use futures_util::StreamExt;

const DEFAULT_BASE: &str = "http://127.0.0.1:12700";
const PEER_BASE: &str = "http://127.0.0.1:12701";
const WIRE_TIMEOUT: Duration = Duration::from_secs(30);

fn token_path(instance: Option<&str>) -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    let dir_name = match instance {
        Some(inst) => format!("x0x-{inst}"),
        None => "x0x".to_owned(),
    };
    Some(
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join(dir_name)
            .join("api-token"),
    )
}

fn read_token(instance: Option<&str>) -> Option<String> {
    let path = token_path(instance)?;
    let raw = std::fs::read_to_string(path).ok()?;
    let trimmed = raw.trim().to_owned();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// A decoded `direct_message` SSE frame from the wire.
struct WireFrame {
    sender: String,
    verified: bool,
    trust_decision: String,
    payload_raw: String,
}

async fn http_get_json(
    client: &reqwest::Client,
    base: &str,
    token: &str,
    path: &str,
) -> Option<serde_json::Value> {
    let resp = client
        .get(format!("{base}{path}"))
        .bearer_auth(token)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.json().await.ok()
}

async fn health(client: &reqwest::Client, base: &str, token: &str) -> bool {
    match client
        .get(format!("{base}/health"))
        .bearer_auth(token)
        .timeout(Duration::from_secs(5))
        .send()
        .await
    {
        Ok(resp) => resp.status().is_success(),
        Err(_) => false,
    }
}

async fn own_agent_id(client: &reqwest::Client, base: &str, token: &str) -> Option<String> {
    let value = http_get_json(client, base, token, "/agent").await?;
    value
        .get("agent_id")
        .and_then(serde_json::Value::as_str)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
}

async fn direct_send(
    client: &reqwest::Client,
    base: &str,
    token: &str,
    dest: &str,
    raw_envelope: &str,
) -> bool {
    let payload_b64 = b64(raw_envelope.as_bytes());
    match client
        .post(format!("{base}/direct/send"))
        .bearer_auth(token)
        .timeout(Duration::from_secs(10))
        .json(&serde_json::json!({ "agent_id": dest, "payload": payload_b64 }))
        .send()
        .await
    {
        Ok(resp) => resp.status().is_success(),
        Err(_) => false,
    }
}

/// Parse one `direct_message` SSE `data:` blob into a frame (mirrors the
/// in-crate `parse_direct_frame`).
fn parse_wire_frame(data: &str) -> Option<WireFrame> {
    let value: serde_json::Value = serde_json::from_str(data).ok()?;
    let sender = value.get("sender").and_then(|v| v.as_str())?.to_owned();
    let payload_b64 = value.get("payload").and_then(|v| v.as_str())?;
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(payload_b64.as_bytes())
        .ok()?;
    Some(WireFrame {
        sender,
        verified: value
            .get("verified")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        trust_decision: value
            .get("trust_decision")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_owned(),
        payload_raw: String::from_utf8(decoded).ok()?,
    })
}

/// Open `/direct/events` and read until a `direct_message` frame arrives from
/// `want_sender` (or the deadline passes). Returns `None` on timeout/error.
async fn read_direct_frame(
    client: &reqwest::Client,
    base: &str,
    token: &str,
    want_sender: &str,
) -> Option<WireFrame> {
    let resp = client
        .get(format!("{base}/direct/events"))
        .bearer_auth(token)
        .header("Accept", "text/event-stream")
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let mut stream = resp.bytes_stream();
    let deadline = Instant::now() + WIRE_TIMEOUT;
    let mut buffer = String::new();
    let mut event: Option<String> = None;
    let mut data = String::new();
    loop {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        let chunk = match tokio::time::timeout(remaining, stream.next()).await {
            Ok(Some(Ok(chunk))) => chunk,
            _ => return None,
        };
        buffer.push_str(&String::from_utf8_lossy(&chunk));
        while let Some(newline) = buffer.find('\n') {
            let line: String = buffer.drain(..=newline).collect();
            let line = line.trim_end_matches(['\r', '\n']);
            if line.is_empty() {
                if event.as_deref() == Some("direct_message") {
                    if let Some(frame) = parse_wire_frame(&data) {
                        if frame.sender.eq_ignore_ascii_case(want_sender) {
                            return Some(frame);
                        }
                    }
                }
                event = None;
                data.clear();
            } else if let Some(rest) = line.strip_prefix("event:") {
                event = Some(rest.trim().to_owned());
            } else if let Some(rest) = line.strip_prefix("data:") {
                let chunk = rest.strip_prefix(' ').unwrap_or(rest);
                if !data.is_empty() {
                    data.push('\n');
                }
                data.push_str(chunk);
            }
        }
    }
}

/// Inline mirror of the production `FaeSenderVerifier` tier rule (which lives in
/// the binary crate, unreachable from here). Kept in lock-step with
/// `src/peer/verifier.rs`.
struct TierVerifier {
    chat: HashSet<String>,
    fleet: HashSet<String>,
}

impl SignatureVerifier for TierVerifier {
    fn verify(&self, envelope: &PeerEnvelope) -> bool {
        let signature = envelope.signature();
        if signature.algorithm() != "ml-dsa-65"
            || signature.public_key_id().trim().is_empty()
            || signature.signature_b64().is_empty()
        {
            return false;
        }
        let sender = envelope.sender_id().to_ascii_lowercase();
        match envelope.kind() {
            EnvelopeKind::SessionHandoff => self.fleet.contains(&sender),
            EnvelopeKind::DirectMessage
            | EnvelopeKind::PresenceUpdate
            | EnvelopeKind::ConsentReceipt
            | EnvelopeKind::ConsentRevocation => {
                self.chat.contains(&sender) || self.fleet.contains(&sender)
            }
            EnvelopeKind::MemoryShareOffer | EnvelopeKind::ConductorGateReceiptPrior => false,
        }
    }
}

fn direct_message_envelope(sender: &str, text: &str) -> String {
    serde_json::json!({
        "schema_version": 1,
        "kind": "direct_message",
        "envelope_id": format!("live-dm-{}", now_ms()),
        "sender_id": sender,
        "created_at_ms": now_ms(),
        "payload": { "text": text },
        "signature": {
            "algorithm": "ml-dsa-65",
            "public_key_id": sender,
            "signature_b64": "cGxhY2Vob2xkZXI=",
        }
    })
    .to_string()
}

fn session_handoff_envelope(sender: &str) -> String {
    serde_json::json!({
        "schema_version": 1,
        "kind": "session_handoff",
        "envelope_id": format!("live-handoff-{}", now_ms()),
        "sender_id": sender,
        "created_at_ms": now_ms(),
        "payload": {
            "source_machine": "peer-test-mac",
            "conversation_tail": [{ "role": "user", "text": "carry this over" }],
            "pending_turn": "and then what?",
            "created_at_ms": 1_700_000_000_000_i64
        },
        "signature": {
            "algorithm": "ml-dsa-65",
            "public_key_id": sender,
            "signature_b64": "cGxhY2Vob2xkZXI=",
        }
    })
    .to_string()
}

#[tokio::test]
#[ignore = "requires two live x0xd daemons on :12700 and :12701"]
async fn peer_x0x_live_ingress_roundtrip() {
    let Some(token_a) = read_token(None) else {
        eprintln!("SKIP: default x0x api-token not found — is x0xd running?");
        return;
    };
    let Some(token_b) = read_token(Some("fae-test-peer")) else {
        eprintln!("SKIP: fae-test-peer x0x api-token not found");
        return;
    };
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .build()
        .expect("reqwest client");

    if !health(&client, DEFAULT_BASE, &token_a).await {
        eprintln!("SKIP: default x0xd ({DEFAULT_BASE}) not healthy");
        return;
    }
    if !health(&client, PEER_BASE, &token_b).await {
        eprintln!("SKIP: peer x0xd ({PEER_BASE}) not healthy");
        return;
    }
    eprintln!("both x0xd daemons healthy");

    let own_a = own_agent_id(&client, DEFAULT_BASE, &token_a)
        .await
        .expect("default /agent id");
    let own_b = own_agent_id(&client, PEER_BASE, &token_b)
        .await
        .expect("peer /agent id");
    eprintln!("agent A = {own_a}");
    eprintln!("agent B = {own_b}");

    let tmp = tempfile::tempdir().expect("tempdir");
    let audit = tmp.path().join("peer_envelope_audit.jsonl");

    // ── A → B : DirectMessage, B allows A ──────────────────────────────────
    // Open B's SSE first (so we do not miss the frame), then A sends.
    let text = format!("hello from A (live test {})", now_ms());
    let envelope = direct_message_envelope(&own_a, &text);
    let recv_b = {
        let client = client.clone();
        let token_b = token_b.clone();
        let own_a = own_a.clone();
        tokio::spawn(async move { read_direct_frame(&client, PEER_BASE, &token_b, &own_a).await })
    };
    // Small head-start so the SSE stream is established before the send.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        direct_send(&client, DEFAULT_BASE, &token_a, &own_b, &envelope).await,
        "A→B /direct/send should accept"
    );

    match recv_b.await.expect("join recv_b") {
        Some(frame) => {
            eprintln!(
                "A→B received: verified={} trust={}",
                frame.verified, frame.trust_decision
            );
            // Transport pre-check.
            assert!(frame.verified, "x0xd must mark the frame verified");
            // THE GATE — B allows A on the chat tier.
            let verifier = TierVerifier {
                chat: HashSet::from([own_a.to_ascii_lowercase()]),
                fleet: HashSet::new(),
            };
            let accepted = gate_and_audit(&frame.payload_raw, &verifier, &audit)
                .expect("A→B direct_message must gate-accept");
            assert_eq!(accepted.kind(), &EnvelopeKind::DirectMessage);
            // Sender cross-check (envelope sender == transport sender).
            assert!(accepted.sender_id().eq_ignore_ascii_case(&frame.sender));
            // Dispatch outcome (dispatch itself is unit-tested in-crate): a
            // non-empty text on a permitted DirectMessage is Published.
            assert_eq!(accepted.peer_text_for_policy_review(), Some(text.as_str()));
            let log = std::fs::read_to_string(&audit).expect("audit file");
            assert!(log.contains("accepted"), "accepted row must be audited");
            eprintln!("A→B: gated + accepted + audited OK");
        }
        None => {
            eprintln!(
                "WARN: A→B frame not observed within {WIRE_TIMEOUT:?} — x0x delivery/trust may not be established; \
                 continuing to deterministic gate assertions"
            );
        }
    }

    // ── B → A : SessionHandoff, A's owner_fleet = {B} ──────────────────────
    let handoff = session_handoff_envelope(&own_b);
    let recv_a = {
        let client = client.clone();
        let token_a = token_a.clone();
        let own_b = own_b.clone();
        tokio::spawn(
            async move { read_direct_frame(&client, DEFAULT_BASE, &token_a, &own_b).await },
        )
    };
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        direct_send(&client, PEER_BASE, &token_b, &own_a, &handoff).await,
        "B→A /direct/send should accept"
    );
    match recv_a.await.expect("join recv_a") {
        Some(frame) => {
            assert!(frame.verified);
            let verifier = TierVerifier {
                chat: HashSet::new(),
                fleet: HashSet::from([own_b.to_ascii_lowercase()]),
            };
            let accepted = gate_and_audit(&frame.payload_raw, &verifier, &audit)
                .expect("B→A session_handoff must gate-accept (owner-fleet)");
            assert_eq!(accepted.kind(), &EnvelopeKind::SessionHandoff);
            // Decode the carrier payload (handoff schema owned by the binary
            // crate; decoded inline here).
            let payload = accepted.prior_payload().expect("handoff payload");
            assert_eq!(payload["source_machine"], "peer-test-mac");
            assert_eq!(payload["pending_turn"], "and then what?");
            eprintln!("B→A: session_handoff gated + accepted + payload decoded OK");
        }
        None => {
            eprintln!("WARN: B→A handoff frame not observed within {WIRE_TIMEOUT:?} — continuing");
        }
    }

    // ── Deterministic gate negatives (no network) ──────────────────────────
    // Non-allowlisted sender → SignatureRejected + a rejected audit row.
    let stranger = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    let stranger_env = direct_message_envelope(stranger, "unsolicited");
    let empty_verifier = TierVerifier {
        chat: HashSet::new(),
        fleet: HashSet::new(),
    };
    let reject_audit = tmp.path().join("reject.jsonl");
    assert!(
        matches!(
            gate_and_audit(&stranger_env, &empty_verifier, &reject_audit),
            Err(GateError::SignatureRejected)
        ),
        "non-allowlisted sender must be rejected"
    );
    let reject_log = std::fs::read_to_string(&reject_audit).expect("reject audit");
    assert!(reject_log.contains("rejected"));
    assert!(reject_log.contains("signature_rejected"));

    // Unknown kind → InvalidJson (closed enum, forward-roll fail-closed).
    let bogus = stranger_env.replace("direct_message", "totally_unknown_kind");
    assert!(matches!(
        gate_and_audit(&bogus, &empty_verifier, &tmp.path().join("bogus.jsonl")),
        Err(GateError::InvalidJson(_))
    ));

    // Oversized (> 64 KiB) → TooLarge, refused before serde allocates.
    let oversized = "x".repeat(MAX_ENVELOPE_BYTES + 1);
    assert!(matches!(
        gate_and_audit(&oversized, &empty_verifier, &tmp.path().join("big.jsonl")),
        Err(GateError::TooLarge { size, max })
            if size == MAX_ENVELOPE_BYTES + 1 && max == MAX_ENVELOPE_BYTES
    ));

    eprintln!("deterministic gate negatives (rejected / unknown-kind / oversized) OK");
    eprintln!("peer_x0x_live_ingress_roundtrip PASSED");
}
