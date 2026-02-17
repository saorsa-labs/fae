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
    capability_requests: Arc<Mutex<Vec<CapabilityRequestRecord>>>,
    capability_grants: Arc<Mutex<Vec<CapabilityGrantRecord>>>,
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
async fn unsupported_command_returns_error_envelope() {
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
        .expect("unsupported command should still produce response envelope");

    assert!(!response.ok);
    assert!(
        response
            .error
            .expect("error message present")
            .contains("not implemented"),
    );

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
