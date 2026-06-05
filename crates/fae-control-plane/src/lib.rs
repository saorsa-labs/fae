//! Fae daemon **control plane** — the local security boundary, as pure logic.
//!
//! This crate is intentionally **transport-free**: it has no sockets, no async,
//! no listeners. It is the authorization core that any future network surface
//! (Unix socket / TCP loopback in `fae-daemon`) MUST route through. Building it
//! first, fully tested, means a half-secure server cannot exist by accident.
//!
//! Implements the model in `docs/architecture/daemon-control-plane.md`:
//! per-client capability scopes, per-command authorization, anti-DNS-rebind
//! `Host` validation, CSPRNG session tokens (hashed at rest, constant-time
//! verify), and structured audit. Daemon-wide bearer auth is **not** sufficient
//! — every command is checked against the client's exact scope set.
#![forbid(unsafe_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

/// ADR-002 command/event protocol version (v2 = daemon era).
pub const PROTOCOL_VERSION: u16 = 2;

#[derive(Debug, thiserror::Error)]
pub enum ControlPlaneError {
    #[error("CSPRNG failure: {0}")]
    Csprng(#[from] getrandom::Error),
    #[error("audit write failed: {0}")]
    Audit(std::io::Error),
}

// ───────────────────────── Protocol envelope (ADR-002 v2) ─────────────────────

/// A control-plane command request. `command` is a dotted name (e.g.
/// `conversation.inject_text`); `payload` is command-specific.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Command {
    pub v: u16,
    pub request_id: String,
    pub command: String,
    #[serde(default)]
    pub payload: serde_json::Value,
}

impl Command {
    /// True if the envelope version is the one this daemon speaks.
    #[must_use]
    pub fn version_ok(&self) -> bool {
        self.v == PROTOCOL_VERSION
    }
}

/// The pre-auth frame a client sends first on a fresh connection. It is **not**
/// a scoped command — it establishes the session, so it never passes through
/// [`authorize`]. Carried in `Command.command == "session.authenticate"` with
/// this shape as the payload.
pub const AUTHENTICATE_COMMAND: &str = "session.authenticate";

/// A control-plane response (ADR-002 v2). `ok` distinguishes success from any
/// non-success (denied, needs-confirmation, error); `error.code` carries the
/// machine-readable reason. Secrets never appear here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Response {
    pub v: u16,
    pub request_id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ResponseError>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResponseError {
    pub code: String,
    pub message: String,
}

impl Response {
    #[must_use]
    pub fn ok(request_id: &str, result: serde_json::Value) -> Response {
        Response {
            v: PROTOCOL_VERSION,
            request_id: request_id.to_owned(),
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    #[must_use]
    pub fn error(request_id: &str, code: &str, message: &str) -> Response {
        Response {
            v: PROTOCOL_VERSION,
            request_id: request_id.to_owned(),
            ok: false,
            result: None,
            error: Some(ResponseError {
                code: code.to_owned(),
                message: message.to_owned(),
            }),
        }
    }
}

// ───────────────────────────────── Scopes ────────────────────────────────────

/// Closed capability catalog. Unknown scope strings never parse, so they are
/// implicitly denied. Wire form uses the `area:action` strings in the design.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Scope {
    StatusRead,
    ConversationWrite,
    ConversationRead,
    MemoryRead,
    MemoryWrite,
    ToolRead,
    ToolExecuteSafe,
    ToolExecuteDangerous,
    AudioCapture,
    AudioPlayback,
    SchedulerRead,
    SchedulerWrite,
    X0xMessage,
    X0xAdmin,
    Admin,
}

impl Scope {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Scope::StatusRead => "status:read",
            Scope::ConversationWrite => "conversation:write",
            Scope::ConversationRead => "conversation:read",
            Scope::MemoryRead => "memory:read",
            Scope::MemoryWrite => "memory:write",
            Scope::ToolRead => "tool:read",
            Scope::ToolExecuteSafe => "tool:execute:safe",
            Scope::ToolExecuteDangerous => "tool:execute:dangerous",
            Scope::AudioCapture => "audio:capture",
            Scope::AudioPlayback => "audio:playback",
            Scope::SchedulerRead => "scheduler:read",
            Scope::SchedulerWrite => "scheduler:write",
            Scope::X0xMessage => "x0x:message",
            Scope::X0xAdmin => "x0x:admin",
            Scope::Admin => "admin",
        }
    }

    /// Parse a wire scope string. Unknown strings return `None` (deny).
    #[must_use]
    pub fn parse(s: &str) -> Option<Scope> {
        let scope = match s {
            "status:read" => Scope::StatusRead,
            "conversation:write" => Scope::ConversationWrite,
            "conversation:read" => Scope::ConversationRead,
            "memory:read" => Scope::MemoryRead,
            "memory:write" => Scope::MemoryWrite,
            "tool:read" => Scope::ToolRead,
            "tool:execute:safe" => Scope::ToolExecuteSafe,
            "tool:execute:dangerous" => Scope::ToolExecuteDangerous,
            "audio:capture" => Scope::AudioCapture,
            "audio:playback" => Scope::AudioPlayback,
            "scheduler:read" => Scope::SchedulerRead,
            "scheduler:write" => Scope::SchedulerWrite,
            "x0x:message" => Scope::X0xMessage,
            "x0x:admin" => Scope::X0xAdmin,
            "admin" => Scope::Admin,
            _ => return None,
        };
        Some(scope)
    }
}

