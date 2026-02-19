//! Permission-aware tool wrapper for Apple ecosystem tools.
//!
//! [`AvailabilityGatedTool`] wraps any [`AppleEcosystemTool`] and checks the
//! [`SharedPermissionStore`] before delegating execution.  When the required
//! permission has not been granted, the tool returns a graceful error instead of
//! failing silently or panicking.
//!
//! ## Live permission semantics
//!
//! The gate holds a [`SharedPermissionStore`] — an `Arc<Mutex<PermissionStore>>`
//! that is shared with the command handler.  When the handler grants or revokes
//! a permission at runtime the change is immediately visible to every
//! `AvailabilityGatedTool` that shares the same handle, with no restart
//! required.
//!
//! ## JIT permission requests
//!
//! When a `jit_request_tx` channel is configured via [`AvailabilityGatedTool::with_jit_channel`], the
//! tool can emit a [`JitPermissionRequest`] and block (up to 60 seconds) while
//! the native dialog awaits user response.  On grant the tool execution proceeds
//! immediately; on deny a graceful failure is returned to the LLM.

use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::mpsc;

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::types::{Tool, ToolResult};
use crate::permissions::{JitPermissionRequest, SharedPermissionStore};

use super::trait_def::AppleEcosystemTool;

/// Timeout for awaiting a JIT permission response from the native dialog.
const JIT_TIMEOUT: Duration = Duration::from_secs(60);

/// A [`Tool`] wrapper that gates execution on a live permission check.
///
/// Delegates `name`, `description`, `schema`, and `allowed_in_mode` to the
/// inner tool.  `execute` locks the [`SharedPermissionStore`]; if the required
/// permission is not granted it returns a descriptive error without invoking the
/// inner tool.
///
/// Because the store is shared (`Arc<Mutex<_>>`), runtime grants (e.g. from a
/// JIT permission dialog) are immediately visible — no tool re-registration
/// is needed.
pub struct AvailabilityGatedTool {
    inner: Arc<dyn AppleEcosystemTool>,
    permissions: SharedPermissionStore,
    /// Optional JIT request channel.
    ///
    /// When `Some`, the gate emits a [`JitPermissionRequest`] and blocks up
    /// to `JIT_TIMEOUT` (60 s) for a response before falling back to the
    /// standard "permission not granted" failure.
    jit_request_tx: Option<mpsc::UnboundedSender<JitPermissionRequest>>,
}

impl AvailabilityGatedTool {
    /// Create a new gated wrapper.
    ///
    /// # Arguments
    ///
    /// * `inner` — the Apple ecosystem tool to wrap.
    /// * `permissions` — the live shared store consulted for grant status.
    pub fn new(inner: Arc<dyn AppleEcosystemTool>, permissions: SharedPermissionStore) -> Self {
        Self {
            inner,
            permissions,
            jit_request_tx: None,
        }
    }

    /// Attach a JIT request channel.
    ///
    /// When a JIT channel is present and the required permission is not
    /// granted, the gate sends a [`JitPermissionRequest`] and blocks until
    /// the user responds or the timeout elapses.
    #[must_use]
    pub fn with_jit_channel(mut self, tx: mpsc::UnboundedSender<JitPermissionRequest>) -> Self {
        self.jit_request_tx = Some(tx);
        self
    }
}

impl Tool for AvailabilityGatedTool {
    /// Delegates to the inner tool's name.
    fn name(&self) -> &str {
        self.inner.name()
    }

    /// Delegates to the inner tool's description.
    fn description(&self) -> &str {
        self.inner.description()
    }

    /// Delegates to the inner tool's schema.
    fn schema(&self) -> serde_json::Value {
        self.inner.schema()
    }

