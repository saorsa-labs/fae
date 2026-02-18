//! End-to-end tests for the `fae-host` binary (stdin/stdout JSON bridge).
//!
//! Each test spawns a fresh subprocess of the `fae-host` binary, sends JSON
//! commands over stdin, and reads JSON responses/events from stdout. The binary
//! is built once per test invocation by cargo's test harness (the first
//! `cargo build --bin fae-host` call will be a no-op on subsequent tests).

use serde_json::Value;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

struct HostBridgeHarness {
    child: Child,
    stdin: BufWriter<ChildStdin>,
    reader: Lines<BufReader<ChildStdout>>,
}

impl HostBridgeHarness {
    async fn spawn() -> Self {
        // Build the binary first (no-op if already built).
        let build_output = std::process::Command::new("cargo")
            .args(["build", "--bin", "fae-host"])
            .output()
            .expect("failed to run cargo build");
        assert!(
            build_output.status.success(),
            "cargo build --bin fae-host failed: {}",
            String::from_utf8_lossy(&build_output.stderr)
        );

        // Locate the built binary.
        let binary = std::env::current_dir()
            .unwrap()
            .join("target/debug/fae-host");

        let mut child = Command::new(&binary)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap_or_else(|e| panic!("failed to spawn fae-host at {}: {e}", binary.display()));

        let child_stdin = child.stdin.take().expect("no stdin on child process");
        let child_stdout = child.stdout.take().expect("no stdout on child process");

        Self {
            child,
            stdin: BufWriter::new(child_stdin),
            reader: BufReader::new(child_stdout).lines(),
        }
    }

    /// Send a command and return the next `ResponseEnvelope` (skipping events).
    async fn send(&mut self, cmd: Value) -> Value {
        let mut json = serde_json::to_string(&cmd).unwrap();
        json.push('\n');
        self.stdin.write_all(json.as_bytes()).await.unwrap();
        self.stdin.flush().await.unwrap();
        self.read_response().await
    }

    /// Read the next JSON line from stdout (with timeout).
    async fn read_line(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(10), self.reader.next_line())
            .await
            .expect("timeout reading from fae-host")
            .expect("IO error reading from fae-host")
            .expect("unexpected EOF from fae-host");
        serde_json::from_str(&line).unwrap_or_else(|e| {
            panic!("invalid JSON from fae-host: {e}\nraw line: {line}");
        })
    }

    /// Read lines until we find a `ResponseEnvelope` (has `"ok"` field).
    async fn read_response(&mut self) -> Value {
        loop {
            let val = self.read_line().await;
            if val.get("ok").is_some() {
                return val;
            }
            // Skip event envelopes.
        }
    }

    /// Send a command and collect both the response and the accompanying event.
    /// Returns `(response, event)`.
    async fn send_with_event(&mut self, cmd: Value) -> (Value, Value) {
        let mut json = serde_json::to_string(&cmd).unwrap();
        json.push('\n');
        self.stdin.write_all(json.as_bytes()).await.unwrap();
        self.stdin.flush().await.unwrap();

        let mut response = None;
        let mut event = None;

        // The bridge writes a response and an event for commands that emit
        // events. The order is not guaranteed, so read up to 2 lines and
        // classify each.
        for _ in 0..2 {
            let val = self.read_line().await;
            if val.get("ok").is_some() {
                response = Some(val);
            } else if val.get("event").is_some() {
                event = Some(val);
            }
            if response.is_some() && event.is_some() {
                break;
            }
        }

        (
            response.expect("no response received within 2 lines"),
            event.expect("no event received within 2 lines"),
        )
    }

    /// Close stdin and verify the process exits cleanly (code 0).
    async fn shutdown(mut self) {
        drop(self.stdin);
        let status = tokio::time::timeout(Duration::from_secs(5), self.child.wait())
            .await
            .expect("timeout waiting for fae-host to exit")
            .expect("failed to wait for fae-host");
        assert!(status.success(), "fae-host exited with: {status}");
    }
}

