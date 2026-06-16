//! TCP-loopback HTTP + WebSocket **diagnostic** listener (chunk 2c).
//!
//! Opt-in only (`FAE_DIAGNOSTIC_TCP_PORT`); never started by default. Binds
//! literal loopback (`127.0.0.1` and `[::1]`) and enforces, per the
//! control-plane design:
//! - exact-match `Host` (anti-DNS-rebind) + literal-loopback `Origin`;
//! - defensive headers on every HTTP response;
//! - bearer auth (`X-Fae-Client-Id` + `Authorization: Bearer …`) for
//!   `GET /v1/status` and `POST /v1/ticket`;
//! - **single-use stream tickets** for `GET /v1/stream/<name>` WS upgrades —
//!   presented via `Sec-WebSocket-Protocol` (never `?token=`), consumed
//!   atomically, endpoint-bound; the ticket's granted scopes (∩ the client's
//!   live scopes) gate every WS message via the shared [`crate::session`] core.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use fae_audio::AudioManager;
use fae_control_plane::{
    append_audit_jsonl, host_header_allowed, origin_allowed, AuditDecision, AuditEvent, AuthError,
    ClientRecord, ClientRegistry, ConsumedTicket, Response as CpResponse, Scope, TicketStore,
    PROTOCOL_VERSION,
};
use fae_engine::{ProviderAdapter, TtsAdapter};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::accept_hdr_async_with_config;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::{HeaderMap, HeaderValue, StatusCode};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

use crate::session::{handle_frame, session_from_ticket, SessionBackends, SessionState};
use crate::{next_event_id, now_ms};

/// WS stream endpoints live under this prefix; the full path is the ticket's
/// endpoint binding.
const STREAM_PREFIX: &str = "/v1/stream/";
/// Base subprotocol the client must offer alongside `fae-ticket.<token>`. Only
/// this (never the secret ticket) is echoed back in the handshake response.
const BASE_SUBPROTOCOL: &str = "fae.v2";
/// Cap on the peeked header block and on a POST body.
const MAX_HEAD_BYTES: usize = 16 * 1024;
const MAX_BODY_BYTES: usize = 64 * 1024;
/// Cap on a single WS message/frame — control frames are tiny, so this bounds a
/// runaway client to the same order as the Unix socket's frame cap instead of
/// tungstenite's multi-MiB default.
const MAX_WS_MESSAGE_BYTES: usize = 256 * 1024;

/// Shared state for the diagnostic listener.
pub struct DiagnosticState {
    pub registry: Arc<ClientRegistry>,
    pub engine: Arc<dyn ProviderAdapter>,
    pub tts: Arc<dyn TtsAdapter>,
    pub audio: Arc<AudioManager>,
    pub tickets: Arc<Mutex<TicketStore>>,
    pub audit_path: PathBuf,
    pub events: crate::events::EventBus,
    pub playbacks: crate::events::PlaybackRegistry,
    pub port: u16,
}

/// Bind both loopback families and serve until killed. IPv4 is required; IPv6 is
/// best-effort (some hosts lack `::1`).
pub async fn serve_tcp(state: Arc<DiagnosticState>) -> std::io::Result<()> {
    let v4 = TcpListener::bind(("127.0.0.1", state.port)).await?;
    eprintln!("fae-daemon: diagnostic HTTP/WS on 127.0.0.1:{}", state.port);
    if let Ok(v6) = TcpListener::bind(("::1", state.port)).await {
        let state6 = Arc::clone(&state);
        tokio::spawn(async move {
            let _ = accept_loop(v6, state6).await;
        });
        eprintln!("fae-daemon: diagnostic HTTP/WS on [::1]:{}", state.port);
    }
    accept_loop(v4, state).await
}

async fn accept_loop(listener: TcpListener, state: Arc<DiagnosticState>) -> std::io::Result<()> {
    loop {
        let (stream, _peer) = listener.accept().await?;
        let state = Arc::clone(&state);
        tokio::spawn(async move {
            if let Err(error) = handle_conn(stream, state).await {
                eprintln!("fae-daemon: diagnostic conn ended: {error}");
            }
        });
    }
}

