//! Tool mode gating security tests.
//!
//! Tests verify that ToolMode (ReadOnly vs Full) correctly enforces access control,
//! blocking mutation tools in read-only mode while allowing read access.

use super::registry::ToolRegistry;
use super::types::Tool;
use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::types::ToolResult;
use std::sync::Arc;

// ── Mock Tools for Testing ────────────────────────────────────────

/// Mock read tool (allowed in all modes).
struct MockReadTool;

impl Tool for MockReadTool {
    fn name(&self) -> &str {
        "read"
    }

    fn description(&self) -> &str {
        "Read files from disk"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": {"type": "string"}
            },
            "required": ["path"]
        })
    }

    fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        Ok(ToolResult::success("file content".to_string()))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // Read allowed in both modes
    }
}

/// Mock write tool (only allowed in Full mode).
struct MockWriteTool;

impl Tool for MockWriteTool {
    fn name(&self) -> &str {
        "write"
    }

    fn description(&self) -> &str {
        "Write files to disk"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"}
            },
            "required": ["path", "content"]
        })
    }

    fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        Ok(ToolResult::success("written".to_string()))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

/// Mock edit tool (only allowed in Full mode).
struct MockEditTool;

impl Tool for MockEditTool {
    fn name(&self) -> &str {
        "edit"
    }

    fn description(&self) -> &str {
        "Edit files in place"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "old_text": {"type": "string"},
                "new_text": {"type": "string"}
            },
            "required": ["path", "old_text", "new_text"]
        })
    }

    fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        Ok(ToolResult::success("edited".to_string()))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

/// Mock bash tool (only allowed in Full mode).
struct MockBashTool;

impl Tool for MockBashTool {
    fn name(&self) -> &str {
        "bash"
    }

    fn description(&self) -> &str {
        "Execute bash commands"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "command": {"type": "string"}
            },
            "required": ["command"]
        })
    }

    fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        Ok(ToolResult::success("command output".to_string()))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

// ── Helper Functions ──────────────────────────────────────────────

/// Create a registry with all mock tools registered.
fn create_registry(mode: ToolMode) -> ToolRegistry {
    let mut registry = ToolRegistry::new(mode);
    registry.register(Arc::new(MockReadTool));
    registry.register(Arc::new(MockWriteTool));
    registry.register(Arc::new(MockEditTool));
    registry.register(Arc::new(MockBashTool));
    registry
}

// ── ReadOnly Mode Tests ───────────────────────────────────────────

#[test]
fn test_read_only_mode_allows_read() {
    // Scenario: ReadOnly mode should allow the read tool
    // Expected: get("read") returns Some

    let registry = create_registry(ToolMode::ReadOnly);

    let tool = registry.get("read");
    assert!(
        tool.is_some(),
        "read tool should be available in ReadOnly mode"
    );
    assert_eq!(tool.unwrap().name(), "read");
}

#[test]
fn test_read_only_mode_blocks_write() {
    // Scenario: ReadOnly mode should block the write tool
    // Expected: get("write") returns None

    let registry = create_registry(ToolMode::ReadOnly);

    let tool = registry.get("write");
    assert!(
        tool.is_none(),
        "write tool should be blocked in ReadOnly mode"
    );
}

#[test]
fn test_read_only_mode_blocks_edit() {
    // Scenario: ReadOnly mode should block the edit tool
    // Expected: get("edit") returns None

    let registry = create_registry(ToolMode::ReadOnly);

    let tool = registry.get("edit");
    assert!(
        tool.is_none(),
        "edit tool should be blocked in ReadOnly mode"
    );
}

#[test]
fn test_read_only_mode_blocks_bash() {
    // Scenario: ReadOnly mode should block the bash tool
    // Expected: get("bash") returns None

    let registry = create_registry(ToolMode::ReadOnly);

    let tool = registry.get("bash");
    assert!(
        tool.is_none(),
        "bash tool should be blocked in ReadOnly mode"
    );
}

#[test]
fn test_read_only_mode_list_available() {
    // Scenario: list_available() should only show read tool in ReadOnly mode
    // Expected: Only "read" in the list

    let registry = create_registry(ToolMode::ReadOnly);

    let available = registry.list_available();
    assert_eq!(available.len(), 1, "Only one tool should be available");
    assert_eq!(available[0], "read");
}

