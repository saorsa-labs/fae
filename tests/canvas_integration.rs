//! Integration tests for the canvas subsystem.
//!
//! These tests exercise cross-module workflows: session creation, message
//! pushing, bridge event routing, tool execution, registry management,
//! and export (local mode).

use std::sync::{Arc, Mutex};

use fae::canvas::backend::{CanvasBackend, ConnectionStatus};
use fae::canvas::bridge::CanvasBridge;
use fae::canvas::registry::CanvasSessionRegistry;
use fae::canvas::session::CanvasSession;
use fae::canvas::tools::{CanvasExportTool, CanvasInteractTool, CanvasRenderTool};
use fae::canvas::types::{CanvasMessage, MessageRole};

use saorsa_agent::Tool;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Create a registry with a single session.
fn registry_with_session(id: &str) -> Arc<Mutex<CanvasSessionRegistry>> {
    let mut reg = CanvasSessionRegistry::new();
    let session: Arc<Mutex<dyn CanvasBackend>> =
        Arc::new(Mutex::new(CanvasSession::new(id, 800.0, 600.0)));
    reg.register(id, session);
    Arc::new(Mutex::new(reg))
}

// ---------------------------------------------------------------------------
// Session → push → scene element verification
// ---------------------------------------------------------------------------

#[test]
fn session_push_and_verify_scene_elements() {
    let mut session = CanvasSession::new("int-1", 800.0, 600.0);
    let msg_a = CanvasMessage::new(MessageRole::User, "Hello", 100);
    let msg_b = CanvasMessage::new(MessageRole::Assistant, "Hi there!", 200);
    let msg_c = CanvasMessage::tool("search", "3 results", 300);

    let id_a = session.push_message(&msg_a);
    let id_b = session.push_message(&msg_b);
    let id_c = session.push_message(&msg_c);

    // Three messages, three scene elements.
    assert_eq!(session.message_count(), 3);
    assert_eq!(session.scene().element_count(), 3);

    // Each element exists.
    assert!(session.scene().get_element(id_a).is_some());
    assert!(session.scene().get_element(id_b).is_some());
    assert!(session.scene().get_element(id_c).is_some());

    // HTML contains all roles.
    let html = session.to_html();
    assert!(html.contains("class=\"message user\""));
    assert!(html.contains("class=\"message assistant\""));
    assert!(html.contains("class=\"message tool\""));
}

// ---------------------------------------------------------------------------
// Bridge event routing → CanvasMessage → Element
// ---------------------------------------------------------------------------

#[test]
fn bridge_routes_transcription_to_user_message() {
    use fae::pipeline::messages::Transcription;
    use fae::runtime::RuntimeEvent;
    use std::time::Instant;

    let mut bridge = CanvasBridge::new("bridge-test", 800.0, 600.0);

    // Final transcription → user message.
    bridge.on_event(&RuntimeEvent::Transcription(Transcription {
        text: "What is the weather?".into(),
        is_final: true,
        voiceprint: None,
        audio_captured_at: Instant::now(),
        transcribed_at: Instant::now(),
    }));

    assert_eq!(bridge.session().message_count(), 1);
    let html = bridge.session().to_html();
    assert!(html.contains("What is the weather?"));
}

#[test]
fn bridge_routes_assistant_chunks_and_tools() {
    use fae::pipeline::messages::SentenceChunk;
    use fae::runtime::RuntimeEvent;

    let mut bridge = CanvasBridge::new("flow", 800.0, 600.0);

    // Tool call + result
    bridge.on_event(&RuntimeEvent::ToolCall {
        id: "call-1".into(),
        name: "canvas_render".into(),
        input_json: r#"{"session_id":"flow"}"#.into(),
    });
    bridge.on_event(&RuntimeEvent::ToolResult {
        id: "call-1".into(),
        name: "canvas_render".into(),
        success: true,
        output_text: None,
    });

    // Assistant response
    bridge.on_event(&RuntimeEvent::AssistantGenerating { active: true });
    bridge.on_event(&RuntimeEvent::AssistantSentence(SentenceChunk {
        text: "Here is the chart.".into(),
        is_final: true,
    }));
    bridge.on_event(&RuntimeEvent::AssistantGenerating { active: false });

    // 2 tool + 1 assistant = 3 messages
    assert_eq!(bridge.session().message_count(), 3);

    let html = bridge.session().to_html();
    assert!(html.contains("canvas_render"));
    assert!(html.contains("Here is the chart."));
}

// ---------------------------------------------------------------------------
// Tool execution: canvas_render with chart data
// ---------------------------------------------------------------------------