async fn handle_conn(mut stream: TcpStream, state: Arc<DiagnosticState>) -> std::io::Result<()> {
    // Peek (don't consume) only to tell a WS upgrade apart from plain HTTP. A WS
    // request must be handed whole to the tungstenite handshake; plain HTTP is
    // read+consumed below. Consuming the full request before we close avoids a
    // TCP RST (which a reader would see as ConnectionReset instead of the reply).
    let mut buf = vec![0u8; MAX_HEAD_BYTES];
    let n = stream.peek(&mut buf).await?;
    let is_ws_stream = parse_head(&buf[..n])
        .is_some_and(|head| head.is_websocket() && head.path.starts_with(STREAM_PREFIX));

    if is_ws_stream {
        // Host/Origin + ticket are validated inside the handshake callback, which
        // consumes the request and replies gracefully on rejection.
        return handle_ws(stream, state).await;
    }

    // Plain HTTP: consume the whole request first, then enforce Host/Origin.
    let Some((head, body)) = read_request(&mut stream).await? else {
        return Ok(());
    };
    // Exactly one Host, and it must be literal loopback (anti-rebind + anti-
    // request-smuggling: a duplicate Host is ambiguous and rejected).
    if head.header_count("host") != 1
        || !head
            .header("host")
            .is_some_and(|h| host_header_allowed(h, state.port))
    {
        return write_http(&mut stream, 403, "text/plain", b"forbidden host").await;
    }
    if let Some(origin) = head.header("origin") {
        if !origin_allowed(origin, state.port) {
            return write_http(&mut stream, 403, "text/plain", b"forbidden origin").await;
        }
    }
    match (head.method.as_str(), head.path.as_str()) {
        ("GET", "/v1/status") => handle_status(&mut stream, &head, &state).await,
        ("POST", "/v1/ticket") => handle_ticket(&mut stream, &head, &body, &state).await,
        _ => write_http(&mut stream, 404, "text/plain", b"not found").await,
    }
}

// ─────────────────────────────── HTTP endpoints ──────────────────────────────

async fn handle_status(
    stream: &mut TcpStream,
    head: &Head,
    state: &DiagnosticState,
) -> std::io::Result<()> {
    let now = now_ms();
    match authenticate_http(head, &state.registry, now) {
        Ok(record) if record.scopes.contains(&Scope::StatusRead) => {
            let body = serde_json::to_vec(&serde_json::json!({
                "status": "ok",
                "protocol": PROTOCOL_VERSION,
                "client_id": record.client_id,
            }))
            .unwrap_or_default();
            write_http(stream, 200, "application/json", &body).await
        }
        Ok(record) => {
            audit(
                state,
                event(
                    now,
                    Some(record.client_id),
                    "status.read",
                    AuditDecision::Deny,
                    "missing_scope",
                ),
            );
            write_http(stream, 403, "text/plain", b"missing scope").await
        }
        Err(err) => {
            audit(
                state,
                event(now, None, "status.read", AuditDecision::Deny, err.code()),
            );
            write_http(stream, 401, "text/plain", b"unauthorized").await
        }
    }
}

#[derive(serde::Deserialize)]
struct TicketRequest {
    endpoint: String,
    scopes: Vec<String>,
}

