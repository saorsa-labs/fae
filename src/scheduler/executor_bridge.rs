//! Scheduler→conversation bridge.
//!
//! Provides [`TaskExecutorBridge`] which implements the [`TaskExecutor`](super::runner::TaskExecutor)
//! callback to connect scheduled tasks to the conversation pipeline.

use crate::pipeline::messages::ConversationRequest;
use crate::scheduler::tasks::{ConversationTrigger, ScheduledTask, TaskResult};
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, warn};

/// Bridges scheduler task execution to the conversation pipeline.
///
/// When a scheduled task with a [`ConversationTrigger`] payload executes,
/// this bridge parses the payload and sends a conversation request to the
/// pipeline via an mpsc channel.
pub struct TaskExecutorBridge {
    /// Channel for sending conversation requests to the pipeline.
    request_tx: mpsc::UnboundedSender<ConversationRequest>,
}

impl TaskExecutorBridge {
    /// Create a new executor bridge with the given request channel.
    pub fn new(request_tx: mpsc::UnboundedSender<ConversationRequest>) -> Self {
        Self { request_tx }
    }

    /// Convert this bridge into a boxed `TaskExecutor` callback.
    ///
    /// The returned callback can be passed to [`Scheduler::with_executor`](super::runner::Scheduler::with_executor).
    pub fn into_executor(self) -> Box<dyn Fn(&ScheduledTask) -> TaskResult + Send + Sync> {
        Box::new(move |task: &ScheduledTask| -> TaskResult {
            debug!("TaskExecutorBridge executing task: {}", task.id);

            // Parse conversation trigger from task payload
            let trigger = match ConversationTrigger::from_task_payload(&task.payload) {
                Ok(t) => t,
                Err(e) => {
                    warn!(
                        "Failed to parse ConversationTrigger from task {}: {e}",
                        task.id
                    );
                    return TaskResult::Error(format!("Invalid conversation payload: {e}"));
                }
            };

            // Create oneshot channel for response
            let (response_tx, response_rx) = oneshot::channel();

            // Build conversation request
            let request = ConversationRequest {
                task_id: task.id.clone(),
                prompt: trigger.prompt.clone(),
                system_addon: trigger.system_addon.clone(),
                response_tx,
            };

            // Send request to pipeline
            if self.request_tx.send(request).is_err() {
                warn!(
                    "Failed to send ConversationRequest for task {}: channel closed",
                    task.id
                );
                return TaskResult::Error("Conversation channel closed".to_owned());
            }

            debug!(
                "ConversationRequest sent for task {}, waiting for response",
                task.id
            );

            // Wait for response from conversation handler
            // We need to block on an async operation from a sync context.
            // The scheduler runner calls this from a tokio::task::spawn_blocking context,
            // so we can safely use block_on here.
            let response = match tokio::runtime::Handle::try_current() {
                Ok(_handle) => {
                    // We're inside a tokio runtime. Since the scheduler spawns task execution
                    // in spawn_blocking, we create a new runtime to avoid blocking issues.
                    match tokio::runtime::Runtime::new() {
                        Ok(rt) => match rt.block_on(response_rx) {
                            Ok(resp) => resp,
                            Err(_) => {
                                warn!(
                                    "ConversationRequest response channel closed for task {}",
                                    task.id
                                );
                                return TaskResult::Error("Response channel closed".to_owned());
                            }
                        },
                        Err(e) => {
                            warn!("Failed to create runtime for task {}: {e}", task.id);
                            return TaskResult::Error(format!("Runtime creation failed: {e}"));
                        }
                    }
                }
                Err(_) => {
                    // No tokio runtime - create one
                    match tokio::runtime::Runtime::new() {
                        Ok(rt) => match rt.block_on(response_rx) {
                            Ok(resp) => resp,
                            Err(_) => {
                                warn!(
                                    "ConversationRequest response channel closed for task {}",
                                    task.id
                                );
                                return TaskResult::Error("Response channel closed".to_owned());
                            }
                        },
                        Err(e) => {
                            warn!("Failed to create runtime for task {}: {e}", task.id);
                            return TaskResult::Error(format!("Runtime creation failed: {e}"));
                        }
                    }
                }
            };

            // Map ConversationResponse to TaskResult
            match response {
                crate::pipeline::messages::ConversationResponse::Success(text) => {
                    debug!("Task {} completed successfully: {}", task.id, text);
                    TaskResult::Success(text)
                }
                crate::pipeline::messages::ConversationResponse::Error(err) => {
                    warn!("Task {} failed: {}", task.id, err);
                    TaskResult::Error(err)
                }
                crate::pipeline::messages::ConversationResponse::Timeout => {
                    warn!("Task {} timed out", task.id);
                    TaskResult::Error("Conversation timed out".to_owned())
                }
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scheduler::tasks::Schedule;

    #[test]
    fn executor_bridge_created() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let bridge = TaskExecutorBridge::new(tx);
        assert!(
            std::ptr::addr_of!(bridge.request_tx).is_aligned(),
            "Bridge should be created"
        );
    }

    #[test]
    fn executor_bridge_into_executor() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let bridge = TaskExecutorBridge::new(tx);
        let _executor = bridge.into_executor();
        // Successfully converted to executor callback
    }

    #[test]
    fn executor_parses_valid_payload_and_sends_request() {
        // Create a new runtime for this test
        let rt = tokio::runtime::Runtime::new().expect("create runtime");

        // Run the test logic in the runtime
        rt.block_on(async {
            let (tx, mut rx) = mpsc::unbounded_channel();
            let bridge = TaskExecutorBridge::new(tx);
            let executor = bridge.into_executor();

            // Create task with valid ConversationTrigger payload
            let trigger = ConversationTrigger::new("Test prompt")
                .with_system_addon("Test addon")
                .with_timeout_secs(60);
            let payload = trigger.to_json().expect("to_json");

            let mut task =
                ScheduledTask::new("test_task", "Test Task", Schedule::Interval { secs: 3600 });
            task.payload = Some(payload);

            // Spawn a task to respond to the conversation request
            tokio::spawn(async move {
                if let Some(request) = rx.recv().await {
                    // Validate the request
                    assert_eq!(request.task_id, "test_task");
                    assert_eq!(request.prompt, "Test prompt");
                    match request.system_addon {
                        Some(ref addon) => assert_eq!(addon, "Test addon"),
                        None => panic!("Expected system_addon"),
                    }

                    // Send success response
                    let _ = request.response_tx.send(
                        crate::pipeline::messages::ConversationResponse::Success(
                            "Test response".to_owned(),
                        ),
                    );
                }
            });

            // Execute task in a spawn_blocking (simulating scheduler behavior)
            let result = tokio::task::spawn_blocking(move || executor(&task))
                .await
                .expect("spawn_blocking failed");

            // Should return success
            match result {
                TaskResult::Success(msg) => {
                    assert!(
                        msg.contains("Test response"),
                        "Expected response text, got: {msg}"
                    );
                }
                other => panic!("Expected Success, got: {other:?}"),
            }
        });
    }

    #[test]
    fn executor_handles_missing_payload() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let bridge = TaskExecutorBridge::new(tx);
        let executor = bridge.into_executor();

        // Create task with no payload
        let task = ScheduledTask::new("no_payload", "No Payload", Schedule::Interval { secs: 60 });

        // Execute task
        let result = executor(&task);

        // Should return error
        match result {
            TaskResult::Error(msg) => {
                assert!(
                    msg.contains("Invalid") || msg.contains("missing"),
                    "Expected error about missing payload: {msg}"
                );
            }
            other => panic!("Expected Error, got: {other:?}"),
        }

        // Should NOT have sent request
        assert!(
            rx.try_recv().is_err(),
            "Should not send request for missing payload"
        );
    }

    #[test]
    fn executor_handles_invalid_payload() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let bridge = TaskExecutorBridge::new(tx);
        let executor = bridge.into_executor();

        // Create task with invalid payload
        let mut task = ScheduledTask::new(
            "bad_payload",
            "Bad Payload",
            Schedule::Interval { secs: 60 },
        );
        task.payload = Some(serde_json::json!({
            "invalid_field": "no prompt field"
        }));

        // Execute task
        let result = executor(&task);

        // Should return error
        match result {
            TaskResult::Error(msg) => {
                assert!(
                    msg.contains("Invalid"),
                    "Expected error about invalid payload: {msg}"
                );
            }
            other => panic!("Expected Error, got: {other:?}"),
        }

        // Should NOT have sent request
        assert!(
            rx.try_recv().is_err(),
            "Should not send request for invalid payload"
        );
    }

