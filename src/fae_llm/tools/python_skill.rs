//! Python skill tool — invokes a managed Python skill subprocess via JSON-RPC 2.0.
//!
//! [`PythonSkillTool`] bridges the synchronous [`Tool`] trait to the async
//! [`PythonSkillRunner`] using `tokio::runtime::Handle::current().block_on()`.
//!
//! The tool is **restricted to [`ToolMode::Full`]** — it will not appear or
//! execute in read-only mode.
//!
//! # Arguments (JSON)
//!
//! ```json
//! {
//!   "skill_name": "discord-bot",
//!   "method":     "send_message",
//!   "params":     { "channel": "general", "text": "Hello" }
//! }
//! ```
//!
//! `params` is optional. `skill_name` and `method` are required.
//!
//! # Returns
//!
//! The raw JSON value returned by the skill in the `result` field of its
//! JSON-RPC 2.0 response, serialized to a compact string.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::skills::error::PythonSkillError;
use crate::skills::python_runner::{PythonSkillRunner, SkillProcessConfig};

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use super::types::{Tool, ToolResult};

/// Global shared runner map.  Both `PythonSkillTool` and the scheduler's
/// health-check task reference the same map so that the scheduler can send
/// `skill.health` pings to processes originally spawned by the tool.
pub type SharedRunnerMap = Arc<Mutex<HashMap<String, PythonSkillRunner>>>;

static GLOBAL_RUNNERS: OnceLock<SharedRunnerMap> = OnceLock::new();

/// Returns the global shared runner map, creating it on first call.
pub fn global_runner_map() -> SharedRunnerMap {
    Arc::clone(GLOBAL_RUNNERS.get_or_init(|| Arc::new(Mutex::new(HashMap::new()))))
}

/// Tool that dispatches a JSON-RPC method call to a named Python skill subprocess.
///
/// Each unique `skill_name` gets its own [`PythonSkillRunner`] in daemon mode,
/// which is lazily created on first use and kept alive between calls.
///
/// # Mode gating
///
/// Only available in [`ToolMode::Full`] — not in `ReadOnly`.
pub struct PythonSkillTool {
    /// Root directory where Python skill packages live.
    skills_dir: PathBuf,
    /// Resolved path to the `uv` binary.
    uv_path: PathBuf,
    /// Live runner instances keyed by skill name (shared global map).
    runners: SharedRunnerMap,
}

impl PythonSkillTool {
    /// Create a new `PythonSkillTool` with the given skills directory and UV path.
    pub fn new(skills_dir: PathBuf, uv_path: PathBuf) -> Self {
        Self {
            skills_dir,
            uv_path,
            runners: global_runner_map(),
        }
    }

    /// Create a tool using defaults (skills dir from [`fae_dirs`] and
    /// `"uv"` for PATH lookup).
    ///
    /// Uses `skills_dir()` (not `python_skills_dir()`) to match the layout
    /// used by `python_lifecycle` when installing skill scripts.
    pub fn with_default_dir() -> Self {
        Self::new(crate::fae_dirs::skills_dir(), PathBuf::from("uv"))
    }
}

impl std::fmt::Debug for PythonSkillTool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PythonSkillTool")
            .field("skills_dir", &self.skills_dir)
            .field("uv_path", &self.uv_path)
            .finish()
    }
}

impl Tool for PythonSkillTool {
    fn name(&self) -> &str {
        "python_skill"
    }

