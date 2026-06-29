//! The per-session durable-workspace-root confirmation channel (A3→B).
//!
//! When an owner wants to bind a durable project directory as a session's
//! ToolHost root (replacing the ephemeral temp sandbox), the daemon asks the
//! owner to approve the SPECIFIC canonical path via a distinct
//! `workspace.confirm_root` server-request — separate from the per-tool
//! `tool.confirm` (root approval authorizes a *place* once per session; tool
//! confirm authorizes a *tool invocation* per call; conflating them would let a
//! per-call tap implicitly grant a durable workspace).
//!
//! Reuses [`ServerRequester`](crate::server_request::ServerRequester) (the same
//! per-connection issuer A3 uses for `tool.confirm`) — no new transport. Like
//! `tool.confirm`, `toolhost.set_root` is SPAWNED so the read loop keeps draining
//! the client's reply (BLOCKER-1).
//!
//! ## The root-safety guard (structural blast-radius bound)
//! Even with the owner's approval, certain roots are refused outright
//! ([`is_safe_workspace_root`]) — `/`, filesystem roots, the user's home
//! directory, and any path too shallow to contain damage. The owner approves a
//! *project subdir*, not a mount point. Defense-in-depth ahead of the
//! damage-control denylist (which catches `rm -rf .` etc. at execute time).

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use crate::server_request::{ServerRequestError, ServerRequester};

/// Timeout for the owner to approve a root (scope §6.5 parity with tool confirm).
const ROOT_CONFIRM_TIMEOUT_SECS: u64 = 60;

/// The fixed blast-radius note. Static so it can never leak file contents.
const ROOT_CONFIRM_NOTE: &str = "Tools the owner approves may read, modify, or delete files under this directory. Choose a project folder, not your home or system root.";

/// The bounded, redacted payload the daemon sends to ask the owner to approve a
/// durable workspace root. Carries ONLY the canonical path + a short note —
/// never a directory listing or file contents.
#[derive(Debug, Clone, Serialize)]
pub struct RootConfirmRequest {
    /// The toolhost.set_root request id (audit correlation + defensive echo).
    pub call_id: String,
    /// The canonicalized absolute path the owner is approving as the root.
    pub path: String,
    /// A short, fixed blast-radius note. Never dynamic file content.
    pub note: &'static str,
}

/// The owner's reply: approve the canonical path, or deny (explicit/timeout/
/// disconnect/malformed/call-id-mismatch).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RootConfirmReply {
    Approved,
    Denied(String),
}

/// Parse the client's `workspace.confirm_root` reply (scope §6.4 parity).
/// Strict: the ONLY accepted shape is `{approved: bool, call_id?: str}` — any
/// other field fails to deserialize → deny (fail-closed).
fn parse_root_confirm_reply(
    result: &serde_json::Value,
    expected_call_id: &str,
) -> RootConfirmReply {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct WireReply {
        approved: bool,
        #[serde(default)]
        call_id: Option<String>,
    }
    let Ok(parsed) = serde_json::from_value::<WireReply>(result.clone()) else {
        return RootConfirmReply::Denied("root_confirm_reply_malformed".into());
    };
    if !parsed.approved {
        return RootConfirmReply::Denied("owner_denied".into());
    }
    if let Some(echoed) = parsed.call_id {
        if echoed != expected_call_id {
            return RootConfirmReply::Denied("root_confirm_call_id_mismatch".into());
        }
    }
    RootConfirmReply::Approved
}

/// Build the bounded [`RootConfirmRequest`] for an approved-to-ask canonical path.
#[must_use]
pub(crate) fn build_root_confirm_request(
    call_id: &str,
    canonical_path: &str,
) -> RootConfirmRequest {
    RootConfirmRequest {
        call_id: call_id.to_owned(),
        path: canonical_path.to_owned(),
        note: ROOT_CONFIRM_NOTE,
    }
}

/// The root-confirmation channel seam. Production =
/// [`ServerRequestRootConfirmation`]; tests use [`FakeRootConfirmation`].
#[async_trait::async_trait]
pub trait RootConfirmation: Send + Sync {
    async fn confirm_root(&self, req: &RootConfirmRequest) -> RootConfirmReply;
}

/// Production impl: reuses the per-connection [`ServerRequester`] with a 60s
/// timeout + single-in-flight-per-connection.
pub struct ServerRequestRootConfirmation {
    requester: ServerRequester,
    /// `true` while a root confirmation is pending. A second concurrent
    /// root-confirm denies `root_confirm_already_pending`.
    in_flight: Arc<Mutex<bool>>,
}

