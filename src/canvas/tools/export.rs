//! `canvas_export` tool — export a canvas session to an image/PDF format.
//!
//! For remote sessions (connected to a canvas-server), export is performed via
//! HTTP POST to `/api/export`. For local sessions, a scene snapshot is returned
//! as JSON metadata until the canvas-renderer export feature is published.

use std::io::Read as _;
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use canvas_mcp::tools::{ExportFormat, ExportParams};

use crate::canvas::backend::ConnectionStatus;
use crate::canvas::registry::CanvasSessionRegistry;
use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::types::{Tool, ToolResult};

/// Tool that exports a canvas session to an image or document format.
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
    fn export_remote(&self, params: &ExportParams) -> std::result::Result<Vec<u8>, String> {
        let base_url = self.server_url.as_deref().ok_or_else(|| {
            "remote export requested but no canvas-server URL configured".to_string()
        })?;

        let url = format!("{base_url}/api/export");
        let body = serde_json::json!({
            "session_id": params.session_id,
            "format": format_string(params.format),
            "quality": params.quality,
        });

        let response = ureq::post(&url)
            .send_json(body)
            .map_err(|e| format!("export HTTP request failed: {e}"))?;

        if response.status() >= 400 {
            let status = response.status();
            let body_text = response.into_string().unwrap_or_default();
            return Err(format!("export failed with status {status}: {body_text}"));
        }

        let mut bytes = Vec::new();
        response
            .into_reader()
            .read_to_end(&mut bytes)
            .map_err(|e| format!("failed to read export response: {e}"))?;

        Ok(bytes)
    }
}

impl Tool for CanvasExportTool {
    fn name(&self) -> &str {
        "canvas_export"
    }

    fn description(&self) -> &str {
        "Export a canvas session to an image or document format (PNG, JPEG, SVG, PDF). \
         Returns base64-encoded data for remote sessions."
    }

    fn schema(&self) -> serde_json::Value {
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

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let params: ExportParams = serde_json::from_value(args).map_err(|e| {
            FaeLlmError::ToolValidationError(format!("invalid canvas_export params: {e}"))
        })?;

        // Get session from registry.
        let registry = match self.registry.lock() {
            Ok(guard) => guard,
            Err(_) => {
                return Ok(ToolResult::failure(
                    "session registry lock poisoned".to_string(),
                ));
            }
        };

        let Some(session_arc) = registry.get(&params.session_id) else {
            return Ok(ToolResult::failure(format!(
                "canvas session '{}' not found",
                params.session_id
            )));
        };

        let session = match session_arc.lock() {
            Ok(guard) => guard,
            Err(_) => return Ok(ToolResult::failure("session lock poisoned".to_string())),
        };

        let status = session.connection_status();
        let element_count = session.element_count();
        let mime = format_mime_type(params.format);

        let response = match status {
            ConnectionStatus::Connected | ConnectionStatus::Reconnecting { .. } => {
                // Drop locks before making HTTP call.
                drop(session);
                drop(registry);

                let data = match self.export_remote(&params) {
                    Ok(bytes) => bytes,
                    Err(e) => return Ok(ToolResult::failure(e)),
                };
                let encoded = base64::engine::general_purpose::STANDARD.encode(&data);

                serde_json::json!({
                    "success": true,
                    "session_id": params.session_id,
                    "format": mime,
                    "size_bytes": data.len(),
                    "element_count": element_count,
                    "data": encoded,
                })
            }
            _ => {
                // Local session — no server available for export rendering.
                serde_json::json!({
                    "success": true,
                    "session_id": params.session_id,
                    "format": mime,
                    "quality": params.quality,
                    "element_count": element_count,
                    "note": "Local export via canvas-server not available. \
                             Connect to a canvas-server for image export.",
                })
            }
        };

        let response_json = serde_json::to_string(&response)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("serialize error: {e}")))?;
        Ok(ToolResult::success(response_json))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true
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

    #[test]
    fn test_export_local_returns_metadata() {
        let reg = setup_registry("test");
        let tool = CanvasExportTool::new(reg);

        let input = serde_json::json!({
            "session_id": "test",
            "format": "png",
            "quality": 95
        });

        let result = tool.execute(input);
        assert!(result.is_ok());
        let result = result.unwrap_or_else(|_| unreachable!());
        assert!(result.success);
        let output: serde_json::Value = serde_json::from_str(&result.content).unwrap_or_default();
        assert_eq!(output["success"], true);
        assert_eq!(output["format"], "image/png");
        assert_eq!(output["quality"], 95);
        assert!(
            output["note"]
                .as_str()
                .unwrap_or_default()
                .contains("Local")
        );
    }

    #[test]
    fn test_export_svg_metadata() {
        let reg = setup_registry("test");
        let tool = CanvasExportTool::new(reg);

        let input = serde_json::json!({
            "session_id": "test",
            "format": "svg"
        });

        let result = tool.execute(input);
        assert!(result.is_ok());
        let result = result.unwrap_or_else(|_| unreachable!());
        assert!(result.success);
        let output: serde_json::Value = serde_json::from_str(&result.content).unwrap_or_default();
        assert_eq!(output["format"], "image/svg+xml");
    }

    #[test]
    fn test_export_missing_session() {
        let reg = setup_registry("test");
        let tool = CanvasExportTool::new(reg);

        let input = serde_json::json!({
            "session_id": "gone",
            "format": "png"
        });

        let result = tool.execute(input);
        assert!(result.is_ok());
        assert!(!result.unwrap_or_else(|_| unreachable!()).success);
    }

    #[test]
    fn test_export_invalid_json() {
        let reg = setup_registry("test");
        let tool = CanvasExportTool::new(reg);

        let input = serde_json::json!({ "bad": true });
        let result = tool.execute(input);
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
            session_id: "x".to_string(),
            format: ExportFormat::Png,
            quality: 90,
        };

        let result = tool.export_remote(&params);
        assert!(result.is_err());
    }
}
