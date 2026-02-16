//! Desktop automation tool — screenshots, clicks, typing, window management.
//!
//! Provides a platform-agnostic [`DesktopTool`] that delegates to the best
//! available backend per OS:
//!
//! - **macOS**: [`PeekabooBackend`](peekaboo::PeekabooBackend) via the `peekaboo` CLI
//! - **Linux/X11**: [`XdotoolBackend`](xdotool::XdotoolBackend) via `xdotool` + `scrot`
//!
//! Only available in `ToolMode::Full`.

#[cfg(target_os = "macos")]
pub mod peekaboo;

#[cfg(target_os = "linux")]
pub mod xdotool;

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;

use super::types::{DEFAULT_MAX_BYTES, Tool, ToolResult, truncate_output};

// ── Common types ────────────────────────────────────────────────

/// Target for a click action.
#[derive(Debug, Clone)]
pub enum ClickTarget {
    /// Click at absolute screen coordinates.
    Coordinates { x: f64, y: f64 },
    /// Click on a UI element identified by its accessibility label.
    Label(String),
}

/// Actions the desktop tool can perform.
#[derive(Debug, Clone)]
pub enum DesktopAction {
    /// Capture a screenshot, optionally scoped to an application.
    Screenshot { app: Option<String> },
    /// Click a target (coordinates or label).
    Click { target: ClickTarget },
    /// Type text (keyboard input).
    Type { text: String },
    /// Press a single key.
    Press { key: String },
    /// Press a key combination (e.g. `["cmd", "shift", "s"]`).
    Hotkey { keys: Vec<String> },
    /// Scroll in a direction by an amount.
    Scroll { direction: String, amount: f64 },
    /// List open windows.
    ListWindows,
    /// Focus a window by title substring.
    FocusWindow { title: String },
    /// List running applications.
    ListApps,
    /// Launch an application by name.
    LaunchApp { name: String },
    /// Raw platform-specific command passthrough.
    Raw { command: String },
}

/// Result of a desktop backend operation.
#[derive(Debug, Clone)]
pub struct DesktopResult {
    /// Textual output (JSON, plain text, etc.).
    pub output: String,
    /// Path to a screenshot file, if one was captured.
    pub screenshot_path: Option<String>,
}

/// Platform backend trait for desktop automation.
///
/// Implementations wrap a platform-specific CLI tool and translate
/// [`DesktopAction`] into process invocations.
pub trait DesktopBackend: Send + Sync {
    /// Human-readable name of the backend (e.g. "peekaboo").
    fn name(&self) -> &str;

    /// Returns `true` if the backend CLI tool is installed and accessible.
    fn is_available(&self) -> bool;

    /// Execute a desktop action and return the result.
    ///
    /// # Errors
    ///
    /// Returns a descriptive error string on failure.
    fn execute(&self, action: &DesktopAction) -> Result<DesktopResult, String>;
}

// ── Backend auto-detection ──────────────────────────────────────

/// Detect and return the best available desktop backend for the current OS.
///
/// Returns `None` if no suitable backend is installed.
pub fn detect_backend() -> Option<Box<dyn DesktopBackend>> {
    #[cfg(target_os = "macos")]
    {
        let pb = peekaboo::PeekabooBackend::new();
        if pb.is_available() {
            return Some(Box::new(pb));
        }
    }

    #[cfg(target_os = "linux")]
    {
        let xd = xdotool::XdotoolBackend::new();
        if xd.is_available() {
            return Some(Box::new(xd));
        }
    }

    None
}

// ── Action parsing ──────────────────────────────────────────────

/// Returns a human-readable message explaining how to install a desktop
/// automation backend on the current platform.
///
/// Used in error messages when no backend is detected.
pub fn install_instructions() -> &'static str {
    #[cfg(target_os = "macos")]
    {
        "No desktop automation backend found.\n\
         Install Peekaboo: brew install steipete/tap/peekaboo\n\
         Then grant Accessibility permission in System Settings > Privacy & Security."
    }
    #[cfg(target_os = "linux")]
    {
        "No desktop automation backend found.\n\
         Install xdotool: sudo apt install xdotool scrot\n\
         (X11 session required; Wayland support is experimental.)"
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        "No desktop automation backend found.\n\
         Desktop automation is currently supported on macOS (Peekaboo) and Linux (xdotool)."
    }
}

