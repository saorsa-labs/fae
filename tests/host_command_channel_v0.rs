use fae::host::channel::{DeviceTarget, DeviceTransferHandler, command_channel};
use fae::host::contract::{CommandEnvelope, CommandName};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

type CapabilityRequestRecord = (String, String, Option<String>);
type CapabilityGrantRecord = (String, Option<String>);

#[derive(Clone, Default)]
struct RecordingHandler {
    moves: Arc<Mutex<Vec<DeviceTarget>>>,
    go_home_calls: Arc<AtomicUsize>,
    palettes: Arc<Mutex<Vec<String>>>,
    palette_clear_calls: Arc<AtomicUsize>,
    feelings: Arc<Mutex<Vec<String>>>,
    urgencies: Arc<Mutex<Vec<f32>>>,
    flashes: Arc<Mutex<Vec<String>>>,
    capability_requests: Arc<Mutex<Vec<CapabilityRequestRecord>>>,
    capability_grants: Arc<Mutex<Vec<CapabilityGrantRecord>>>,
    conversation_texts: Arc<Mutex<Vec<String>>>,
    gate_sets: Arc<Mutex<Vec<bool>>>,
}

impl DeviceTransferHandler for RecordingHandler {
    fn request_move(&self, target: DeviceTarget) -> fae::Result<()> {
        self.moves.lock().expect("lock move records").push(target);
        Ok(())
    }

    fn request_go_home(&self) -> fae::Result<()> {
        self.go_home_calls.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    fn request_orb_palette_set(&self, palette: &str) -> fae::Result<()> {
        self.palettes
            .lock()
            .expect("lock palette records")
            .push(palette.to_owned());
        Ok(())
    }

    fn request_orb_palette_clear(&self) -> fae::Result<()> {
        self.palette_clear_calls.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    fn request_orb_feeling_set(&self, feeling: &str) -> fae::Result<()> {
        self.feelings
            .lock()
            .expect("lock feeling records")
            .push(feeling.to_owned());
        Ok(())
    }

    fn request_orb_urgency_set(&self, urgency: f32) -> fae::Result<()> {
        self.urgencies
            .lock()
            .expect("lock urgency records")
            .push(urgency);
        Ok(())
    }

    fn request_orb_flash(&self, flash_type: &str) -> fae::Result<()> {
        self.flashes
            .lock()
            .expect("lock flash records")
            .push(flash_type.to_owned());
        Ok(())
    }

    fn request_capability(
        &self,
        capability: &str,
        reason: &str,
        scope: Option<&str>,
    ) -> fae::Result<()> {
        self.capability_requests
            .lock()
            .expect("lock capability request records")
            .push((
                capability.to_owned(),
                reason.to_owned(),
                scope.map(ToOwned::to_owned),
            ));
        Ok(())
    }

    fn grant_capability(&self, capability: &str, scope: Option<&str>) -> fae::Result<()> {
        self.capability_grants
            .lock()
            .expect("lock capability grant records")
            .push((capability.to_owned(), scope.map(ToOwned::to_owned)));
        Ok(())
    }

    fn request_conversation_inject_text(&self, text: &str) -> fae::Result<()> {
        self.conversation_texts
            .lock()
            .expect("lock conversation text records")
            .push(text.to_owned());
        Ok(())
    }

    fn request_conversation_gate_set(&self, active: bool) -> fae::Result<()> {
        self.gate_sets
            .lock()
            .expect("lock gate set records")
            .push(active);
        Ok(())
    }
}

#[tokio::test]
async fn host_ping_round_trip_returns_pong() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-ping",
            CommandName::HostPing,
            serde_json::json!({}),
        ))
        .await
        .expect("host ping should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["pong"], true);

    handle.abort();
}

#[tokio::test]
async fn device_move_routes_to_handler_and_event_stream() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-move-watch",
            CommandName::DeviceMove,
            serde_json::json!({"target": "watch"}),
        ))
        .await
        .expect("device move should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["target"], "watch");

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "device.transfer_requested");
    assert_eq!(event.payload["target"], "watch");

    let moves = tracker.moves.lock().expect("lock move records");
    assert_eq!(moves.as_slice(), &[DeviceTarget::Watch]);

    handle.abort();
}