/// Required scopes for a known command. `None` = unknown command = deny.
/// `tool:execute:dangerous` additionally forces broker confirmation (see
/// [`authorize`]).
#[must_use]
pub fn required_scopes(command: &str) -> Option<&'static [Scope]> {
    let scopes: &'static [Scope] = match command {
        "host.ping" | "host.version" | "runtime.status" => &[Scope::StatusRead],
        "conversation.inject_text" => &[Scope::ConversationWrite],
        "conversation.subscribe" => &[Scope::ConversationRead],
        "audio.start_capture" | "audio.stop_capture" => &[Scope::AudioCapture],
        "audio.playback_control" => &[Scope::AudioPlayback],
        "memory.search" => &[Scope::MemoryRead],
        "memory.capture" => &[Scope::MemoryWrite],
        "tool.list" => &[Scope::ToolRead],
        "tool.execute_safe" => &[Scope::ToolExecuteSafe],
        "tool.execute_dangerous" => &[Scope::ToolExecuteDangerous],
        "scheduler.list" => &[Scope::SchedulerRead],
        "scheduler.mutate" => &[Scope::SchedulerWrite],
        "runtime.shutdown" | "runtime.emergency_lockout" => &[Scope::Admin],
        _ => return None,
    };
    Some(scopes)
}

// ─────────────────────────────── Client records ──────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClientClass {
    SwiftFrontend,
    CliDiagnostic,
    TestHarness,
    BrowserDiagnostic,
    X0xPeerBridge,
}

impl ClientClass {
    /// Conservative default scopes per the design. Anything more sensitive
    /// (audio capture, memory, tools) is granted explicitly during rollout, not
    /// by default.
    #[must_use]
    pub fn default_scopes(self) -> Vec<Scope> {
        match self {
            ClientClass::SwiftFrontend => {
                vec![
                    Scope::StatusRead,
                    Scope::ConversationWrite,
                    Scope::ConversationRead,
                    Scope::AudioPlayback,
                ]
            }
            ClientClass::CliDiagnostic | ClientClass::BrowserDiagnostic => vec![Scope::StatusRead],
            ClientClass::TestHarness => Vec::new(), // explicit scopes only; dev-mode gated
            ClientClass::X0xPeerBridge => Vec::new(), // requires G5 envelope gate + owner approval
        }
    }
}

#[derive(Debug, Clone)]
pub struct ClientRecord {
    pub client_id: String,
    pub class: ClientClass,
    pub scopes: HashSet<Scope>,
    pub issued_at_ms: u64,
    pub expires_at_ms: u64,
    pub revoked_at_ms: Option<u64>,
    pub display_name: String,
}

impl ClientRecord {
    #[must_use]
    pub fn is_active(&self, now_ms: u64) -> bool {
        self.revoked_at_ms.is_none() && now_ms < self.expires_at_ms
    }
}