#[tokio::test]
async fn render_tool_adds_element_to_session() {
    let reg = registry_with_session("gui");
    let tool = CanvasRenderTool::new(reg.clone());

    let input = serde_json::json!({
        "session_id": "gui",
        "content": {
            "type": "Chart",
            "data": {
                "chart_type": "bar",
                "data": {"labels": ["Jan", "Feb", "Mar"], "values": [10, 20, 30]},
                "title": "Sales"
            }
        },
        "position": { "x": 0.0, "y": 0.0, "width": 400.0, "height": 300.0 }
    });

    let result = tool.execute(input).await;
    assert!(result.is_ok());

    let output: serde_json::Value =
        serde_json::from_str(&result.unwrap_or_default()).unwrap_or_default();
    assert_eq!(output["success"], true);

    // Session now has 1 element.
    let reg_guard = reg.lock().unwrap_or_else(|e| e.into_inner());
    let session_arc = reg_guard.get("gui");
    assert!(session_arc.is_some());
    let session = session_arc
        .as_ref()
        .unwrap()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    assert_eq!(session.element_count(), 1);
}

#[tokio::test]
async fn render_tool_text_content() {
    let reg = registry_with_session("gui");
    let tool = CanvasRenderTool::new(reg.clone());

    let input = serde_json::json!({
        "session_id": "gui",
        "content": {
            "type": "Text",
            "data": {
                "content": "Annotation text",
                "font_size": 18.0
            }
        }
    });

    let result = tool.execute(input).await;
    assert!(result.is_ok());
}

// ---------------------------------------------------------------------------
// Tool execution: canvas_interact
// ---------------------------------------------------------------------------

#[tokio::test]
async fn interact_tool_touch_returns_interpretation() {
    let reg = registry_with_session("gui");
    let tool = CanvasInteractTool::new(reg);

    let input = serde_json::json!({
        "session_id": "gui",
        "interaction": {
            "type": "Touch",
            "data": { "x": 150.0, "y": 250.0, "element_id": "chart-1" }
        }
    });

    let result = tool.execute(input).await;
    assert!(result.is_ok());

    let output: serde_json::Value =
        serde_json::from_str(&result.unwrap_or_default()).unwrap_or_default();
    assert_eq!(output["success"], true);
    assert_eq!(output["interpretation"]["type"], "touch");
    assert_eq!(output["interpretation"]["element"], "chart-1");
}

#[tokio::test]
async fn interact_tool_voice_with_context() {
    let reg = registry_with_session("gui");
    let tool = CanvasInteractTool::new(reg);

    let input = serde_json::json!({
        "session_id": "gui",
        "interaction": {
            "type": "Voice",
            "data": {
                "transcript": "Make this bar red",
                "context_element": "bar-2"
            }
        }
    });

    let result = tool.execute(input).await;
    assert!(result.is_ok());
    let output: serde_json::Value =
        serde_json::from_str(&result.unwrap_or_default()).unwrap_or_default();
    assert_eq!(output["interpretation"]["transcript"], "Make this bar red");
    assert_eq!(output["interpretation"]["context_element"], "bar-2");
}

// ---------------------------------------------------------------------------
// Tool execution: canvas_export (local mode)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn export_tool_local_returns_metadata() {
    let reg = registry_with_session("gui");

    // Push some content first.
    {
        let reg_guard = reg.lock().unwrap_or_else(|e| e.into_inner());
        let session_arc = reg_guard.get("gui").unwrap();
        let mut session = session_arc.lock().unwrap_or_else(|e| e.into_inner());
        let msg = CanvasMessage::new(MessageRole::User, "test content", 1);
        session.push_message(&msg);
    }

    let tool = CanvasExportTool::new(reg);
    let input = serde_json::json!({
        "session_id": "gui",
        "format": "png",
        "quality": 90
    });

    let result = tool.execute(input).await;
    assert!(result.is_ok());

    let output: serde_json::Value =
        serde_json::from_str(&result.unwrap_or_default()).unwrap_or_default();
    assert_eq!(output["success"], true);
    assert_eq!(output["format"], "image/png");
    assert_eq!(output["element_count"], 1);
    // Local session returns a note about needing canvas-server.
    assert!(
        output["note"]
            .as_str()
            .unwrap_or_default()
            .contains("Local")
    );
}

// ---------------------------------------------------------------------------
// Session registry management
// ---------------------------------------------------------------------------

