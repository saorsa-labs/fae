//! Per-connection session logic — **pure**, no sockets.
//!
//! The transport shell ([`crate::transport`]) reads one NDJSON frame, calls
//! [`handle_frame`], persists the returned audit row, writes the response, and
//! optionally closes. All authentication + authorization + dispatch decisions
//! live here so the whole frame lifecycle is unit-testable without a socket —
//! the same control-plane-first discipline the workspace was built on.

use fae_control_plane::{
    authorize, AuditDecision, AuditEvent, AuthzDecision, ClientRecord, ClientRegistry, Command,
    Response, AUTHENTICATE_COMMAND, PROTOCOL_VERSION,
};
use serde::Deserialize;

/// Daemon version surfaced by `host.version`.
const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");

/// State carried across frames on a single connection.
pub enum SessionState {
    Unauthenticated,
    Authenticated(ClientRecord),
}

/// The `session.authenticate` payload.
#[derive(Deserialize)]
struct AuthPayload {
    client_id: String,
    token: String,
}

/// Result of handling one frame: what to write back, what to audit, and whether
/// the connection should be closed afterwards.
pub struct FrameOutcome {
    pub response: Response,
    pub audit: AuditEvent,
    pub close: bool,
}

/// Handle one decoded NDJSON line. `event_id` is supplied by the caller (a
/// monotonic, non-secret id) so this function stays pure. `now_ms` is the
/// per-frame wall clock — never a stale snapshot.
#[must_use]
pub fn handle_frame(
    registry: &ClientRegistry,
    state: &mut SessionState,
    line: &str,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    let cmd: Command = match serde_json::from_str(line) {
        Ok(cmd) => cmd,
        Err(_) => {
            // request_id is unrecoverable from a malformed frame.
            return FrameOutcome {
                response: Response::error("unknown", "bad_request", "malformed command frame"),
                audit: manual_audit(
                    event_id,
                    now_ms,
                    None,
                    "<malformed>",
                    AuditDecision::Error,
                    "bad_request",
                ),
                close: true,
            };
        }
    };

    match state {
        SessionState::Unauthenticated => handle_auth(registry, state, &cmd, now_ms, event_id),
        SessionState::Authenticated(record) => {
            // Clone the record out so we no longer borrow `state`; the session
            // is already established and never mutated by a command frame.
            let record = record.clone();
            handle_command(&record, &cmd, now_ms, event_id)
        }
    }
}

fn handle_auth(
    registry: &ClientRegistry,
    state: &mut SessionState,
    cmd: &Command,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    if cmd.command != AUTHENTICATE_COMMAND {
        // A command before authentication — refuse, but keep the connection so
        // the client can authenticate and retry.
        return FrameOutcome {
            response: Response::error(
                &cmd.request_id,
                "not_authenticated",
                "authenticate before issuing commands",
            ),
            audit: manual_audit(
                event_id,
                now_ms,
                None,
                &cmd.command,
                AuditDecision::Deny,
                "not_authenticated",
            ),
            close: false,
        };
    }
    if !cmd.version_ok() {
        return FrameOutcome {
            response: Response::error(
                &cmd.request_id,
                "wrong_protocol_version",
                "unsupported protocol version",
            ),
            audit: AuditEvent::authentication(
                event_id,
                now_ms,
                None,
                AuditDecision::Error,
                "wrong_protocol_version",
            ),
            close: true,
        };
    }
    let payload: AuthPayload = match serde_json::from_value(cmd.payload.clone()) {
        Ok(payload) => payload,
        Err(_) => {
            return FrameOutcome {
                response: Response::error(
                    &cmd.request_id,
                    "bad_request",
                    "malformed authenticate payload",
                ),
                audit: AuditEvent::authentication(
                    event_id,
                    now_ms,
                    None,
                    AuditDecision::Error,
                    "bad_request",
                ),
                close: true,
            };
        }
    };

    match registry.authenticate(&payload.client_id, &payload.token, now_ms) {
        Ok(record) => {
            let client_id = record.client_id.clone();
            *state = SessionState::Authenticated(record);
            FrameOutcome {
                response: Response::ok(
                    &cmd.request_id,
                    serde_json::json!({ "authenticated": true, "client_id": client_id }),
                ),
                audit: AuditEvent::authentication(
                    event_id,
                    now_ms,
                    Some(client_id),
                    AuditDecision::Allow,
                    "allow",
                ),
                close: false,
            }
        }
        Err(err) => FrameOutcome {
            // Coarse wire message; the precise factor stays in the audit only.
            response: Response::error(&cmd.request_id, err.code(), "authentication failed"),
            audit: AuditEvent::authentication(
                event_id,
                now_ms,
                Some(payload.client_id),
                AuditDecision::Deny,
                err.code(),
            ),
            // Close on failed auth — a new attempt needs a fresh connection.
            close: true,
        },
    }
}

fn handle_command(
    record: &ClientRecord,
    cmd: &Command,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    if cmd.command == AUTHENTICATE_COMMAND {
        return FrameOutcome {
            response: Response::error(
                &cmd.request_id,
                "already_authenticated",
                "session already authenticated",
            ),
            audit: manual_audit(
                event_id,
                now_ms,
                Some(record.client_id.clone()),
                &cmd.command,
                AuditDecision::Error,
                "already_authenticated",
            ),
            close: false,
        };
    }

    let decision = authorize(record, cmd, now_ms);
    let audit = AuditEvent::from_authz(
        event_id,
        now_ms,
        Some(record.client_id.clone()),
        cmd,
        &decision,
    );
    let response = match &decision {
        // `dispatch` is side-effect-free in this chunk (reads only), and the
        // shell persists `audit` before writing this response, so nothing is
        // observable pre-audit. When mutating commands land, their side effect
        // MUST move behind the audit write in the shell.
        AuthzDecision::Allow => match dispatch(cmd) {
            Ok(result) => Response::ok(&cmd.request_id, result),
            Err(code) => Response::error(&cmd.request_id, code, "command not yet implemented"),
        },
        AuthzDecision::ConfirmRequired => Response::error(
            &cmd.request_id,
            "confirm_required",
            "owner confirmation required for this action",
        ),
        AuthzDecision::Deny(reason) => {
            Response::error(&cmd.request_id, reason.code(), "authorization denied")
        }
    };
    FrameOutcome {
        response,
        audit,
        close: false,
    }
}

