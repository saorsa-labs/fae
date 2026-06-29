//! Owner confirmation for dangerous tools (A3, scope §6).
//!
//! A2's [`FaeToolPolicy`](crate::toolhost::policy::FaeToolPolicy) maps a
//! dangerous tool's `ConfirmRequired` → `Deny` (the §4.1 trap: fluers' loop
//! treats `Confirm` as allow-with-log). A3 converts that into a real
//! `tool.confirm` round-trip: the governed ToolHost path calls
//! [`FaeToolPolicy::evaluate`](crate::toolhost::policy::FaeToolPolicy::evaluate),
//! and on `NeedsConfirmation` asks the owner via this trait.
//!
//! The payload is **bounded + redacted** (scope §6.3, owner Q3): per-tool
//! summary fields only — path, byte counts, a bounded command preview. **Never**
//! arbitrary tool input JSON, **never** file contents. The reply parser is
//! fail-closed: only `{approved: true}` proceeds; everything else denies.
//!
//! Production impl ([`ServerRequestConfirmation`]) reuses the existing
//! [`ServerRequester`](crate::server_request::ServerRequester) (the same
//! daemon→client request/reply channel `agent.prompt` uses for permission/fs
//! mediation) with a 60s timeout + single-in-flight-per-connection
//! (scope §6.5 / oracle MAJOR-3). No new transport is forked.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde::Serialize;

use crate::server_request::{ServerRequestError, ServerRequester};

/// Server-side bound on a single confirmation round-trip (scope §6.5). An owner
/// who never replies is treated as a deny after this elapses (bounds the
/// unbounded pending map + a hung connection).
const CONFIRM_TIMEOUT_SECS: u64 = 60;

/// Maximum characters of a shell command echoed in the confirm preview (scope
/// §6.3). The command IS the action the owner is approving, so a truncated echo
/// is unavoidable — but bounded.
const COMMAND_PREVIEW_CHARS: usize = 200;

/// The bounded, redacted confirmation request sent to the owner (daemon→client
/// `tool.confirm` params). Serialize so it crosses the wire as JSON.
#[derive(Debug, Serialize, Clone)]
pub struct ConfirmRequest {
    /// Which tool (audit + card title).
    pub tool: String,
    /// The tool-call id (audit correlation + defensive echo in the reply).
    pub call_id: String,
    /// The risk class label (`Write`/`Edit`/`Shell`).
    pub risk_class: String,
    /// Why confirmation is required (always `dangerous_tool_requires_confirmation`).
    pub reason: String,
    /// Tool-specific bounded detail (never arbitrary input, never file contents).
    pub detail: ConfirmDetail,
}

/// Per-tool bounded detail. Redacted by construction (owner Q3): no content,
/// no diff, no full path beyond the relative path the tool received.
#[derive(Debug, Serialize, Clone)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ConfirmDetail {
    /// `write` / `edit`: the path + the size of the incoming content + whether
    /// an existing file is being overwritten.
    WriteEdit {
        path: String,
        new_bytes: u64,
        old_exists: bool,
    },
    /// `bash`: a bounded preview of the command (the command IS the action).
    Shell { command_preview: String },
}

/// The owner's reply to a confirmation (parsed fail-closed from the wire).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfirmReply {
    /// The owner approved; the tool may execute.
    Approved,
    /// The owner denied (explicit deny, timeout, disconnect, malformed reply,
    /// call-id mismatch, or a second confirm while one was pending).
    Denied(String),
}

