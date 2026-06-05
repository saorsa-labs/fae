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