// ──────────────────────────────── Authorization ──────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthzDecision {
    Allow,
    /// Authorized, but a dangerous/destructive action requires the broker to
    /// obtain explicit owner confirmation before any side effect.
    ConfirmRequired,
    Deny(DenyReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DenyReason {
    ClientRevoked,
    TokenExpired,
    UnknownCommand,
    MissingScope,
    WrongProtocolVersion,
}

impl DenyReason {
    #[must_use]
    pub fn code(self) -> &'static str {
        match self {
            DenyReason::ClientRevoked => "client_revoked",
            DenyReason::TokenExpired => "token_expired",
            DenyReason::UnknownCommand => "unknown_command",
            DenyReason::MissingScope => "missing_scope",
            DenyReason::WrongProtocolVersion => "wrong_protocol_version",
        }
    }
}

/// The single chokepoint. Decide whether `client` may run `command` at `now_ms`.
/// Checks, in order: protocol version, revocation, expiry, command-known,
/// scope-held, then dangerous→confirm. Unknown command and any missing scope are
/// denied. Pure function — supply `now_ms` from the daemon clock.
#[must_use]
pub fn authorize(client: &ClientRecord, cmd: &Command, now_ms: u64) -> AuthzDecision {
    if !cmd.version_ok() {
        return AuthzDecision::Deny(DenyReason::WrongProtocolVersion);
    }
    if client.revoked_at_ms.is_some() {
        return AuthzDecision::Deny(DenyReason::ClientRevoked);
    }
    if now_ms >= client.expires_at_ms {
        return AuthzDecision::Deny(DenyReason::TokenExpired);
    }
    let Some(required) = required_scopes(&cmd.command) else {
        return AuthzDecision::Deny(DenyReason::UnknownCommand);
    };
    if !required.iter().all(|scope| client.scopes.contains(scope)) {
        return AuthzDecision::Deny(DenyReason::MissingScope);
    }
    if required.contains(&Scope::ToolExecuteDangerous) {
        return AuthzDecision::ConfirmRequired;
    }
    AuthzDecision::Allow
}

// ──────────────────────── Host validation (anti-DNS-rebind) ───────────────────

/// Accept only literal loopback `Host` headers for any TCP diagnostic listener.
/// `localhost`, LAN/private hostnames, and mDNS names are rejected **even if
/// they resolve to loopback** — this is the DNS-rebinding defense.
#[must_use]
pub fn host_header_allowed(host: &str, port: u16) -> bool {
    host == format!("127.0.0.1:{port}") || host == format!("[::1]:{port}")
}

/// Browser Origin allowlist for the diagnostic UI only (literal loopback).
#[must_use]
pub fn origin_allowed(origin: &str, port: u16) -> bool {
    origin == format!("http://127.0.0.1:{port}") || origin == format!("http://[::1]:{port}")
}

// ───────────────────────────────── Tokens ────────────────────────────────────

/// SHA-256 of a session token, stored at rest. The raw token is never persisted
/// or logged. Verification is constant-time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenHash([u8; 32]);

impl TokenHash {
    #[must_use]
    pub fn to_hex(&self) -> String {
        hex::encode(self.0)
    }
}

/// Generate a fresh 256-bit session token (hex) from the OS CSPRNG.
pub fn generate_token() -> Result<String, ControlPlaneError> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes)?;
    Ok(hex::encode(bytes))
}

/// Hash a token for at-rest storage.
#[must_use]
pub fn hash_token(token: &str) -> TokenHash {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(token.as_bytes());
    let mut out = [0u8; 32];
    out.copy_from_slice(&digest);
    TokenHash(out)
}

/// Constant-time check of a presented token against a stored hash.
#[must_use]
pub fn verify_token(presented: &str, stored: &TokenHash) -> bool {
    use subtle::ConstantTimeEq;
    let candidate = hash_token(presented);
    let lhs: &[u8] = &candidate.0;
    let rhs: &[u8] = &stored.0;
    lhs.ct_eq(rhs).into()
}

// ───────────────────────────────── Audit ─────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditDecision {
    Allow,
    Deny,
    ConfirmRequired,
    Error,
}

/// One audit row. Minimum fields per the design; never holds raw secrets — only
/// a redacted argument hash.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AuditEvent {
    pub event_id: String,
    pub ts_ms: u64,
    pub client_id: Option<String>,
    pub command: String,
    pub decision: AuditDecision,
    pub reason: String,
    pub scopes: Vec<String>,
    pub arg_hash: String,
}

