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
            let (response_tx, _response_rx) = oneshot::channel();

            // Build conversation request
            let request = ConversationRequest {
                task_id: task.id.clone(),
                prompt: trigger.prompt.clone(),
                system_addon: trigger.system_addon.clone(),
                response_tx,
            };

            // Send request to pipeline
            match self.request_tx.send(request) {
                Ok(()) => {
                    debug!("ConversationRequest sent for task {}", task.id);
                    // For now, return success immediately. Later tasks will handle
                    // waiting for the response and capturing the result.
                    TaskResult::Success(format!("Conversation triggered: {}", trigger.prompt))
                }
                Err(_) => {
                    warn!(
                        "Failed to send ConversationRequest for task {}: channel closed",
                        task.id
                    );
                    TaskResult::Error("Conversation channel closed".to_owned())
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

        // Execute task
        let result = executor(&task);

        // Should return success
        match result {
            TaskResult::Success(msg) => {
                assert!(
                    msg.contains("Conversation triggered"),
                    "Expected success message"
                );
            }
            other => panic!("Expected Success, got: {other:?}"),
        }

        // Should have sent request
        let request = rx.try_recv().expect("Should have sent request");
        assert_eq!(request.task_id, "test_task");
        assert_eq!(request.prompt, "Test prompt");
        match request.system_addon {
            Some(ref addon) => assert_eq!(addon, "Test addon"),
            None => panic!("Expected system_addon"),
        }
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

    #[test]
    fn executor_handles_minimal_trigger() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let bridge = TaskExecutorBridge::new(tx);
        let executor = bridge.into_executor();

        // Create task with minimal trigger (no addon, no timeout)
        let trigger = ConversationTrigger::new("Minimal prompt");
        let payload = trigger.to_json().expect("to_json");

        let mut task = ScheduledTask::new("minimal", "Minimal", Schedule::Interval { secs: 60 });
        task.payload = Some(payload);

        // Execute task
        let result = executor(&task);

        // Should return success
        match result {
            TaskResult::Success(_) => {}
            other => panic!("Expected Success, got: {other:?}"),
        }

        // Should have sent request with no addon
        let request = rx.try_recv().expect("Should have sent request");
        assert_eq!(request.prompt, "Minimal prompt");
        assert!(request.system_addon.is_none());
    }
}