impl ServerRequestRootConfirmation {
    #[must_use]
    pub fn new(requester: ServerRequester) -> Self {
        Self {
            requester,
            in_flight: Arc::new(Mutex::new(false)),
        }
    }

    async fn do_confirm(&self, req: &RootConfirmRequest) -> RootConfirmReply {
        // Single-in-flight: a second concurrent root-confirm denies immediately.
        {
            let mut guard = self.in_flight.lock().await;
            if *guard {
                return RootConfirmReply::Denied("root_confirm_already_pending".into());
            }
            *guard = true;
        }
        // Run the round-trip, then ALWAYS release the slot (approve/deny/timeout/
        // disconnect) so a settled confirm can't block a later one.
        let outcome = self.confirm_round_trip(req).await;
        if let Ok(mut guard) = self.in_flight.try_lock() {
            *guard = false;
        }
        outcome
    }

    async fn confirm_round_trip(&self, req: &RootConfirmRequest) -> RootConfirmReply {
        let params = match serde_json::to_value(req) {
            Ok(v) => v,
            Err(_) => {
                return RootConfirmReply::Denied("root_confirm_payload_serialize_failed".into());
            }
        };
        match tokio::time::timeout(
            Duration::from_secs(ROOT_CONFIRM_TIMEOUT_SECS),
            self.requester.request("workspace.confirm_root", params),
        )
        .await
        {
            Err(_) => RootConfirmReply::Denied("root_confirm_timeout".into()),
            Ok(Err(ServerRequestError::Disconnected)) => {
                RootConfirmReply::Denied("root_confirm_disconnected".into())
            }
            Ok(Ok(result)) => parse_root_confirm_reply(&result, &req.call_id),
        }
    }
}

#[async_trait::async_trait]
impl RootConfirmation for ServerRequestRootConfirmation {
    async fn confirm_root(&self, req: &RootConfirmRequest) -> RootConfirmReply {
        self.do_confirm(req).await
    }
}

/// The per-session durable-root lifecycle (advisor #3: a state machine, not
/// loose locals). Drives immutability + the execute-while-pending deny.
#[derive(Debug, Clone)]
pub enum ToolRootState {
    /// No root requested yet (A3 inert default; routed file tools stay Swift-local
    /// or get `workspace_root_required`).
    Unset,
    /// A `toolhost.set_root` confirm is in flight. `toolhost.execute` during this
    /// state denies `root_initialization_pending`.
    PendingRootConfirm,
    /// The owner approved a durable root; the ToolHost has NOT been created yet
    /// (lazy on first `toolhost.execute`). Carries the canonical path.
    ApprovedRoot { path: String },
    /// The ToolHost was created bound to the ephemeral temp sandbox (A3 behavior
    /// for callers that never set a durable root). A later `set_root` denies
    /// `root_already_initialized`.
    InitializedTemp,
    /// The ToolHost was created bound to the approved durable root.
    InitializedDurable { path: String },
}

impl ToolRootState {
    /// `true` once a ToolHost exists (temp or durable) — `set_root` must deny.
    #[must_use]
    pub fn is_initialized(&self) -> bool {
        matches!(
            self,
            Self::InitializedTemp | Self::InitializedDurable { .. }
        )
    }

    /// `true` while a root confirm is in flight — `toolhost.execute` must deny.
    #[must_use]
    pub fn is_pending(&self) -> bool {
        matches!(self, Self::PendingRootConfirm)
    }
}

/// (advisor #3: structural blast-radius bound) reject roots too broad to contain
/// damage — `/`, the user's home directory, single-component system dirs, and
/// non-existent/non-directory paths. The owner approves a *project subdir*.
///
/// `home_dir` is the canonicalized home (passed in so this is pure + testable
/// without env reads). `path` is the RAW requested path (canonicalized inside).
#[must_use]
pub fn is_safe_workspace_root(path: &std::path::Path, home_dir: Option<&std::path::Path>) -> bool {
    // Must exist + be a directory (no creating roots; no approving a file/ghost).
    let canon = match path.canonicalize() {
        Ok(c) => c,
        Err(_) => return false,
    };
    if !canon.is_dir() {
        return false;
    }
    // Reject the filesystem root itself.
    if canon == std::path::Path::new("/") {
        return false;
    }
    // Reject the user's home directory (too broad — `rm -rf .` wipes everything).
    if let Some(home) = home_dir {
        if let Ok(home_canon) = home.canonicalize() {
            if canon == home_canon {
                return false;
            }
        }
    }
    // Reject single-component roots directly under `/` (e.g. `/Users`, `/etc`,
    // `/var`) — system directories, not projects. Require ≥2 Normal components
    // (e.g. `/Users/alice/projects/foo` is fine; `/Users` is not).
    let depth = canon
        .components()
        .filter(|c| matches!(c, std::path::Component::Normal(_)))
        .count();
    if depth < 2 {
        return false;
    }
    true
}

