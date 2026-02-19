//! Permission-aware tool wrapper for Apple ecosystem tools.
//!
//! [`AvailabilityGatedTool`] wraps any [`AppleEcosystemTool`] and checks the
//! [`PermissionStore`] before delegating execution.  When the required permission
//! has not been granted, the tool returns a graceful error instead of failing
//! silently or panicking.

use std::sync::Arc;

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::types::{Tool, ToolResult};
use crate::permissions::PermissionStore;

use super::trait_def::AppleEcosystemTool;

/// A [`Tool`] wrapper that gates execution on a permission check.
///
/// Delegates `name`, `description`, `schema`, and `allowed_in_mode` to the
/// inner tool.  `execute` first consults the [`PermissionStore`]; if the
/// required permission is not granted it returns a descriptive error without
/// invoking the inner tool.
pub struct AvailabilityGatedTool {
    inner: Arc<dyn AppleEcosystemTool>,
    permissions: Arc<PermissionStore>,
}

impl AvailabilityGatedTool {
    /// Create a new gated wrapper.
    ///
    /// # Arguments
    ///
    /// * `inner` — the Apple ecosystem tool to wrap.
    /// * `permissions` — the store consulted for grant status.
    pub fn new(inner: Arc<dyn AppleEcosystemTool>, permissions: Arc<PermissionStore>) -> Self {
        Self { inner, permissions }
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
    /// Returns a [`ToolResult::failure`] when the permission has not been
    /// granted, with a message indicating which permission is needed.
    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let kind = self.inner.required_permission();
        if !self.permissions.is_granted(kind) {
            return Ok(ToolResult::failure(format!(
                "Permission not granted: {kind}. Please grant {kind} permission to use this tool."
            )));
        }
        self.inner.execute(args)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::permissions::PermissionKind;

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

    fn gated(store: PermissionStore) -> AvailabilityGatedTool {
        AvailabilityGatedTool::new(Arc::new(MockTool), Arc::new(store))
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
}