/// Build a `CommandEnvelope` JSON value with a unique request ID.
fn make_cmd(command: &str, payload: Value) -> Value {
    serde_json::json!({
        "v": 1,
        "request_id": format!("test-{}", uuid::Uuid::new_v4()),
        "command": command,
        "payload": payload
    })
}

/// Assert that a response indicates an error (ok == false or error is non-null).
fn assert_error_response(resp: &Value) {
    let ok = resp.get("ok").and_then(Value::as_bool).unwrap_or(true);
    let has_error = resp.get("error").map(|v| !v.is_null()).unwrap_or(false);
    assert!(
        !ok || has_error,
        "expected error response but got ok={ok}, error={:?}, full={resp}",
        resp.get("error")
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn e2e_host_ping() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h.send(make_cmd("host.ping", serde_json::json!({}))).await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["pong"], true);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_host_version() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h
        .send(make_cmd("host.version", serde_json::json!({})))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["contract_version"], 1);
    assert_eq!(resp["payload"]["channel"], "host_command_v0");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_device_move_watch() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "device.move",
            serde_json::json!({"target": "watch"}),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["target"], "watch");
    assert_eq!(event["event"], "device.transfer_requested");
    assert_eq!(event["payload"]["target"], "watch");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_device_go_home() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd("device.go_home", serde_json::json!({})))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["target"], "mac");
    assert_eq!(event["event"], "device.home_requested");
    assert_eq!(event["payload"]["target"], "mac");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_device_move_invalid() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h
        .send(make_cmd(
            "device.move",
            serde_json::json!({"target": "fridge"}),
        ))
        .await;
    assert_error_response(&resp);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_orb_palette_set() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "orb.palette.set",
            serde_json::json!({"palette": "heather-mist"}),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["palette"], "heather-mist");
    assert_eq!(event["event"], "orb.palette_set_requested");
    assert_eq!(event["payload"]["palette"], "heather-mist");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_orb_palette_set_invalid() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h
        .send(make_cmd(
            "orb.palette.set",
            serde_json::json!({"palette": "neon-green"}),
        ))
        .await;
    assert_error_response(&resp);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_orb_palette_clear() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd("orb.palette.clear", serde_json::json!({})))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(event["event"], "orb.palette_cleared");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_orb_feeling_set() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "orb.feeling.set",
            serde_json::json!({"feeling": "calm"}),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["feeling"], "calm");
    assert_eq!(event["event"], "orb.feeling_set_requested");
    assert_eq!(event["payload"]["feeling"], "calm");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_orb_feeling_set_invalid() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h
        .send(make_cmd(
            "orb.feeling.set",
            serde_json::json!({"feeling": "angry"}),
        ))
        .await;
    assert_error_response(&resp);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_orb_urgency_set() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "orb.urgency.set",
            serde_json::json!({"urgency": 0.5}),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["urgency"], 0.5);
    assert_eq!(event["event"], "orb.urgency_set_requested");
    assert_eq!(event["payload"]["urgency"], 0.5);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_orb_urgency_out_of_range() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h
        .send(make_cmd(
            "orb.urgency.set",
            serde_json::json!({"urgency": 5.0}),
        ))
        .await;
    assert_error_response(&resp);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_orb_flash() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "orb.flash",
            serde_json::json!({"flash_type": "error"}),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["flash_type"], "error");
    assert_eq!(event["event"], "orb.flash_requested");
    assert_eq!(event["payload"]["flash_type"], "error");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_orb_flash_invalid() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h
        .send(make_cmd(
            "orb.flash",
            serde_json::json!({"flash_type": "sparkle"}),
        ))
        .await;
    assert_error_response(&resp);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_conversation_inject_text() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "conversation.inject_text",
            serde_json::json!({"text": "Hello"}),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["text"], "Hello");
    assert_eq!(event["event"], "conversation.text_injected");
    assert_eq!(event["payload"]["text"], "Hello");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_conversation_inject_text_empty() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h
        .send(make_cmd(
            "conversation.inject_text",
            serde_json::json!({"text": "   "}),
        ))
        .await;
    assert_error_response(&resp);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_conversation_gate_set_true() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "conversation.gate_set",
            serde_json::json!({"active": true}),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["active"], true);
    assert_eq!(event["event"], "conversation.gate_set");
    assert_eq!(event["payload"]["active"], true);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_conversation_gate_set_false() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "conversation.gate_set",
            serde_json::json!({"active": false}),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["active"], false);
    assert_eq!(event["event"], "conversation.gate_set");
    assert_eq!(event["payload"]["active"], false);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_conversation_gate_set_non_bool() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h
        .send(make_cmd(
            "conversation.gate_set",
            serde_json::json!({"active": "yes"}),
        ))
        .await;
    assert_error_response(&resp);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_capability_request() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "capability.request",
            serde_json::json!({
                "capability": "file_read",
                "reason": "need to read config",
                "scope": "/etc"
            }),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["capability"], "file_read");
    assert_eq!(resp["payload"]["scope"], "/etc");
    assert_eq!(event["event"], "capability.requested");
    assert_eq!(event["payload"]["capability"], "file_read");
    assert_eq!(event["payload"]["scope"], "/etc");
    assert_eq!(event["payload"]["reason"], "need to read config");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_capability_grant() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "capability.grant",
            serde_json::json!({
                "capability": "file_read",
                "scope": "/etc"
            }),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["capability"], "file_read");
    assert_eq!(resp["payload"]["scope"], "/etc");
    assert_eq!(event["event"], "capability.granted");
    assert_eq!(event["payload"]["capability"], "file_read");
    assert_eq!(event["payload"]["scope"], "/etc");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_capability_deny() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "capability.deny",
            serde_json::json!({
                "capability": "file_read",
                "scope": "/etc"
            }),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["capability"], "file_read");
    assert_eq!(resp["payload"]["scope"], "/etc");
    assert_eq!(event["event"], "capability.denied");
    assert_eq!(event["payload"]["capability"], "file_read");
    assert_eq!(event["payload"]["scope"], "/etc");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_conversation_link_detected() {
    let mut h = HostBridgeHarness::spawn().await;
    let (resp, event) = h
        .send_with_event(make_cmd(
            "conversation.link_detected",
            serde_json::json!({"url": "https://example.com/page"}),
        ))
        .await;
    assert_eq!(resp["ok"], true);
    assert_eq!(resp["payload"]["accepted"], true);
    assert_eq!(resp["payload"]["url"], "https://example.com/page");
    assert_eq!(event["event"], "conversation.link_detected");
    assert_eq!(event["payload"]["url"], "https://example.com/page");
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_conversation_link_detected_bad_scheme() {
    let mut h = HostBridgeHarness::spawn().await;
    let resp = h
        .send(make_cmd(
            "conversation.link_detected",
            serde_json::json!({"url": "javascript:alert(1)"}),
        ))
        .await;
    assert_error_response(&resp);
    h.shutdown().await;
}

#[tokio::test]
async fn e2e_rapid_fire_10_commands() {
    let mut h = HostBridgeHarness::spawn().await;

    for i in 0..10 {
        let cmd = serde_json::json!({
            "v": 1,
            "request_id": format!("rapid-{i}"),
            "command": "host.ping",
            "payload": {}
        });
        let resp = h.send(cmd).await;
        assert_eq!(resp["ok"], true, "ping {i} should succeed, got: {resp}");
        assert_eq!(resp["payload"]["pong"], true);
    }

    h.shutdown().await;
}

#[tokio::test]
async fn e2e_stdin_eof_clean_exit() {
    let h = HostBridgeHarness::spawn().await;
    // Immediately close stdin without sending any commands.
    h.shutdown().await;
    // If we reach here, the process exited with code 0.
}