#[test]
fn registry_register_get_remove_lifecycle() {
    let mut reg = CanvasSessionRegistry::new();
    assert!(reg.is_empty());

    let s1: Arc<Mutex<dyn CanvasBackend>> =
        Arc::new(Mutex::new(CanvasSession::new("a", 800.0, 600.0)));
    let s2: Arc<Mutex<dyn CanvasBackend>> =
        Arc::new(Mutex::new(CanvasSession::new("b", 800.0, 600.0)));

    reg.register("a", s1);
    reg.register("b", s2);
    assert_eq!(reg.len(), 2);

    // Lookup works.
    assert!(reg.get("a").is_some());
    assert!(reg.get("b").is_some());
    assert!(reg.get("c").is_none());

    // Remove.
    let removed = reg.remove("a");
    assert!(removed.is_some());
    assert_eq!(reg.len(), 1);
    assert!(reg.get("a").is_none());

    // Session IDs.
    let ids = reg.session_ids();
    assert_eq!(ids, vec!["b"]);
}

#[test]
fn registry_shared_arc_access() {
    let mut reg = CanvasSessionRegistry::new();
    let session: Arc<Mutex<dyn CanvasBackend>> =
        Arc::new(Mutex::new(CanvasSession::new("shared", 800.0, 600.0)));

    reg.register("shared", session.clone());

    // Push through the original Arc.
    {
        let mut guard = session.lock().unwrap_or_else(|e| e.into_inner());
        let msg = CanvasMessage::new(MessageRole::User, "from original", 1);
        guard.push_message(&msg);
    }

    // Read through the registry copy.
    let from_reg = reg.get("shared").unwrap();
    let guard = from_reg.lock().unwrap_or_else(|e| e.into_inner());
    assert_eq!(guard.message_count(), 1);
}

// ---------------------------------------------------------------------------
// Backend trait: CanvasSession implements CanvasBackend correctly
// ---------------------------------------------------------------------------

#[test]
fn canvas_session_implements_backend_trait() {
    let session: Arc<Mutex<dyn CanvasBackend>> =
        Arc::new(Mutex::new(CanvasSession::new("trait-test", 800.0, 600.0)));

    let mut guard = session.lock().unwrap_or_else(|e| e.into_inner());
    assert_eq!(guard.session_id(), "trait-test");
    assert_eq!(guard.message_count(), 0);
    assert_eq!(guard.element_count(), 0);

    // Push message via trait.
    let msg = CanvasMessage::new(MessageRole::Assistant, "hello", 1);
    let _id = guard.push_message(&msg);
    assert_eq!(guard.message_count(), 1);
    assert_eq!(guard.element_count(), 1);

    // Add raw element via trait.
    let el = canvas_core::Element::new(canvas_core::ElementKind::Text {
        content: "raw".into(),
        font_size: 12.0,
        color: "#FFF".into(),
    });
    let raw_id = guard.add_element(el);
    assert_eq!(guard.element_count(), 2);

    // Remove raw element.
    let removed = guard.remove_element(&raw_id);
    assert!(removed.is_some());
    assert_eq!(guard.element_count(), 1);

    // HTML rendering.
    let html = guard.to_html();
    assert!(html.contains("hello"));

    // Connection status.
    assert_eq!(guard.connection_status(), ConnectionStatus::Local);

    // Scene snapshot.
    let snapshot = guard.scene_snapshot();
    assert_eq!(snapshot.element_count(), 1);

    // Clear.
    guard.clear();
    assert_eq!(guard.message_count(), 0);
    assert_eq!(guard.element_count(), 0);
}

// ---------------------------------------------------------------------------
// End-to-end: conversation → tools → export
// ---------------------------------------------------------------------------