#[test]
fn test_read_only_mode_schemas() {
    // Scenario: schemas_for_api() should only include read tool
    // Expected: Only one schema (for read)

    let registry = create_registry(ToolMode::ReadOnly);

    let schemas = registry.schemas_for_api();
    assert_eq!(schemas.len(), 1, "Only one schema should be exported");

    let schema = &schemas[0];
    assert_eq!(schema["name"], "read");
}

#[test]
fn test_read_only_mode_is_blocked_by_mode() {
    // Scenario: is_blocked_by_mode() should identify blocked tools
    // Expected: write, edit, bash return true; read returns false

    let registry = create_registry(ToolMode::ReadOnly);

    assert!(
        !registry.is_blocked_by_mode("read"),
        "read should not be blocked"
    );
    assert!(
        registry.is_blocked_by_mode("write"),
        "write should be blocked"
    );
    assert!(
        registry.is_blocked_by_mode("edit"),
        "edit should be blocked"
    );
    assert!(
        registry.is_blocked_by_mode("bash"),
        "bash should be blocked"
    );
}

// ── Full Mode Tests ───────────────────────────────────────────────

#[test]
fn test_full_mode_allows_read() {
    // Scenario: Full mode should allow the read tool
    // Expected: get("read") returns Some

    let registry = create_registry(ToolMode::Full);

    let tool = registry.get("read");
    assert!(tool.is_some(), "read tool should be available in Full mode");
}

#[test]
fn test_full_mode_allows_write() {
    // Scenario: Full mode should allow the write tool
    // Expected: get("write") returns Some

    let registry = create_registry(ToolMode::Full);

    let tool = registry.get("write");
    assert!(
        tool.is_some(),
        "write tool should be available in Full mode"
    );
}

#[test]
fn test_full_mode_allows_edit() {
    // Scenario: Full mode should allow the edit tool
    // Expected: get("edit") returns Some

    let registry = create_registry(ToolMode::Full);

    let tool = registry.get("edit");
    assert!(tool.is_some(), "edit tool should be available in Full mode");
}

#[test]
fn test_full_mode_allows_bash() {
    // Scenario: Full mode should allow the bash tool
    // Expected: get("bash") returns Some

    let registry = create_registry(ToolMode::Full);

    let tool = registry.get("bash");
    assert!(tool.is_some(), "bash tool should be available in Full mode");
}

#[test]
fn test_full_mode_list_available() {
    // Scenario: list_available() should show all tools in Full mode
    // Expected: All 4 tools in sorted order

    let registry = create_registry(ToolMode::Full);

    let available = registry.list_available();
    assert_eq!(available.len(), 4, "All tools should be available");

    // Should be sorted alphabetically
    assert_eq!(available, vec!["bash", "edit", "read", "write"]);
}

#[test]
fn test_full_mode_schemas() {
    // Scenario: schemas_for_api() should include all tools
    // Expected: 4 schemas

    let registry = create_registry(ToolMode::Full);

    let schemas = registry.schemas_for_api();
    assert_eq!(schemas.len(), 4, "All schemas should be exported");

    // Verify all tool names present (schemas are sorted)
    let names: Vec<&str> = schemas
        .iter()
        .map(|s| {
            s["name"]
                .as_str()
                .unwrap_or_else(|| panic!("name field required"))
        })
        .collect();
    assert_eq!(names, vec!["bash", "edit", "read", "write"]);
}

#[test]
fn test_full_mode_is_blocked_by_mode() {
    // Scenario: is_blocked_by_mode() should return false for all tools
    // Expected: All tools return false (none blocked)

    let registry = create_registry(ToolMode::Full);

    assert!(!registry.is_blocked_by_mode("read"));
    assert!(!registry.is_blocked_by_mode("write"));
    assert!(!registry.is_blocked_by_mode("edit"));
    assert!(!registry.is_blocked_by_mode("bash"));
}

// ── Mode Switching Tests ──────────────────────────────────────────

#[test]
fn test_switch_from_read_only_to_full() {
    // Scenario: Switch from ReadOnly to Full mode
    // Expected: Mutation tools become available after switch

    let mut registry = create_registry(ToolMode::ReadOnly);

    // Initially blocked
    assert!(registry.get("write").is_none());

    // Switch to Full
    registry.set_mode(ToolMode::Full);
    assert_eq!(registry.mode(), ToolMode::Full);

    // Now available
    assert!(registry.get("write").is_some());
    assert!(registry.get("edit").is_some());
    assert!(registry.get("bash").is_some());
}