/// Test-only root confirmation that returns a fixed reply without a wire.
#[cfg(test)]
pub struct FakeRootConfirmation {
    reply: RootConfirmReply,
    called: std::sync::atomic::AtomicBool,
}

#[cfg(test)]
impl FakeRootConfirmation {
    pub fn approve() -> Self {
        Self {
            reply: RootConfirmReply::Approved,
            called: std::sync::atomic::AtomicBool::new(false),
        }
    }
    pub fn deny() -> Self {
        Self {
            reply: RootConfirmReply::Denied("fake_deny".into()),
            called: std::sync::atomic::AtomicBool::new(false),
        }
    }
    pub fn was_called(&self) -> bool {
        self.called.load(std::sync::atomic::Ordering::Relaxed)
    }
}

#[cfg(test)]
#[async_trait::async_trait]
impl RootConfirmation for FakeRootConfirmation {
    async fn confirm_root(&self, _req: &RootConfirmRequest) -> RootConfirmReply {
        self.called
            .store(true, std::sync::atomic::Ordering::Relaxed);
        self.reply.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_root_reply_approved() {
        let r = parse_root_confirm_reply(&serde_json::json!({"approved": true}), "c1");
        assert_eq!(r, RootConfirmReply::Approved);
    }

    #[test]
    fn parse_root_reply_denied() {
        let r = parse_root_confirm_reply(&serde_json::json!({"approved": false}), "c1");
        assert_eq!(r, RootConfirmReply::Denied("owner_denied".into()));
    }

    #[test]
    fn parse_root_reply_stray_field_denies() {
        let r = parse_root_confirm_reply(&serde_json::json!({"approved": true, "extra": 1}), "c1");
        assert_eq!(
            r,
            RootConfirmReply::Denied("root_confirm_reply_malformed".into())
        );
    }

    #[test]
    fn parse_root_reply_missing_approved_denies() {
        let r = parse_root_confirm_reply(&serde_json::json!({}), "c1");
        assert_eq!(
            r,
            RootConfirmReply::Denied("root_confirm_reply_malformed".into())
        );
    }

    #[test]
    fn parse_root_reply_call_id_mismatch_denies() {
        let r = parse_root_confirm_reply(
            &serde_json::json!({"approved": true, "call_id": "other"}),
            "c1",
        );
        assert_eq!(
            r,
            RootConfirmReply::Denied("root_confirm_call_id_mismatch".into())
        );
    }

    #[test]
    fn safe_root_rejects_filesystem_root() {
        assert!(!is_safe_workspace_root(std::path::Path::new("/"), None));
    }

    #[test]
    fn safe_root_rejects_nonexistent() {
        assert!(!is_safe_workspace_root(
            std::path::Path::new("/this/does/not/exist/at-all-xyz-123"),
            None,
        ));
    }

    #[test]
    fn safe_root_rejects_home_dir() {
        let tmp = tempfile::tempdir().expect("tempdir");
        assert!(!is_safe_workspace_root(tmp.path(), Some(tmp.path())));
    }

    #[test]
    fn root_state_machine_queries() {
        assert!(!ToolRootState::Unset.is_initialized());
        assert!(!ToolRootState::Unset.is_pending());
        assert!(ToolRootState::PendingRootConfirm.is_pending());
        assert!(!ToolRootState::PendingRootConfirm.is_initialized());
        assert!(!ToolRootState::ApprovedRoot { path: "/x".into() }.is_pending());
        assert!(ToolRootState::InitializedTemp.is_initialized());
        assert!(ToolRootState::InitializedDurable { path: "/x".into() }.is_initialized());
    }

    #[test]
    fn build_request_is_bounded() {
        let req = build_root_confirm_request("cid", "/x/y/z");
        assert_eq!(req.call_id, "cid");
        assert_eq!(req.path, "/x/y/z");
        assert!(!req.note.is_empty());
    }
}