#[tokio::test]
async fn end_to_end_conversation_with_tools() {
    // Set up registry and bridge sharing the same session.
    let session: Arc<Mutex<dyn CanvasBackend>> =
        Arc::new(Mutex::new(CanvasSession::new("e2e", 800.0, 600.0)));
    let mut reg = CanvasSessionRegistry::new();
    reg.register("e2e", session.clone());
    let reg_arc = Arc::new(Mutex::new(reg));

    // Create tools pointing at the same registry.
    let render_tool = CanvasRenderTool::new(reg_arc.clone());
    let export_tool = CanvasExportTool::new(reg_arc.clone());

    // Simulate user transcription → push to session via bridge-style direct push.
    {
        let mut guard = session.lock().unwrap_or_else(|e| e.into_inner());
        let msg = CanvasMessage::new(MessageRole::User, "Show me a bar chart of sales", 1);
        guard.push_message(&msg);
    }

    // AI renders a chart via tool.
    let chart_input = serde_json::json!({
        "session_id": "e2e",
        "content": {
            "type": "Chart",
            "data": {
                "chart_type": "bar",
                "data": {"labels": ["Q1", "Q2", "Q3", "Q4"], "values": [100, 200, 150, 300]},
                "title": "Quarterly Sales"
            }
        }
    });
    let render_result = render_tool.execute(chart_input).await;
    assert!(render_result.is_ok());

    // Session now has 1 message + 1 tool element = 2 elements total.
    {
        let guard = session.lock().unwrap_or_else(|e| e.into_inner());
        assert_eq!(guard.message_count(), 1);
        assert_eq!(guard.element_count(), 2);

        // HTML has both message and tool sections.
        let html = guard.to_html();
        assert!(html.contains("canvas-messages"));
        assert!(html.contains("canvas-tools"));
    }

    // Export (local mode) — returns metadata.
    let export_input = serde_json::json!({
        "session_id": "e2e",
        "format": "png",
        "quality": 95
    });
    let export_result = export_tool.execute(export_input).await;
    assert!(export_result.is_ok());

    let output: serde_json::Value =
        serde_json::from_str(&export_result.unwrap_or_default()).unwrap_or_default();
    assert_eq!(output["success"], true);
    assert_eq!(output["element_count"], 2);
}

// ---------------------------------------------------------------------------
// Message views for GUI rendering
// ---------------------------------------------------------------------------

#[test]
fn message_views_carry_role_and_html() {
    let mut session = CanvasSession::new("views", 800.0, 600.0);
    session.push_message(&CanvasMessage::new(MessageRole::User, "Hi", 1));
    session.push_message(&CanvasMessage::new(MessageRole::Assistant, "Hello!", 2));
    session.push_message(&CanvasMessage::tool("web", "fetched page", 3));

    let views = session.message_views();
    assert_eq!(views.len(), 3);
    assert_eq!(views[0].role, MessageRole::User);
    assert_eq!(views[1].role, MessageRole::Assistant);
    assert_eq!(views[2].role, MessageRole::Tool);
    assert_eq!(views[2].tool_name.as_deref(), Some("web"));

    // Each view has non-empty HTML.
    for v in &views {
        assert!(!v.html.is_empty());
    }
}

// ---------------------------------------------------------------------------
// Resize relayouts messages
// ---------------------------------------------------------------------------

#[test]
fn resize_relayouts_all_messages() {
    let mut session = CanvasSession::new("resize", 800.0, 600.0);
    let id1 = session.push_message(&CanvasMessage::new(MessageRole::User, "A", 1));
    let id2 = session.push_message(&CanvasMessage::new(MessageRole::User, "B", 2));

    // Original widths.
    let w_before = session
        .scene()
        .get_element(id1)
        .map(|e| e.transform.width)
        .unwrap_or(0.0);

    // Resize to narrower viewport.
    session.resize_viewport(400.0, 300.0);

    let w_after = session
        .scene()
        .get_element(id1)
        .map(|e| e.transform.width)
        .unwrap_or(0.0);
    assert!(
        w_after < w_before,
        "width should decrease after narrowing viewport"
    );

    // Both elements updated.
    let w2 = session
        .scene()
        .get_element(id2)
        .map(|e| e.transform.width)
        .unwrap_or(0.0);
    assert!(
        (w_after - w2).abs() < f32::EPSILON,
        "both messages should have same width"
    );
}

// ---------------------------------------------------------------------------
// Tool elements rendered separately in HTML
// ---------------------------------------------------------------------------

#[test]
fn tool_elements_html_separate_from_messages() {
    let mut session = CanvasSession::new("sep", 800.0, 600.0);

    // Push a message.
    session.push_message(&CanvasMessage::new(MessageRole::User, "Hi", 1));

    // Push a raw element (simulating tool).
    let el = canvas_core::Element::new(canvas_core::ElementKind::Text {
        content: "Tool output".into(),
        font_size: 14.0,
        color: "#FFF".into(),
    });
    session.scene_mut().add_element(el);

    // tool_elements_html should contain only the tool content.
    let tool_html = session.tool_elements_html();
    assert!(tool_html.contains("Tool output"));
    assert!(!tool_html.contains("Hi"));

    // Full HTML should have both sections.
    let full_html = session.to_html();
    assert!(full_html.contains("canvas-messages"));
    assert!(full_html.contains("canvas-tools"));
    assert!(full_html.contains("Hi"));
    assert!(full_html.contains("Tool output"));
}