/// Parse the client's `tool.confirm` reply (`result` payload) fail-closed
/// (scope §6.4 / oracle MAJOR-3). The ONLY accepted shape is
/// `{"approved": bool, "call_id"?: str}` — any other field (incl. `error`,
/// `cancelled`, or a stray key) is a malformed/contradictory reply and DENIES.
/// `approved: true` (with matching/absent `call_id`) is the sole path to
/// [`ConfirmReply::Approved`]; everything else denies.
fn parse_confirm_reply(result: &serde_json::Value, expected_call_id: &str) -> ConfirmReply {
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct WireReply {
        approved: bool,
        #[serde(default)]
        call_id: Option<String>,
    }
    // deny_unknown_fields: a reply carrying `error`, `cancelled`, or any stray
    // key fails to deserialize → deny. This closes the {approved:true, error:x}
    // contradiction the strict contract forbids.
    let Ok(parsed) = serde_json::from_value::<WireReply>(result.clone()) else {
        return ConfirmReply::Denied("confirm_reply_malformed".into());
    };
    if !parsed.approved {
        return ConfirmReply::Denied("owner_denied".into());
    }
    // Defensive: if the client echoed `call_id` and it mismatches, deny.
    if let Some(echoed) = parsed.call_id {
        if echoed != expected_call_id {
            return ConfirmReply::Denied("confirm_call_id_mismatch".into());
        }
    }
    ConfirmReply::Approved
}

/// The confirmation channel seam. Production = [`ServerRequestConfirmation`];
/// tests inject [`FakeConfirmation`]. Kept as a trait so the ToolHost does not
/// depend on the wire transport (mirrors the A2 egress/audit trait seams).
#[async_trait]
pub trait ToolConfirmation: Send + Sync {
    /// Ask the owner to approve `req`. Resolves fail-closed (deny on any error,
    /// timeout, disconnect, or malformed reply).
    async fn confirm(&self, req: &ConfirmRequest) -> ConfirmReply;
}

/// Production confirmation channel: reuses the connection's
/// [`ServerRequester`] with a 60s timeout + single-in-flight-per-connection.
///
/// Created per-connection (holds the requester). The single-in-flight guard is
/// shared via `Arc` so a spawned `toolhost.execute` task sees the same slot as
/// any sibling on the connection.
pub struct ServerRequestConfirmation {
    requester: ServerRequester,
    /// `true` while a confirmation is pending on this connection. A second
    /// concurrent confirm denies `confirm_already_pending` (oracle MAJOR-3).
    in_flight: Arc<Mutex<bool>>,
}

impl ServerRequestConfirmation {
    /// Wrap a connection's requester. Cheap; clone the requester you already
    /// hold (the spawned `toolhost.execute` task owns one).
    #[must_use]
    pub fn new(requester: ServerRequester) -> Self {
        Self {
            requester,
            in_flight: Arc::new(Mutex::new(false)),
        }
    }

    /// The shared in-flight slot, for connection-close to inspect/release.
    #[must_use]
    pub fn in_flight_slot(&self) -> Arc<Mutex<bool>> {
        Arc::clone(&self.in_flight)
    }

    async fn do_confirm(&self, req: &ConfirmRequest) -> ConfirmReply {
        let params = match serde_json::to_value(req) {
            Ok(v) => v,
            // The payload is bounded + serializable by construction; a failure
            // here is an internal bug. Fail-closed.
            Err(_) => return ConfirmReply::Denied("confirm_payload_serialize_failed".into()),
        };
        // 60s timeout (scope §6.5). On timeout the parked oneshot is orphaned in
        // the requester's pending map; the single-in-flight guard bounds that to
        // at most one entry, released on connection close.
        match tokio::time::timeout(
            Duration::from_secs(CONFIRM_TIMEOUT_SECS),
            self.requester.request("tool.confirm", params),
        )
        .await
        {
            Err(_) => ConfirmReply::Denied("confirm_timeout".into()),
            Ok(Err(ServerRequestError::Disconnected)) => {
                ConfirmReply::Denied("confirm_disconnected".into())
            }
            Ok(Ok(result)) => parse_confirm_reply(&result, &req.call_id),
        }
    }
}

