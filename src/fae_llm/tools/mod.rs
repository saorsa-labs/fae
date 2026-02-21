//! Tool system for the fae_llm module.
//!
//! Provides a registry-based tool architecture with mode gating,
//! JSON Schema validation, and bounded output.
//!
//! # Tools
//!
//! - **read** — Read file contents with pagination
//! - **bash** — Execute shell commands with timeout
//! - **edit** — Deterministic text edits (find/replace)
//! - **write** — Create or overwrite files
//! - **web_search** — Search the web via embedded multi-engine scraper
//! - **fetch_url** — Fetch and extract web page content
//! - **desktop** — Desktop automation (screenshots, clicks, typing, windows)
//! - **apple** — Apple ecosystem tools (Contacts, Calendar) — macOS only
//!
//! # Mode Gating
//!
//! Tools respect [`ToolMode`](crate::fae_llm::config::types::ToolMode):
//! - `ReadOnly` — Only read-only tools are available (read, web_search, fetch_url)
//! - `Full` — All tools are available

pub mod apple;
pub mod bash;
pub mod desktop;
pub mod edit;
pub mod fetch_url;
pub mod input_sanitize;
pub mod path_validation;
pub mod python_skill;
pub mod read;
pub mod registry;
pub mod sanitize;
pub mod scheduler_create;
pub mod scheduler_delete;
pub mod scheduler_list;
pub mod scheduler_trigger;
pub mod scheduler_update;
pub mod types;
pub mod web_search;
pub mod write;

pub use bash::BashTool;
pub use desktop::DesktopTool;
pub use edit::EditTool;
pub use fetch_url::FetchUrlTool;
pub use input_sanitize::{SanitizedInput, sanitize_command_input, sanitize_content_input};
pub use path_validation::{validate_read_path, validate_write_path};
pub use python_skill::PythonSkillTool;
pub use read::ReadTool;
pub use registry::ToolRegistry;
pub use sanitize::{SanitizedOutput, sanitize_tool_output};
pub use scheduler_create::SchedulerCreateTool;
pub use scheduler_delete::SchedulerDeleteTool;
pub use scheduler_list::SchedulerListTool;
pub use scheduler_trigger::SchedulerTriggerTool;
pub use scheduler_update::SchedulerUpdateTool;
pub use types::{Tool, ToolResult, truncate_output};
pub use web_search::WebSearchTool;
pub use write::WriteTool;

#[cfg(test)]
mod mode_gating_tests;

#[cfg(test)]
mod scheduler_integration_tests;

#[cfg(test)]
mod integration_tests {
    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use std::path::PathBuf;
    use std::sync::Arc;

    fn make_registry_with_root(mode: ToolMode, workspace_root: PathBuf) -> ToolRegistry {
        let mut reg = ToolRegistry::new(mode);
        reg.register(Arc::new(ReadTool::with_workspace_root(
            workspace_root.clone(),
        )));
        reg.register(Arc::new(BashTool::new()));
        reg.register(Arc::new(EditTool::with_workspace_root(
            workspace_root.clone(),
        )));
        reg.register(Arc::new(WriteTool::with_workspace_root(workspace_root)));
        reg
    }

    fn make_registry(mode: ToolMode) -> ToolRegistry {
        let workspace_root = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        make_registry_with_root(mode, workspace_root)
    }

    fn temp_dir() -> tempfile::TempDir {
        match tempfile::tempdir() {
            Ok(d) => d,
            Err(_) => unreachable!("tempdir creation should not fail"),
        }
    }

    // ── Registry with all tools ───────────────────────────────

    #[test]
    fn register_all_four_tools() {
        let reg = make_registry(ToolMode::Full);
        let available = reg.list_available();
        assert_eq!(available.len(), 4);
        assert!(available.contains(&"read"));
        assert!(available.contains(&"bash"));
        assert!(available.contains(&"edit"));
        assert!(available.contains(&"write"));
    }

    // ── Mode gating ──────────────────────────────────────────

    #[test]
    fn read_only_allows_only_read() {
        let reg = make_registry(ToolMode::ReadOnly);
        let available = reg.list_available();
        assert_eq!(available, vec!["read"]);
    }

    #[test]
    fn read_only_blocks_bash() {
        let reg = make_registry(ToolMode::ReadOnly);
        assert!(reg.get("bash").is_none());
    }

    #[test]
    fn read_only_blocks_edit() {
        let reg = make_registry(ToolMode::ReadOnly);
        assert!(reg.get("edit").is_none());
    }

    #[test]
    fn read_only_blocks_write() {
        let reg = make_registry(ToolMode::ReadOnly);
        assert!(reg.get("write").is_none());
    }

    #[test]
    fn full_mode_allows_all() {
        let reg = make_registry(ToolMode::Full);
        assert!(reg.get("read").is_some());
        assert!(reg.get("bash").is_some());
        assert!(reg.get("edit").is_some());
        assert!(reg.get("write").is_some());
    }

    // ── Schema export ────────────────────────────────────────

