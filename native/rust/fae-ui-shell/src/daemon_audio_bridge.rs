//! Voice spine V4b — direct daemon audio bridge (Linux / headless face).
//!
//! When the orb host runs WITHOUT the Swift relay (a Linux face, or a headless
//! orb), it subscribes to the daemon's `audio.level` event stream itself and
//! drives `bridge_audio` directly. This mirrors the Swift `DaemonEventSubscriber`
//! (own connection, authenticate, `conversation.subscribe`, demux `{event,
//! payload}`), but feeds `UserEvent::DaemonAudio` into the tao event loop so the
//! render thread applies it.
//!
//! Compile-gated: Unix-only (`#![cfg(unix)]`). Runtime-gated by
//! `FAE_ORB_DAEMON_AUDIO` — **default ON** (the orb host owns its mode from the
//! daemon now); set `FAE_ORB_DAEMON_AUDIO=0/false/off/no` to disable and fall
//! back to a calm idle (the retired Swift relay no longer feeds `state.audio`).
//!
//! Reconnect: on any error the bridge sleeps with capped exponential backoff
//! (250 ms → … → 5 s) and reconnects. It NEVER blocks the render loop — it runs
//! on its own thread and communicates only via the event-loop proxy.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use fae_control_plane::{Command, PROTOCOL_VERSION};
use serde::Deserialize;
use tao::event_loop::EventLoopProxy;

use crate::orb_state::{InfoItem, InfoItems, OrbDaemonEvent};
use crate::UserEvent;

/// The maximum backoff between reconnect attempts (capped exponential).
const MAX_BACKOFF: Duration = Duration::from_secs(5);

/// Spawn the daemon bridge on its own thread. Returns immediately; the thread
/// runs until the event-loop proxy is dropped (process exit). Default ON (the
/// orb host owns its state from the daemon now); `FAE_ORB_DAEMON_AUDIO=
/// 0/false/off/no` disables it explicitly. When ON but no socket/token is
/// reachable, the bridge logs + retries with backoff (the orb falls back to a
/// calm idle in the meantime).
pub fn spawn_daemon_bridge(proxy: EventLoopProxy<UserEvent>) {
    if !runtime_enabled() {
        return;
    }
    thread::spawn(move || run_loop(proxy));
}

/// Default ON. Explicitly OFF only via `FAE_ORB_DAEMON_AUDIO=0/false/off/no`.
fn runtime_enabled() -> bool {
    !matches!(
        std::env::var("FAE_ORB_DAEMON_AUDIO")
            .ok()
            .as_deref()
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("0" | "false" | "off" | "no")
    )
}

/// Resolve the daemon socket path: explicit `FAE_DAEMON_SOCK` override,
/// else `<run_dir>/fae-daemon.sock` (mirrors the daemon's own path).
fn resolve_socket() -> PathBuf {
    if let Some(sock) = std::env::var_os("FAE_DAEMON_SOCK") {
        return PathBuf::from(sock);
    }
    run_dir().join("fae-daemon.sock")
}

/// Resolve the bootstrap token: explicit `FAE_DAEMON_TOKEN` override, else
/// `<run_dir>/bootstrap.token`.
fn resolve_token_path() -> PathBuf {
    if let Some(tok) = std::env::var_os("FAE_DAEMON_TOKEN") {
        return PathBuf::from(tok);
    }
    run_dir().join("bootstrap.token")
}

/// Resolve the daemon run dir: explicit override first, else the platform data
/// dir + "run" (mirrors the daemon's own `run_directory()`).
fn run_dir() -> PathBuf {
    if let Some(override_dir) = std::env::var_os("FAE_DAEMON_RUN_DIR") {
        return PathBuf::from(override_dir);
    }
    let base = match std::env::var_os("XDG_DATA_HOME") {
        Some(xdg) => PathBuf::from(xdg).join("fae"),
        None => home_data_dir().join("fae"),
    };
    base.join("run")
}

#[cfg(target_os = "macos")]
fn home_data_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library/Application Support"))
        .unwrap_or_else(|| PathBuf::from("."))
}

