//! Tool registry with mode-based gating.
//!
//! The [`ToolRegistry`] holds registered tools, provides lookup by name,
//! enforces mode permissions, and exports JSON schemas for LLM API calls.

use std::collections::HashMap;
use std::sync::Arc;

use crate::fae_llm::config::types::ToolMode;

use super::types::Tool;

/// Registry of available tools with mode-based access control.
///
/// Tools are registered with [`register()`](Self::register) and looked up
/// by name with [`get()`](Self::get). The registry enforces mode gating:
/// tools that aren't allowed in the current mode are hidden from
/// [`list_available()`](Self::list_available) and [`get()`](Self::get).
pub struct ToolRegistry {
    tools: HashMap<String, Arc<dyn Tool>>,
    mode: ToolMode,
}

impl ToolRegistry {
    /// Create a new empty registry with the given mode.
    pub fn new(mode: ToolMode) -> Self {
        Self {
            tools: HashMap::new(),
            mode,
        }
    }

    /// Register a tool. Replaces any existing tool with the same name.
    pub fn register(&mut self, tool: Arc<dyn Tool>) {
        self.tools.insert(tool.name().to_string(), tool);
    }

    /// Get a tool by name, respecting mode gating.
    ///
    /// Returns `None` if the tool doesn't exist or isn't allowed in the current mode.
    pub fn get(&self, name: &str) -> Option<Arc<dyn Tool>> {
        self.tools
            .get(name)
            .filter(|t| t.allowed_in_mode(self.mode))
            .cloned()
    }

    /// List names of all tools available in the current mode.
    pub fn list_available(&self) -> Vec<&str> {
        let mut names: Vec<&str> = self
            .tools
            .values()
            .filter(|t| t.allowed_in_mode(self.mode))
            .map(|t| t.name())
            .collect();
        names.sort_unstable();
        names
    }

    /// Export JSON schemas for all available tools (for LLM API calls).
    ///
    /// Each entry contains `name`, `description`, and `parameters` (the schema).
    pub fn schemas_for_api(&self) -> Vec<serde_json::Value> {
        let mut schemas: Vec<(String, serde_json::Value)> = self
            .tools
            .values()
            .filter(|t| t.allowed_in_mode(self.mode))
            .map(|t| {
                let entry = serde_json::json!({
                    "name": t.name(),
                    "description": t.description(),
                    "parameters": t.schema(),
                });
                (t.name().to_string(), entry)
            })
            .collect();
        schemas.sort_by(|a, b| a.0.cmp(&b.0));
        schemas.into_iter().map(|(_, v)| v).collect()
    }

    /// Change the active tool mode.
    pub fn set_mode(&mut self, mode: ToolMode) {
        self.mode = mode;
    }

    /// Returns the current tool mode.
    pub fn mode(&self) -> ToolMode {
        self.mode
    }

    /// Check if a tool exists in the registry (regardless of mode).
    pub fn exists(&self, name: &str) -> bool {
        self.tools.contains_key(name)
    }

    /// Check if a tool is registered but blocked by the current mode.
    pub fn is_blocked_by_mode(&self, name: &str) -> bool {
        self.tools
            .get(name)
            .map(|t| !t.allowed_in_mode(self.mode))
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::error::FaeLlmError;
    use crate::fae_llm::tools::types::ToolResult;

    /// A read-only tool (allowed in both modes).
    struct ReadOnlyTool;

    impl Tool for ReadOnlyTool {
        fn name(&self) -> &str {
            "read"
        }
        fn description(&self) -> &str {
            "Read files"
        }
        fn schema(&self) -> serde_json::Value {
            serde_json::json!({"type": "object", "properties": {"path": {"type": "string"}}})
        }
        fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            Ok(ToolResult::success("file content".to_string()))
        }
        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    /// A mutation tool (only allowed in Full mode).
    struct MutationTool {
        tool_name: &'static str,
    }

    impl Tool for MutationTool {
        fn name(&self) -> &str {
            self.tool_name
        }
        fn description(&self) -> &str {
            "Mutation tool"
        }
        fn schema(&self) -> serde_json::Value {
            serde_json::json!({"type": "object", "properties": {}})
        }
        fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            Ok(ToolResult::success("mutated".to_string()))
        }
        fn allowed_in_mode(&self, mode: ToolMode) -> bool {
            mode == ToolMode::Full
        }
    }

    fn make_registry(mode: ToolMode) -> ToolRegistry {
        let mut reg = ToolRegistry::new(mode);
        reg.register(Arc::new(ReadOnlyTool));
        reg.register(Arc::new(MutationTool { tool_name: "bash" }));
        reg.register(Arc::new(MutationTool { tool_name: "edit" }));
        reg.register(Arc::new(MutationTool { tool_name: "write" }));
        reg
    }

