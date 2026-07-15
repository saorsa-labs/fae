//! Phase E (commit 2) — the x0xd REST client for peer messaging.
//!
//! [`X0xPeerClient`] speaks the small slice of the x0xd HTTP surface the peer
//! lane needs: `GET /agent` (own identity), `POST /direct/send` (outbound
//! envelopes), `GET /direct/events` (inbound SSE), and `GET /health`. Auth is
//! the durable bearer token in the `Authorization` header ONLY — x0xd rejects
//! query-string tokens with 401.
//!
//! The client is **transport only**: it has NO retry logic and NO reconnect
//! loop (the ingress supervisor in [`super`] owns backoff), and NO envelope
//! knowledge (it ships an opaque base64 payload and hands back the decoded
//! bytes). Every request is timeout-bounded EXCEPT the long-lived
//! `/direct/events` stream, which stays open until the peer disconnects or the
//! supervisor drops it.

use std::time::Duration;

use base64::Engine as _;
use futures_util::{Stream, StreamExt};
use serde::Deserialize;

/// Per-request timeout for the short REST calls (`/agent`, `/direct/send`).
/// Deliberately NOT applied to the `/direct/events` stream.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
/// Health probe timeout — shorter, since it gates "is x0xd up at all".
const HEALTH_TIMEOUT: Duration = Duration::from_secs(5);
/// Connection establishment ceiling shared by every request.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Failures surfaced by the client. The supervisor logs + backs off; it never
/// panics on any of these.
#[derive(Debug, thiserror::Error)]
pub enum X0xClientError {
    #[error("x0x request failed: {0}")]
    Request(reqwest::Error),
    #[error("x0x returned HTTP {0}")]
    Status(u16),
    #[error("x0x response missing field: {0}")]
    MissingField(&'static str),
}

/// One decoded `direct_message` SSE frame. `payload_raw` is the base64-**decoded**
/// carrier — i.e. the raw peer-envelope JSON string, ready to hand straight to
/// `fae_envelope_gate::gate_and_audit`. `verified` / `trust_decision` are x0xd's
/// transport-layer verdict, cross-checked by the supervisor BEFORE the gate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectEventFrame {
    /// x0x agent id of the sender (transport-attested, lowercase 64-hex).
    pub sender: String,
    /// x0xd verified the sender's transport signature.
    pub verified: bool,
    /// x0xd's trust verdict string (e.g. `accept_with_flag`).
    pub trust_decision: String,
    /// The base64-decoded carrier payload (the raw peer-envelope JSON).
    pub payload_raw: String,
}

/// A thin, cloneable x0xd REST client (the inner `reqwest::Client` is an `Arc`).
#[derive(Debug, Clone)]
pub struct X0xPeerClient {
    http: reqwest::Client,
    /// Base URL with any trailing slash trimmed (e.g. `http://127.0.0.1:12700`).
    base_url: String,
    token: String,
}