#[async_trait]
impl ToolConfirmation for ServerRequestConfirmation {
    async fn confirm(&self, req: &ConfirmRequest) -> ConfirmReply {
        // Single-in-flight-per-connection (oracle MAJOR-3).
        {
            let mut guard = match self.in_flight.lock() {
                Ok(g) => g,
                // Poisoned = an internal panic; fail-closed.
                Err(_) => return ConfirmReply::Denied("confirm_lock_poisoned".into()),
            };
            if *guard {
                return ConfirmReply::Denied("confirm_already_pending".into());
            }
            *guard = true;
        }
        let result = self.do_confirm(req).await;
        // Release the slot regardless of outcome.
        if let Ok(mut g) = self.in_flight.lock() {
            *g = false;
        }
        result
    }
}

/// Build the bounded, redacted [`ConfirmDetail`] for a tool call. Reads ONLY the
/// fields needed for the summary (never echoes content). `old_exists` requires a
/// cheap existence probe via the env; absence is reported, not an error.
///
/// Returns `None` if the tool/input is so malformed no useful detail can be
/// built (the caller denies — better to fail closed than send a useless prompt).
pub(crate) fn build_detail(
    tool: &str,
    input: &serde_json::Value,
    old_exists: bool,
) -> Option<ConfirmDetail> {
    match tool {
        // `write` takes `content`; `edit` takes `old_text`+`new_text`. Both
        // surface as a WriteEdit summary: path + the incoming byte count +
        // whether an existing file is overwritten. The CONTENT is never echoed
        // (owner Q3 — redacted). (oracle MAJOR-4: edit was reading `content`,
        // which doesn't exist on the edit input → new_bytes=0.)
        "write" => {
            let path = input.get("path").and_then(serde_json::Value::as_str)?;
            let new_bytes = input
                .get("content")
                .and_then(serde_json::Value::as_str)
                .map_or(0, |s| s.len() as u64);
            Some(ConfirmDetail::WriteEdit {
                path: truncate(path, 1024),
                new_bytes,
                old_exists,
            })
        }
        "edit" => {
            let path = input.get("path").and_then(serde_json::Value::as_str)?;
            // edit replaces old_text→new_text; report the new snippet's size.
            let new_bytes = input
                .get("new_text")
                .and_then(serde_json::Value::as_str)
                .map_or(0, |s| s.len() as u64);
            Some(ConfirmDetail::WriteEdit {
                path: truncate(path, 1024),
                new_bytes,
                old_exists,
            })
        }
        "bash" => {
            let command = input.get("command").and_then(serde_json::Value::as_str)?;
            Some(ConfirmDetail::Shell {
                command_preview: truncate(command, COMMAND_PREVIEW_CHARS),
            })
        }
        // A dangerous tool with no detail builder: the caller should have
        // classified it; reaching here means a gap. Deny.
        _ => None,
    }
}

/// Truncate a string to `max_chars` (char-boundary-safe).
fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        s.to_string()
    } else {
        s.chars().take(max_chars).collect()
    }
}

/// Test confirmation channel: returns a pre-set reply, records whether it was
/// called, and captures the last request (for the no-prompt-on-escape +
/// bounded-payload assertions). `#[cfg(test)]` — matches the A2
/// `FakeEgressGate` / `CapturingAudit` pattern.
#[cfg(test)]
pub struct FakeConfirmation {
    reply: ConfirmReply,
    called: std::sync::atomic::AtomicBool,
    last_request: Mutex<Option<ConfirmRequest>>,
}

#[cfg(test)]
impl FakeConfirmation {
    /// A confirmation channel that always approves.
    #[must_use]
    pub fn approve() -> Self {
        Self {
            reply: ConfirmReply::Approved,
            called: std::sync::atomic::AtomicBool::new(false),
            last_request: Mutex::new(None),
        }
    }

    /// A confirmation channel that always denies.
    #[must_use]
    pub fn deny() -> Self {
        Self {
            reply: ConfirmReply::Denied("fake_deny".into()),
            called: std::sync::atomic::AtomicBool::new(false),
            last_request: Mutex::new(None),
        }
    }

