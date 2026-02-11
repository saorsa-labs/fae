//! Agent tool that delegates coding tasks to Pi via RPC.
//!
//! Registers as `pi_delegate` in the agent tool registry, allowing Fae's
//! LLM to invoke Pi for coding, file editing, and research tasks.

use crate::pi::session::{PiAgentEvent, PiOutput, PiSession};
use saorsa_agent::Tool;
use saorsa_agent::error::{Result as ToolResult, SaorsaAgentError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Maximum time to wait for Pi to complete a task before timing out.
const PI_TASK_TIMEOUT: Duration = Duration::from_secs(300); // 5 minutes

/// Agent tool that delegates tasks to the Pi coding agent.
///
/// When invoked, sends the task description to Pi via its RPC session
/// and returns the accumulated response text. Includes a 5-minute timeout
/// to prevent indefinite blocking if Pi hangs.
pub struct PiDelegateTool {
    session: Arc<Mutex<PiSession>>,
}

impl PiDelegateTool {
    /// Create a new `PiDelegateTool` with a shared Pi session.
    pub fn new(session: Arc<Mutex<PiSession>>) -> Self {
        Self { session }
    }
}

#[async_trait::async_trait]
impl Tool for PiDelegateTool {
    fn name(&self) -> &str {
        "pi_delegate"
    }

    fn description(&self) -> &str {
        "Delegate a coding task to the Pi coding agent. Pi can read files, \
         edit code, run shell commands, and perform research. Use this for \
         tasks that require writing or modifying code, running tests, \
         editing configuration files, or performing multi-step development work."
    }

    fn input_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "task": {
                    "type": "string",
                    "description": "Description of the coding task for Pi to execute"
                },
                "working_directory": {
                    "type": "string",
                    "description": "Optional working directory for the task (defaults to current directory)"
                }
            },
            "required": ["task"]
        })
    }

    async fn execute(&self, input: serde_json::Value) -> ToolResult<String> {
        let task = input["task"]
            .as_str()
            .ok_or_else(|| SaorsaAgentError::Tool("missing 'task' field".to_owned()))?;

        // Build the prompt, optionally prefixing with working directory context.
        let working_dir = input["working_directory"].as_str();
        let prompt = match working_dir {
            Some(dir) if !dir.is_empty() => format!("Working directory: {dir}\n\n{task}"),
            _ => task.to_owned(),
        };

        // Clone session Arc for the async block.
        let session = Arc::clone(&self.session);

        // Run the task in a blocking context since PiSession uses sync I/O.
        tokio::task::spawn_blocking(move || {
            let mut guard = session
                .lock()
                .map_err(|e| SaorsaAgentError::Tool(format!("Pi session lock poisoned: {e}")))?;

            // Ensure Pi is spawned.
            guard
                .spawn()
                .map_err(|e| SaorsaAgentError::Tool(format!("failed to spawn Pi: {e}")))?;

            // Send prompt.
            guard
                .send_prompt(&prompt)
                .map_err(|e| SaorsaAgentError::Tool(format!("failed to send prompt to Pi: {e}")))?;

            // Collect response text until AgentEnd, with timeout.
            let mut text = String::new();
            let mut delta_buffer = String::new();
            let deadline = Instant::now() + PI_TASK_TIMEOUT;

            loop {
                if Instant::now() > deadline {
                    // Abort the hanging task and shut down the session.
                    let _ = guard.send_abort();
                    guard.shutdown();
                    return Err(SaorsaAgentError::Tool(format!(
                        "Pi task timed out after {} seconds",
                        PI_TASK_TIMEOUT.as_secs()
                    )));
                }

                let event = match guard.try_recv() {
                    Some(ev) => ev,
                    None => {
                        // Brief sleep to avoid busy-waiting.
                        std::thread::sleep(Duration::from_millis(50));
                        continue;
                    }
                };

                match event {
                    PiOutput::Event(PiAgentEvent::MessageStart { message }) => {
                        if message.get("role").and_then(|v| v.as_str()) == Some("assistant") {
                            delta_buffer.clear();
                        }
                    }
                    PiOutput::Event(PiAgentEvent::MessageUpdate {
                        message,
                        assistant_message_event,
                    }) => {
                        if message.get("role").and_then(|v| v.as_str()) != Some("assistant") {
                            continue;
                        }
                        // Extract monotonic text chunks from the event stream.
                        let evt_type = assistant_message_event
                            .get("type")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if evt_type != "text_delta"
                            && evt_type != "text_start"
                            && evt_type != "text_end"
                        {
                            continue;
                        }

                        let delta = assistant_message_event
                            .get("delta")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let content = assistant_message_event
                            .get("content")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");

                        let mut chunk = String::new();
                        if !delta.is_empty() {
                            chunk.push_str(delta);
                        } else if !content.is_empty() {
                            // Some providers resend full content on `text_end`.
                            if let Some(stripped) = content.strip_prefix(&delta_buffer) {
                                chunk.push_str(stripped);
                            } else if delta_buffer.starts_with(content) {
                                // Late/duplicate end event.
                            } else if !delta_buffer.contains(content) {
                                chunk.push_str(content);
                            }
                        }

                        if !chunk.is_empty() {
                            delta_buffer.push_str(&chunk);
                            text.push_str(&chunk);
                        }
                    }
                    PiOutput::Event(PiAgentEvent::AgentEnd { .. }) => break,
                    PiOutput::ProcessExited => {
                        return Err(SaorsaAgentError::Tool(
                            "Pi process exited during task".to_owned(),
                        ));
                    }
                    PiOutput::ExtensionUiRequest(req) => {
                        // Delegate tool has no interactive UI; fail safe by cancelling.
                        let _ = guard.send_ui_cancel(req.id());
                    }
                    _ => {}
                }
            }

            Ok(text)
        })
        .await
        .map_err(|e| SaorsaAgentError::Tool(format!("Pi task thread panicked: {e}")))?
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use std::path::PathBuf;

    fn make_tool() -> PiDelegateTool {
        let session = Arc::new(Mutex::new(PiSession::new(
            PathBuf::from("/usr/local/bin/pi"),
            "fae-local".to_owned(),
            "fae-qwen3".to_owned(),
        )));
        PiDelegateTool::new(session)
    }

    #[test]
    fn tool_name_and_description() {
        let tool = make_tool();
        assert_eq!(tool.name(), "pi_delegate");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn tool_input_schema_has_task_field() {
        let tool = make_tool();
        let schema = tool.input_schema();
        assert_eq!(schema["properties"]["task"]["type"], "string");
        let required = schema["required"].as_array().unwrap();
        assert!(required.iter().any(|v| v.as_str() == Some("task")));
    }

    #[test]
    fn tool_input_schema_has_working_directory_field() {
        let tool = make_tool();
        let schema = tool.input_schema();
        assert_eq!(
            schema["properties"]["working_directory"]["type"], "string",
            "schema should define working_directory as a string"
        );
    }

    #[test]
    fn timeout_constant_is_reasonable() {
        // Timeout should be between 1 minute and 30 minutes.
        assert!(
            PI_TASK_TIMEOUT >= Duration::from_secs(60),
            "timeout too short: {:?}",
            PI_TASK_TIMEOUT
        );
        assert!(
            PI_TASK_TIMEOUT <= Duration::from_secs(1800),
            "timeout too long: {:?}",
            PI_TASK_TIMEOUT
        );
    }
}
