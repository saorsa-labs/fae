//! Tool wrapper that gates execution behind an interactive approval.

use crate::approval::{ToolApprovalRequest, ToolApprovalResponse};
use saorsa_agent::Tool;
use saorsa_agent::error::{Result as ToolResult, SaorsaAgentError};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

static NEXT_APPROVAL_ID: AtomicU64 = AtomicU64::new(1);

pub struct ApprovalTool {
    inner: Box<dyn Tool>,
    approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
    timeout: Duration,
}

impl ApprovalTool {
    pub fn new(
        inner: Box<dyn Tool>,
        approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
        timeout: Duration,
    ) -> Self {
        Self {
            inner,
            approval_tx,
            timeout,
        }
    }

    fn next_id() -> u64 {
        NEXT_APPROVAL_ID.fetch_add(1, Ordering::Relaxed)
    }
}

#[async_trait::async_trait]
impl Tool for ApprovalTool {
    fn name(&self) -> &str {
        self.inner.name()
    }

    fn description(&self) -> &str {
        self.inner.description()
    }

    fn input_schema(&self) -> serde_json::Value {
        self.inner.input_schema()
    }

    async fn execute(&self, input: serde_json::Value) -> ToolResult<String> {
        let Some(approval_tx) = &self.approval_tx else {
            // No interactive handler wired up; run normally (CLI/dev usage).
            return self.inner.execute(input).await;
        };

        let (respond_to, response_rx) = oneshot::channel::<ToolApprovalResponse>();
        let id = Self::next_id();
        let name = self.inner.name().to_owned();
        let input_json = match serde_json::to_string(&input) {
            Ok(s) => s,
            Err(e) => format!("{{\"_error\":\"failed to serialize tool input: {e}\"}}"),
        };

        let req = ToolApprovalRequest::new(id, name, input_json, respond_to);
        if approval_tx.send(req).is_err() {
            return Err(SaorsaAgentError::Tool(
                "tool approval handler is unavailable".to_owned(),
            ));
        }

        match tokio::time::timeout(self.timeout, response_rx).await {
            Ok(Ok(resp)) if resp.is_approved() => self.inner.execute(input).await,
            Ok(Ok(_)) => Err(SaorsaAgentError::Tool(
                "tool call denied by user".to_owned(),
            )),
            Ok(Err(_)) => Err(SaorsaAgentError::Tool(
                "tool approval response channel closed".to_owned(),
            )),
            Err(_) => Err(SaorsaAgentError::Tool("tool approval timed out".to_owned())),
        }
    }
}
