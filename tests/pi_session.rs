#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! Integration tests for Pi RPC session types, tool, and manager.

use fae::pi::manager::{
    PiInstallState, PiManager, bundled_pi_path, parse_pi_version, platform_asset_name,
    version_is_newer,
};
use fae::pi::session::{PiAgentEvent, PiExtensionUiRequest, PiRpcRequest, PiSession};
use fae::pi::tool::PiDelegateTool;
use saorsa_agent::Tool;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

// ---------------------------------------------------------------------------
// PiRpcRequest serialization
// ---------------------------------------------------------------------------

#[test]
fn prompt_request_json_has_type_and_message() {
    let req = PiRpcRequest::prompt("add error handling");
    let json = serde_json::to_string(&req).unwrap();
    assert!(json.contains("\"type\":\"prompt\""));
    assert!(json.contains("\"message\":\"add error handling\""));
}

#[test]
fn abort_request_json_has_type() {
    let json = serde_json::to_string(&PiRpcRequest::Abort).unwrap();
    assert!(json.contains("\"type\":\"abort\""));
}

#[test]
fn new_session_request_json_has_type() {
    let json = serde_json::to_string(&PiRpcRequest::new_session()).unwrap();
    assert!(json.contains("\"type\":\"new_session\""));
}

// ---------------------------------------------------------------------------
// PiAgentEvent deserialization
// ---------------------------------------------------------------------------