    #[test]
    fn executor_handles_channel_closed() {
        let (tx, rx) = mpsc::unbounded_channel();
        drop(rx); // Close receiver

        let bridge = TaskExecutorBridge::new(tx);
        let executor = bridge.into_executor();

        // Create task with valid payload
        let trigger = ConversationTrigger::new("Test");
        let payload = trigger.to_json().expect("to_json");

        let mut task = ScheduledTask::new("test", "Test", Schedule::Interval { secs: 60 });
        task.payload = Some(payload);

        // Execute task
        let result = executor(&task);

        // Should return error about channel closed
        match result {
            TaskResult::Error(msg) => {
                assert!(
                    msg.contains("closed"),
                    "Expected error about closed channel: {msg}"
                );
            }
            other => panic!("Expected Error for closed channel, got: {other:?}"),
        }
    }

    // -----------------------------------------------------------------------
    // Integration tests
    // -----------------------------------------------------------------------

    #[test]
    fn full_workflow_scheduled_task_to_conversation_response() {
        let rt = tokio::runtime::Runtime::new().expect("create runtime");

        rt.block_on(async {
            let (tx, mut rx) = mpsc::unbounded_channel();
            let bridge = TaskExecutorBridge::new(tx);
            let executor = bridge.into_executor();

            // Create a scheduled task with conversation trigger
            let trigger = ConversationTrigger::new("What is 2+2?")
                .with_system_addon("You are a helpful calculator")
                .with_timeout_secs(60);
            let payload = trigger.to_json().expect("serialize trigger");

            let mut task = ScheduledTask::user_task(
                "calc_task",
                "Calculator Task",
                Schedule::Interval { secs: 3600 },
            );
            task.payload = Some(payload);

            // Spawn conversation handler (simulates the runtime handler)
            tokio::spawn(async move {
                if let Some(request) = rx.recv().await {
                    // Validate request fields
                    assert_eq!(request.task_id, "calc_task");
                    assert_eq!(request.prompt, "What is 2+2?");
                    assert_eq!(
                        request.system_addon,
                        Some("You are a helpful calculator".to_owned())
                    );

                    // Simulate successful conversation
                    let _ = request.response_tx.send(
                        crate::pipeline::messages::ConversationResponse::Success(
                            "The answer is 4.".to_owned(),
                        ),
                    );
                }
            });

            // Execute task (this blocks until response received)
            let result = tokio::task::spawn_blocking(move || executor(&task))
                .await
                .expect("spawn_blocking failed");

            // Verify result
            match result {
                TaskResult::Success(text) => {
                    assert_eq!(text, "The answer is 4.");
                }
                other => panic!("Expected Success, got: {other:?}"),
            }
        });
    }