async fn handle_ticket(
    stream: &mut TcpStream,
    head: &Head,
    body: &[u8],
    state: &DiagnosticState,
) -> std::io::Result<()> {
    let now = now_ms();
    let record = match authenticate_http(head, &state.registry, now) {
        Ok(record) => record,
        Err(err) => {
            audit(
                state,
                event(
                    now,
                    None,
                    "stream.ticket_issue",
                    AuditDecision::Deny,
                    err.code(),
                ),
            );
            return write_http(stream, 401, "text/plain", b"unauthorized").await;
        }
    };
    let Ok(req) = serde_json::from_slice::<TicketRequest>(body) else {
        return write_http(stream, 400, "text/plain", b"bad ticket request").await;
    };
    if !req.endpoint.starts_with(STREAM_PREFIX) {
        return write_http(stream, 400, "text/plain", b"endpoint not a stream").await;
    }
    // Parse requested scopes; unknown strings are denied (closed catalog).
    let mut scopes = Vec::with_capacity(req.scopes.len());
    for raw in &req.scopes {
        let Some(scope) = Scope::parse(raw) else {
            return write_http(stream, 400, "text/plain", b"unknown scope").await;
        };
        scopes.push(scope);
    }
    // No escalation: a ticket can only carry scopes the client already holds.
    if !scopes.iter().all(|scope| record.scopes.contains(scope)) {
        audit(
            state,
            event(
                now,
                Some(record.client_id),
                "stream.ticket_issue",
                AuditDecision::Deny,
                "scope_escalation",
            ),
        );
        return write_http(stream, 403, "text/plain", b"scope escalation").await;
    }

    // Acquire, issue, and DROP the lock entirely inside this non-async block —
    // a `std::sync::MutexGuard` must never be held across an `.await`.
    let issued = state
        .tickets
        .lock()
        .ok()
        .map(|mut store| store.issue(&record.client_id, &req.endpoint, scopes, now));

    match issued {
        Some(Ok(grant)) => {
            audit(
                state,
                event(
                    now,
                    Some(record.client_id),
                    "stream.ticket_issue",
                    AuditDecision::Allow,
                    "allow",
                ),
            );
            let body = serde_json::to_vec(&serde_json::json!({
                "ticket": grant.ticket,
                "expires_at_ms": grant.expires_at_ms,
                "subprotocols": [BASE_SUBPROTOCOL, format!("fae-ticket.{}", grant.ticket)],
            }))
            .unwrap_or_default();
            write_http(stream, 200, "application/json", &body).await
        }
        Some(Err(_)) => write_http(stream, 500, "text/plain", b"ticket issue failed").await,
        None => write_http(stream, 500, "text/plain", b"ticket store").await,
    }
}

// ──────────────────────────────── WebSocket ──────────────────────────────────