#[cfg(not(target_os = "macos"))]
fn home_data_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Connect → authenticate → subscribe → read loop, forever, with reconnect
/// backoff. Never returns except on proxy drop (process exit).
fn run_loop(proxy: EventLoopProxy<UserEvent>) {
    let mut backoff = Duration::from_millis(250);
    loop {
        match session(&proxy) {
            Ok(()) => {
                // The read loop only returns Ok on a clean socket close or proxy
                // drop — reconnect (the daemon may restart).
                log::info!("daemon-audio-bridge: session ended; reconnecting");
            }
            Err(error) => {
                log::warn!("daemon-audio-bridge: {error}; reconnecting");
            }
        }
        if proxy
            .send_event(UserEvent::DaemonOrb(OrbDaemonEvent::ConnectionReset))
            .is_err()
        {
            return; // event loop gone — exit.
        }
        thread::sleep(backoff);
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

/// One full session: connect, auth, subscribe, then drain the event stream
/// until the socket closes or an error occurs.
fn session(proxy: &EventLoopProxy<UserEvent>) -> Result<(), String> {
    let socket_path = resolve_socket();
    let token = read_token(&resolve_token_path())?;

    let mut stream = UnixStream::connect(&socket_path)
        .map_err(|e| format!("connect({}): {e}", socket_path.display()))?;
    stream
        .set_read_timeout(None)
        .map_err(|e| format!("set_read_timeout: {e}"))?;

    authenticate(&mut stream, &token)?;
    subscribe(&mut stream)?;

    // Read loop: one JSON object per line. Demux by the `event` key (a Response
    // has no `event` field; `deny_unknown_fields` would reject it if decoded as
    // an Event, so we decode into a permissive shape and inspect). Each mapped
    // event is forwarded as a `DaemonOrb` user event; the render loop runs the
    // grace-hold state machine + applies the audio level.
    let reader = BufReader::new(&stream);
    for line in reader.lines() {
        let line = line.map_err(|e| format!("recv: {e}"))?;
        let frame: EventFrame = match serde_json::from_str(&line) {
            Ok(frame) => frame,
            Err(_) => continue, // non-event / response frame — ignore
        };
        let Some(event_name) = frame.event.as_deref() else {
            continue;
        };
        // Map the wire event to an OrbDaemonEvent to forward. Kept out of the
        // match arms so no proxy call lives in a guard (clippy collapsible).
        let forward: Option<OrbDaemonEvent> = match event_name {
            "assistant.generating" => frame
                .payload
                .get("active")
                .and_then(|v| v.as_bool())
                .map(OrbDaemonEvent::Generating),
            "audio.level" => frame
                .payload
                .get("rms")
                .and_then(|v| v.as_f64())
                .map(|rms| OrbDaemonEvent::AudioLevel(rms.clamp(0.0, 1.0) as f32)),
            "audio.playback_ended" => Some(OrbDaemonEvent::PlaybackEnded),
            "info.update" => parse_info_items(&frame.payload).map(OrbDaemonEvent::InfoUpdate),
            _ => None, // forward-compatible: ignore unknown events.
        };
        if let Some(event) = forward {
            if proxy.send_event(UserEvent::DaemonOrb(event)).is_err() {
                return Ok(()); // event loop gone.
            }
        }
    }
    Ok(())
}

/// Parse `info.update { items: [{id,kind,title,action?}] }`. Drops malformed
/// items rather than failing the whole frame (a partial update is still
/// useful). The optional `action` carries the click-routing payload.
fn parse_info_items(payload: &serde_json::Value) -> Option<InfoItems> {
    let items = payload.get("items")?.as_array()?;
    let parsed: Vec<InfoItem> = items
        .iter()
        .filter_map(|item| {
            Some(InfoItem {
                id: item.get("id")?.as_str()?.to_owned(),
                kind: item.get("kind")?.as_str()?.to_owned(),
                title: item.get("title")?.as_str()?.to_owned(),
                action: item
                    .get("action")
                    .and_then(|v| v.as_str())
                    .map(str::to_owned),
            })
        })
        .collect();
    Some(InfoItems { items: parsed })
}

fn read_token(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path)
        .map(|s| s.trim().to_owned())
        .map_err(|e| format!("read token {}: {e}", path.display()))
        .and_then(|t| {
            if t.is_empty() {
                Err("bootstrap token is empty".to_owned())
            } else {
                Ok(t)
            }
        })
}

/// Authenticate under the daemon's single bootstrapped client id
/// ([`fae_control_plane::BOOTSTRAP_CLIENT_ID`]). The orb host is launched by the
/// same Swift frontend inside the same trust boundary and reads the same
/// `bootstrap.token`; `registry.authenticate` rejects any other id with
/// `UnknownClient`, which would leave the bridge reconnect-looping and the orb
/// stuck idle. The bootstrap client's `SwiftFrontend` scopes
/// (`StatusRead`/`ConversationRead`/`AudioPlayback`) are exactly what the
/// subscribed events (`info.update`/`assistant.generating`/`audio.level`)
/// require.
fn authenticate(stream: &mut UnixStream, token: &str) -> Result<(), String> {
    send_command(
        stream,
        "sub-auth",
        "session.authenticate",
        serde_json::json!({
            "client_id": fae_control_plane::BOOTSTRAP_CLIENT_ID,
            "token": token,
        }),
    )
}

fn subscribe(stream: &mut UnixStream) -> Result<(), String> {
    send_command(
        stream,
        "sub-1",
        "conversation.subscribe",
        serde_json::json!({}),
    )
}

/// Send a command frame. We do NOT wait for the ack — the read loop drains it as
/// a non-event frame (ignored). Errors surface as a failed session → reconnect.
fn send_command(
    stream: &mut UnixStream,
    request_id: &str,
    command: &str,
    payload: serde_json::Value,
) -> Result<(), String> {
    let frame = Command {
        v: PROTOCOL_VERSION,
        request_id: request_id.to_owned(),
        command: command.to_owned(),
        payload,
    };
    let mut line = serde_json::to_string(&frame).map_err(|e| format!("encode: {e}"))?;
    line.push('\n');
    stream
        .write_all(line.as_bytes())
        .map_err(|e| format!("send {command}: {e}"))
}

/// A permissive wire frame — `event` is present on server-push events and absent
/// on responses, so decoding succeeds for both and we branch on `event`.
#[derive(Debug, Deserialize)]
struct EventFrame {
    #[serde(default)]
    event: Option<String>,
    #[serde(default)]
    payload: serde_json::Value,
}

#[cfg(test)]
mod tests {
    use super::parse_info_items;

    #[test]
    fn parse_info_items_with_action() {
        let payload = serde_json::json!({
            "items": [
                {"id":"r1","kind":"research","title":"New research result","action":"https://example.org/r/1"},
                {"id":"wa","kind":"app","title":"WhatsApp"}
            ]
        });
        let parsed = parse_info_items(&payload).expect("parsed");
        assert_eq!(parsed.items.len(), 2);
        assert_eq!(
            parsed.items[0].action.as_deref(),
            Some("https://example.org/r/1")
        );
        assert!(parsed.items[1].action.is_none());
    }

    #[test]
    fn parse_info_items_drops_malformed() {
        // Missing `kind` and a non-string `title` are dropped; the valid item survives.
        let payload = serde_json::json!({
            "items": [
                {"id":"ok","kind":"url","title":"good","action":"https://x"},
                {"id":"bad","title":"no kind"},
                {"id":"bad2","kind":"url","title":{"nested":true}}
            ]
        });
        let parsed = parse_info_items(&payload).expect("parsed");
        assert_eq!(parsed.items.len(), 1);
        assert_eq!(parsed.items[0].id, "ok");
    }

    #[test]
    fn parse_info_items_missing_items_returns_none() {
        assert!(parse_info_items(&serde_json::json!({})).is_none());
        assert!(parse_info_items(&serde_json::json!({"items": "notarray"})).is_none());
    }
}
