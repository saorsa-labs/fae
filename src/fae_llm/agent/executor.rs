//! Tool executor with timeout and cancellation support.
//!
//! The [`ToolExecutor`] wraps a [`ToolRegistry`] and executes tool calls
//! with per-tool timeouts and cancellation token propagation.

use std::sync::Arc;
use std::time::Instant;

use tokio_util::sync::CancellationToken;

use super::accumulator::AccumulatedToolCall;
use super::types::ExecutedToolCall;
use super::validation::validate_tool_args;
use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::observability::spans::*;
use crate::fae_llm::tools::registry::ToolRegistry;

/// Executes tool calls with timeout and cancellation support.
///
/// Wraps a [`ToolRegistry`] and adds:
/// - Per-tool execution timeout
/// - Cancellation token checking between tool calls
/// - Argument validation against tool schemas
/// - Execution timing
pub struct ToolExecutor {
    registry: Arc<ToolRegistry>,
    tool_timeout_secs: u64,
}

impl ToolExecutor {
    /// Create a new tool executor.
    ///
    /// # Arguments
    ///
    /// * `registry` — The tool registry to look up and execute tools
    /// * `tool_timeout_secs` — Maximum time for each tool execution in seconds
    pub fn new(registry: Arc<ToolRegistry>, tool_timeout_secs: u64) -> Self {
        Self {
            registry,
            tool_timeout_secs,
        }
    }

    /// Execute a single tool call.
    ///
    /// Validates arguments against the tool's schema, executes with timeout,
    /// and returns the result with timing information.
    ///
    /// # Errors
    ///
    /// Returns:
    /// - [`FaeLlmError::ToolValidationError`] when arguments fail schema validation.
    /// - [`FaeLlmError::ToolExecutionError`] when execution fails, is cancelled, or the tool is unavailable.
    /// - [`FaeLlmError::TimeoutError`] when execution exceeds the configured timeout.
    /// - The tool is not found in the registry
    /// - Execution times out
    /// - The operation is cancelled
    pub async fn execute_tool(
        &self,
        call: &AccumulatedToolCall,
        cancel: &CancellationToken,
    ) -> Result<ExecutedToolCall, FaeLlmError> {
        let mode = match self.registry.mode() {
            ToolMode::ReadOnly => "read_only",
            ToolMode::Full => "full",
        };

        let tool_span = tracing::info_span!(
            SPAN_TOOL_EXECUTE,
            { FIELD_TOOL_NAME } = %call.function_name,
            { FIELD_TOOL_MODE } = mode,
        );
        let _tool_enter = tool_span.enter();

        tracing::debug!(tool_name = %call.function_name, mode = mode, "Executing tool");

        // Check cancellation before starting
        if cancel.is_cancelled() {
            tracing::warn!(tool_name = %call.function_name, "Tool execution cancelled before start");
            return Err(FaeLlmError::ToolExecutionError(format!(
                "tool '{}': cancelled before execution",
                call.function_name
            )));
        }

        // Look up tool
        let tool = self.registry.get(&call.function_name).ok_or_else(|| {
            if self.registry.is_blocked_by_mode(&call.function_name) {
                tracing::error!(tool_name = %call.function_name, "Tool blocked by mode");
                FaeLlmError::ToolExecutionError(format!(
                    "tool '{}': blocked by current mode (read-only mode does not allow mutation tools)",
                    call.function_name
                ))
            } else {
                tracing::error!(tool_name = %call.function_name, "Tool not found in registry");
                FaeLlmError::ToolExecutionError(format!(
                    "tool '{}': not found in registry",
                    call.function_name
                ))
            }
        })?;

        // Validate arguments against schema
        tracing::debug!(tool_name = %call.function_name, "Validating tool arguments");
        let args = validate_tool_args(&call.function_name, &call.arguments_json, &tool.schema())?;
        tracing::debug!(tool_name = %call.function_name, "Arguments validated successfully");

        // Execute with timeout
        let start = Instant::now();
        let timeout = tokio::time::Duration::from_secs(self.tool_timeout_secs);

        let tool_clone = Arc::clone(&tool);
        let args_clone = args.clone();

        let result = tokio::select! {
            _ = cancel.cancelled() => {
                tracing::warn!(tool_name = %call.function_name, "Tool execution cancelled during execution");
                return Err(FaeLlmError::ToolExecutionError(format!(
                    "tool '{}': cancelled during execution",
                    call.function_name
                )));
            }
            result = tokio::time::timeout(timeout, tokio::task::spawn_blocking(move || {
                tool_clone.execute(args_clone)
            })) => {
                match result {
                    Ok(Ok(Ok(tool_result))) => tool_result,
                    Ok(Ok(Err(e))) => {
                        tracing::error!(tool_name = %call.function_name, error = %e, "Tool execution failed");
                        return Err(e);
                    }
                    Ok(Err(join_err)) => {
                        tracing::error!(tool_name = %call.function_name, error = %join_err, "Tool execution panicked");
                        return Err(FaeLlmError::ToolExecutionError(format!(
                            "tool '{}': execution panicked: {join_err}",
                            call.function_name
                        )));
                    }
                    Err(_elapsed) => {
                        tracing::error!(tool_name = %call.function_name, timeout_secs = self.tool_timeout_secs, "Tool execution timed out");
                        return Err(FaeLlmError::TimeoutError(format!(
                            "tool '{}': execution timed out after {}s",
                            call.function_name,
                            self.tool_timeout_secs
                        )));
                    }
                }
            }
        };

        let duration_ms = start.elapsed().as_millis() as u64;

        tracing::info!(tool_name = %call.function_name, duration_ms = duration_ms, "Tool execution completed successfully");

        Ok(ExecutedToolCall {
            call_id: call.call_id.clone(),
            function_name: call.function_name.clone(),
            arguments: args,
            result,
            duration_ms,
        })
    }