impl X0xPeerClient {
    /// Build a client for `base_url` authenticating with `token`. Constructing
    /// the client never touches the network — the first request does.
    pub fn new(
        base_url: impl Into<String>,
        token: impl Into<String>,
    ) -> Result<X0xPeerClient, X0xClientError> {
        let http = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .build()
            .map_err(X0xClientError::Request)?;
        let base_url = base_url.into().trim_end_matches('/').to_owned();
        Ok(X0xPeerClient {
            http,
            base_url,
            token: token.into(),
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base_url)
    }

    /// This node's own x0x agent id, via `GET /agent`. Discovered at startup so
    /// nothing hardcodes it.
    pub async fn own_agent_id(&self) -> Result<String, X0xClientError> {
        let response = self
            .http
            .get(self.url("/agent"))
            .bearer_auth(&self.token)
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(X0xClientError::Request)?;
        if !response.status().is_success() {
            return Err(X0xClientError::Status(response.status().as_u16()));
        }
        let body: AgentResponse = response.json().await.map_err(X0xClientError::Request)?;
        body.agent_id
            .filter(|id| !id.trim().is_empty())
            .ok_or(X0xClientError::MissingField("agent_id"))
    }

    /// Sign `payload` under a domain-separation `context` with this node's
    /// x0xd-held ML-DSA-65 identity key, via `POST /agent/sign`. x0xd
    /// assembles the external DST server-side (see `super::signing`); the
    /// response carries the raw public key + detached signature, base64.
    /// Transport only — response validation (scheme, context echo, identity
    /// binding) is the caller's job (`signing::validate_sign_response`).
    pub async fn agent_sign(
        &self,
        context: &str,
        payload: &[u8],
    ) -> Result<AgentSignResponse, X0xClientError> {
        let payload_b64 = base64::engine::general_purpose::STANDARD.encode(payload);
        let response = self
            .http
            .post(self.url("/agent/sign"))
            .bearer_auth(&self.token)
            .timeout(REQUEST_TIMEOUT)
            .json(&serde_json::json!({ "context": context, "payload_b64": payload_b64 }))
            .send()
            .await
            .map_err(X0xClientError::Request)?;
        if !response.status().is_success() {
            return Err(X0xClientError::Status(response.status().as_u16()));
        }
        let body: RawAgentSignResponse = response.json().await.map_err(X0xClientError::Request)?;
        let field_or = |value: Option<String>, name: &'static str| {
            value
                .filter(|v| !v.trim().is_empty())
                .ok_or(X0xClientError::MissingField(name))
        };
        Ok(AgentSignResponse {
            agent_id: field_or(body.agent_id, "agent_id")?,
            public_key_b64: field_or(body.public_key_b64, "public_key_b64")?,
            signature_b64: field_or(body.signature_b64, "signature_b64")?,
            algorithm: field_or(body.algorithm, "algorithm")?,
            context: field_or(body.context, "context")?,
        })
    }

    /// Send a raw peer-envelope JSON string to `dest_agent_id` via
    /// `POST /direct/send`. The envelope is base64-encoded into the `payload`
    /// field; x0xd re-emits it (re-base64'd) on the destination's SSE stream.
    pub async fn direct_send(
        &self,
        dest_agent_id: &str,
        raw_envelope_json: &str,
    ) -> Result<(), X0xClientError> {
        let payload_b64 =
            base64::engine::general_purpose::STANDARD.encode(raw_envelope_json.as_bytes());
        let response = self
            .http
            .post(self.url("/direct/send"))
            .bearer_auth(&self.token)
            .timeout(REQUEST_TIMEOUT)
            .json(&serde_json::json!({ "agent_id": dest_agent_id, "payload": payload_b64 }))
            .send()
            .await
            .map_err(X0xClientError::Request)?;
        if !response.status().is_success() {
            return Err(X0xClientError::Status(response.status().as_u16()));
        }
        Ok(())
    }

    /// Open the inbound `GET /direct/events` SSE stream. The returned stream
    /// yields one [`DirectEventFrame`] per `event: direct_message` block;
    /// keepalives, other event types, and unparseable blocks are silently
    /// skipped. The stream ENDS (no error item) when the connection drops — the
    /// supervisor treats end-of-stream as its reconnect trigger. This request
    /// is intentionally NOT timeout-bounded (it is long-lived).
    pub async fn direct_events(
        &self,
    ) -> Result<impl Stream<Item = DirectEventFrame>, X0xClientError> {
        let response = self
            .http
            .get(self.url("/direct/events"))
            .bearer_auth(&self.token)
            .header("Accept", "text/event-stream")
            .send()
            .await
            .map_err(X0xClientError::Request)?;
        if !response.status().is_success() {
            return Err(X0xClientError::Status(response.status().as_u16()));
        }
        let stream = async_stream::stream! {
            let mut bytes = response.bytes_stream();
            let mut acc = DirectEventAccumulator::default();
            let mut buffer = String::new();
            while let Some(chunk) = bytes.next().await {
                let Ok(chunk) = chunk else {
                    // A transport read error ends the stream; the supervisor
                    // reconnects with backoff. No partial frame is emitted.
                    break;
                };
                buffer.push_str(&String::from_utf8_lossy(&chunk));
                while let Some(newline) = buffer.find('\n') {
                    let line: String = buffer.drain(..=newline).collect();
                    let line = line.trim_end_matches('\n');
                    if let Some(frame) = acc.push_line(line) {
                        yield frame;
                    }
                }
            }
        };
        Ok(stream)
    }