#[test]
fn agent_start_event_from_json() {
    let event: PiAgentEvent = serde_json::from_str(r#"{"type":"agent_start"}"#).unwrap();
    assert!(matches!(event, PiAgentEvent::AgentStart));
}

#[test]
fn agent_end_event_from_json() {
    let event: PiAgentEvent =
        serde_json::from_str(r#"{"type":"agent_end","messages":[]}"#).unwrap();
    assert!(matches!(event, PiAgentEvent::AgentEnd { .. }));
}

#[test]
fn turn_start_event_from_json() {
    let event: PiAgentEvent = serde_json::from_str(r#"{"type":"turn_start"}"#).unwrap();
    assert!(matches!(event, PiAgentEvent::TurnStart));
}

#[test]
fn turn_end_event_from_json() {
    let event: PiAgentEvent =
        serde_json::from_str(r#"{"type":"turn_end","message":{},"toolResults":[]}"#).unwrap();
    assert!(matches!(event, PiAgentEvent::TurnEnd { .. }));
}

#[test]
fn message_start_event_from_json() {
    let event: PiAgentEvent =
        serde_json::from_str(r#"{"type":"message_start","message":{}}"#).unwrap();
    assert!(matches!(event, PiAgentEvent::MessageStart { .. }));
}

#[test]
fn message_end_event_from_json() {
    let event: PiAgentEvent =
        serde_json::from_str(r#"{"type":"message_end","message":{}}"#).unwrap();
    assert!(matches!(event, PiAgentEvent::MessageEnd { .. }));
}

#[test]
fn tool_execution_start_with_name() {
    let event: PiAgentEvent = serde_json::from_str(
        r#"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"bash","args":{"command":"ls"}}"#,
    )
    .unwrap();
    assert!(matches!(
        event,
        PiAgentEvent::ToolExecutionStart { tool_name, .. } if tool_name == "bash"
    ));
}

#[test]
fn extension_ui_confirm_parses() {
    let req: PiExtensionUiRequest = serde_json::from_str(
        r#"{"type":"extension_ui_request","id":"uuid-1","method":"confirm","title":"OK?","message":"Proceed?"}"#,
    )
    .unwrap();
    assert!(matches!(req, PiExtensionUiRequest::Confirm { .. }));
}

// ---------------------------------------------------------------------------
// PiSession construction (no actual process)
// ---------------------------------------------------------------------------

#[test]
fn pi_session_new_is_not_running() {
    let session = PiSession::new(
        PathBuf::from("/usr/local/bin/pi"),
        "fae-local".to_owned(),
        "fae-qwen3".to_owned(),
    );
    assert!(!session.is_running());
}

#[test]
fn pi_session_pi_path_returns_configured_path() {
    let session = PiSession::new(
        PathBuf::from("/opt/pi/bin/pi"),
        "anthropic".to_owned(),
        "claude-3-haiku".to_owned(),
    );
    assert_eq!(session.pi_path(), Path::new("/opt/pi/bin/pi"));
}

#[test]
fn pi_session_try_recv_returns_none_when_not_spawned() {
    let mut session = PiSession::new(
        PathBuf::from("/usr/local/bin/pi"),
        "test".to_owned(),
        "model".to_owned(),
    );
    assert!(session.try_recv().is_none());
}

// ---------------------------------------------------------------------------
// PiDelegateTool schema validation
// ---------------------------------------------------------------------------

#[test]
fn pi_delegate_tool_name() {
    let session = Arc::new(Mutex::new(PiSession::new(
        PathBuf::from("/usr/local/bin/pi"),
        "fae-local".to_owned(),
        "fae-qwen3".to_owned(),
    )));
    let tool = PiDelegateTool::new(session);
    assert_eq!(tool.name(), "pi_delegate");
}

#[test]
fn pi_delegate_tool_description_is_nonempty() {
    let session = Arc::new(Mutex::new(PiSession::new(
        PathBuf::from("/usr/local/bin/pi"),
        "fae-local".to_owned(),
        "fae-qwen3".to_owned(),
    )));
    let tool = PiDelegateTool::new(session);
    assert!(!tool.description().is_empty());
    assert!(tool.description().contains("coding"));
}

#[test]
fn pi_delegate_tool_schema_has_task_field() {
    let session = Arc::new(Mutex::new(PiSession::new(
        PathBuf::from("/usr/local/bin/pi"),
        "fae-local".to_owned(),
        "fae-qwen3".to_owned(),
    )));
    let tool = PiDelegateTool::new(session);
    let schema = tool.input_schema();
    assert_eq!(schema["properties"]["task"]["type"], "string");
    let required = schema["required"].as_array().unwrap();
    assert!(required.iter().any(|v| v.as_str() == Some("task")));
}

#[test]
fn pi_delegate_tool_schema_has_working_directory_field() {
    let session = Arc::new(Mutex::new(PiSession::new(
        PathBuf::from("/usr/local/bin/pi"),
        "fae-local".to_owned(),
        "fae-qwen3".to_owned(),
    )));
    let tool = PiDelegateTool::new(session);
    let schema = tool.input_schema();
    assert_eq!(schema["properties"]["working_directory"]["type"], "string");
}

#[test]
fn pi_delegate_tool_task_is_required_working_dir_is_not() {
    let session = Arc::new(Mutex::new(PiSession::new(
        PathBuf::from("/usr/local/bin/pi"),
        "fae-local".to_owned(),
        "fae-qwen3".to_owned(),
    )));
    let tool = PiDelegateTool::new(session);
    let schema = tool.input_schema();
    let required = schema["required"].as_array().unwrap();
    assert!(required.iter().any(|v| v.as_str() == Some("task")));
    assert!(
        !required
            .iter()
            .any(|v| v.as_str() == Some("working_directory"))
    );
}

// ---------------------------------------------------------------------------
// PiManager — version utilities
// ---------------------------------------------------------------------------

#[test]
fn version_is_newer_detects_patch_bump() {
    assert!(version_is_newer("0.52.8", "0.52.9"));
}

#[test]
fn version_is_newer_detects_minor_bump() {
    assert!(version_is_newer("0.52.9", "0.53.0"));
}

#[test]
fn version_is_newer_returns_false_for_equal() {
    assert!(!version_is_newer("1.0.0", "1.0.0"));
}

#[test]
fn version_is_newer_returns_false_for_older() {
    assert!(!version_is_newer("1.0.0", "0.9.0"));
}

#[test]
fn parse_pi_version_handles_v_prefix() {
    assert_eq!(parse_pi_version("v1.2.3"), Some("1.2.3".to_owned()));
}

#[test]
fn parse_pi_version_handles_multiline() {
    assert_eq!(
        parse_pi_version("Pi Coding Agent\n0.52.9\n"),
        Some("0.52.9".to_owned())
    );
}

#[test]
fn parse_pi_version_returns_none_for_garbage() {
    assert!(parse_pi_version("not a version").is_none());
}

// ---------------------------------------------------------------------------
// PiManager — platform asset
// ---------------------------------------------------------------------------

#[test]
fn platform_asset_name_returns_valid_format() {
    if let Some(name) = platform_asset_name() {
        assert!(name.starts_with("pi-"), "expected pi- prefix: {name}");
        assert!(
            name.ends_with(".tar.gz") || name.ends_with(".zip"),
            "unexpected extension: {name}"
        );
    }
}

// ---------------------------------------------------------------------------
// PiManager — install state
// ---------------------------------------------------------------------------

#[test]
fn pi_install_state_not_found_is_not_installed() {
    let state = PiInstallState::NotFound;
    assert!(!state.is_installed());
    assert!(!state.is_fae_managed());
    assert!(state.path().is_none());
    assert!(state.version().is_none());
}

#[test]
fn pi_install_state_user_installed_reports_correctly() {
    let state = PiInstallState::UserInstalled {
        path: PathBuf::from("/usr/local/bin/pi"),
        version: "0.52.9".to_owned(),
    };
    assert!(state.is_installed());
    assert!(!state.is_fae_managed());
    assert_eq!(state.version(), Some("0.52.9"));
}

#[test]
fn pi_install_state_fae_managed_reports_correctly() {
    let state = PiInstallState::FaeManaged {
        path: PathBuf::from("/home/user/.local/bin/pi"),
        version: "1.0.0".to_owned(),
    };
    assert!(state.is_installed());
    assert!(state.is_fae_managed());
}

// ---------------------------------------------------------------------------
// PiManager — bundled Pi path
// ---------------------------------------------------------------------------

#[test]
fn bundled_pi_path_does_not_panic() {
    // Should always return cleanly, whether Some or None.
    let _ = bundled_pi_path();
}

// ---------------------------------------------------------------------------
// PiManager — construction
// ---------------------------------------------------------------------------

#[test]
fn pi_manager_new_defaults_are_valid() {
    let config = fae::config::PiConfig::default();
    let manager = PiManager::new(&config).unwrap();
    assert!(!manager.state().is_installed());
    assert!(manager.auto_install());
}

#[test]
fn pi_manager_custom_install_dir() {
    let config = fae::config::PiConfig {
        install_dir: Some(PathBuf::from("/custom/test/path")),
        ..Default::default()
    };
    let manager = PiManager::new(&config).unwrap();
    assert_eq!(manager.install_dir(), Path::new("/custom/test/path"));
}

#[test]
fn pi_manager_detect_nonexistent_dir_does_not_error() {
    let config = fae::config::PiConfig {
        install_dir: Some(PathBuf::from("/nonexistent/fae-pi-test")),
        auto_install: false,
    };
    let mut manager = PiManager::new(&config).unwrap();
    let state = manager.detect().unwrap();
    // Should be NotFound or UserInstalled (if Pi in PATH on dev machine).
    assert!(
        matches!(
            state,
            PiInstallState::NotFound | PiInstallState::UserInstalled { .. }
        ),
        "unexpected state: {state}"
    );
}