#[tokio::test]
async fn device_go_home_routes_to_handler_and_event_stream() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-go-home",
            CommandName::DeviceGoHome,
            serde_json::json!({}),
        ))
        .await
        .expect("go home should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["target"], "mac");

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "device.home_requested");
    assert_eq!(event.payload["target"], "mac");

    assert_eq!(tracker.go_home_calls.load(Ordering::SeqCst), 1);

    handle.abort();
}

#[tokio::test]
async fn invalid_device_target_returns_error_response() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-move-invalid",
            CommandName::DeviceMove,
            serde_json::json!({"target": "satellite"}),
        ))
        .await
        .expect_err("invalid target should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("unsupported device target"), "{msg}");

    handle.abort();
}

#[tokio::test]
async fn runtime_start_returns_accepted() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-runtime-start",
            CommandName::RuntimeStart,
            serde_json::json!({}),
        ))
        .await
        .expect("runtime.start should return response");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);

    handle.abort();
}

#[tokio::test]
async fn orb_palette_set_routes_to_handler_and_event_stream() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-palette-set",
            CommandName::OrbPaletteSet,
            serde_json::json!({"palette": "moss-stone"}),
        ))
        .await
        .expect("orb palette set should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["palette"], "moss-stone");

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "orb.palette_set_requested");
    assert_eq!(event.payload["palette"], "moss-stone");

    let palettes = tracker.palettes.lock().expect("lock palette records");
    assert_eq!(palettes.as_slice(), &["moss-stone"]);

    handle.abort();
}

#[tokio::test]
async fn orb_palette_clear_routes_to_handler_and_event_stream() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-palette-clear",
            CommandName::OrbPaletteClear,
            serde_json::json!({}),
        ))
        .await
        .expect("orb palette clear should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "orb.palette_cleared");

    assert_eq!(tracker.palette_clear_calls.load(Ordering::SeqCst), 1);

    handle.abort();
}

#[tokio::test]
async fn orb_palette_set_rejects_unsupported_palette() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-palette-bad",
            CommandName::OrbPaletteSet,
            serde_json::json!({"palette": "neon-cyan"}),
        ))
        .await
        .expect_err("invalid palette should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("unsupported orb palette"), "{msg}");

    handle.abort();
}

#[tokio::test]
async fn capability_request_routes_to_handler_and_event_stream() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-capability-request",
            CommandName::CapabilityRequest,
            serde_json::json!({
                "capability": "external.unsandboxed_tools",
                "reason": "Edit project files outside container",
                "scope": "session"
            }),
        ))
        .await
        .expect("capability request should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["capability"], "external.unsandboxed_tools");
    assert_eq!(response.payload["scope"], "session");

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "capability.requested");
    assert_eq!(event.payload["capability"], "external.unsandboxed_tools");
    assert_eq!(event.payload["scope"], "session");

    let requests = tracker
        .capability_requests
        .lock()
        .expect("lock capability request records");
    assert_eq!(
        requests.as_slice(),
        &[(
            "external.unsandboxed_tools".to_owned(),
            "Edit project files outside container".to_owned(),
            Some("session".to_owned())
        )]
    );

    handle.abort();
}

#[tokio::test]
async fn capability_grant_routes_to_handler_and_event_stream() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-capability-grant",
            CommandName::CapabilityGrant,
            serde_json::json!({
                "capability": "external.unsandboxed_tools",
                "scope": "once"
            }),
        ))
        .await
        .expect("capability grant should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["capability"], "external.unsandboxed_tools");
    assert_eq!(response.payload["scope"], "once");

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "capability.granted");
    assert_eq!(event.payload["capability"], "external.unsandboxed_tools");
    assert_eq!(event.payload["scope"], "once");

    let grants = tracker
        .capability_grants
        .lock()
        .expect("lock capability grant records");
    assert_eq!(
        grants.as_slice(),
        &[(
            "external.unsandboxed_tools".to_owned(),
            Some("once".to_owned())
        )]
    );

    handle.abort();
}