    #[test]
    fn register_and_get_tool() {
        let reg = make_registry(ToolMode::Full);
        let tool = reg.get("read");
        assert!(tool.is_some());
        assert_eq!(tool.map(|t| t.name().to_string()), Some("read".to_string()));
    }

    #[test]
    fn get_nonexistent_tool_returns_none() {
        let reg = make_registry(ToolMode::Full);
        assert!(reg.get("nonexistent").is_none());
    }

    #[test]
    fn read_only_mode_allows_read_tool() {
        let reg = make_registry(ToolMode::ReadOnly);
        assert!(reg.get("read").is_some());
    }

    #[test]
    fn read_only_mode_blocks_mutation_tools() {
        let reg = make_registry(ToolMode::ReadOnly);
        assert!(reg.get("bash").is_none());
        assert!(reg.get("edit").is_none());
        assert!(reg.get("write").is_none());
    }

    #[test]
    fn full_mode_allows_all_tools() {
        let reg = make_registry(ToolMode::Full);
        assert!(reg.get("read").is_some());
        assert!(reg.get("bash").is_some());
        assert!(reg.get("edit").is_some());
        assert!(reg.get("write").is_some());
    }

    #[test]
    fn list_available_read_only() {
        let reg = make_registry(ToolMode::ReadOnly);
        let available = reg.list_available();
        assert_eq!(available, vec!["read"]);
    }

    #[test]
    fn list_available_full() {
        let reg = make_registry(ToolMode::Full);
        let available = reg.list_available();
        assert_eq!(available, vec!["bash", "edit", "read", "write"]);
    }

    #[test]
    fn schemas_for_api_full_mode() {
        let reg = make_registry(ToolMode::Full);
        let schemas = reg.schemas_for_api();
        assert_eq!(schemas.len(), 4);
        for schema in &schemas {
            assert!(schema.get("name").is_some());
            assert!(schema.get("description").is_some());
            assert!(schema.get("parameters").is_some());
        }
    }

    #[test]
    fn schemas_for_api_read_only_mode() {
        let reg = make_registry(ToolMode::ReadOnly);
        let schemas = reg.schemas_for_api();
        assert_eq!(schemas.len(), 1);
        assert_eq!(
            schemas[0].get("name").and_then(|v| v.as_str()),
            Some("read")
        );
    }

    #[test]
    fn set_mode_changes_available_tools() {
        let mut reg = make_registry(ToolMode::ReadOnly);
        assert_eq!(reg.list_available().len(), 1);

        reg.set_mode(ToolMode::Full);
        assert_eq!(reg.list_available().len(), 4);

        reg.set_mode(ToolMode::ReadOnly);
        assert_eq!(reg.list_available().len(), 1);
    }

    #[test]
    fn mode_getter() {
        let reg = ToolRegistry::new(ToolMode::ReadOnly);
        assert_eq!(reg.mode(), ToolMode::ReadOnly);
    }

    #[test]
    fn empty_registry_returns_empty() {
        let reg = ToolRegistry::new(ToolMode::Full);
        assert!(reg.list_available().is_empty());
        assert!(reg.schemas_for_api().is_empty());
        assert!(reg.get("anything").is_none());
    }

    #[test]
    fn exists_returns_true_for_registered_tool() {
        let reg = make_registry(ToolMode::ReadOnly);
        assert!(reg.exists("read"));
        assert!(reg.exists("bash"));
        assert!(reg.exists("edit"));
        assert!(reg.exists("write"));
    }

    #[test]
    fn exists_returns_false_for_unregistered_tool() {
        let reg = make_registry(ToolMode::Full);
        assert!(!reg.exists("nonexistent"));
    }

    #[test]
    fn is_blocked_by_mode_returns_true_for_mutation_tools_in_read_only() {
        let reg = make_registry(ToolMode::ReadOnly);
        assert!(reg.is_blocked_by_mode("bash"));
        assert!(reg.is_blocked_by_mode("edit"));
        assert!(reg.is_blocked_by_mode("write"));
    }

    #[test]
    fn is_blocked_by_mode_returns_false_for_read_tool_in_read_only() {
        let reg = make_registry(ToolMode::ReadOnly);
        assert!(!reg.is_blocked_by_mode("read"));
    }

    #[test]
    fn is_blocked_by_mode_returns_false_for_all_tools_in_full_mode() {
        let reg = make_registry(ToolMode::Full);
        assert!(!reg.is_blocked_by_mode("read"));
        assert!(!reg.is_blocked_by_mode("bash"));
        assert!(!reg.is_blocked_by_mode("edit"));
        assert!(!reg.is_blocked_by_mode("write"));
    }

    #[test]
    fn is_blocked_by_mode_returns_false_for_nonexistent_tool() {
        let reg = make_registry(ToolMode::ReadOnly);
        assert!(!reg.is_blocked_by_mode("nonexistent"));
    }
}