    /// Whether `confirm` was invoked at all (the §6.2 no-prompt-on-escape /
    /// no-prompt-on-catastrophic guard).
    pub fn was_called(&self) -> bool {
        self.called.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// The last request the channel received (for the bounded-payload check).
    pub fn last_request(&self) -> Option<ConfirmRequest> {
        self.last_request.lock().ok().and_then(|g| g.clone())
    }
}

#[cfg(test)]
#[async_trait]
impl ToolConfirmation for FakeConfirmation {
    async fn confirm(&self, req: &ConfirmRequest) -> ConfirmReply {
        self.called
            .store(true, std::sync::atomic::Ordering::Relaxed);
        if let Ok(mut g) = self.last_request.lock() {
            *g = Some(req.clone());
        }
        self.reply.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // --- reply parser (fail-closed) ---

    #[test]
    fn reply_approved_true_proceeds() {
        assert_eq!(
            parse_confirm_reply(&json!({"approved": true}), "c1"),
            ConfirmReply::Approved
        );
    }

    #[test]
    fn reply_approved_true_with_matching_call_id_proceeds() {
        assert_eq!(
            parse_confirm_reply(&json!({"approved": true, "call_id": "c1"}), "c1"),
            ConfirmReply::Approved
        );
    }

    #[test]
    fn reply_approved_true_with_mismatched_call_id_denies() {
        assert_eq!(
            parse_confirm_reply(&json!({"approved": true, "call_id": "other"}), "c1"),
            ConfirmReply::Denied("confirm_call_id_mismatch".into())
        );
    }

    #[test]
    fn reply_approved_false_denies() {
        assert_eq!(
            parse_confirm_reply(&json!({"approved": false}), "c1"),
            ConfirmReply::Denied("owner_denied".into())
        );
    }

    #[test]
    fn reply_missing_approved_denies() {
        assert_eq!(
            parse_confirm_reply(&json!({"call_id": "c1"}), "c1"),
            ConfirmReply::Denied("confirm_reply_malformed".into())
        );
    }

    #[test]
    fn reply_wrong_type_approved_denies() {
        assert_eq!(
            parse_confirm_reply(&json!({"approved": "yes"}), "c1"),
            ConfirmReply::Denied("confirm_reply_malformed".into())
        );
    }

    #[test]
    fn reply_empty_object_denies() {
        assert_eq!(
            parse_confirm_reply(&json!({}), "c1"),
            ConfirmReply::Denied("confirm_reply_malformed".into())
        );
    }

    #[test]
    fn reply_approved_with_stray_error_field_denies() {
        // oracle MAJOR-3: {approved:true, error:x} is contradictory → deny.
        assert_eq!(
            parse_confirm_reply(&json!({"approved": true, "error": "oops"}), "c1"),
            ConfirmReply::Denied("confirm_reply_malformed".into())
        );
    }

    #[test]
    fn reply_approved_with_cancelled_field_denies() {
        // A cancelled reply that also claims approved is contradictory → deny.
        assert_eq!(
            parse_confirm_reply(&json!({"approved": true, "cancelled": true}), "c1"),
            ConfirmReply::Denied("confirm_reply_malformed".into())
        );
    }

    #[test]
    fn reply_with_unknown_field_denies() {
        // Any field beyond approved/call_id → malformed → deny.
        assert_eq!(
            parse_confirm_reply(&json!({"approved": true, "extra": 1}), "c1"),
            ConfirmReply::Denied("confirm_reply_malformed".into())
        );
    }

    #[test]
    fn detail_edit_uses_new_text_not_content() {
        // oracle MAJOR-4: edit input carries old_text/new_text, NOT content.
        // The detail must report new_text's size (was 0 when reading `content`).
        let d = build_detail(
            "edit",
            &json!({"path": "f.txt", "old_text": "old", "new_text": "replacement"}),
            true,
        )
        .expect("edit detail");
        match d {
            ConfirmDetail::WriteEdit { new_bytes, .. } => {
                assert_eq!(new_bytes, 11, "new_bytes = len(new_text)");
            }
            _ => panic!("expected WriteEdit"),
        }
    }

    #[test]
    fn detail_edit_missing_new_text_reports_zero() {
        let d = build_detail("edit", &json!({"path": "f.txt", "old_text": "x"}), false)
            .expect("edit detail");
        match d {
            ConfirmDetail::WriteEdit { new_bytes, .. } => assert_eq!(new_bytes, 0),
            _ => panic!("expected WriteEdit"),
        }
    }

    // --- detail builder (bounded + redacted) ---

    #[test]
    fn detail_write_carries_path_and_new_bytes_not_content() {
        let d = build_detail(
            "write",
            &json!({"path": "src/a.txt", "content": "hello world"}),
            true,
        )
        .expect("write detail");
        match d {
            ConfirmDetail::WriteEdit {
                path,
                new_bytes,
                old_exists,
            } => {
                assert_eq!(path, "src/a.txt");
                assert_eq!(new_bytes, 11);
                assert!(old_exists);
            }
            _ => panic!("expected WriteEdit"),
        }
    }

    #[test]
    fn detail_edit_overwrite_flagged() {
        let d = build_detail("edit", &json!({"path": "f.txt", "content": "x"}), false)
            .expect("edit detail");
        match d {
            ConfirmDetail::WriteEdit { old_exists, .. } => assert!(!old_exists),
            _ => panic!("expected WriteEdit"),
        }
    }

    #[test]
    fn detail_bash_command_preview_bounded() {
        let long = "x".repeat(500);
        let d = build_detail("bash", &json!({"command": long}), false).expect("bash detail");
        match d {
            ConfirmDetail::Shell { command_preview } => {
                assert_eq!(command_preview.chars().count(), COMMAND_PREVIEW_CHARS);
            }
            _ => panic!("expected Shell"),
        }
    }

    #[test]
    fn detail_write_missing_path_returns_none() {
        assert!(build_detail("write", &json!({"content": "x"}), false).is_none());
    }

    #[test]
    fn detail_unknown_tool_returns_none() {
        assert!(build_detail("nope", &json!({}), false).is_none());
    }

    #[test]
    fn detail_write_payload_has_no_content_field() {
        // The bounding invariant: the serialized detail must NOT contain the
        // file content (owner Q3 — redacted). Mutation guard: if a future change
        // adds the content to the payload, this fails.
        let d = build_detail(
            "write",
            &json!({"path": "f.txt", "content": "SECRET-SENTINEL"}),
            false,
        )
        .expect("write detail");
        let serialized = serde_json::to_string(&d).expect("serialize");
        assert!(
            !serialized.contains("SECRET-SENTINEL"),
            "file content leaked into confirm payload: {serialized}"
        );
    }

    // --- ServerRequestConfirmation single-in-flight + timeout ---

    #[tokio::test]
    async fn server_confirm_second_concurrent_denies_already_pending() {
        // Two confirmations on the same slot: the second must deny
        // confirm_already_pending. We use a requester that never resolves the
        // first (no reply) so the slot stays held, then race the second to the
        // guard check before the first's timeout.
        let requester = ServerRequester::new({
            let (sink, _h) = crate::events::ConnSink::spawn(tokio::io::sink());
            sink
        });
        let conf = Arc::new(ServerRequestConfirmation::new(requester));
        let req = ConfirmRequest {
            tool: "write".into(),
            call_id: "c1".into(),
            risk_class: "Write".into(),
            reason: "dangerous_tool_requires_confirmation".into(),
            detail: ConfirmDetail::WriteEdit {
                path: "f.txt".into(),
                new_bytes: 1,
                old_exists: false,
            },
        };
        // Hold the slot manually (simulate a confirm mid-flight), then confirm.
        let slot = conf.in_flight_slot();
        {
            let mut g = slot.lock().unwrap();
            *g = true;
        }
        let reply = conf.confirm(&req).await;
        assert_eq!(
            reply,
            ConfirmReply::Denied("confirm_already_pending".into())
        );
    }
}