impl AuditEvent {
    /// Build an audit row from an authorization decision.
    #[must_use]
    pub fn from_authz(
        event_id: String,
        ts_ms: u64,
        client_id: Option<String>,
        cmd: &Command,
        decision: &AuthzDecision,
    ) -> AuditEvent {
        let (audit_decision, reason) = match decision {
            AuthzDecision::Allow => (AuditDecision::Allow, "allow".to_owned()),
            AuthzDecision::ConfirmRequired => (
                AuditDecision::ConfirmRequired,
                "confirm_required".to_owned(),
            ),
            AuthzDecision::Deny(reason) => (AuditDecision::Deny, reason.code().to_owned()),
        };
        let scopes = required_scopes(&cmd.command)
            .unwrap_or(&[])
            .iter()
            .map(|scope| scope.as_str().to_owned())
            .collect();
        AuditEvent {
            event_id,
            ts_ms,
            client_id,
            command: cmd.command.clone(),
            decision: audit_decision,
            reason,
            scopes,
            arg_hash: hash_token(&cmd.payload.to_string()).to_hex(),
        }
    }

    /// Build an audit row for an authentication attempt. The auth payload holds
    /// the presented token, so it is **never** hashed into `arg_hash` (a digest
    /// of a known-format token is needlessly brute-checkable). `arg_hash` is
    /// empty for auth rows.
    #[must_use]
    pub fn authentication(
        event_id: String,
        ts_ms: u64,
        client_id: Option<String>,
        decision: AuditDecision,
        reason: &str,
    ) -> AuditEvent {
        AuditEvent {
            event_id,
            ts_ms,
            client_id,
            command: AUTHENTICATE_COMMAND.to_owned(),
            decision,
            reason: reason.to_owned(),
            scopes: Vec::new(),
            arg_hash: String::new(),
        }
    }
}

/// Append one audit row as JSON Lines. Fail-closed: a write error is surfaced so
/// callers can reject the action rather than proceed unaudited.
pub fn append_audit_jsonl(
    path: &std::path::Path,
    event: &AuditEvent,
) -> Result<(), ControlPlaneError> {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(ControlPlaneError::Audit)?;
    let line = serde_json::to_string(event).map_err(|error| {
        ControlPlaneError::Audit(std::io::Error::new(std::io::ErrorKind::InvalidData, error))
    })?;
    file.write_all(line.as_bytes())
        .map_err(ControlPlaneError::Audit)?;
    file.write_all(b"\n").map_err(ControlPlaneError::Audit)?;
    Ok(())
}

// ─────────────────────────── Client registry / auth ──────────────────────────

/// Why an authentication attempt was refused. Maps to an audit reason code; the
/// wire error message is deliberately coarse so it does not leak which factor
/// failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthError {
    UnknownClient,
    BadToken,
    Revoked,
    Expired,
}

impl AuthError {
    #[must_use]
    pub fn code(self) -> &'static str {
        match self {
            AuthError::UnknownClient => "unknown_client",
            AuthError::BadToken => "bad_token",
            AuthError::Revoked => "client_revoked",
            AuthError::Expired => "token_expired",
        }
    }
}

struct RegisteredClient {
    record: ClientRecord,
    token_hash: TokenHash,
}

/// In-memory registry of sessions the daemon trusts. Pure logic — no I/O. The
/// transport shell looks a client up by id, verifies the presented token in
/// constant time, and gets back the exact [`ClientRecord`] (scopes) to run
/// [`authorize`] against per message.
#[derive(Default)]
pub struct ClientRegistry {
    clients: std::collections::HashMap<String, RegisteredClient>,
}

impl ClientRegistry {
    #[must_use]
    pub fn new() -> ClientRegistry {
        ClientRegistry {
            clients: std::collections::HashMap::new(),
        }
    }

    /// Register (or replace) a client and the at-rest hash of its session token.
    pub fn insert(&mut self, record: ClientRecord, token_hash: TokenHash) {
        self.clients.insert(
            record.client_id.clone(),
            RegisteredClient { record, token_hash },
        );
    }