    /// Best-effort health probe: `true` iff `GET /health` returns 2xx within the
    /// short timeout. Any error (down, refused, timed out) is `false`.
    pub async fn health(&self) -> bool {
        match self
            .http
            .get(self.url("/health"))
            .bearer_auth(&self.token)
            .timeout(HEALTH_TIMEOUT)
            .send()
            .await
        {
            Ok(response) => response.status().is_success(),
            Err(_) => false,
        }
    }
}

#[derive(Deserialize)]
struct AgentResponse {
    agent_id: Option<String>,
}

/// One validated-shape `POST /agent/sign` response (all fields present and
/// non-empty; cryptographic/identity validation happens in `super::signing`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentSignResponse {
    /// x0xd's agent id (lowercase 64-hex).
    pub agent_id: String,
    /// Base64 of the raw ML-DSA-65 public key.
    pub public_key_b64: String,
    /// Base64 detached ML-DSA-65 signature.
    pub signature_b64: String,
    /// x0xd's signing scheme id (expected `x0x.agent-sign.v2.ml-dsa-65`).
    pub algorithm: String,
    /// Echo of the requested domain-separation context.
    pub context: String,
}

/// Lenient wire view of `/agent/sign` (x0xd adds e.g. `ok`; ignored).
#[derive(Deserialize)]
struct RawAgentSignResponse {
    agent_id: Option<String>,
    public_key_b64: Option<String>,
    signature_b64: Option<String>,
    algorithm: Option<String>,
    context: Option<String>,
}

/// Lenient view of a `direct_message` SSE `data:` JSON. NOT `deny_unknown_fields`
/// — x0xd may add transport fields (`machine_id`, `received_at`, …) we ignore.
#[derive(Deserialize)]
struct RawDirectData {
    sender: Option<String>,
    #[serde(default)]
    verified: bool,
    #[serde(default)]
    trust_decision: String,
    payload: Option<String>,
}

/// Incremental SSE accumulator: feed it lines (newline already stripped) and it
/// emits one [`DirectEventFrame`] on the blank line terminating a
/// `direct_message` event. Everything else (comment/keepalive lines, non
/// `direct_message` events, blocks whose data won't parse or decode) yields
/// `None`. Pure and deterministic — unit-tested below.
#[derive(Default)]
struct DirectEventAccumulator {
    event: Option<String>,
    data: String,
}

impl DirectEventAccumulator {
    fn push_line(&mut self, raw_line: &str) -> Option<DirectEventFrame> {
        let line = raw_line.trim_end_matches('\r');
        // Blank line = event boundary: dispatch whatever accumulated.
        if line.is_empty() {
            return self.take_frame();
        }
        // Comment / keepalive.
        if line.starts_with(':') {
            return None;
        }
        if let Some(rest) = line.strip_prefix("event:") {
            self.event = Some(rest.trim().to_owned());
        } else if let Some(rest) = line.strip_prefix("data:") {
            // SSE strips exactly one leading space; multiple data lines join
            // with a newline.
            let chunk = rest.strip_prefix(' ').unwrap_or(rest);
            if !self.data.is_empty() {
                self.data.push('\n');
            }
            self.data.push_str(chunk);
        }
        // `id:` / `retry:` / unknown fields are ignored.
        None
    }

    fn take_frame(&mut self) -> Option<DirectEventFrame> {
        let event = self.event.take();
        let data = std::mem::take(&mut self.data);
        if event.as_deref() != Some("direct_message") || data.is_empty() {
            return None;
        }
        parse_direct_frame(&data)
    }
}