// The handshake callback's `Result<Response, ErrorResponse>` is dictated by the
// tungstenite `Callback` trait; `ErrorResponse` (http::Response) is large and we
// cannot box it without changing that external signature.
#[allow(clippy::result_large_err)]
async fn handle_ws(stream: TcpStream, state: Arc<DiagnosticState>) -> std::io::Result<()> {
    let now = now_ms();
    let port = state.port;
    let tickets = Arc::clone(&state.tickets);
    let mut consumed: Option<ConsumedTicket> = None;
    // The specific rejection reason, set inside the (sync) callback so the outer
    // async branch can audit it precisely — the callback can only hand back an
    // opaque ErrorResponse.
    let mut reject_reason: Option<&'static str> = None;

    // The handshake callback validates Host/Origin on the real request, consumes
    // the single-use ticket bound to the request path, and echoes only the base
    // subprotocol (never the secret ticket) on success.
    let callback = |req: &Request, mut resp: Response| -> Result<Response, ErrorResponse> {
        // Reject an ambiguous (duplicate) Host before trusting it — defends
        // against request-smuggling where a downstream hop picks a different one.
        if req.headers().get_all("host").iter().count() != 1 {
            reject_reason = Some("ambiguous_host");
            return Err(error_response(400, "ambiguous host"));
        }
        let host = req
            .headers()
            .get("host")
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default();
        if !host_header_allowed(host, port) {
            reject_reason = Some("forbidden_host");
            return Err(error_response(403, "forbidden host"));
        }
        // A present Origin must parse AND be loopback; a present-but-garbled
        // Origin is rejected, not silently skipped. A missing Origin is allowed
        // (non-browser clients don't send one).
        if let Some(origin_value) = req.headers().get("origin") {
            let allowed = origin_value
                .to_str()
                .is_ok_and(|origin| origin_allowed(origin, port));
            if !allowed {
                reject_reason = Some("forbidden_origin");
                return Err(error_response(403, "forbidden origin"));
            }
        }
        let endpoint = req.uri().path().to_owned();
        let offered = req
            .headers()
            .get("sec-websocket-protocol")
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default();
        let mut ticket: Option<String> = None;
        let mut has_base = false;
        for proto in offered.split(',') {
            let proto = proto.trim();
            if proto == BASE_SUBPROTOCOL {
                has_base = true;
            } else if let Some(token) = proto.strip_prefix("fae-ticket.") {
                ticket = Some(token.to_owned());
            }
        }
        let (Some(token), true) = (ticket, has_base) else {
            reject_reason = Some("missing_ticket");
            return Err(error_response(400, "missing base subprotocol or ticket"));
        };
        let outcome = match tickets.lock() {
            Ok(mut store) => store.consume(&token, &endpoint, now),
            Err(_) => {
                reject_reason = Some("ticket_store_unavailable");
                return Err(error_response(500, "ticket store unavailable"));
            }
        };
        match outcome {
            Ok(ticket) => {
                consumed = Some(ticket);
                resp.headers_mut().insert(
                    "sec-websocket-protocol",
                    HeaderValue::from_static(BASE_SUBPROTOCOL),
                );
                add_defensive_headers(resp.headers_mut());
                Ok(resp)
            }
            Err(err) => {
                reject_reason = Some(err.code());
                Err(error_response(401, err.code()))
            }
        }
    };

    let ws = match accept_hdr_async_with_config(stream, callback, Some(ws_config())).await {
        Ok(ws) => ws,
        Err(error) => {
            audit(
                &state,
                event(
                    now,
                    None,
                    "stream.ticket_consume",
                    AuditDecision::Deny,
                    reject_reason.unwrap_or("ticket_rejected"),
                ),
            );
            eprintln!("fae-daemon: diagnostic ws handshake refused: {error}");
            return Ok(());
        }
    };
    let Some(consumed) = consumed else {
        return Ok(());
    };
    let client_id = consumed.client_id.clone();
    let Some(session) = session_from_ticket(&state.registry, &consumed, now) else {
        audit(
            &state,
            event(
                now,
                Some(client_id),
                "stream.ticket_consume",
                AuditDecision::Error,
                "client_unavailable",
            ),
        );
        return Ok(());
    };
    audit(
        &state,
        event(
            now,
            Some(client_id),
            "stream.ticket_consume",
            AuditDecision::Allow,
            "allow",
        ),
    );
    ws_message_loop(
        ws,
        session,
        &state.registry,
        state.engine.as_ref(),
        state.tts.as_ref(),
        state.audio.as_ref(),
        &state.audit_path,
        &state.events,
        &state.playbacks,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn ws_message_loop(
    mut ws: WebSocketStream<TcpStream>,
    mut session: SessionState,
    registry: &ClientRegistry,
    engine: &dyn ProviderAdapter,
    tts: &dyn TtsAdapter,
    audio: &AudioManager,
    audit_path: &Path,
    events: &crate::events::EventBus,
    playbacks: &crate::events::PlaybackRegistry,
) -> std::io::Result<()> {
    while let Some(message) = ws.next().await {
        let text = match message {
            Ok(Message::Text(text)) => text,
            Ok(Message::Close(_)) | Err(_) => break,
            Ok(_) => continue, // ignore binary/ping/pong
        };
        let line = text.as_str().trim();
        if line.is_empty() {
            continue;
        }
        let now = now_ms();
        let event_id = next_event_id(now);
        let backends = SessionBackends {
            engine,
            tts,
            audio,
            events,
            playbacks,
        };
        let outcome = handle_frame(registry, &backends, &mut session, line, now, event_id).await;

        // Same fail-closed audit contract as the Unix socket: no response before
        // the frame is durably audited.
        if append_audit_jsonl(audit_path, &outcome.audit).is_err() {
            let err = CpResponse::error(
                &outcome.response.request_id,
                "audit_error",
                "audit write failed",
            );
            let _ = ws.send(Message::text(to_line(&err))).await;
            break;
        }
        if ws
            .send(Message::text(to_line(&outcome.response)))
            .await
            .is_err()
        {
            break;
        }
        if outcome.close {
            break;
        }
    }
    let _ = ws.close(None).await;
    Ok(())
}

// ──────────────────────────────── Helpers ────────────────────────────────────

fn authenticate_http(
    head: &Head,
    registry: &ClientRegistry,
    now_ms: u64,
) -> Result<ClientRecord, AuthError> {
    let client_id = head
        .header("x-fae-client-id")
        .ok_or(AuthError::UnknownClient)?;
    let auth = head.header("authorization").ok_or(AuthError::BadToken)?;
    let token = auth
        .strip_prefix("Bearer ")
        .or_else(|| auth.strip_prefix("bearer "))
        .ok_or(AuthError::BadToken)?;
    registry.authenticate(client_id, token, now_ms)
}

fn to_line(response: &CpResponse) -> String {
    serde_json::to_string(response).unwrap_or_else(|_| "{\"ok\":false}".to_owned())
}

fn event(
    now_ms: u64,
    client_id: Option<String>,
    command: &str,
    decision: AuditDecision,
    reason: &str,
) -> AuditEvent {
    AuditEvent {
        event_id: next_event_id(now_ms),
        ts_ms: now_ms,
        client_id,
        command: command.to_owned(),
        decision,
        reason: reason.to_owned(),
        scopes: Vec::new(),
        arg_hash: String::new(),
    }
}

fn audit(state: &DiagnosticState, ev: AuditEvent) {
    if let Err(error) = append_audit_jsonl(&state.audit_path, &ev) {
        eprintln!("fae-daemon: diagnostic audit write failed: {error}");
    }
}

fn error_response(status: u16, message: &str) -> ErrorResponse {
    let mut response = ErrorResponse::new(Some(message.to_owned()));
    *response.status_mut() = StatusCode::from_u16(status).unwrap_or(StatusCode::BAD_REQUEST);
    add_defensive_headers(response.headers_mut());
    response
}

/// Add the standard defensive headers (matching [`write_http`]) to a WS
/// handshake / error response so every browser-visible response carries them.
fn add_defensive_headers(headers: &mut HeaderMap) {
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("cache-control", HeaderValue::from_static("no-store"));
    headers.insert(
        "content-security-policy",
        HeaderValue::from_static(
            "default-src 'none'; connect-src 'self'; script-src 'self'; style-src 'self'",
        ),
    );
}

/// WebSocket config that caps message/frame size well below tungstenite's
/// multi-MiB default — control frames are tiny.
fn ws_config() -> WebSocketConfig {
    WebSocketConfig {
        max_message_size: Some(MAX_WS_MESSAGE_BYTES),
        max_frame_size: Some(MAX_WS_MESSAGE_BYTES),
        ..WebSocketConfig::default()
    }
}

async fn write_http(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        _ => "OK",
    };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         X-Content-Type-Options: nosniff\r\n\
         Cache-Control: no-store\r\n\
         Content-Security-Policy: default-src 'none'; connect-src 'self'; script-src 'self'; style-src 'self'\r\n\
         Connection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(body).await?;
    stream.flush().await
}

/// A parsed HTTP request head (request line + headers), keys lowercased.
struct Head {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
}

impl Head {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    }

    fn header_count(&self, name: &str) -> usize {
        self.headers.iter().filter(|(key, _)| key == name).count()
    }

    fn is_websocket(&self) -> bool {
        self.header("upgrade")
            .is_some_and(|u| u.to_ascii_lowercase().contains("websocket"))
            && self
                .header("connection")
                .is_some_and(|c| c.to_ascii_lowercase().contains("upgrade"))
    }
}