    /// Authenticate a presented token for `client_id`. Constant-time token
    /// comparison; returns the live record only if the token matches and the
    /// record is neither revoked nor expired. Returns a clone so the caller owns
    /// the session's scope set without holding a borrow on the registry.
    pub fn authenticate(
        &self,
        client_id: &str,
        presented_token: &str,
        now_ms: u64,
    ) -> Result<ClientRecord, AuthError> {
        let entry = self
            .clients
            .get(client_id)
            .ok_or(AuthError::UnknownClient)?;
        if !verify_token(presented_token, &entry.token_hash) {
            return Err(AuthError::BadToken);
        }
        if entry.record.revoked_at_ms.is_some() {
            return Err(AuthError::Revoked);
        }
        if now_ms >= entry.record.expires_at_ms {
            return Err(AuthError::Expired);
        }
        Ok(entry.record.clone())
    }

    /// Mark a client revoked (emergency lockout / security event). Idempotent.
    pub fn revoke(&mut self, client_id: &str, now_ms: u64) {
        if let Some(entry) = self.clients.get_mut(client_id) {
            entry.record.revoked_at_ms.get_or_insert(now_ms);
        }
    }

    /// Look up a client's live record by id, without a token check. Used to
    /// rebuild a session after a stream ticket has already authenticated the
    /// client — the caller still runs per-message [`authorize`], so live
    /// revocation/expiry are re-checked there.
    #[must_use]
    pub fn record(&self, client_id: &str) -> Option<ClientRecord> {
        self.clients
            .get(client_id)
            .map(|entry| entry.record.clone())
    }
}

// ───────────────────────────── Stream tickets ────────────────────────────────

/// Maximum lifetime of a WS/SSE stream ticket. The control-plane design caps
/// this at 60 s and requires single use; [`TicketStore`] enforces both.
pub const STREAM_TICKET_TTL_MS: u64 = 60_000;

/// What a client receives when it requests a stream ticket: the opaque token to
/// present (via `Sec-WebSocket-Protocol`, never a `?token=` query) and when it
/// expires. The token is 256-bit CSPRNG and subsumes the design's id+nonce — it
/// is never stored raw (the store keeps only its hash).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamTicketGrant {
    pub ticket: String,
    pub expires_at_ms: u64,
}

/// Session facts unlocked by consuming a valid ticket: which client, which
/// endpoint it was bound to, and the exact scopes granted for the stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConsumedTicket {
    pub client_id: String,
    pub endpoint: String,
    pub scopes: Vec<Scope>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TicketError {
    /// Never issued, already consumed (single-use), or wrong token.
    Unknown,
    Expired,
    WrongEndpoint,
}

impl TicketError {
    #[must_use]
    pub fn code(self) -> &'static str {
        match self {
            TicketError::Unknown => "unknown_ticket",
            TicketError::Expired => "ticket_expired",
            TicketError::WrongEndpoint => "ticket_wrong_endpoint",
        }
    }
}

struct TicketRecord {
    client_id: String,
    endpoint: String,
    scopes: Vec<Scope>,
    expires_at_ms: u64,
}

/// In-memory single-use stream-ticket replay cache. Pure logic — wrap in a mutex
/// for concurrent use. Tickets are keyed by the hash of the opaque token, so the
/// raw token is never retained after issue.
#[derive(Default)]
pub struct TicketStore {
    by_hash: std::collections::HashMap<String, TicketRecord>,
}

impl TicketStore {
    #[must_use]
    pub fn new() -> TicketStore {
        TicketStore {
            by_hash: std::collections::HashMap::new(),
        }
    }

    /// Issue a fresh single-use ticket bound to a client, endpoint, and scope
    /// set, expiring in [`STREAM_TICKET_TTL_MS`]. GCs expired entries first.
    pub fn issue(
        &mut self,
        client_id: &str,
        endpoint: &str,
        scopes: Vec<Scope>,
        now_ms: u64,
    ) -> Result<StreamTicketGrant, ControlPlaneError> {
        self.gc(now_ms);
        let ticket = generate_token()?;
        let expires_at_ms = now_ms.saturating_add(STREAM_TICKET_TTL_MS);
        self.by_hash.insert(
            hash_token(&ticket).to_hex(),
            TicketRecord {
                client_id: client_id.to_owned(),
                endpoint: endpoint.to_owned(),
                scopes,
                expires_at_ms,
            },
        );
        Ok(StreamTicketGrant {
            ticket,
            expires_at_ms,
        })
    }

