//! `canvas_export` tool — export a canvas session to an image/PDF format.

use std::sync::{Arc, Mutex};

use canvas_mcp::tools::{ExportFormat, ExportParams};
use saorsa_agent::Tool;
use saorsa_agent::error::{Result as ToolResult, SaorsaAgentError};

use crate::canvas::registry::CanvasSessionRegistry;

/// Tool that exports a canvas session to an image or document format.
///
/// Currently returns a placeholder response with the format metadata.
/// Actual rendering will be implemented in Phase 2.2 (Content Renderers).
pub struct CanvasExportTool {
    registry: Arc<Mutex<CanvasSessionRegistry>>,
}

impl CanvasExportTool {
    /// Create a new export tool backed by the given session registry.
    pub fn new(registry: Arc<Mutex<CanvasSessionRegistry>>) -> Self {
        Self { registry }
    }
}

#[async_trait::async_trait]
impl Tool for CanvasExportTool {
    fn name(&self) -> &str {
        "canvas_export"
    }

    fn description(&self) -> &str {
        "Export a canvas session to an image or document format (PNG, JPEG, SVG, PDF, WebP). \
         Returns metadata about the export."
    }

    fn input_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "Canvas session ID to export"
                },
                "format": {
                    "type": "string",
                    "enum": ["png", "jpeg", "svg", "pdf", "webp"],
                    "description": "Export format"
                },
                "quality": {
                    "type": "integer",
                    "description": "Quality 0-100 for lossy formats (default: 90)",
                    "minimum": 0,
                    "maximum": 100
                }
            },
            "required": ["session_id", "format"]
        })
    }

    async fn execute(&self, input: serde_json::Value) -> ToolResult<String> {
        let params: ExportParams = serde_json::from_value(input)
            .map_err(|e| SaorsaAgentError::Tool(format!("invalid canvas_export params: {e}")))?;

        // Verify session exists and get element count.
        let registry = self
            .registry
            .lock()
            .map_err(|_| SaorsaAgentError::Tool("session registry lock poisoned".to_owned()))?;

        let session_arc = registry.get(&params.session_id).ok_or_else(|| {
            SaorsaAgentError::Tool(format!("canvas session '{}' not found", params.session_id))
        })?;

        let session = session_arc
            .lock()
            .map_err(|_| SaorsaAgentError::Tool("session lock poisoned".to_owned()))?;

        let element_count = session.scene().element_count();

        let mime_type = format_mime_type(params.format);

        let response = serde_json::json!({
            "success": true,
            "session_id": params.session_id,
            "format": mime_type,
            "quality": params.quality,
            "element_count": element_count,
            "note": "Export rendering not yet implemented — metadata only",
        });

        serde_json::to_string(&response)
            .map_err(|e| SaorsaAgentError::Tool(format!("failed to serialize response: {e}")))
    }
}

/// Map export format to MIME type string.
fn format_mime_type(format: ExportFormat) -> &'static str {
    match format {
        ExportFormat::Png => "image/png",
        ExportFormat::Jpeg => "image/jpeg",
        ExportFormat::Svg => "image/svg+xml",
        ExportFormat::Pdf => "application/pdf",
        ExportFormat::WebP => "image/webp",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canvas::session::CanvasSession;

    fn setup_registry(session_id: &str) -> Arc<Mutex<CanvasSessionRegistry>> {
        let mut reg = CanvasSessionRegistry::new();
        let session = Arc::new(Mutex::new(CanvasSession::new(session_id, 800.0, 600.0)));
        reg.register(session_id, session);
        Arc::new(Mutex::new(reg))
    }

    #[tokio::test]
    async fn test_export_png() {
        let reg = setup_registry("test");
        let tool = CanvasExportTool::new(reg);

        let input = serde_json::json!({
            "session_id": "test",
            "format": "png",
            "quality": 95
        });

        let result = tool.execute(input).await;
        assert!(result.is_ok());
        let output: serde_json::Value =
            serde_json::from_str(&result.unwrap_or_default()).unwrap_or_default();
        assert_eq!(output["success"], true);
        assert_eq!(output["format"], "image/png");
        assert_eq!(output["quality"], 95);
    }

    #[tokio::test]
    async fn test_export_svg() {
        let reg = setup_registry("test");
        let tool = CanvasExportTool::new(reg);

        let input = serde_json::json!({
            "session_id": "test",
            "format": "svg"
        });

        let result = tool.execute(input).await;
        assert!(result.is_ok());
        let output: serde_json::Value =
            serde_json::from_str(&result.unwrap_or_default()).unwrap_or_default();
        assert_eq!(output["format"], "image/svg+xml");
    }

    #[tokio::test]
    async fn test_export_missing_session() {
        let reg = setup_registry("test");
        let tool = CanvasExportTool::new(reg);

        let input = serde_json::json!({
            "session_id": "gone",
            "format": "png"
        });

        let result = tool.execute(input).await;
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("not found"));
    }

    #[tokio::test]
    async fn test_export_invalid_json() {
        let reg = setup_registry("test");
        let tool = CanvasExportTool::new(reg);

        let input = serde_json::json!({ "bad": true });
        let result = tool.execute(input).await;
        assert!(result.is_err());
    }

    #[test]
    fn test_tool_metadata() {
        let reg = Arc::new(Mutex::new(CanvasSessionRegistry::new()));
        let tool = CanvasExportTool::new(reg);
        assert_eq!(tool.name(), "canvas_export");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn test_format_mime_types() {
        assert_eq!(format_mime_type(ExportFormat::Png), "image/png");
        assert_eq!(format_mime_type(ExportFormat::Jpeg), "image/jpeg");
        assert_eq!(format_mime_type(ExportFormat::Svg), "image/svg+xml");
        assert_eq!(format_mime_type(ExportFormat::Pdf), "application/pdf");
        assert_eq!(format_mime_type(ExportFormat::WebP), "image/webp");
    }
}