    #[test]
    fn full_workflow_conversation_error_propagates() {
        let rt = tokio::runtime::Runtime::new().expect("create runtime");

        rt.block_on(async {
            let (tx, mut rx) = mpsc::unbounded_channel();
            let bridge = TaskExecutorBridge::new(tx);
            let executor = bridge.into_executor();

            // Create task
            let trigger = ConversationTrigger::new("Trigger error");
            let payload = trigger.to_json().expect("serialize trigger");

            let mut task = ScheduledTask::user_task(
                "error_task",
                "Error Task",
                Schedule::Interval { secs: 3600 },
            );
            task.payload = Some(payload);

            // Spawn handler that returns error
            tokio::spawn(async move {
                if let Some(request) = rx.recv().await {
                    let _ = request.response_tx.send(
                        crate::pipeline::messages::ConversationResponse::Error(
                            "LLM connection failed".to_owned(),
                        ),
                    );
                }
            });

            // Execute task
            let result = tokio::task::spawn_blocking(move || executor(&task))
                .await
                .expect("spawn_blocking failed");

            // Verify error propagates
            match result {
                TaskResult::Error(msg) => {
                    assert_eq!(msg, "LLM connection failed");
                }
                other => panic!("Expected Error, got: {other:?}"),
            }
        });
    }

    #[test]
    fn full_workflow_conversation_timeout_propagates() {
        let rt = tokio::runtime::Runtime::new().expect("create runtime");

        rt.block_on(async {
            let (tx, mut rx) = mpsc::unbounded_channel();
            let bridge = TaskExecutorBridge::new(tx);
            let executor = bridge.into_executor();

            // Create task
            let trigger = ConversationTrigger::new("Trigger timeout");
            let payload = trigger.to_json().expect("serialize trigger");

            let mut task = ScheduledTask::user_task(
                "timeout_task",
                "Timeout Task",
                Schedule::Interval { secs: 3600 },
            );
            task.payload = Some(payload);

            // Spawn handler that returns timeout
            tokio::spawn(async move {
                if let Some(request) = rx.recv().await {
                    let _ = request
                        .response_tx
                        .send(crate::pipeline::messages::ConversationResponse::Timeout);
                }
            });

            // Execute task
            let result = tokio::task::spawn_blocking(move || executor(&task))
                .await
                .expect("spawn_blocking failed");

            // Verify timeout propagates as error
            match result {
                TaskResult::Error(msg) => {
                    assert!(
                        msg.contains("timed out"),
                        "Expected timeout error, got: {msg}"
                    );
                }
                other => panic!("Expected Error for timeout, got: {other:?}"),
            }
        });
    }

    #[test]
    fn executor_handles_minimal_trigger() {
        let rt = tokio::runtime::Runtime::new().expect("create runtime");

        rt.block_on(async {
            let (tx, mut rx) = mpsc::unbounded_channel();
            let bridge = TaskExecutorBridge::new(tx);
            let executor = bridge.into_executor();

            // Create task with minimal trigger (no addon, no timeout)
            let trigger = ConversationTrigger::new("Minimal prompt");
            let payload = trigger.to_json().expect("to_json");

            let mut task =
                ScheduledTask::new("minimal", "Minimal", Schedule::Interval { secs: 60 });
            task.payload = Some(payload);

            // Spawn a task to respond
            tokio::spawn(async move {
                if let Some(request) = rx.recv().await {
                    assert_eq!(request.prompt, "Minimal prompt");
                    assert!(request.system_addon.is_none());

                    // Send success response
                    let _ = request.response_tx.send(
                        crate::pipeline::messages::ConversationResponse::Success(
                            "Minimal response".to_owned(),
                        ),
                    );
                }
            });

            // Execute task in spawn_blocking
            let result = tokio::task::spawn_blocking(move || executor(&task))
                .await
                .expect("spawn_blocking failed");

            // Should return success
            match result {
                TaskResult::Success(_) => {}
                other => panic!("Expected Success, got: {other:?}"),
            }
        });
    }
}