/// Parse one `direct_message` `data:` payload into a frame, decoding the base64
/// carrier. Returns `None` on any malformed/missing field so a single bad frame
/// is dropped, never fatal.
fn parse_direct_frame(data: &str) -> Option<DirectEventFrame> {
    let raw: RawDirectData = serde_json::from_str(data).ok()?;
    let sender = raw.sender.filter(|s| !s.trim().is_empty())?;
    let payload_b64 = raw.payload?;
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(payload_b64.as_bytes())
        .ok()?;
    let payload_raw = String::from_utf8(decoded).ok()?;
    Some(DirectEventFrame {
        sender,
        verified: raw.verified,
        trust_decision: raw.trust_decision,
        payload_raw,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b64(s: &str) -> String {
        base64::engine::general_purpose::STANDARD.encode(s.as_bytes())
    }

    /// Feed a whole SSE blob line-by-line, collecting every emitted frame.
    fn drain(blob: &str) -> Vec<DirectEventFrame> {
        let mut acc = DirectEventAccumulator::default();
        let mut out = Vec::new();
        for line in blob.split_inclusive('\n') {
            let line = line.trim_end_matches('\n');
            if let Some(frame) = acc.push_line(line) {
                out.push(frame);
            }
        }
        out
    }

    #[test]
    fn parses_a_single_direct_message_frame() {
        let envelope = r#"{"kind":"direct_message"}"#;
        let data = format!(
            "{{\"machine_id\":\"m\",\"payload\":\"{}\",\"received_at\":1,\"sender\":\"aabb\",\"trust_decision\":\"accept_with_flag\",\"verified\":true}}",
            b64(envelope)
        );
        let blob = format!("event: direct_message\ndata: {data}\n\n");
        let frames = drain(&blob);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].sender, "aabb");
        assert!(frames[0].verified);
        assert_eq!(frames[0].trust_decision, "accept_with_flag");
        assert_eq!(frames[0].payload_raw, envelope);
    }

    #[test]
    fn preserves_verified_false() {
        // The parser must not coerce or drop unverified frames — the supervisor
        // owns the verified==true decision, not the wire parser.
        let data = format!(
            "{{\"payload\":\"{}\",\"sender\":\"aa\",\"trust_decision\":\"rejected\",\"verified\":false}}",
            b64("{}")
        );
        let frames = drain(&format!("event: direct_message\ndata: {data}\n\n"));
        assert_eq!(frames.len(), 1);
        assert!(!frames[0].verified);
        assert_eq!(frames[0].trust_decision, "rejected");
    }

    #[test]
    fn multi_line_data_is_joined_with_newlines() {
        // Two `data:` lines concatenate with a '\n' per the SSE spec, so a JSON
        // payload split across lines still parses.
        let data_json = "{\"payload\":\"PAYLOAD\",\"sender\":\"aa\",\"verified\":true}";
        let (first, second) = data_json.split_at(20);
        let payload = b64(r#"{"x":1}"#);
        let blob = format!("event: direct_message\ndata: {first}\ndata: {second}\n\n")
            .replace("PAYLOAD", &payload);
        let frames = drain(&blob);
        assert_eq!(frames.len(), 1, "split data lines must rejoin and parse");
        assert_eq!(frames[0].payload_raw, r#"{"x":1}"#);
    }

    #[test]
    fn keepalive_and_comment_lines_are_skipped() {
        let payload = b64(r#"{"ok":true}"#);
        let blob = format!(
            ": keepalive\n\nevent: direct_message\ndata: {{\"payload\":\"{payload}\",\"sender\":\"aa\",\"verified\":true}}\n\n: another keepalive\n\n"
        );
        let frames = drain(&blob);
        assert_eq!(frames.len(), 1, "comments/keepalives must not emit frames");
        assert_eq!(frames[0].sender, "aa");
    }

    #[test]
    fn non_direct_message_events_are_ignored() {
        let payload = b64(r#"{"ok":true}"#);
        let blob = format!(
            "event: presence\ndata: {{\"payload\":\"{payload}\",\"sender\":\"aa\",\"verified\":true}}\n\n"
        );
        assert!(
            drain(&blob).is_empty(),
            "only direct_message events surface a frame"
        );
    }

    #[test]
    fn undecodable_payload_is_dropped_not_fatal() {
        let blob = "event: direct_message\ndata: {\"payload\":\"!!!not base64!!!\",\"sender\":\"aa\",\"verified\":true}\n\n";
        assert!(drain(blob).is_empty(), "bad base64 → drop, never panic");
    }

    #[test]
    fn missing_sender_is_dropped() {
        let payload = b64("{}");
        let blob = format!(
            "event: direct_message\ndata: {{\"payload\":\"{payload}\",\"verified\":true}}\n\n"
        );
        assert!(drain(&blob).is_empty());
    }

    #[test]
    fn base_url_trailing_slash_is_trimmed() {
        let client = X0xPeerClient::new("http://127.0.0.1:12700/", "tok").unwrap();
        assert_eq!(client.url("/agent"), "http://127.0.0.1:12700/agent");
    }
}
