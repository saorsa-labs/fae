//! Bash tool — executes shell commands with timeout and bounded output.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::input_sanitize::sanitize_command_input;

use super::types::{DEFAULT_MAX_BYTES, Tool, ToolResult, truncate_output};

/// Default command timeout in seconds.
const DEFAULT_TIMEOUT_SECS: u64 = 30;

/// Tool that executes shell commands via `/bin/sh -c`.
///
/// Arguments (JSON):
/// - `command` (string, required) — shell command to execute
/// - `timeout` (integer, optional) — timeout in seconds (default 30)
///
/// Only available in `ToolMode::Full`.
pub struct BashTool {
    max_bytes: usize,
    timeout_secs: u64,
}

impl BashTool {
    /// Create a new BashTool with default settings.
    pub fn new() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
            timeout_secs: DEFAULT_TIMEOUT_SECS,
        }
    }

    /// Create a new BashTool with custom settings.
    pub fn with_config(max_bytes: usize, timeout_secs: u64) -> Self {
        Self {
            max_bytes,
            timeout_secs,
        }
    }
}

impl Default for BashTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for BashTool {
    fn name(&self) -> &str {
        "bash"
    }

    fn description(&self) -> &str {
        "Execute a shell command with timeout and bounded output"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "Shell command to execute"
                },
                "timeout": {
                    "type": "integer",
                    "description": "Timeout in seconds (default 30)"
                }
            },
            "required": ["command"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let command = args
            .get("command")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                FaeLlmError::ToolValidationError("missing required argument: command".into())
            })?;

        if command.is_empty() {
            return Err(FaeLlmError::ToolValidationError(
                "command cannot be empty".into(),
            ));
        }

        // Sanitize command input to prevent shell injection
        let sanitized = sanitize_command_input(command);
        if sanitized.modified {
            tracing::debug!(
                removed = ?sanitized.removed_categories,
                "command input sanitized"
            );
        }
        let command = sanitized.content;

        let timeout_secs = args
            .get("timeout")
            .and_then(|v| v.as_u64())
            .unwrap_or(self.timeout_secs);

        // Execute synchronously with timeout using std::process
        let timeout = std::time::Duration::from_secs(timeout_secs);
        let start = std::time::Instant::now();

        let mut cmd = std::process::Command::new("/bin/sh");
        cmd.arg("-c")
            .arg(command)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        // When running inside an App Sandbox, inject sandbox-safe directory
        // env vars so that child processes can locate Fae's data/config/cache
        // without relying on hardcoded `~/.fae` paths.
        if crate::fae_dirs::is_sandboxed() {
            cmd.env("FAE_DATA_DIR", crate::fae_dirs::data_dir());
            cmd.env("FAE_CONFIG_DIR", crate::fae_dirs::config_dir());
            cmd.env("FAE_CACHE_DIR", crate::fae_dirs::cache_dir());
        }

        let mut child = match cmd.spawn() {
            Ok(child) => child,
            Err(e) => {
                return Ok(ToolResult::failure(format!("failed to spawn command: {e}")));
            }
        };

        // Wait with timeout by polling
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    // Process finished
                    let stdout = child
                        .stdout
                        .take()
                        .map(|mut s| {
                            let mut buf = String::new();
                            std::io::Read::read_to_string(&mut s, &mut buf).unwrap_or(0);
                            buf
                        })
                        .unwrap_or_default();

                    let stderr = child
                        .stderr
                        .take()
                        .map(|mut s| {
                            let mut buf = String::new();
                            std::io::Read::read_to_string(&mut s, &mut buf).unwrap_or(0);
                            buf
                        })
                        .unwrap_or_default();

                    // Merge stdout and stderr
                    let output = if stderr.is_empty() {
                        stdout
                    } else if stdout.is_empty() {
                        stderr
                    } else {
                        format!("{stdout}\n--- stderr ---\n{stderr}")
                    };

                    let (truncated, was_truncated) = truncate_output(&output, self.max_bytes);

                    if status.success() {
                        if was_truncated {
                            return Ok(ToolResult::success_truncated(truncated));
                        }
                        return Ok(ToolResult::success(truncated));
                    }

                    let exit_code = status.code().unwrap_or(-1);
                    let mut result =
                        ToolResult::failure(format!("command exited with code {exit_code}"));
                    result.content = truncated;
                    result.truncated = was_truncated;
                    return Ok(result);
                }
                Ok(None) => {
                    // Still running — check timeout
                    if start.elapsed() > timeout {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Ok(ToolResult::failure(format!(
                            "command timed out after {timeout_secs}s"
                        )));
                    }
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(e) => {
                    return Ok(ToolResult::failure(format!(
                        "failed to check command status: {e}"
                    )));
                }
            }
        }
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bash_simple_command() {
        let tool = BashTool::new();
        let result = tool.execute(serde_json::json!({"command": "echo hello"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("echo should succeed"),
        };
        assert!(result.success);
        assert_eq!(result.content.trim(), "hello");
    }

    #[test]
    fn bash_nonzero_exit() {
        let tool = BashTool::new();
        let result = tool.execute(serde_json::json!({"command": "exit 42"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return ToolResult not Err"),
        };
        assert!(!result.success);
        assert!(result.error.as_ref().is_some_and(|e| e.contains("code 42")));
    }

    #[test]
    fn bash_stderr_output() {
        let tool = BashTool::new();
        let result = tool.execute(serde_json::json!({"command": "echo error >&2"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return ToolResult"),
        };
        assert!(result.success);
        assert!(result.content.contains("error"));
    }

    #[test]
    fn bash_timeout() {
        let tool = BashTool::with_config(DEFAULT_MAX_BYTES, 1);
        let result = tool.execute(serde_json::json!({"command": "sleep 10", "timeout": 1}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return ToolResult"),
        };
        assert!(!result.success);
        assert!(
            result
                .error
                .as_ref()
                .is_some_and(|e| e.contains("timed out"))
        );
    }

    #[test]
    fn bash_truncates_large_output() {
        let tool = BashTool::with_config(50, DEFAULT_TIMEOUT_SECS);
        // Generate output larger than 50 bytes
        let result =
            tool.execute(serde_json::json!({"command": "python3 -c 'print(\"x\" * 200)'"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return ToolResult"),
        };
        assert!(result.success);
        assert!(result.truncated);
        assert!(result.content.contains("[output truncated"));
    }

    #[test]
    fn bash_missing_command_argument() {
        let tool = BashTool::new();
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
    }

    #[test]
    fn bash_empty_command_rejected() {
        let tool = BashTool::new();
        let result = tool.execute(serde_json::json!({"command": ""}));
        assert!(result.is_err());
    }

    #[test]
    fn bash_only_allowed_in_full_mode() {
        let tool = BashTool::new();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn bash_schema_has_required_command() {
        let tool = BashTool::new();
        let schema = tool.schema();
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = match required {
            Some(r) => r,
            None => unreachable!("schema should have required"),
        };
        assert!(required.iter().any(|v| v.as_str() == Some("command")));
    }

    #[test]
    fn bash_multiline_output() {
        let tool = BashTool::new();
        let result =
            tool.execute(serde_json::json!({"command": "echo line1; echo line2; echo line3"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("line1"));
        assert!(result.content.contains("line2"));
        assert!(result.content.contains("line3"));
    }

    #[test]
    fn bash_sandbox_env_vars_injected_when_sandboxed() {
        // Simulate sandbox by setting the sentinel env var.
        let key = "APP_SANDBOX_CONTAINER_ID";
        let original = std::env::var_os(key);
        unsafe { std::env::set_var(key, "test-container") };

        let tool = BashTool::new();
        // Use `printenv` which doesn't need shell metacharacters.
        let result = tool.execute(serde_json::json!({
            "command": "printenv FAE_DATA_DIR"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("printenv should succeed"),
        };
        assert!(result.success, "printenv should succeed");
        assert!(
            result.content.contains("fae"),
            "FAE_DATA_DIR should contain 'fae': {}",
            result.content.trim()
        );

        // Restore.
        match original {
            Some(v) => unsafe { std::env::set_var(key, v) },
            None => unsafe { std::env::remove_var(key) },
        }
    }
}