    /// Execute multiple tool calls sequentially.
    ///
    /// Stops on cancellation. Each call is executed one at a time
    /// (no parallel execution in v1 for safety).
    ///
    /// Returns results in the same order as the input calls.
    /// Individual failures are captured as `Err` entries.
    pub async fn execute_tools(
        &self,
        calls: &[AccumulatedToolCall],
        cancel: &CancellationToken,
    ) -> Vec<Result<ExecutedToolCall, FaeLlmError>> {
        let mut results = Vec::with_capacity(calls.len());

        for call in calls {
            if cancel.is_cancelled() {
                results.push(Err(FaeLlmError::ToolExecutionError(format!(
                    "tool '{}': cancelled before execution",
                    call.function_name
                ))));
                break;
            }

            results.push(self.execute_tool(call, cancel).await);
        }

        results
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::tools::types::{Tool, ToolResult};

    /// A test tool that returns its arguments as content.
    struct EchoTool;

    impl Tool for EchoTool {
        fn name(&self) -> &str {
            "echo"
        }
        fn description(&self) -> &str {
            "Echo arguments"
        }
        fn schema(&self) -> serde_json::Value {
            serde_json::json!({
                "type": "object",
                "properties": {
                    "message": { "type": "string" }
                },
                "required": ["message"]
            })
        }
        fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            let msg = args["message"].as_str().unwrap_or("no message");
            Ok(ToolResult::success(msg.to_string()))
        }
        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    /// A tool that sleeps before returning (for timeout testing).
    struct SlowTool {
        delay_ms: u64,
    }

    impl Tool for SlowTool {
        fn name(&self) -> &str {
            "slow"
        }
        fn description(&self) -> &str {
            "A slow tool"
        }
        fn schema(&self) -> serde_json::Value {
            serde_json::json!({
                "type": "object",
                "properties": {}
            })
        }
        fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            std::thread::sleep(std::time::Duration::from_millis(self.delay_ms));
            Ok(ToolResult::success("done".to_string()))
        }
        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    fn make_registry() -> Arc<ToolRegistry> {
        let mut reg = ToolRegistry::new(ToolMode::Full);
        reg.register(Arc::new(EchoTool));
        Arc::new(reg)
    }

    fn make_registry_with_slow(delay_ms: u64) -> Arc<ToolRegistry> {
        let mut reg = ToolRegistry::new(ToolMode::Full);
        reg.register(Arc::new(EchoTool));
        reg.register(Arc::new(SlowTool { delay_ms }));
        Arc::new(reg)
    }

    fn make_call(name: &str, args: &str) -> AccumulatedToolCall {
        AccumulatedToolCall {
            call_id: format!("call_{name}"),
            function_name: name.to_string(),
            arguments_json: args.to_string(),
        }
    }

    // ── Successful execution ─────────────────────────────────

    #[tokio::test]
    async fn execute_tool_success() {
        let registry = make_registry();
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();
        let call = make_call("echo", r#"{"message": "hello"}"#);

        let result = executor.execute_tool(&call, &cancel).await;
        assert!(result.is_ok());
        let executed = match result {
            Ok(e) => e,
            Err(_) => unreachable!("execution succeeded"),
        };
        assert_eq!(executed.call_id, "call_echo");
        assert_eq!(executed.function_name, "echo");
        assert!(executed.result.success);
        assert_eq!(executed.result.content, "hello");
        assert!(executed.duration_ms < 5000);
    }

    // ── Tool not found ───────────────────────────────────────

    #[tokio::test]
    async fn execute_tool_not_found() {
        let registry = make_registry();
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();
        let call = make_call("nonexistent", r#"{}"#);

        let result = executor.execute_tool(&call, &cancel).await;
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolExecutionError(msg)) => {
                assert!(msg.contains("not found"));
                assert!(msg.contains("nonexistent"));
            }
            _ => unreachable!("expected ToolExecutionError"),
        }
    }

    // ── Validation failure ───────────────────────────────────

    #[tokio::test]
    async fn execute_tool_validation_failure() {
        let registry = make_registry();
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();
        // Missing required field "message"
        let call = make_call("echo", r#"{}"#);

        let result = executor.execute_tool(&call, &cancel).await;
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolValidationError(msg)) => {
                assert!(msg.contains("missing required field"));
            }
            _ => unreachable!("expected ToolValidationError"),
        }
    }