#[tokio::test]
async fn capability_request_rejects_missing_reason() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-capability-missing-reason",
            CommandName::CapabilityRequest,
            serde_json::json!({"capability": "external.unsandboxed_tools"}),
        ))
        .await
        .expect_err("missing reason should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("payload.reason"), "{msg}");

    handle.abort();
}

#[tokio::test]
async fn capability_grant_rejects_empty_capability() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-capability-empty",
            CommandName::CapabilityGrant,
            serde_json::json!({"capability": "   "}),
        ))
        .await
        .expect_err("empty capability should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("non-empty payload.capability"), "{msg}");

    handle.abort();
}

// ---- OrbFeelingSet tests ----

#[tokio::test]
async fn orb_feeling_set_accepted() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-feeling-set",
            CommandName::OrbFeelingSet,
            serde_json::json!({"feeling": "calm"}),
        ))
        .await
        .expect("orb feeling set should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["feeling"], "calm");

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "orb.feeling_set_requested");
    assert_eq!(event.payload["feeling"], "calm");

    let feelings = tracker.feelings.lock().expect("lock feeling records");
    assert_eq!(feelings.as_slice(), &["calm"]);

    handle.abort();
}

#[tokio::test]
async fn orb_feeling_set_unsupported_feeling() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-feeling-bad",
            CommandName::OrbFeelingSet,
            serde_json::json!({"feeling": "angry"}),
        ))
        .await
        .expect_err("unsupported feeling should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("unsupported orb feeling"), "{msg}");

    handle.abort();
}

#[tokio::test]
async fn orb_feeling_set_missing_field() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-feeling-empty",
            CommandName::OrbFeelingSet,
            serde_json::json!({}),
        ))
        .await
        .expect_err("missing feeling should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("payload.feeling"), "{msg}");

    handle.abort();
}

// ---- OrbUrgencySet tests ----

#[tokio::test]
async fn orb_urgency_set_accepted() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-urgency-set",
            CommandName::OrbUrgencySet,
            serde_json::json!({"urgency": 0.5}),
        ))
        .await
        .expect("orb urgency set should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["urgency"], 0.5);

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "orb.urgency_set_requested");
    assert_eq!(event.payload["urgency"], 0.5);

    let urgencies = tracker.urgencies.lock().expect("lock urgency records");
    assert_eq!(urgencies.as_slice(), &[0.5_f32]);

    handle.abort();
}

#[tokio::test]
async fn orb_urgency_set_out_of_range() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-urgency-bad",
            CommandName::OrbUrgencySet,
            serde_json::json!({"urgency": 1.5}),
        ))
        .await
        .expect_err("out-of-range urgency should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("range 0.0-1.0"), "{msg}");

    handle.abort();
}

#[tokio::test]
async fn orb_urgency_set_missing_field() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-urgency-empty",
            CommandName::OrbUrgencySet,
            serde_json::json!({}),
        ))
        .await
        .expect_err("missing urgency should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("payload.urgency"), "{msg}");

    handle.abort();
}

// ---- OrbFlash tests ----

#[tokio::test]
async fn orb_flash_accepted() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-flash-error",
            CommandName::OrbFlash,
            serde_json::json!({"flash_type": "error"}),
        ))
        .await
        .expect("orb flash should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["flash_type"], "error");

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "orb.flash_requested");
    assert_eq!(event.payload["flash_type"], "error");

    let flashes = tracker.flashes.lock().expect("lock flash records");
    assert_eq!(flashes.as_slice(), &["error"]);

    handle.abort();
}

#[tokio::test]
async fn orb_flash_success_accepted() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-flash-success",
            CommandName::OrbFlash,
            serde_json::json!({"flash_type": "success"}),
        ))
        .await
        .expect("orb flash success should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["flash_type"], "success");

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "orb.flash_requested");
    assert_eq!(event.payload["flash_type"], "success");

    let flashes = tracker.flashes.lock().expect("lock flash records");
    assert_eq!(flashes.as_slice(), &["success"]);

    handle.abort();
}