fn parse_head(bytes: &[u8]) -> Option<Head> {
    let text = std::str::from_utf8(bytes).ok()?;
    let end = text.find("\r\n\r\n")?;
    parse_head_text(&text[..end])
}

fn parse_head_text(head: &str) -> Option<Head> {
    let mut lines = head.split("\r\n");
    let mut request_line = lines.next()?.split(' ');
    let method = request_line.next()?.to_owned();
    let path = request_line.next()?.to_owned();
    let mut headers = Vec::new();
    for line in lines {
        if let Some((key, value)) = line.split_once(':') {
            headers.push((key.trim().to_ascii_lowercase(), value.trim().to_owned()));
        }
    }
    Some(Head {
        method,
        path,
        headers,
    })
}

/// Consume a full plain-HTTP request (head + Content-Length body) from the
/// stream. Returns `None` on a clean EOF before any bytes.
async fn read_request(stream: &mut TcpStream) -> std::io::Result<Option<(Head, Vec<u8>)>> {
    let mut reader = BufReader::new(stream);
    let mut head_text = String::new();
    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line).await?;
        if read == 0 {
            return Ok(None);
        }
        if line == "\r\n" || line == "\n" {
            break;
        }
        head_text.push_str(&line);
        if head_text.len() > MAX_HEAD_BYTES {
            return Ok(None);
        }
    }
    let head_trimmed = head_text.trim_end_matches(['\r', '\n']);
    let Some(head) = parse_head_text(head_trimmed) else {
        return Ok(None);
    };
    let len = head
        .header("content-length")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0)
        .min(MAX_BODY_BYTES);
    let mut body = vec![0u8; len];
    if len > 0 {
        reader.read_exact(&mut body).await?;
    }
    Ok(Some((head, body)))
}