    fn description(&self) -> &str {
        "Invoke a method on a named Python skill subprocess via JSON-RPC 2.0. \
         The skill must be installed in the python skills directory. \
         Use `skill_name` to identify the skill package, `method` for the \
         RPC method to call, and optional `params` for method arguments."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "skill_name": {
                    "type": "string",
                    "description": "Name of the Python skill package to invoke (e.g. \"discord-bot\")"
                },
                "method": {
                    "type": "string",
                    "description": "JSON-RPC method name to call on the skill (e.g. \"send_message\")"
                },
                "params": {
                    "type": "object",
                    "description": "Optional parameters to pass to the method"
                }
            },
            "required": ["skill_name", "method"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let skill_name = args
            .get("skill_name")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                FaeLlmError::ToolValidationError("missing required argument: skill_name".into())
            })?;

        if skill_name.trim().is_empty() {
            return Err(FaeLlmError::ToolValidationError(
                "skill_name must not be empty".into(),
            ));
        }

        let method = args.get("method").and_then(|v| v.as_str()).ok_or_else(|| {
            FaeLlmError::ToolValidationError("missing required argument: method".into())
        })?;

        if method.trim().is_empty() {
            return Err(FaeLlmError::ToolValidationError(
                "method must not be empty".into(),
            ));
        }

        let params = args.get("params").cloned();

        // Validate skill_name characters to prevent path traversal.
        if !skill_name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            return Err(FaeLlmError::ToolValidationError(format!(
                "invalid skill_name \"{skill_name}\" (use alphanumeric, - or _)"
            )));
        }

        let script_path = self.skills_dir.join(format!("{skill_name}.py"));

        // Check if the skill script exists.
        if !script_path.exists() {
            return Ok(ToolResult::failure(format!(
                "skill not found: {skill_name} (expected {})",
                script_path.display()
            )));
        }

        // Ensure a runner exists for this skill.
        let mut runners = self
            .runners
            .lock()
            .map_err(|_| FaeLlmError::ToolExecutionError("runner lock poisoned".into()))?;

        if !runners.contains_key(skill_name) {
            let config =
                SkillProcessConfig::new(skill_name, script_path).with_uv_path(self.uv_path.clone());
            runners.insert(skill_name.to_owned(), PythonSkillRunner::new(config));
        }

        let runner = runners.get_mut(skill_name).ok_or_else(|| {
            FaeLlmError::ToolExecutionError("runner disappeared after insert".into())
        })?;

        // Bridge async send() to sync Tool::execute using the current tokio runtime.
        let skill_name_owned = skill_name.to_owned();
        let method_owned = method.to_owned();

        let result = tokio::runtime::Handle::current().block_on(runner.send(&method_owned, params));

        match result {
            Ok(value) => {
                let content = if value.is_string() {
                    value.as_str().unwrap_or_default().to_owned()
                } else {
                    serde_json::to_string(&value).unwrap_or_else(|_| value.to_string())
                };
                Ok(ToolResult::success(content))
            }
            Err(PythonSkillError::SkillNotFound { name }) => {
                Ok(ToolResult::failure(format!("skill not found: {name}")))
            }
            Err(PythonSkillError::MaxRestartsExceeded { count }) => Ok(ToolResult::failure(
                format!("skill {skill_name_owned} exceeded maximum restarts ({count})"),
            )),
            Err(PythonSkillError::Timeout { timeout_secs }) => Ok(ToolResult::failure(format!(
                "skill {skill_name_owned} timed out after {timeout_secs}s"
            ))),
            Err(e) => Ok(ToolResult::failure(format!(
                "skill {skill_name_owned} error: {e}"
            ))),
        }
    }

    /// Only available in `ToolMode::Full`.
    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::fae_llm::config::types::ToolMode;

    #[test]
    fn tool_name_and_description() {
        let tool = PythonSkillTool::new(
            std::path::PathBuf::from("/tmp/skills"),
            std::path::PathBuf::from("uv"),
        );
        assert_eq!(tool.name(), "python_skill");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn schema_has_required_fields() {
        let tool = PythonSkillTool::new(
            std::path::PathBuf::from("/tmp/skills"),
            std::path::PathBuf::from("uv"),
        );
        let schema = tool.schema();
        assert_eq!(schema["type"], "object");
        assert!(schema["properties"]["skill_name"].is_object());
        assert!(schema["properties"]["method"].is_object());
        let required = schema["required"].as_array().unwrap();
        assert!(required.iter().any(|v| v == "skill_name"));
        assert!(required.iter().any(|v| v == "method"));
    }

    #[test]
    fn only_allowed_in_full_mode() {
        let tool = PythonSkillTool::new(
            std::path::PathBuf::from("/tmp/skills"),
            std::path::PathBuf::from("uv"),
        );
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn missing_skill_name_returns_validation_error() {
        let tool = PythonSkillTool::new(
            std::path::PathBuf::from("/tmp/skills"),
            std::path::PathBuf::from("uv"),
        );
        let args = serde_json::json!({"method": "ping"});
        let err = tool.execute(args).unwrap_err();
        assert!(err.to_string().contains("skill_name"));
    }

    #[test]
    fn missing_method_returns_validation_error() {
        let tool = PythonSkillTool::new(
            std::path::PathBuf::from("/tmp/skills"),
            std::path::PathBuf::from("uv"),
        );
        let args = serde_json::json!({"skill_name": "discord-bot"});
        let err = tool.execute(args).unwrap_err();
        assert!(err.to_string().contains("method"));
    }

    #[test]
    fn empty_skill_name_returns_validation_error() {
        let tool = PythonSkillTool::new(
            std::path::PathBuf::from("/tmp/skills"),
            std::path::PathBuf::from("uv"),
        );
        let args = serde_json::json!({"skill_name": "", "method": "ping"});
        let err = tool.execute(args).unwrap_err();
        assert!(err.to_string().contains("skill_name"));
    }

    #[test]
    fn invalid_skill_name_chars_rejected() {
        let tool = PythonSkillTool::new(
            std::path::PathBuf::from("/tmp/skills"),
            std::path::PathBuf::from("uv"),
        );
        let args = serde_json::json!({"skill_name": "../etc/passwd", "method": "ping"});
        let err = tool.execute(args).unwrap_err();
        assert!(err.to_string().contains("invalid skill_name"));
    }

    #[test]
    fn nonexistent_skill_returns_failure_not_error() {
        let tool = PythonSkillTool::new(
            std::path::PathBuf::from("/tmp/nonexistent-skills-dir"),
            std::path::PathBuf::from("uv"),
        );
        let args = serde_json::json!({"skill_name": "my-skill", "method": "ping"});
        // Should return Ok(ToolResult::failure(...)), not Err
        let result = tool.execute(args).unwrap();
        assert!(!result.success);
        assert!(result.error.unwrap().contains("skill not found"));
    }

    #[test]
    fn script_path_matches_lifecycle_flat_layout() {
        // The python_lifecycle installs scripts at `{skills_root}/{id}.py` (flat).
        // The PythonSkillTool must look for scripts at the same path.
        let root = std::path::PathBuf::from("/test/skills");
        let tool = PythonSkillTool::new(root.clone(), std::path::PathBuf::from("uv"));
        let skill_name = "discord-bot";

        // Simulate the path the tool would construct (from execute()).
        let tool_path = tool.skills_dir.join(format!("{skill_name}.py"));

        // Simulate the path the lifecycle would install to (active_script_path).
        let lifecycle_path = root.join(format!("{skill_name}.py"));

        assert_eq!(
            tool_path, lifecycle_path,
            "PythonSkillTool path must match python_lifecycle active_script_path layout"
        );
    }

    #[test]
    fn with_default_dir_uses_skills_dir() {
        // Verify with_default_dir() uses skills_dir (matching lifecycle)
        // rather than python_skills_dir.
        let tool = PythonSkillTool::with_default_dir();
        let expected = crate::fae_dirs::skills_dir();
        assert_eq!(
            tool.skills_dir, expected,
            "with_default_dir should use fae_dirs::skills_dir() to match lifecycle"
        );
    }

    #[test]
    fn tool_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<PythonSkillTool>();
    }

    #[test]
    fn debug_format() {
        let tool = PythonSkillTool::new(
            std::path::PathBuf::from("/tmp/skills"),
            std::path::PathBuf::from("uv"),
        );
        let dbg = format!("{tool:?}");
        assert!(dbg.contains("PythonSkillTool"));
    }
}