    /// Atomically consume a presented ticket for `endpoint`. Single-use: the
    /// record is removed whether or not it validates, so a replay always fails
    /// as `Unknown`. Returns the unlocked session facts on success.
    pub fn consume(
        &mut self,
        presented_ticket: &str,
        endpoint: &str,
        now_ms: u64,
    ) -> Result<ConsumedTicket, TicketError> {
        let key = hash_token(presented_ticket).to_hex();
        let record = self.by_hash.remove(&key).ok_or(TicketError::Unknown)?;
        if now_ms >= record.expires_at_ms {
            return Err(TicketError::Expired);
        }
        if record.endpoint != endpoint {
            return Err(TicketError::WrongEndpoint);
        }
        Ok(ConsumedTicket {
            client_id: record.client_id,
            endpoint: record.endpoint,
            scopes: record.scopes,
        })
    }

    /// Drop expired tickets. Called opportunistically by [`issue`]; can also be
    /// driven by a timer.
    pub fn gc(&mut self, now_ms: u64) {
        self.by_hash
            .retain(|_, record| now_ms < record.expires_at_ms);
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.by_hash.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.by_hash.is_empty()
    }
}

// ───────────────────────────────── Tests ─────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(name: &str) -> Command {
        Command {
            v: PROTOCOL_VERSION,
            request_id: "r1".to_owned(),
            command: name.to_owned(),
            payload: serde_json::Value::Null,
        }
    }

    fn client(scopes: &[Scope], expires_at_ms: u64, revoked: Option<u64>) -> ClientRecord {
        ClientRecord {
            client_id: "c1".to_owned(),
            class: ClientClass::SwiftFrontend,
            scopes: scopes.iter().copied().collect(),
            issued_at_ms: 0,
            expires_at_ms,
            revoked_at_ms: revoked,
            display_name: "test".to_owned(),
        }
    }

    #[test]
    fn allows_when_scope_held_and_active() {
        let c = client(&[Scope::ConversationWrite], 1000, None);
        assert_eq!(
            authorize(&c, &cmd("conversation.inject_text"), 10),
            AuthzDecision::Allow
        );
    }

    #[test]
    fn denies_missing_scope() {
        let c = client(&[Scope::StatusRead], 1000, None);
        assert_eq!(
            authorize(&c, &cmd("conversation.inject_text"), 10),
            AuthzDecision::Deny(DenyReason::MissingScope)
        );
    }

    #[test]
    fn denies_unknown_command() {
        let c = client(&[Scope::Admin], 1000, None);
        assert_eq!(
            authorize(&c, &cmd("totally.unknown"), 10),
            AuthzDecision::Deny(DenyReason::UnknownCommand)
        );
    }

    #[test]
    fn denies_expired_and_revoked() {
        let expired = client(&[Scope::StatusRead], 5, None);
        assert_eq!(
            authorize(&expired, &cmd("host.ping"), 10),
            AuthzDecision::Deny(DenyReason::TokenExpired)
        );
        let revoked = client(&[Scope::StatusRead], 1000, Some(1));
        assert_eq!(
            authorize(&revoked, &cmd("host.ping"), 10),
            AuthzDecision::Deny(DenyReason::ClientRevoked)
        );
    }

    #[test]
    fn denies_wrong_protocol_version() {
        let c = client(&[Scope::StatusRead], 1000, None);
        let mut bad = cmd("host.ping");
        bad.v = 99;
        assert_eq!(
            authorize(&c, &bad, 10),
            AuthzDecision::Deny(DenyReason::WrongProtocolVersion)
        );
    }

    #[test]
    fn dangerous_tool_requires_confirmation_even_with_scope() {
        let c = client(&[Scope::ToolExecuteDangerous], 1000, None);
        assert_eq!(
            authorize(&c, &cmd("tool.execute_dangerous"), 10),
            AuthzDecision::ConfirmRequired
        );
    }

    #[test]
    fn host_validation_rejects_rebind_and_lan() {
        assert!(host_header_allowed("127.0.0.1:12700", 12700));
        assert!(host_header_allowed("[::1]:12700", 12700));
        assert!(!host_header_allowed("localhost:12700", 12700)); // DNS-rebind vector
        assert!(!host_header_allowed("192.168.1.10:12700", 12700));
        assert!(!host_header_allowed("fae.local:12700", 12700)); // mDNS
        assert!(!host_header_allowed("127.0.0.1:1", 12700)); // wrong port
    }

    #[test]
    fn every_scope_roundtrips_through_as_str_and_parse() {
        // Guards the two parallel match tables (`as_str` / `parse`) against
        // drift: a variant added to one but not the other fails here.
        let all = [
            Scope::StatusRead,
            Scope::ConversationWrite,
            Scope::ConversationRead,
            Scope::MemoryRead,
            Scope::MemoryWrite,
            Scope::ToolRead,
            Scope::ToolExecuteSafe,
            Scope::ToolExecuteDangerous,
            Scope::AudioCapture,
            Scope::AudioPlayback,
            Scope::SchedulerRead,
            Scope::SchedulerWrite,
            Scope::X0xMessage,
            Scope::X0xAdmin,
            Scope::Admin,
        ];
        for scope in all {
            assert_eq!(
                Scope::parse(scope.as_str()),
                Some(scope),
                "round-trip failed for {scope:?}"
            );
        }
    }

    #[test]
    fn unknown_scope_strings_do_not_parse() {
        assert_eq!(Scope::parse("status:read"), Some(Scope::StatusRead));
        assert_eq!(
            Scope::parse("tool:execute:dangerous"),
            Some(Scope::ToolExecuteDangerous)
        );
        assert_eq!(Scope::parse("root:everything"), None);
    }

    #[test]
    fn token_roundtrip_and_constant_time_verify() -> Result<(), ControlPlaneError> {
        let token = generate_token()?;
        assert_eq!(token.len(), 64); // 32 bytes hex
        let stored = hash_token(&token);
        assert!(verify_token(&token, &stored));
        assert!(!verify_token("not-the-token", &stored));
        Ok(())
    }

    #[test]
    fn audit_row_serializes_and_redacts_payload() -> Result<(), Box<dyn std::error::Error>> {
        let c = cmd("conversation.inject_text");
        let decision = AuthzDecision::Allow;
        let ev = AuditEvent::from_authz("e1".to_owned(), 42, Some("c1".to_owned()), &c, &decision);
        let json = serde_json::to_string(&ev)?;
        assert!(json.contains("\"decision\":\"allow\""));
        assert!(json.contains("\"command\":\"conversation.inject_text\""));
        assert!(json.contains("arg_hash"));
        Ok(())
    }

    fn registry_with_bootstrap(
        token: &str,
        expires_at_ms: u64,
        revoked: Option<u64>,
    ) -> ClientRegistry {
        let mut registry = ClientRegistry::new();
        registry.insert(
            client(&[Scope::ConversationWrite], expires_at_ms, revoked),
            hash_token(token),
        );
        registry
    }

    #[test]
    fn registry_authenticates_valid_token() -> Result<(), AuthError> {
        let registry = registry_with_bootstrap("s3cret-token", 1000, None);
        let record = registry.authenticate("c1", "s3cret-token", 10)?;
        assert!(record.scopes.contains(&Scope::ConversationWrite));
        Ok(())
    }

    #[test]
    fn registry_rejects_bad_token_unknown_expired_revoked() {
        let registry = registry_with_bootstrap("s3cret-token", 1000, None);
        assert!(matches!(
            registry.authenticate("c1", "wrong", 10),
            Err(AuthError::BadToken)
        ));
        assert!(matches!(
            registry.authenticate("nope", "s3cret-token", 10),
            Err(AuthError::UnknownClient)
        ));

        let expired = registry_with_bootstrap("s3cret-token", 5, None);
        assert!(matches!(
            expired.authenticate("c1", "s3cret-token", 10),
            Err(AuthError::Expired)
        ));

        let revoked = registry_with_bootstrap("s3cret-token", 1000, Some(1));
        assert!(matches!(
            revoked.authenticate("c1", "s3cret-token", 10),
            Err(AuthError::Revoked)
        ));
    }

    #[test]
    fn revoke_blocks_subsequent_auth() {
        let mut registry = registry_with_bootstrap("s3cret-token", 1000, None);
        assert!(registry.authenticate("c1", "s3cret-token", 10).is_ok());
        registry.revoke("c1", 11);
        assert!(matches!(
            registry.authenticate("c1", "s3cret-token", 12),
            Err(AuthError::Revoked)
        ));
    }

    #[test]
    fn response_serializes_without_secret_fields() -> Result<(), serde_json::Error> {
        let ok = Response::ok("r1", serde_json::json!({ "pong": true }));
        let json = serde_json::to_string(&ok)?;
        assert!(json.contains("\"ok\":true"));
        assert!(json.contains("\"pong\":true"));
        assert!(!json.contains("error"));

        let err = Response::error("r2", "missing_scope", "needs conversation:write");
        let json = serde_json::to_string(&err)?;
        assert!(json.contains("\"ok\":false"));
        assert!(json.contains("missing_scope"));
        assert!(!json.contains("result"));
        Ok(())
    }

    #[test]
    fn ticket_issue_then_consume_unlocks_scopes() -> Result<(), Box<dyn std::error::Error>> {
        let mut store = TicketStore::new();
        let grant = store.issue(
            "c1",
            "/v1/stream/conversation",
            vec![Scope::ConversationRead],
            100,
        )?;
        assert_eq!(store.len(), 1);
        let consumed = store
            .consume(&grant.ticket, "/v1/stream/conversation", 200)
            .map_err(|e| e.code())?;
        assert_eq!(consumed.client_id, "c1");
        assert_eq!(consumed.scopes, vec![Scope::ConversationRead]);
        assert!(store.is_empty()); // consumed
        Ok(())
    }

    #[test]
    fn ticket_is_single_use() -> Result<(), ControlPlaneError> {
        let mut store = TicketStore::new();
        let grant = store.issue("c1", "/v1/stream/x", vec![], 100)?;
        assert!(store.consume(&grant.ticket, "/v1/stream/x", 200).is_ok());
        // Replay of the same token must now fail as Unknown.
        assert!(matches!(
            store.consume(&grant.ticket, "/v1/stream/x", 201),
            Err(TicketError::Unknown)
        ));
        Ok(())
    }

    #[test]
    fn ticket_rejects_expired_wrong_endpoint_and_unknown() -> Result<(), ControlPlaneError> {
        let mut store = TicketStore::new();
        let grant = store.issue("c1", "/v1/stream/x", vec![], 100)?;
        // Expired: now beyond issue + TTL.
        assert!(matches!(
            store.consume(&grant.ticket, "/v1/stream/x", 100 + STREAM_TICKET_TTL_MS),
            Err(TicketError::Expired)
        ));

        let grant = store.issue("c1", "/v1/stream/x", vec![], 100)?;
        assert!(matches!(
            store.consume(&grant.ticket, "/v1/stream/other", 200),
            Err(TicketError::WrongEndpoint)
        ));

        assert!(matches!(
            store.consume("never-issued", "/v1/stream/x", 200),
            Err(TicketError::Unknown)
        ));
        Ok(())
    }

    #[test]
    fn ticket_gc_drops_expired() -> Result<(), ControlPlaneError> {
        let mut store = TicketStore::new();
        store.issue("c1", "/v1/stream/x", vec![], 100)?;
        assert_eq!(store.len(), 1);
        store.gc(100 + STREAM_TICKET_TTL_MS);
        assert!(store.is_empty());
        Ok(())
    }

    #[test]
    fn registry_record_lookup_by_id() {
        let mut registry = ClientRegistry::new();
        registry.insert(client(&[Scope::StatusRead], 1000, None), hash_token("tok"));
        assert!(registry.record("c1").is_some());
        assert!(registry.record("absent").is_none());
    }

    #[test]
    fn default_scopes_are_conservative() {
        assert!(ClientClass::X0xPeerBridge.default_scopes().is_empty());
        assert!(!ClientClass::SwiftFrontend
            .default_scopes()
            .contains(&Scope::AudioCapture));
        assert!(ClientClass::SwiftFrontend
            .default_scopes()
            .contains(&Scope::ConversationWrite));
    }
}
