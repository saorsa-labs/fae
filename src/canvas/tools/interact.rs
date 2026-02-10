//! `canvas_interact` tool — report user interactions to the LLM.

use std::sync::{Arc, Mutex};

use canvas_mcp::tools::{InteractParams, Interaction};
use saorsa_agent::Tool;
use saorsa_agent::error::{Result as ToolResult, SaorsaAgentError};

use crate::canvas::registry::CanvasSessionRegistry;

/// Tool that reports user canvas interactions back to the LLM.
///
/// The LLM can use this to understand what the user touched, selected,
/// or spoke about in the canvas context.
pub struct CanvasInteractTool {
    registry: Arc<Mutex<CanvasSessionRegistry>>,
}

impl CanvasInteractTool {
    /// Create a new interact tool backed by the given session registry.
    pub fn new(registry: Arc<Mutex<CanvasSessionRegistry>>) -> Self {
        Self { registry }
    }
}

#[async_trait::async_trait]
impl Tool for CanvasInteractTool {
    fn name(&self) -> &str {
        "canvas_interact"
    }

    fn description(&self) -> &str {
        "Report a user interaction on the canvas (touch, voice command, or selection). \
         Returns an AI-friendly description of what the user interacted with."
    }

    fn input_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "Canvas session ID"
                },
                "interaction": {
                    "type": "object",
                    "description": "Interaction details",
                    "properties": {
                        "type": {
                            "type": "string",
                            "enum": ["Touch", "Voice", "Select"]
                        },
                        "data": {
                            "type": "object",
                            "description": "Interaction data (varies by type)"
                        }
                    },
                    "required": ["type", "data"]
                }
            },
            "required": ["session_id", "interaction"]
        })
    }

    async fn execute(&self, input: serde_json::Value) -> ToolResult<String> {
        let params: InteractParams = serde_json::from_value(input)
            .map_err(|e| SaorsaAgentError::Tool(format!("invalid canvas_interact params: {e}")))?;

        // Verify session exists.
        let registry = self
            .registry
            .lock()
            .map_err(|_| SaorsaAgentError::Tool("session registry lock poisoned".to_owned()))?;

        if registry.get(&params.session_id).is_none() {
            return Err(SaorsaAgentError::Tool(format!(
                "canvas session '{}' not found",
                params.session_id
            )));
        }

        let interpretation = interpret_interaction(&params.interaction);

        let response = serde_json::json!({
            "success": true,
            "session_id": params.session_id,
            "interpretation": interpretation,
        });

        serde_json::to_string(&response)
            .map_err(|e| SaorsaAgentError::Tool(format!("failed to serialize response: {e}")))
    }
}

/// Produce an AI-friendly description of the interaction.
fn interpret_interaction(interaction: &Interaction) -> serde_json::Value {
    match interaction {
        Interaction::Touch { x, y, element_id } => {
            serde_json::json!({
                "type": "touch",
                "location": { "x": x, "y": y },
                "element": element_id,
            })
        }
        Interaction::Voice {
            transcript,
            context_element,
        } => {
            serde_json::json!({
                "type": "voice",
                "transcript": transcript,
                "context_element": context_element,
            })
        }
        Interaction::Select { element_ids } => {
            serde_json::json!({
                "type": "selection",
                "element_ids": element_ids,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canvas::backend::CanvasBackend;
    use crate::canvas::session::CanvasSession;

    fn setup_registry(session_id: &str) -> Arc<Mutex<CanvasSessionRegistry>> {
        let mut reg = CanvasSessionRegistry::new();
        let session: Arc<Mutex<dyn CanvasBackend>> =
            Arc::new(Mutex::new(CanvasSession::new(session_id, 800.0, 600.0)));
        reg.register(session_id, session);
        Arc::new(Mutex::new(reg))
    }

    #[tokio::test]
    async fn test_interact_touch() {
        let reg = setup_registry("test");
        let tool = CanvasInteractTool::new(reg);

        let input = serde_json::json!({
            "session_id": "test",
            "interaction": {
                "type": "Touch",
                "data": { "x": 100.0, "y": 200.0, "element_id": "el-1" }
            }
        });

        let result = tool.execute(input).await;
        assert!(result.is_ok());
        let output: serde_json::Value =
            serde_json::from_str(&result.unwrap_or_default()).unwrap_or_default();
        assert_eq!(output["success"], true);
        assert_eq!(output["interpretation"]["type"], "touch");
    }

    #[tokio::test]
    async fn test_interact_voice() {
        let reg = setup_registry("test");
        let tool = CanvasInteractTool::new(reg);

        let input = serde_json::json!({
            "session_id": "test",
            "interaction": {
                "type": "Voice",
                "data": { "transcript": "zoom in on the chart" }
            }
        });

        let result = tool.execute(input).await;
        assert!(result.is_ok());
        let output: serde_json::Value =
            serde_json::from_str(&result.unwrap_or_default()).unwrap_or_default();
        assert_eq!(output["interpretation"]["type"], "voice");
        assert_eq!(
            output["interpretation"]["transcript"],
            "zoom in on the chart"
        );
    }

    #[tokio::test]
    async fn test_interact_select() {
        let reg = setup_registry("test");
        let tool = CanvasInteractTool::new(reg);

        let input = serde_json::json!({
            "session_id": "test",
            "interaction": {
                "type": "Select",
                "data": { "element_ids": ["el-1", "el-2"] }
            }
        });

        let result = tool.execute(input).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_interact_missing_session() {
        let reg = setup_registry("test");
        let tool = CanvasInteractTool::new(reg);

        let input = serde_json::json!({
            "session_id": "gone",
            "interaction": {
                "type": "Touch",
                "data": { "x": 0.0, "y": 0.0 }
            }
        });

        let result = tool.execute(input).await;
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("not found"));
    }

    #[tokio::test]
    async fn test_interact_invalid_json() {
        let reg = setup_registry("test");
        let tool = CanvasInteractTool::new(reg);

        let input = serde_json::json!({ "bad": "input" });
        let result = tool.execute(input).await;
        assert!(result.is_err());
    }

    #[test]
    fn test_tool_metadata() {
        let reg = Arc::new(Mutex::new(CanvasSessionRegistry::new()));
        let tool = CanvasInteractTool::new(reg);
        assert_eq!(tool.name(), "canvas_interact");
        assert!(!tool.description().is_empty());
    }
}