/// Command dispatch. Chunk 2a wires only the read-only `host`/`runtime` status
/// commands; everything else is authorized-but-unimplemented (fail loud, not a
/// silent success) until the relevant subsystem is ported.
fn dispatch(cmd: &Command) -> Result<serde_json::Value, &'static str> {
    match cmd.command.as_str() {
        "host.ping" => Ok(serde_json::json!({ "pong": true })),
        "host.version" => {
            Ok(serde_json::json!({ "version": DAEMON_VERSION, "protocol": PROTOCOL_VERSION }))
        }
        "runtime.status" => Ok(serde_json::json!({ "status": "ok", "engine": "not_loaded" })),
        _ => Err("not_implemented"),
    }
}

/// An audit row for a non-authz, non-authenticate event (parse failure, command
/// before auth). Never hashes a payload — `arg_hash` is empty.
fn manual_audit(
    event_id: String,
    now_ms: u64,
    client_id: Option<String>,
    command: &str,
    decision: AuditDecision,
    reason: &str,
) -> AuditEvent {
    AuditEvent {
        event_id,
        ts_ms: now_ms,
        client_id,
        command: command.to_owned(),
        decision,
        reason: reason.to_owned(),
        scopes: Vec::new(),
        arg_hash: String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fae_control_plane::{hash_token, ClientClass, Scope};
    use std::collections::HashSet;

    fn registry() -> ClientRegistry {
        let mut registry = ClientRegistry::new();
        let scopes: HashSet<Scope> = [Scope::StatusRead, Scope::ConversationWrite]
            .into_iter()
            .collect();
        registry.insert(
            ClientRecord {
                client_id: "c1".to_owned(),
                class: ClientClass::SwiftFrontend,
                scopes,
                issued_at_ms: 0,
                expires_at_ms: 1_000,
                revoked_at_ms: None,
                display_name: "test".to_owned(),
            },
            hash_token("good-token"),
        );
        registry
    }

    fn frame(command: &str, payload: serde_json::Value) -> String {
        serde_json::to_string(&serde_json::json!({
            "v": PROTOCOL_VERSION,
            "request_id": "r1",
            "command": command,
            "payload": payload,
        }))
        .expect("frame json")
    }

    fn auth_frame(client_id: &str, token: &str) -> String {
        frame(
            AUTHENTICATE_COMMAND,
            serde_json::json!({ "client_id": client_id, "token": token }),
        )
    }

    #[test]
    fn command_before_auth_is_refused_but_connection_kept() {
        let reg = registry();
        let mut state = SessionState::Unauthenticated;
        let out = handle_frame(
            &reg,
            &mut state,
            &frame("host.ping", serde_json::Value::Null),
            10,
            "e1".to_owned(),
        );
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("not_authenticated")
        );
        assert!(!out.close);
        assert!(matches!(state, SessionState::Unauthenticated));
    }

    #[test]
    fn malformed_frame_closes_connection() {
        let reg = registry();
        let mut state = SessionState::Unauthenticated;
        let out = handle_frame(&reg, &mut state, "{not json", 10, "e1".to_owned());
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("bad_request")
        );
        assert!(out.close);
    }

    #[test]
    fn successful_auth_transitions_state() {
        let reg = registry();
        let mut state = SessionState::Unauthenticated;
        let out = handle_frame(
            &reg,
            &mut state,
            &auth_frame("c1", "good-token"),
            10,
            "e1".to_owned(),
        );
        assert!(out.response.ok);
        assert!(!out.close);
        assert!(matches!(state, SessionState::Authenticated(_)));
    }

    #[test]
    fn bad_token_is_denied_and_closes() {
        let reg = registry();
        let mut state = SessionState::Unauthenticated;
        let out = handle_frame(
            &reg,
            &mut state,
            &auth_frame("c1", "wrong"),
            10,
            "e1".to_owned(),
        );
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("bad_token")
        );
        assert!(out.close);
        assert!(matches!(state, SessionState::Unauthenticated));
    }

    #[test]
    fn authed_ping_dispatches() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mut state,
            &frame("host.ping", serde_json::Value::Null),
            11,
            "e2".to_owned(),
        );
        assert!(out.response.ok);
        assert_eq!(
            out.response.result,
            Some(serde_json::json!({ "pong": true }))
        );
    }

    #[test]
    fn authed_command_missing_scope_is_denied() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        // runtime.shutdown needs `admin`, which this client lacks.
        let out = handle_frame(
            &reg,
            &mut state,
            &frame("runtime.shutdown", serde_json::Value::Null),
            11,
            "e2".to_owned(),
        );
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("missing_scope")
        );
    }

    #[test]
    fn authed_unimplemented_command_fails_loud() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        // conversation.inject_text is authorized (scope held) but not yet wired.
        let out = handle_frame(
            &reg,
            &mut state,
            &frame(
                "conversation.inject_text",
                serde_json::json!({ "text": "hi" }),
            ),
            11,
            "e2".to_owned(),
        );
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("not_implemented")
        );
    }
}