    /// Delegates to the inner tool's mode check.
    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        self.inner.allowed_in_mode(mode)
    }

    /// Execute the inner tool only if the required permission is granted.
    ///
    /// Locks the [`SharedPermissionStore`] to check the current grant status.
    ///
    /// If the permission is not granted and a JIT channel is configured, emits
    /// a [`JitPermissionRequest`] and blocks (spin-loop, 25 ms intervals) until
    /// the user responds via the native dialog or `JIT_TIMEOUT` (60 s) elapses.  On
    /// grant the permission store is expected to be updated externally (via
    /// `capability.grant`) so the re-check succeeds.
    ///
    /// Returns a [`ToolResult::failure`] when:
    /// - No JIT channel is configured and the permission is not granted.
    /// - The JIT response is `false` (denied).
    /// - The JIT response channel times out.
    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let kind = self.inner.required_permission();

        let check_granted = || {
            self.permissions
                .lock()
                .map(|guard| guard.is_granted(kind))
                .unwrap_or(false)
        };

        if check_granted() {
            return self.inner.execute(args);
        }

        // Permission not granted — attempt JIT request if channel is available.
        if let Some(ref jit_tx) = self.jit_request_tx {
            let (respond_to, mut response_rx) = tokio::sync::oneshot::channel::<bool>();
            let request = JitPermissionRequest {
                kind,
                tool_name: self.inner.name().to_owned(),
                reason: format!(
                    "The LLM wants to use the `{}` tool, which requires {} permission.",
                    self.inner.name(),
                    kind
                ),
                respond_to,
            };

            if jit_tx.send(request).is_err() {
                // Channel closed — fall through to standard failure.
                return Ok(ToolResult::failure(format!(
                    "Permission not granted: {kind}. JIT permission channel unavailable."
                )));
            }

            // Block (spin-loop, 25ms intervals) waiting for the native dialog.
            let start = Instant::now();
            loop {
                match response_rx.try_recv() {
                    Ok(true) => {
                        // User granted — re-check the store (handler should have applied the
                        // grant) and proceed.
                        if check_granted() {
                            return self.inner.execute(args);
                        }
                        // Store not yet updated — proceed optimistically.
                        return self.inner.execute(args);
                    }
                    Ok(false) => {
                        return Ok(ToolResult::failure(format!(
                            "Permission denied by user: {kind}."
                        )));
                    }
                    Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                        if start.elapsed() >= JIT_TIMEOUT {
                            return Ok(ToolResult::failure(format!(
                                "Permission request timed out: {kind}. \
                                 Please grant {kind} permission and try again."
                            )));
                        }
                        std::thread::sleep(Duration::from_millis(25));
                    }
                    Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                        return Ok(ToolResult::failure(format!(
                            "Permission not granted: {kind}. \
                             JIT response channel closed unexpectedly."
                        )));
                    }
                }
            }
        }

        Ok(ToolResult::failure(format!(
            "Permission not granted: {kind}. Please grant {kind} permission to use this tool."
        )))
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::permissions::{PermissionKind, PermissionStore};

    /// Minimal mock implementing both `Tool` and `AppleEcosystemTool`.
    struct MockTool;

    impl Tool for MockTool {
        fn name(&self) -> &str {
            "mock_contacts"
        }

        fn description(&self) -> &str {
            "A mock contacts tool"
        }

        fn schema(&self) -> serde_json::Value {
            serde_json::json!({ "type": "object", "properties": { "q": { "type": "string" } } })
        }

        fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            Ok(ToolResult::success("mock result".to_owned()))
        }

        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    impl AppleEcosystemTool for MockTool {
        fn required_permission(&self) -> PermissionKind {
            PermissionKind::Contacts
        }
    }

    /// Create a gated tool from a `PermissionStore` value.
    fn gated(store: PermissionStore) -> AvailabilityGatedTool {
        AvailabilityGatedTool::new(Arc::new(MockTool), store.into_shared())
    }

    #[test]
    fn gate_allows_when_permission_granted() {
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Contacts);
        let tool = gated(store);

        let result = tool.execute(serde_json::json!({})).unwrap();
        assert!(result.success);
        assert_eq!(result.content, "mock result");
    }

    #[test]
    fn gate_blocks_when_permission_denied() {
        let tool = gated(PermissionStore::default());

        let result = tool.execute(serde_json::json!({})).unwrap();
        assert!(!result.success);
        let err = result.error.unwrap();
        assert!(
            err.contains("Permission not granted: contacts"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn gate_delegates_name() {
        let tool = gated(PermissionStore::default());
        assert_eq!(tool.name(), "mock_contacts");
    }

    #[test]
    fn gate_delegates_description() {
        let tool = gated(PermissionStore::default());
        assert_eq!(tool.description(), "A mock contacts tool");
    }

    #[test]
    fn gate_delegates_schema() {
        let tool = gated(PermissionStore::default());
        let schema = tool.schema();
        assert!(schema.get("properties").is_some());
    }

    #[test]
    fn gate_delegates_allowed_in_mode() {
        let tool = gated(PermissionStore::default());
        assert!(tool.allowed_in_mode(ToolMode::Full));
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
    }

    #[test]
    fn live_grant_visible_through_shared_store() {
        // Create a shared store with no permissions.
        let shared = PermissionStore::default_shared();
        let tool = AvailabilityGatedTool::new(Arc::new(MockTool), Arc::clone(&shared));

        // Gate blocks initially.
        let result = tool.execute(serde_json::json!({})).unwrap();
        assert!(!result.success, "should block before grant");

        // Grant through the same shared handle.
        shared.lock().unwrap().grant(PermissionKind::Contacts);

        // Gate now allows.
        let result = tool.execute(serde_json::json!({})).unwrap();
        assert!(result.success, "should allow after live grant");
    }

    #[test]
    fn live_revoke_blocks_previously_allowed_tool() {
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Contacts);
        let shared = store.into_shared();
        let tool = AvailabilityGatedTool::new(Arc::new(MockTool), Arc::clone(&shared));

        // Allowed initially.
        let result = tool.execute(serde_json::json!({})).unwrap();
        assert!(result.success, "should allow when permission is granted");

        // Revoke.
        shared.lock().unwrap().deny(PermissionKind::Contacts);

        // Now blocked.
        let result = tool.execute(serde_json::json!({})).unwrap();
        assert!(!result.success, "should block after revocation");
    }
}