    // ── Invalid JSON ─────────────────────────────────────────

    #[tokio::test]
    async fn execute_tool_invalid_json() {
        let registry = make_registry();
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();
        let call = make_call("echo", "not json");

        let result = executor.execute_tool(&call, &cancel).await;
        assert!(result.is_err());
    }

    // ── Timeout ──────────────────────────────────────────────

    #[tokio::test]
    async fn execute_tool_timeout() {
        let registry = make_registry_with_slow(5000); // 5s delay
        let executor = ToolExecutor::new(registry, 1); // 1s timeout
        let cancel = CancellationToken::new();
        let call = make_call("slow", r#"{}"#);

        let result = executor.execute_tool(&call, &cancel).await;
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::TimeoutError(msg)) => {
                assert!(msg.contains("timed out"));
                assert!(msg.contains("slow"));
            }
            _ => unreachable!("expected TimeoutError"),
        }
    }

    // ── Cancellation ─────────────────────────────────────────

    #[tokio::test]
    async fn execute_tool_cancelled_before_start() {
        let registry = make_registry();
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();
        cancel.cancel(); // Cancel before execution
        let call = make_call("echo", r#"{"message": "hi"}"#);

        let result = executor.execute_tool(&call, &cancel).await;
        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolExecutionError(msg)) => {
                assert!(msg.contains("cancelled"));
            }
            _ => unreachable!("expected ToolExecutionError for cancellation"),
        }
    }

    #[tokio::test]
    async fn execute_tool_cancelled_during_execution() {
        let registry = make_registry_with_slow(5000); // 5s delay
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();
        let call = make_call("slow", r#"{}"#);

        // Cancel after a short delay
        let cancel_clone = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
            cancel_clone.cancel();
        });

        let result = executor.execute_tool(&call, &cancel).await;
        assert!(result.is_err());
    }

    // ── Multiple tool execution ──────────────────────────────

    #[tokio::test]
    async fn execute_tools_all_success() {
        let registry = make_registry();
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();
        let calls = vec![
            make_call("echo", r#"{"message": "one"}"#),
            make_call("echo", r#"{"message": "two"}"#),
        ];

        let results = executor.execute_tools(&calls, &cancel).await;
        assert_eq!(results.len(), 2);
        assert!(results[0].is_ok());
        assert!(results[1].is_ok());
    }

    #[tokio::test]
    async fn execute_tools_partial_failure() {
        let registry = make_registry();
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();
        let calls = vec![
            make_call("echo", r#"{"message": "ok"}"#),
            make_call("nonexistent", r#"{}"#),
            make_call("echo", r#"{"message": "also ok"}"#),
        ];

        let results = executor.execute_tools(&calls, &cancel).await;
        assert_eq!(results.len(), 3);
        assert!(results[0].is_ok());
        assert!(results[1].is_err()); // Not found
        assert!(results[2].is_ok());
    }

    #[tokio::test]
    async fn execute_tools_cancelled_mid_batch() {
        let registry = make_registry_with_slow(5000);
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();
        let calls = vec![
            make_call("echo", r#"{"message": "first"}"#),
            make_call("slow", r#"{}"#), // This one will be running when cancelled
            make_call("echo", r#"{"message": "third"}"#), // Should not run
        ];

        let cancel_clone = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
            cancel_clone.cancel();
        });

        let results = executor.execute_tools(&calls, &cancel).await;
        // First should succeed, second cancelled, third may not run
        assert!(results[0].is_ok());
        // The remaining entries should be errors (cancelled)
        assert!(results.len() >= 2);
    }

    #[tokio::test]
    async fn execute_tools_empty_list() {
        let registry = make_registry();
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();

        let results = executor.execute_tools(&[], &cancel).await;
        assert!(results.is_empty());
    }

    // ── Tool Mode Enforcement Tests ──────────────────────────

    #[tokio::test]
    async fn execute_tool_blocked_by_read_only_mode() {
        use crate::fae_llm::tools::bash::BashTool;
        let mut reg = ToolRegistry::new(ToolMode::ReadOnly);
        reg.register(Arc::new(BashTool::new()));
        let registry = Arc::new(reg);
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();

        let call = make_call("bash", r#"{"command": "echo test"}"#);
        let result = executor.execute_tool(&call, &cancel).await;

        assert!(result.is_err());
        match result {
            Err(FaeLlmError::ToolExecutionError(msg)) => {
                assert!(msg.contains("blocked by current mode"));
                assert!(msg.contains("read-only"));
            }
            _ => unreachable!("expected ToolExecutionError with mode block message"),
        }
    }

    #[tokio::test]
    async fn execute_tool_allowed_in_full_mode() {
        use crate::fae_llm::tools::bash::BashTool;
        let mut reg = ToolRegistry::new(ToolMode::Full);
        reg.register(Arc::new(BashTool::new()));
        let registry = Arc::new(reg);
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();

        let call = make_call("bash", r#"{"command": "echo test"}"#);
        let result = executor.execute_tool(&call, &cancel).await;

        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn execute_tool_read_allowed_in_read_only() {
        use crate::fae_llm::tools::read::ReadTool;
        let mut reg = ToolRegistry::new(ToolMode::ReadOnly);
        reg.register(Arc::new(ReadTool::new()));
        let registry = Arc::new(reg);
        let executor = ToolExecutor::new(registry, 30);
        let cancel = CancellationToken::new();

        let call = make_call("read", r#"{"file_path": "/tmp/test.txt"}"#);
        let result = executor.execute_tool(&call, &cancel).await;

        // Will fail with file not found, but that's OK - we're testing mode enforcement
        // If it was blocked by mode, we'd get a different error
        if let Err(FaeLlmError::ToolExecutionError(msg)) = result {
            assert!(!msg.contains("blocked by current mode"));
        }
    }
}