#[tokio::test]
async fn orb_flash_invalid_type() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-flash-bad",
            CommandName::OrbFlash,
            serde_json::json!({"flash_type": "warning"}),
        ))
        .await
        .expect_err("unsupported flash type should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("unsupported orb flash type"), "{msg}");

    handle.abort();
}

#[tokio::test]
async fn orb_flash_missing_field() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-orb-flash-empty",
            CommandName::OrbFlash,
            serde_json::json!({}),
        ))
        .await
        .expect_err("missing flash_type should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("payload.flash_type"), "{msg}");

    handle.abort();
}

// ---- ConversationInjectText tests ----

#[tokio::test]
async fn conversation_inject_text_routes_to_handler_and_event_stream() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-conv-inject",
            CommandName::ConversationInjectText,
            serde_json::json!({"text": "Hello Fae"}),
        ))
        .await
        .expect("conversation inject text should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["text"], "Hello Fae");

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "conversation.text_injected");
    assert_eq!(event.payload["text"], "Hello Fae");

    let texts = tracker
        .conversation_texts
        .lock()
        .expect("lock conversation text records");
    assert_eq!(texts.as_slice(), &["Hello Fae"]);

    handle.abort();
}

#[tokio::test]
async fn conversation_inject_text_rejects_empty_text() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-conv-inject-empty",
            CommandName::ConversationInjectText,
            serde_json::json!({"text": "   "}),
        ))
        .await
        .expect_err("empty text should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("non-empty"), "{msg}");

    handle.abort();
}

#[tokio::test]
async fn conversation_inject_text_missing_field() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-conv-inject-missing",
            CommandName::ConversationInjectText,
            serde_json::json!({}),
        ))
        .await
        .expect_err("missing text should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("payload.text"), "{msg}");

    handle.abort();
}

// ---- ConversationGateSet tests ----

#[tokio::test]
async fn conversation_gate_set_routes_to_handler_and_event_stream() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-conv-gate-set",
            CommandName::ConversationGateSet,
            serde_json::json!({"active": true}),
        ))
        .await
        .expect("conversation gate set should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["active"], true);

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "conversation.gate_set");
    assert_eq!(event.payload["active"], true);

    let gates = tracker.gate_sets.lock().expect("lock gate set records");
    assert_eq!(gates.as_slice(), &[true]);

    handle.abort();
}

#[tokio::test]
async fn conversation_gate_set_false_accepted() {
    let handler = RecordingHandler::default();
    let tracker = handler.clone();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());
    let mut events = client.subscribe_events();

    let response = client
        .send(CommandEnvelope::new(
            "req-conv-gate-false",
            CommandName::ConversationGateSet,
            serde_json::json!({"active": false}),
        ))
        .await
        .expect("conversation gate set false should succeed");

    assert!(response.ok);
    assert_eq!(response.payload["accepted"], true);
    assert_eq!(response.payload["active"], false);

    let event = tokio::time::timeout(std::time::Duration::from_secs(2), events.recv())
        .await
        .expect("event timeout")
        .expect("event recv");
    assert_eq!(event.event, "conversation.gate_set");
    assert_eq!(event.payload["active"], false);

    let gates = tracker.gate_sets.lock().expect("lock gate set records");
    assert_eq!(gates.as_slice(), &[false]);

    handle.abort();
}

#[tokio::test]
async fn conversation_gate_set_missing_field() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-conv-gate-missing",
            CommandName::ConversationGateSet,
            serde_json::json!({}),
        ))
        .await
        .expect_err("missing active should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("payload.active"), "{msg}");

    handle.abort();
}

#[tokio::test]
async fn conversation_gate_set_non_bool() {
    let handler = RecordingHandler::default();
    let (client, server) = command_channel(8, 8, handler);
    let handle = tokio::spawn(server.run());

    let response = client
        .send(CommandEnvelope::new(
            "req-conv-gate-nonbool",
            CommandName::ConversationGateSet,
            serde_json::json!({"active": "yes"}),
        ))
        .await
        .expect_err("non-bool active should return channel error");

    let msg = response.to_string();
    assert!(msg.contains("payload.active"), "{msg}");

    handle.abort();
}
