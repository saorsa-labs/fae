//! `AppleEcosystemTool` — extension trait for permission-gated Apple tools.
//!
//! All Apple ecosystem tools (Contacts, Calendar, Reminders, Mail, Notes) extend
//! this trait to declare the macOS permission they require and gain a default
//! [`is_available`](AppleEcosystemTool::is_available) implementation.

use crate::fae_llm::tools::types::Tool;
use crate::permissions::{PermissionKind, PermissionStore};

/// Extension trait for Apple-framework tools that require a specific macOS
/// permission to operate.
///
/// Implementors must provide the [`Tool`] methods and declare which
/// [`PermissionKind`] gates them.  The default [`is_available`] returns
/// `true` only when that permission is granted in the supplied store.
///
/// [`is_available`]: AppleEcosystemTool::is_available
pub trait AppleEcosystemTool: Tool {
    /// The macOS permission this tool requires.
    fn required_permission(&self) -> PermissionKind;

    /// Whether this tool is available given the current permission state.
    ///
    /// Returns `true` only when [`required_permission`] is granted in `store`.
    ///
    /// [`required_permission`]: AppleEcosystemTool::required_permission
    fn is_available(&self, store: &PermissionStore) -> bool {
        store.is_granted(self.required_permission())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::error::FaeLlmError;
    use crate::fae_llm::tools::types::ToolResult;

    /// Minimal test tool that requires Contacts permission.
    struct ContactsTestTool;

    impl Tool for ContactsTestTool {
        fn name(&self) -> &str {
            "test_contacts"
        }

        fn description(&self) -> &str {
            "A contacts tool for testing"
        }

        fn schema(&self) -> serde_json::Value {
            serde_json::json!({ "type": "object", "properties": {} })
        }

        fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            Ok(ToolResult::success("contacts ok".to_owned()))
        }

        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    impl AppleEcosystemTool for ContactsTestTool {
        fn required_permission(&self) -> PermissionKind {
            PermissionKind::Contacts
        }
    }

    /// Minimal test tool that requires Calendar permission.
    struct CalendarTestTool;

    impl Tool for CalendarTestTool {
        fn name(&self) -> &str {
            "test_calendar"
        }

        fn description(&self) -> &str {
            "A calendar tool for testing"
        }

        fn schema(&self) -> serde_json::Value {
            serde_json::json!({ "type": "object", "properties": {} })
        }

        fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            Ok(ToolResult::success("calendar ok".to_owned()))
        }

        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    impl AppleEcosystemTool for CalendarTestTool {
        fn required_permission(&self) -> PermissionKind {
            PermissionKind::Calendar
        }
    }

    #[test]
    fn unavailable_without_permission() {
        let tool = ContactsTestTool;
        let store = PermissionStore::default();
        assert!(!tool.is_available(&store));
    }

    #[test]
    fn available_after_grant() {
        let tool = ContactsTestTool;
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Contacts);
        assert!(tool.is_available(&store));
    }

    #[test]
    fn unavailable_after_deny() {
        let tool = ContactsTestTool;
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Contacts);
        assert!(tool.is_available(&store));

        store.deny(PermissionKind::Contacts);
        assert!(!tool.is_available(&store));
    }

    #[test]
    fn wrong_permission_does_not_enable() {
        let tool = ContactsTestTool;
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Calendar);
        // Calendar granted, but tool needs Contacts
        assert!(!tool.is_available(&store));
    }

    #[test]
    fn calendar_tool_available_with_calendar_permission() {
        let tool = CalendarTestTool;
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Calendar);
        assert!(tool.is_available(&store));
    }

    #[test]
    fn required_permission_returns_correct_kind() {
        let contacts = ContactsTestTool;
        assert_eq!(contacts.required_permission(), PermissionKind::Contacts);

        let calendar = CalendarTestTool;
        assert_eq!(calendar.required_permission(), PermissionKind::Calendar);
    }

    /// Verify that `AppleEcosystemTool` is object-safe by constructing a
    /// trait object.  If the trait were not object-safe, this would fail to compile.
    #[test]
    fn trait_is_object_safe() {
        let tool: &dyn AppleEcosystemTool = &ContactsTestTool;
        assert_eq!(tool.name(), "test_contacts");
        assert_eq!(tool.required_permission(), PermissionKind::Contacts);
    }
}
