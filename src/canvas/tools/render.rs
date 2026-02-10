//! `canvas_render` tool — push content to a canvas session.

use std::sync::{Arc, Mutex};

use canvas_core::{Element, ElementKind, ImageFormat, Transform};
use canvas_mcp::tools::{RenderContent, RenderParams};
use saorsa_agent::Tool;
use saorsa_agent::error::{Result as ToolResult, SaorsaAgentError};

use crate::canvas::registry::CanvasSessionRegistry;

/// Tool that renders content to a canvas session.
///
/// The LLM calls this to push charts, images, 3D models, or text annotations
/// into the active canvas.
pub struct CanvasRenderTool {
    registry: Arc<Mutex<CanvasSessionRegistry>>,
}

impl CanvasRenderTool {
    /// Create a new render tool backed by the given session registry.
    pub fn new(registry: Arc<Mutex<CanvasSessionRegistry>>) -> Self {
        Self { registry }
    }
}

#[async_trait::async_trait]
impl Tool for CanvasRenderTool {
    fn name(&self) -> &str {
        "canvas_render"
    }

    fn description(&self) -> &str {
        "Render content (chart, image, 3D model, or text) to a canvas session. \
         Returns the element ID of the rendered content."
    }

    fn input_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "Canvas session ID to render into"
                },
                "content": {
                    "type": "object",
                    "description": "Content to render",
                    "properties": {
                        "type": {
                            "type": "string",
                            "enum": ["Chart", "Image", "Model3D", "Text"]
                        },
                        "data": {
                            "type": "object",
                            "description": "Content data (varies by type)"
                        }
                    },
                    "required": ["type", "data"]
                },
                "position": {
                    "type": "object",
                    "description": "Optional position (x, y, width, height)",
                    "properties": {
                        "x": { "type": "number" },
                        "y": { "type": "number" },
                        "width": { "type": "number" },
                        "height": { "type": "number" }
                    },
                    "required": ["x", "y"]
                }
            },
            "required": ["session_id", "content"]
        })
    }

    async fn execute(&self, input: serde_json::Value) -> ToolResult<String> {
        let params: RenderParams = serde_json::from_value(input)
            .map_err(|e| SaorsaAgentError::Tool(format!("invalid canvas_render params: {e}")))?;

        let element = render_content_to_element(&params);

        let registry = self
            .registry
            .lock()
            .map_err(|_| SaorsaAgentError::Tool("session registry lock poisoned".to_owned()))?;

        let session_arc = registry.get(&params.session_id).ok_or_else(|| {
            SaorsaAgentError::Tool(format!("canvas session '{}' not found", params.session_id))
        })?;

        let mut session = session_arc
            .lock()
            .map_err(|_| SaorsaAgentError::Tool("session lock poisoned".to_owned()))?;

        let element_id = session.add_element(element);

        let response = serde_json::json!({
            "success": true,
            "session_id": params.session_id,
            "element_id": element_id.to_string(),
        });

        serde_json::to_string(&response)
            .map_err(|e| SaorsaAgentError::Tool(format!("failed to serialize response: {e}")))
    }
}

/// Convert `RenderContent` + optional position into a canvas-core `Element`.
pub(crate) fn render_content_to_element(params: &RenderParams) -> Element {
    let kind = match &params.content {
        RenderContent::Chart {
            chart_type, data, ..
        } => ElementKind::Chart {
            chart_type: chart_type.clone(),
            data: data.clone(),
        },
        RenderContent::Image { src, .. } => ElementKind::Image {
            src: src.clone(),
            format: ImageFormat::Png,
        },
        RenderContent::Model3D { src, rotation } => ElementKind::Model3D {
            src: src.clone(),
            rotation: rotation.unwrap_or([0.0, 0.0, 0.0]),
            scale: 1.0,
        },
        RenderContent::Text { content, font_size } => ElementKind::Text {
            content: content.clone(),
            font_size: font_size.unwrap_or(14.0),
            color: "#FFFFFF".to_owned(),
        },
    };

    let transform = match &params.position {
        Some(pos) => Transform {
            x: pos.x,
            y: pos.y,
            width: pos.width.unwrap_or(400.0),
            height: pos.height.unwrap_or(300.0),
            rotation: 0.0,
            z_index: 0,
        },
        None => Transform::default(),
    };

    Element::new(kind).with_transform(transform)
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
    async fn test_render_text() {
        let reg = setup_registry("test");
        let tool = CanvasRenderTool::new(reg.clone());

        let input = serde_json::json!({
            "session_id": "test",
            "content": {
                "type": "Text",
                "data": {
                    "content": "Hello from tool",
                    "font_size": 16.0
                }
            }
        });

        let result = tool.execute(input).await;
        assert!(result.is_ok());
        let output: serde_json::Value =
            serde_json::from_str(&result.unwrap_or_default()).unwrap_or_default();
        assert_eq!(output["success"], true);
        assert!(output["element_id"].is_string());
    }

    #[tokio::test]
    async fn test_render_chart() {
        let reg = setup_registry("test");
        let tool = CanvasRenderTool::new(reg);

        let input = serde_json::json!({
            "session_id": "test",
            "content": {
                "type": "Chart",
                "data": {
                    "chart_type": "bar",
                    "data": {"values": [1, 2, 3]},
                    "title": "Test Chart"
                }
            },
            "position": { "x": 10.0, "y": 20.0, "width": 400.0, "height": 300.0 }
        });

        let result = tool.execute(input).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_render_image() {
        let reg = setup_registry("test");
        let tool = CanvasRenderTool::new(reg);

        let input = serde_json::json!({
            "session_id": "test",
            "content": {
                "type": "Image",
                "data": {
                    "src": "https://example.com/img.png",
                    "alt": "A test image"
                }
            }
        });

        let result = tool.execute(input).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_render_missing_session() {
        let reg = setup_registry("test");
        let tool = CanvasRenderTool::new(reg);

        let input = serde_json::json!({
            "session_id": "nonexistent",
            "content": {
                "type": "Text",
                "data": { "content": "oops" }
            }
        });

        let result = tool.execute(input).await;
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("not found"));
    }

    #[tokio::test]
    async fn test_render_invalid_json() {
        let reg = setup_registry("test");
        let tool = CanvasRenderTool::new(reg);

        let input = serde_json::json!({ "bad": "input" });
        let result = tool.execute(input).await;
        assert!(result.is_err());
    }

    #[test]
    fn test_tool_metadata() {
        let reg = Arc::new(Mutex::new(CanvasSessionRegistry::new()));
        let tool = CanvasRenderTool::new(reg);
        assert_eq!(tool.name(), "canvas_render");
        assert!(!tool.description().is_empty());
        assert!(tool.input_schema()["properties"]["session_id"].is_object());
    }
}