#[test]
fn test_switch_from_full_to_read_only() {
    // Scenario: Switch from Full to ReadOnly mode
    // Expected: Mutation tools become blocked after switch

    let mut registry = create_registry(ToolMode::Full);

    // Initially allowed
    assert!(registry.get("write").is_some());
    assert!(registry.get("edit").is_some());
    assert!(registry.get("bash").is_some());

    // Switch to ReadOnly
    registry.set_mode(ToolMode::ReadOnly);
    assert_eq!(registry.mode(), ToolMode::ReadOnly);

    // Now blocked
    assert!(registry.get("write").is_none());
    assert!(registry.get("edit").is_none());
    assert!(registry.get("bash").is_none());

    // Read still available
    assert!(registry.get("read").is_some());
}

#[test]
fn test_multiple_mode_switches() {
    // Scenario: Switch modes multiple times
    // Expected: Permissions update correctly each time

    let mut registry = create_registry(ToolMode::ReadOnly);

    // ReadOnly → Full → ReadOnly → Full
    registry.set_mode(ToolMode::Full);
    assert_eq!(registry.list_available().len(), 4);

    registry.set_mode(ToolMode::ReadOnly);
    assert_eq!(registry.list_available().len(), 1);

    registry.set_mode(ToolMode::Full);
    assert_eq!(registry.list_available().len(), 4);
}

// ── Registry State Tests ──────────────────────────────────────────

#[test]
fn test_tool_exists_regardless_of_mode() {
    // Scenario: exists() should return true even if tool is blocked
    // Expected: All registered tools exist

    let registry = create_registry(ToolMode::ReadOnly);

    // All tools exist, even though some are blocked
    assert!(registry.exists("read"));
    assert!(registry.exists("write"));
    assert!(registry.exists("edit"));
    assert!(registry.exists("bash"));
}

#[test]
fn test_tool_not_registered() {
    // Scenario: Check for tool that was never registered
    // Expected: exists() returns false, is_blocked_by_mode() returns false

    let registry = create_registry(ToolMode::Full);

    assert!(!registry.exists("nonexistent"));
    assert!(!registry.is_blocked_by_mode("nonexistent"));
    assert!(registry.get("nonexistent").is_none());
}

#[test]
fn test_registry_mode_query() {
    // Scenario: Query current mode
    // Expected: mode() returns the configured mode

    let registry_readonly = create_registry(ToolMode::ReadOnly);
    let registry_full = create_registry(ToolMode::Full);

    assert_eq!(registry_readonly.mode(), ToolMode::ReadOnly);
    assert_eq!(registry_full.mode(), ToolMode::Full);
}

// ── Security Boundary Tests ───────────────────────────────────────

#[test]
fn test_security_boundary_clear_error_message() {
    // Scenario: Attempting to get a blocked tool should provide clear error semantics
    // Expected: None return with is_blocked_by_mode() returning true

    let registry = create_registry(ToolMode::ReadOnly);

    // Tool exists but is blocked
    assert!(registry.exists("write"), "Tool should exist in registry");
    assert!(
        registry.is_blocked_by_mode("write"),
        "Tool should be blocked by mode"
    );
    assert!(
        registry.get("write").is_none(),
        "Tool should not be accessible"
    );

    // This pattern allows callers to provide clear error messages:
    // "Tool 'write' is not allowed in ReadOnly mode"
}

#[test]
fn test_read_only_mode_prevents_mutation() {
    // Scenario: Verify ReadOnly mode enforces the security boundary
    // Expected: No mutation tools accessible, only read

    let registry = create_registry(ToolMode::ReadOnly);

    // Collect all available tool names
    let available = registry.list_available();

    // Verify no mutation tools are accessible
    assert!(!available.contains(&"write"));
    assert!(!available.contains(&"edit"));
    assert!(!available.contains(&"bash"));

    // Only read should be available
    assert_eq!(available, vec!["read"]);
}

#[test]
fn test_full_mode_grants_all_permissions() {
    // Scenario: Verify Full mode grants access to all tools
    // Expected: All tools accessible

    let registry = create_registry(ToolMode::Full);

    // All tools should be accessible
    assert!(registry.get("read").is_some());
    assert!(registry.get("write").is_some());
    assert!(registry.get("edit").is_some());
    assert!(registry.get("bash").is_some());

    // No tools should be blocked
    assert!(!registry.is_blocked_by_mode("read"));
    assert!(!registry.is_blocked_by_mode("write"));
    assert!(!registry.is_blocked_by_mode("edit"));
    assert!(!registry.is_blocked_by_mode("bash"));
}
