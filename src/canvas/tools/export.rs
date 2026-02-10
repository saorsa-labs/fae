//! `canvas_export` tool — export a canvas session to an image/PDF format.
//!
//! For remote sessions (connected to a canvas-server), export is performed via
//! HTTP POST to `/api/export`. For local sessions, a scene snapshot is returned
//! as JSON metadata until the canvas-renderer export feature is published.

use std::io::Read as _;
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use canvas_mcp::tools::{ExportFormat, ExportParams};
use saorsa_agent::Tool;
use saorsa_agent::error::{Result as ToolResult, SaorsaAgentError};

use crate::canvas::backend::ConnectionStatus;
use crate::canvas::registry::CanvasSessionRegistry;

/// Tool that exports a canvas session to an image or document format.
///
/// Remote sessions export via HTTP POST to the canvas-server `/api/export`
/// endpoint. Local sessions return scene metadata until the `canvas-renderer`
/// export feature is available.
pub struct CanvasExportTool {
    registry: Arc<Mutex<CanvasSessionRegistry>>,
    /// Base URL for the canvas-server (e.g. `http://localhost:9473`).
    server_url: Option<String>,
}

impl CanvasExportTool {
    /// Create a new export tool backed by the given session registry.
    pub fn new(registry: Arc<Mutex<CanvasSessionRegistry>>) -> Self {
        Self {
            registry,
            server_url: None,
        }
    }

    /// Set the canvas-server base URL for remote exports.
    pub fn with_server_url(mut self, url: impl Into<String>) -> Self {
        self.server_url = Some(url.into());
        self
    }

    /// Export via the canvas-server HTTP API.
    fn export_remote(&self, params: &ExportParams) -> ToolResult<Vec<u8>> {
        let base_url = self.server_url.as_deref().ok_or_else(|| {
            SaorsaAgentError::Tool(
                "remote export requested but no canvas-server URL configured".to_owned(),
            )
        })?;

        let url = format!("{base_url}/api/export");
        let body = serde_json::json!({
            "session_id": params.session_id,
            "format": format_string(params.format),
            "quality": params.quality,
        });

        let response = ureq::post(&url)
            .send_json(body)
            .map_err(|e| SaorsaAgentError::Tool(format!("export HTTP request failed: {e}")))?;

        if response.status() >= 400 {
            let status = response.status();
            let body_text = response.into_string().unwrap_or_default();
            return Err(SaorsaAgentError::Tool(format!(
                "export failed with status {status}: {body_text}"
            )));
        }

        let mut bytes = Vec::new();
        response
            .into_reader()
            .read_to_end(&mut bytes)
            .map_err(|e| SaorsaAgentError::Tool(format!("failed to read export response: {e}")))?;

        Ok(bytes)
    }
}

#[async_trait::async_trait]
impl Tool for CanvasExportTool {
    fn name(&self) -> &str {
        "canvas_export"
    }

    fn description(&self) -> &str {
        "Export a canvas session to an image or document format (PNG, JPEG, SVG, PDF). \
         Returns base64-encoded data for remote sessions."
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
                    "enum": ["png", "jpeg", "svg", "pdf"],
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

        // Get session from registry.
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

        let status = session.connection_status();
        let element_count = session.element_count();
        let mime = format_mime_type(params.format);

        match status {
            ConnectionStatus::Connected | ConnectionStatus::Reconnecting { .. } => {
                // Drop locks before making HTTP call.
                drop(session);
                drop(registry);

                let data = self.export_remote(&params)?;
                let encoded =
                    base64::engine::general_purpose::STANDARD.encode(&data);

                let response = serde_json::json!({
                    "success": true,
                    "session_id": params.session_id,
                    "format": mime,
                    "size_bytes": data.len(),
                    "element_count": element_count,
                    "data": encoded,
                });

                serde_json::to_string(&response)
                    .map_err(|e| SaorsaAgentError::Tool(format!("serialize error: {e}")))
            }
            _ => {
                // Local session — no server available for export rendering.
                // Return metadata so the caller knows the session exists.
                let response = serde_json::json!({
                    "success": true,
                    "session_id": params.session_id,
                    "format": mime,
                    "quality": params.quality,
                    "element_count": element_count,
                    "note": "Local export via canvas-server not available. \
                             Connect to a canvas-server for image export.",
                });

                serde_json::to_string(&response)
                    .map_err(|e| SaorsaAgentError::Tool(format!("serialize error: {e}")))
            }
        }
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

/// Map export format to the string accepted by the canvas-server API.
fn format_string(format: ExportFormat) -> &'static str {
    match format {
        ExportFormat::Png => "png",
        ExportFormat::Jpeg => "jpeg",
        ExportFormat::Svg => "svg",
        ExportFormat::Pdf => "pdf",
        ExportFormat::WebP => "png", // WebP not supported by server, fallback to PNG.
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
    async fn test_export_local_returns_metadata() {
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
        // Local sessions return metadata with a note.
        assert!(output["note"].as_str().unwrap_or_default().contains("Local"));
    }

    #[tokio::test]
    async fn test_export_svg_metadata() {
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

    #[test]
    fn test_format_strings() {
        assert_eq!(format_string(ExportFormat::Png), "png");
        assert_eq!(format_string(ExportFormat::Jpeg), "jpeg");
        assert_eq!(format_string(ExportFormat::Svg), "svg");
        assert_eq!(format_string(ExportFormat::Pdf), "pdf");
        assert_eq!(format_string(ExportFormat::WebP), "png");
    }

    #[test]
    fn test_with_server_url() {
        let reg = Arc::new(Mutex::new(CanvasSessionRegistry::new()));
        let tool = CanvasExportTool::new(reg).with_server_url("http://localhost:9473");
        assert_eq!(tool.server_url.as_deref(), Some("http://localhost:9473"));
    }

    #[test]
    fn test_export_remote_no_url() {
        let reg = Arc::new(Mutex::new(CanvasSessionRegistry::new()));
        let tool = CanvasExportTool::new(reg);
        let params = ExportParams {
            session_id: "test".into(),
            format: ExportFormat::Png,
            quality: 90,
        };
        let result = tool.export_remote(&params);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("no canvas-server URL"));
    }
}