/// Parse a JSON value into a [`DesktopAction`].
fn parse_action(args: &serde_json::Value) -> Result<DesktopAction, FaeLlmError> {
    let action_str = args.get("action").and_then(|v| v.as_str()).ok_or_else(|| {
        FaeLlmError::ToolValidationError("missing required argument: action (string)".into())
    })?;

    match action_str {
        "screenshot" => {
            let app = args.get("app").and_then(|v| v.as_str()).map(String::from);
            Ok(DesktopAction::Screenshot { app })
        }
        "click" => {
            // Try coordinates first, then label.
            if let Some(coords) = args.get("coordinates") {
                let x = coords.get("x").and_then(|v| v.as_f64()).ok_or_else(|| {
                    FaeLlmError::ToolValidationError(
                        "click coordinates require numeric 'x' field".into(),
                    )
                })?;
                let y = coords.get("y").and_then(|v| v.as_f64()).ok_or_else(|| {
                    FaeLlmError::ToolValidationError(
                        "click coordinates require numeric 'y' field".into(),
                    )
                })?;
                Ok(DesktopAction::Click {
                    target: ClickTarget::Coordinates { x, y },
                })
            } else if let Some(label) = args.get("target").and_then(|v| v.as_str()) {
                Ok(DesktopAction::Click {
                    target: ClickTarget::Label(label.to_string()),
                })
            } else {
                Err(FaeLlmError::ToolValidationError(
                    "click requires either 'coordinates' ({x, y}) or 'target' (label string)"
                        .into(),
                ))
            }
        }
        "type" => {
            let text = args.get("text").and_then(|v| v.as_str()).ok_or_else(|| {
                FaeLlmError::ToolValidationError("type action requires 'text' argument".into())
            })?;
            Ok(DesktopAction::Type {
                text: text.to_string(),
            })
        }
        "press" => {
            let key = args.get("key").and_then(|v| v.as_str()).ok_or_else(|| {
                FaeLlmError::ToolValidationError("press action requires 'key' argument".into())
            })?;
            Ok(DesktopAction::Press {
                key: key.to_string(),
            })
        }
        "hotkey" => {
            let keys = args.get("keys").and_then(|v| v.as_array()).ok_or_else(|| {
                FaeLlmError::ToolValidationError("hotkey action requires 'keys' array".into())
            })?;
            let keys: Vec<String> = keys
                .iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect();
            if keys.is_empty() {
                return Err(FaeLlmError::ToolValidationError(
                    "hotkey 'keys' array must not be empty".into(),
                ));
            }
            Ok(DesktopAction::Hotkey { keys })
        }
        "scroll" => {
            let direction = args
                .get("direction")
                .and_then(|v| v.as_str())
                .unwrap_or("down")
                .to_string();
            let amount = args.get("amount").and_then(|v| v.as_f64()).unwrap_or(3.0);
            Ok(DesktopAction::Scroll { direction, amount })
        }
        "list_windows" => Ok(DesktopAction::ListWindows),
        "focus_window" => {
            let title = args.get("title").and_then(|v| v.as_str()).ok_or_else(|| {
                FaeLlmError::ToolValidationError("focus_window requires 'title' argument".into())
            })?;
            Ok(DesktopAction::FocusWindow {
                title: title.to_string(),
            })
        }
        "list_apps" => Ok(DesktopAction::ListApps),
        "launch_app" => {
            let name = args.get("name").and_then(|v| v.as_str()).ok_or_else(|| {
                FaeLlmError::ToolValidationError("launch_app requires 'name' argument".into())
            })?;
            Ok(DesktopAction::LaunchApp {
                name: name.to_string(),
            })
        }
        "raw" => {
            let command = args
                .get("command")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    FaeLlmError::ToolValidationError(
                        "raw action requires 'command' argument".into(),
                    )
                })?;
            Ok(DesktopAction::Raw {
                command: command.to_string(),
            })
        }
        other => Err(FaeLlmError::ToolValidationError(format!(
            "unknown desktop action: '{other}'. Valid actions: screenshot, click, type, \
             press, hotkey, scroll, list_windows, focus_window, list_apps, launch_app, raw"
        ))),
    }
}

// ── DesktopTool ─────────────────────────────────────────────────