    #[test]
    fn schemas_for_api_returns_valid_json() {
        let reg = make_registry(ToolMode::Full);
        let schemas = reg.schemas_for_api();
        assert_eq!(schemas.len(), 4);

        for schema in &schemas {
            let name = schema.get("name").and_then(|v| v.as_str());
            assert!(name.is_some());

            let desc = schema.get("description").and_then(|v| v.as_str());
            assert!(desc.is_some());
            assert!(!desc.unwrap_or("").is_empty());

            let params = schema.get("parameters");
            assert!(params.is_some());
            assert!(params.is_some_and(|p| p.is_object()));
        }
    }

    #[test]
    fn schemas_sorted_by_name() {
        let reg = make_registry(ToolMode::Full);
        let schemas = reg.schemas_for_api();
        let names: Vec<&str> = schemas
            .iter()
            .filter_map(|s| s.get("name").and_then(|v| v.as_str()))
            .collect();
        assert_eq!(names, vec!["bash", "edit", "read", "write"]);
    }

    // ── Mode switch ──────────────────────────────────────────

    #[test]
    fn mode_switch_changes_available_tools() {
        let mut reg = make_registry(ToolMode::ReadOnly);
        assert_eq!(reg.list_available().len(), 1);

        reg.set_mode(ToolMode::Full);
        assert_eq!(reg.list_available().len(), 4);

        reg.set_mode(ToolMode::ReadOnly);
        assert_eq!(reg.list_available().len(), 1);
    }

    // ── End-to-end workflow ──────────────────────────────────

    /// Write a file → read it → edit it → read again (verify changes).
    #[test]
    fn write_read_edit_read_workflow() {
        let dir = temp_dir();
        let file_path = dir.path().join("workflow.txt");
        let path_str = file_path.to_str().unwrap_or("/tmp/fae_test_workflow.txt");

        let reg = make_registry_with_root(ToolMode::Full, dir.path().to_path_buf());

        // Step 1: Write a file
        let write_tool = reg.get("write");
        assert!(write_tool.is_some());
        let write_tool = match write_tool {
            Some(t) => t,
            None => unreachable!("write tool should be available"),
        };
        let result = write_tool.execute(serde_json::json!({
            "path": path_str,
            "content": "hello world\nfoo bar\nbaz qux"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("write should succeed"),
        };
        assert!(result.success);

        // Step 2: Read the file
        let read_tool = reg.get("read");
        assert!(read_tool.is_some());
        let read_tool = match read_tool {
            Some(t) => t,
            None => unreachable!("read tool should be available"),
        };
        let result = read_tool.execute(serde_json::json!({
            "path": path_str
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("read should succeed"),
        };
        assert!(result.success);
        assert_eq!(result.content, "hello world\nfoo bar\nbaz qux");

        // Step 3: Edit the file
        let edit_tool = reg.get("edit");
        assert!(edit_tool.is_some());
        let edit_tool = match edit_tool {
            Some(t) => t,
            None => unreachable!("edit tool should be available"),
        };
        let result = edit_tool.execute(serde_json::json!({
            "path": path_str,
            "old_string": "foo bar",
            "new_string": "hello rust"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("edit should succeed"),
        };
        assert!(result.success);

        // Step 4: Read again and verify
        let result = read_tool.execute(serde_json::json!({
            "path": path_str
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("read should succeed"),
        };
        assert!(result.success);
        assert_eq!(result.content, "hello world\nhello rust\nbaz qux");
    }

    /// Bash tool executes commands and captures output.
    #[test]
    fn bash_tool_captures_output() {
        let reg = make_registry(ToolMode::Full);
        let bash = match reg.get("bash") {
            Some(t) => t,
            None => unreachable!("bash should be available in full mode"),
        };

        let result = bash.execute(serde_json::json!({"command": "echo integration_test"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("echo should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("integration_test"));
    }

    /// Read tool with pagination in full workflow.
    #[test]
    fn read_tool_pagination() {
        let dir = temp_dir();
        let file_path = dir.path().join("paged.txt");

        // Write multi-line file directly
        let lines = (1..=10)
            .map(|i| format!("line {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        std::fs::write(&file_path, &lines).unwrap_or_default();

        let reg = make_registry_with_root(ToolMode::Full, dir.path().to_path_buf());
        let read = match reg.get("read") {
            Some(t) => t,
            None => unreachable!("read should be available"),
        };

        // Read lines 3-5
        let result = read.execute(serde_json::json!({
            "path": file_path.to_str(),
            "offset": 3,
            "limit": 3
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("read should succeed"),
        };
        assert!(result.success);
        assert_eq!(result.content, "line 3\nline 4\nline 5");
    }

    /// All tool names are unique.
    #[test]
    fn all_tool_names_unique() {
        let tools: Vec<Arc<dyn Tool>> = vec![
            Arc::new(ReadTool::new()),
            Arc::new(BashTool::new()),
            Arc::new(EditTool::new()),
            Arc::new(WriteTool::new()),
        ];
        let names: Vec<&str> = tools.iter().map(|t| t.name()).collect();
        let mut unique = names.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(names.len(), unique.len());
    }
}