/// Desktop automation tool that wraps a platform-specific backend.
///
/// Only available in `ToolMode::Full`. If no backend is detected at
/// construction time, [`DesktopTool::try_new`] returns `None` so the
/// tool is silently excluded from the registry.
pub struct DesktopTool {
    backend: Box<dyn DesktopBackend>,
    max_bytes: usize,
}

impl DesktopTool {
    /// Attempt to create a `DesktopTool` with the auto-detected backend.
    ///
    /// Returns `None` if no backend is available on this platform.
    pub fn try_new() -> Option<Self> {
        detect_backend().map(|backend| Self {
            backend,
            max_bytes: DEFAULT_MAX_BYTES,
        })
    }

    /// Create a `DesktopTool` with an explicit backend (for testing).
    #[cfg(test)]
    pub fn with_backend(backend: Box<dyn DesktopBackend>) -> Self {
        Self {
            backend,
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }
}

impl Tool for DesktopTool {
    fn name(&self) -> &str {
        "desktop"
    }

    fn description(&self) -> &str {
        "Control the desktop — screenshots, clicks, typing, window management"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "Desktop action to perform",
                    "enum": [
                        "screenshot", "click", "type", "press", "hotkey",
                        "scroll", "list_windows", "focus_window",
                        "list_apps", "launch_app", "raw"
                    ]
                },
                "app": {
                    "type": "string",
                    "description": "Application name (for screenshot scope)"
                },
                "target": {
                    "type": "string",
                    "description": "UI element label (for click)"
                },
                "coordinates": {
                    "type": "object",
                    "description": "Screen coordinates (for click)",
                    "properties": {
                        "x": { "type": "number" },
                        "y": { "type": "number" }
                    }
                },
                "text": {
                    "type": "string",
                    "description": "Text to type"
                },
                "key": {
                    "type": "string",
                    "description": "Key to press (e.g. 'return', 'escape')"
                },
                "keys": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Keys for hotkey combo (e.g. ['cmd', 'shift', 's'])"
                },
                "direction": {
                    "type": "string",
                    "description": "Scroll direction (up/down/left/right)"
                },
                "amount": {
                    "type": "number",
                    "description": "Scroll amount (default 3)"
                },
                "title": {
                    "type": "string",
                    "description": "Window title substring (for focus_window)"
                },
                "name": {
                    "type": "string",
                    "description": "Application name (for launch_app)"
                },
                "command": {
                    "type": "string",
                    "description": "Raw platform-specific command"
                }
            },
            "required": ["action"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let action = parse_action(&args)?;

        match self.backend.execute(&action) {
            Ok(result) => {
                let mut output = result.output;
                if let Some(path) = &result.screenshot_path {
                    if !output.is_empty() {
                        output.push('\n');
                    }
                    output.push_str(&format!("Screenshot saved: {path}"));
                }
                let (truncated, was_truncated) = truncate_output(&output, self.max_bytes);
                if was_truncated {
                    Ok(ToolResult::success_truncated(truncated))
                } else {
                    Ok(ToolResult::success(truncated))
                }
            }
            Err(e) => Ok(ToolResult::failure(e)),
        }
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

// ── Tests ───────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// A mock backend for testing that records calls.
    struct MockBackend {
        available: bool,
    }

    impl MockBackend {
        fn new(available: bool) -> Self {
            Self { available }
        }
    }

    impl DesktopBackend for MockBackend {
        fn name(&self) -> &str {
            "mock"
        }

        fn is_available(&self) -> bool {
            self.available
        }

        fn execute(&self, action: &DesktopAction) -> Result<DesktopResult, String> {
            match action {
                DesktopAction::Screenshot { app } => {
                    let msg = match app {
                        Some(name) => format!("screenshot of {name}"),
                        None => "full screenshot".to_string(),
                    };
                    Ok(DesktopResult {
                        output: msg,
                        screenshot_path: Some("/tmp/screenshot.png".to_string()),
                    })
                }
                DesktopAction::ListWindows => Ok(DesktopResult {
                    output: "[\"Window 1\", \"Window 2\"]".to_string(),
                    screenshot_path: None,
                }),
                _ => Ok(DesktopResult {
                    output: format!("executed {action:?}"),
                    screenshot_path: None,
                }),
            }
        }
    }

    /// A mock backend that always fails.
    struct FailingBackend;

    impl DesktopBackend for FailingBackend {
        fn name(&self) -> &str {
            "failing"
        }

        fn is_available(&self) -> bool {
            true
        }

        fn execute(&self, _action: &DesktopAction) -> Result<DesktopResult, String> {
            Err("backend execution failed".to_string())
        }
    }

    #[test]
    fn schema_has_required_action() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let schema = tool.schema();
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = match required {
            Some(r) => r,
            None => unreachable!("schema should have required"),
        };
        assert!(required.iter().any(|v| v.as_str() == Some("action")));
    }

    #[test]
    fn missing_action_returns_error() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
    }

    #[test]
    fn unknown_action_returns_error() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "teleport"}));
        assert!(result.is_err());
    }

    #[test]
    fn allowed_only_in_full_mode() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn screenshot_action_succeeds() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "screenshot"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("screenshot should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("full screenshot"));
        assert!(result.content.contains("Screenshot saved:"));
    }

    #[test]
    fn screenshot_with_app_scope() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({
            "action": "screenshot",
            "app": "Safari"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("screenshot should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("screenshot of Safari"));
    }

    #[test]
    fn click_with_coordinates() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({
            "action": "click",
            "coordinates": {"x": 100.0, "y": 200.0}
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("click should succeed"),
        };
        assert!(result.success);
    }

    #[test]
    fn click_with_label() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({
            "action": "click",
            "target": "OK Button"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("click should succeed"),
        };
        assert!(result.success);
    }

    #[test]
    fn click_missing_target_returns_error() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "click"}));
        assert!(result.is_err());
    }

    #[test]
    fn type_action_requires_text() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "type"}));
        assert!(result.is_err());
    }

    #[test]
    fn type_action_succeeds() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({
            "action": "type",
            "text": "hello world"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("type should succeed"),
        };
        assert!(result.success);
    }

    #[test]
    fn press_action_requires_key() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "press"}));
        assert!(result.is_err());
    }

    #[test]
    fn hotkey_action_requires_keys_array() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "hotkey"}));
        assert!(result.is_err());
    }

    #[test]
    fn hotkey_empty_keys_returns_error() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "hotkey", "keys": []}));
        assert!(result.is_err());
    }

    #[test]
    fn hotkey_action_succeeds() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({
            "action": "hotkey",
            "keys": ["cmd", "shift", "s"]
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("hotkey should succeed"),
        };
        assert!(result.success);
    }

    #[test]
    fn scroll_defaults() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "scroll"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("scroll should succeed"),
        };
        assert!(result.success);
    }

    #[test]
    fn list_windows_succeeds() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "list_windows"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("list_windows should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Window 1"));
    }

    #[test]
    fn focus_window_requires_title() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "focus_window"}));
        assert!(result.is_err());
    }

    #[test]
    fn launch_app_requires_name() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "launch_app"}));
        assert!(result.is_err());
    }

    #[test]
    fn raw_requires_command() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        let result = tool.execute(serde_json::json!({"action": "raw"}));
        assert!(result.is_err());
    }

    #[test]
    fn backend_failure_returns_tool_failure() {
        let tool = DesktopTool::with_backend(Box::new(FailingBackend));
        let result = tool.execute(serde_json::json!({"action": "screenshot"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return ToolResult not Err"),
        };
        assert!(!result.success);
        assert!(
            result
                .error
                .as_ref()
                .is_some_and(|e| e.contains("backend execution failed"))
        );
    }

    #[test]
    fn tool_name_is_desktop() {
        let tool = DesktopTool::with_backend(Box::new(MockBackend::new(true)));
        assert_eq!(tool.name(), "desktop");
    }

    #[test]
    fn desktop_action_parsing_screenshot() {
        let action = parse_action(&serde_json::json!({"action": "screenshot"}));
        assert!(action.is_ok());
        assert!(matches!(
            action.as_ref().ok(),
            Some(DesktopAction::Screenshot { app: None })
        ));
    }

    #[test]
    fn desktop_action_parsing_list_apps() {
        let action = parse_action(&serde_json::json!({"action": "list_apps"}));
        assert!(action.is_ok());
        assert!(matches!(
            action.as_ref().ok(),
            Some(DesktopAction::ListApps)
        ));
    }

    #[test]
    fn install_instructions_not_empty() {
        let instructions = install_instructions();
        assert!(!instructions.is_empty());
        assert!(instructions.contains("No desktop automation backend found"));
    }
}
