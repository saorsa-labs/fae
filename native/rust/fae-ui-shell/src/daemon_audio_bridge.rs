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

use std::ffi::CString;
use std::fs::{File, Metadata};
use std::io::{BufRead, BufReader, Cursor, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use fae_control_plane::{Command, AUTHENTICATE_COMMAND, BOOTSTRAP_CLIENT_ID, PROTOCOL_VERSION};
use serde::{Deserialize, Serialize};
use tao::event_loop::EventLoopProxy;
use zeroize::{Zeroize, Zeroizing};

use crate::orb_state::{InfoItem, InfoItems, OrbDaemonEvent};
use crate::UserEvent;

/// The maximum backoff between reconnect attempts (capped exponential).
const MAX_BACKOFF: Duration = Duration::from_secs(5);
/// Fixed-capacity authentication frame buffer. Serialization writes through a
/// bounded slice so secret-bearing bytes can never pass through `Vec` reallocation.
const AUTH_FRAME_BUFFER_BYTES: usize = 512;

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

/// Resolve the canonical private run directory. There are deliberately no
/// socket/token path overrides: privileged bootstrap authentication must stay
/// on the daemon-owned local boundary. MUST stay byte-identical to the daemon's
/// `data_directory()` + `run_directory()` (crates/fae-daemon/src/main.rs) or
/// the bridge polls the wrong socket and the orb never sees events:
/// - macOS: `$HOME/Library/Application Support/fae` (no XDG check — the daemon
///   does not consult `XDG_DATA_HOME` on macOS);
/// - Linux/other: `$XDG_DATA_HOME/fae` else `$HOME/.local/share/fae`.
fn run_dir() -> Result<PathBuf, String> {
    data_dir().map(|path| path.join("run"))
}

#[cfg(target_os = "macos")]
fn data_dir() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library/Application Support/fae"))
        .ok_or_else(|| "HOME is unset; refusing daemon credential discovery".to_owned())
}

#[cfg(not(target_os = "macos"))]
fn data_dir() -> Result<PathBuf, String> {
    if let Some(xdg) = std::env::var_os("XDG_DATA_HOME") {
        return Ok(PathBuf::from(xdg).join("fae"));
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(".local/share/fae"))
        .ok_or_else(|| {
            "HOME and XDG_DATA_HOME are unset; refusing daemon credential discovery".to_owned()
        })
}

const TOKEN_FILE_NAME: &str = "bootstrap.token";
/// The daemon's bootstrap token is exactly 32 random bytes hex-encoded — 64
/// lowercase hex characters, no trailing newline (`fae_control_plane::
/// generate_token` + the daemon's `write_secret_file`).
const TOKEN_HEX_BYTES: u64 = 64;

fn effective_uid() -> u32 {
    // SAFETY: `geteuid` has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

fn path_cstring(path: &Path) -> Result<CString, String> {
    CString::new(path.as_os_str().as_bytes())
        .map_err(|_| format!("path {} contains a NUL byte", path.display()))
}

fn enforce_owner_mode(
    meta: &Metadata,
    what: &str,
    path: &Path,
    expected_mode: u32,
) -> Result<(), String> {
    if meta.uid() != effective_uid() {
        return Err(format!(
            "{what} {} not owned by effective user",
            path.display()
        ));
    }
    let actual = meta.mode() & 0o777;
    if actual != expected_mode {
        return Err(format!(
            "{what} {} mode {actual:04o}, expected {expected_mode:04o}",
            path.display()
        ));
    }
    Ok(())
}

/// Open the run directory itself with `O_NOFOLLOW`, then validate the opened
/// descriptor. All credential access is relative to this anchored descriptor.
fn open_private_run_dir(path: &Path) -> Result<File, String> {
    let c_path = path_cstring(path)?;
    // SAFETY: `c_path` is NUL-terminated; flags require no variadic mode arg.
    let fd = unsafe {
        libc::open(
            c_path.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        return Err(format!(
            "open private run dir {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    // SAFETY: `fd` is a newly-owned descriptor returned by `open`.
    let file = unsafe { File::from_raw_fd(fd) };
    let meta = file
        .metadata()
        .map_err(|error| format!("fstat run dir {}: {error}", path.display()))?;
    if !meta.is_dir() {
        return Err(format!("run dir {} is not a directory", path.display()));
    }
    enforce_owner_mode(&meta, "run dir", path, 0o700)?;
    Ok(file)
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct SocketIdentity {
    device: u64,
    inode: u64,
}

/// Validate the canonical socket pathname before connect. Peer credentials are
/// checked again on the connected descriptor before the token is read or sent.
fn validate_socket(path: &Path) -> Result<SocketIdentity, String> {
    let meta = std::fs::symlink_metadata(path)
        .map_err(|e| format!("stat socket {}: {e}", path.display()))?;
    if meta.file_type().is_symlink() || !meta.file_type().is_socket() {
        return Err(format!(
            "socket {} is not a direct Unix socket",
            path.display()
        ));
    }
    if meta.nlink() != 1 {
        return Err(format!(
            "socket {} has unexpected link count",
            path.display()
        ));
    }
    enforce_owner_mode(&meta, "socket", path, 0o600)?;
    Ok(SocketIdentity {
        device: meta.dev(),
        inode: meta.ino(),
    })
}

fn validate_socket_identity(path: &Path, expected: SocketIdentity) -> Result<(), String> {
    let current = validate_socket(path)?;
    if current != expected {
        return Err(format!("socket {} changed during connect", path.display()));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn validate_connected_peer(stream: &UnixStream) -> Result<(), String> {
    // SAFETY: valid socket fd and correctly sized writable `ucred` buffer.
    let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let status = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            std::ptr::addr_of_mut!(credentials).cast(),
            &mut length,
        )
    };
    if status != 0 || length as usize != std::mem::size_of::<libc::ucred>() {
        return Err(format!(
            "read daemon peer credentials: {}",
            std::io::Error::last_os_error()
        ));
    }
    if credentials.uid != effective_uid() {
        return Err("daemon socket peer is not owned by effective user".to_owned());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn validate_connected_peer(stream: &UnixStream) -> Result<(), String> {
    let mut uid: libc::uid_t = 0;
    let mut gid: libc::gid_t = 0;
    // SAFETY: valid socket fd and writable uid/gid output pointers.
    let status = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    if status != 0 {
        return Err(format!(
            "read daemon peer credentials: {}",
            std::io::Error::last_os_error()
        ));
    }
    if uid != effective_uid() {
        return Err("daemon socket peer is not owned by effective user".to_owned());
    }
    Ok(())
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn validate_connected_peer(_stream: &UnixStream) -> Result<(), String> {
    Err("daemon peer credential validation is unsupported on this platform".to_owned())
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
    let run_dir_path = run_dir()?;
    let run_dir_handle = open_private_run_dir(&run_dir_path)?;
    let socket_path = run_dir_path.join("fae-daemon.sock");
    let socket_identity = validate_socket(&socket_path)?;

    let mut stream = UnixStream::connect(&socket_path)
        .map_err(|e| format!("connect({}): {e}", socket_path.display()))?;
    validate_socket_identity(&socket_path, socket_identity)?;
    validate_connected_peer(&stream)?;
    let token = read_token(&run_dir_handle, &run_dir_path)?;
    stream
        .set_read_timeout(None)
        .map_err(|e| format!("set_read_timeout: {e}"))?;

    authenticate(&mut stream, &token)?;
    // Drop and zeroize the source token immediately after sending the auth
    // frame. A rejected authentication surfaces as a failed session; the
    // reconnect loop reopens the token rather than caching it.
    drop(token);
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

/// Secret bytes backed by RustCrypto `Zeroizing`, whose volatile writes and
/// compiler fence prevent the wipe from being removed as a dead store. This
/// wrapper intentionally has no `Clone` or `Debug`.
struct SecretBytes(Zeroizing<Vec<u8>>);

impl SecretBytes {
    fn new(bytes: Vec<u8>) -> Self {
        Self(Zeroizing::new(bytes))
    }

    fn as_str(&self) -> Result<&str, String> {
        std::str::from_utf8(self.0.as_slice())
            .map_err(|_| "bootstrap token is not UTF-8".to_owned())
    }

    fn as_bytes(&self) -> &[u8] {
        self.0.as_slice()
    }

    #[cfg(test)]
    fn wipe(&mut self) {
        self.0.as_mut_slice().zeroize();
    }
}

/// Open `bootstrap.token` relative to the already-validated run-directory fd
/// with `O_NOFOLLOW`, then validate the opened file descriptor before reading.
fn read_token(run_dir: &File, run_dir_path: &Path) -> Result<SecretBytes, String> {
    let name = CString::new(TOKEN_FILE_NAME)
        .map_err(|_| "bootstrap token filename contains NUL".to_owned())?;
    // SAFETY: directory fd and C string are valid; flags require no mode arg.
    let fd = unsafe {
        libc::openat(
            run_dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        )
    };
    let display_path = run_dir_path.join(TOKEN_FILE_NAME);
    if fd < 0 {
        return Err(format!(
            "open token {}: {}",
            display_path.display(),
            std::io::Error::last_os_error()
        ));
    }
    // SAFETY: `fd` is a newly-owned descriptor returned by `openat`.
    let file = unsafe { File::from_raw_fd(fd) };
    let meta = file
        .metadata()
        .map_err(|error| format!("fstat token {}: {error}", display_path.display()))?;
    if !meta.is_file() {
        return Err(format!(
            "token {} is not a regular file",
            display_path.display()
        ));
    }
    enforce_owner_mode(&meta, "token", &display_path, 0o600)?;
    if meta.nlink() != 1 {
        return Err(format!(
            "token {} has unexpected link count",
            display_path.display()
        ));
    }
    if meta.len() != TOKEN_HEX_BYTES {
        return Err(format!(
            "token {} has invalid length",
            display_path.display()
        ));
    }

    // Include the bounded overflow probe byte up front: even a raced invalid
    // file cannot reallocate and abandon an earlier secret-bearing buffer.
    let mut bytes = Vec::with_capacity(TOKEN_HEX_BYTES as usize + 1);
    if let Err(error) = file.take(TOKEN_HEX_BYTES + 1).read_to_end(&mut bytes) {
        bytes.zeroize();
        return Err(format!("read token {}: {error}", display_path.display()));
    }
    if bytes.len() as u64 != TOKEN_HEX_BYTES
        || !bytes
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        bytes.zeroize();
        return Err(format!(
            "token {} has invalid content",
            display_path.display()
        ));
    }
    Ok(SecretBytes::new(bytes))
}

#[derive(Serialize)]
struct AuthPayload<'a> {
    client_id: &'static str,
    token: &'a str,
}

#[derive(Serialize)]
struct AuthFrame<'a> {
    v: u16,
    request_id: &'static str,
    command: &'static str,
    payload: AuthPayload<'a>,
}

/// Serialize authentication directly from the borrowed zeroizing token into a
/// single bounded, zeroizing output buffer. No `Value::String`, owned payload,
/// owned `Command`, or secret-bearing `Vec` reallocation is possible.
fn encode_auth_frame(token: &SecretBytes) -> Result<SecretBytes, String> {
    let frame = AuthFrame {
        v: PROTOCOL_VERSION,
        request_id: "sub-auth",
        command: AUTHENTICATE_COMMAND,
        payload: AuthPayload {
            client_id: BOOTSTRAP_CLIENT_ID,
            token: token.as_str()?,
        },
    };
    let mut output = SecretBytes::new(vec![0; AUTH_FRAME_BUFFER_BYTES]);
    let written = {
        let mut cursor = Cursor::new(output.0.as_mut_slice());
        serde_json::to_writer(&mut cursor, &frame)
            .map_err(|error| format!("encode {AUTHENTICATE_COMMAND}: {error}"))?;
        usize::try_from(cursor.position())
            .map_err(|error| format!("measure {AUTHENTICATE_COMMAND}: {error}"))?
    };
    output.0.truncate(written);
    Ok(output)
}

/// Authenticate under the daemon's single bootstrapped client id
/// ([`fae_control_plane::BOOTSTRAP_CLIENT_ID`]). The orb host is launched by the
/// same Swift frontend inside the same trust boundary and reads the same
/// `bootstrap.token`; `registry.authenticate` rejects any other id with
/// `UnknownClient`, which would leave the bridge reconnect-looping and the orb
/// stuck idle. The bootstrap client's `SwiftFrontend` scopes
/// (`StatusRead`/`ConversationRead`/`AudioPlayback`) are exactly what the
/// subscribed events (`info.update`/`assistant.generating`/`audio.level`)
/// require. The token is borrowed directly into one zeroize-backed serialized
/// frame and never copied into a `serde_json::Value` or owned protocol payload.
fn authenticate(stream: &mut UnixStream, token: &SecretBytes) -> Result<(), String> {
    let frame = encode_auth_frame(token)?;
    let result = write_secret_frame(stream, frame.as_bytes());
    drop(frame);
    result
}

/// Write a borrowed token-bearing frame without constructing another owned
/// buffer. The caller owns the zeroizing allocation and drops it after return.
fn write_secret_frame(stream: &mut UnixStream, frame: &[u8]) -> Result<(), String> {
    stream
        .write_all(frame)
        .map_err(|error| format!("send authentication: {error}"))?;
    stream
        .write_all(b"\n")
        .map_err(|error| format!("send authentication newline: {error}"))
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
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};

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

    // ── Descriptor-relative credential tests ─────────────────────────────
    //
    // Defend the hardened bootstrap path: the run dir and token are opened
    // relative to an anchored 0700 descriptor with O_NOFOLLOW, then the opened
    // fd is checked for ownership, mode, link count, regular-file-ness, and
    // exact 64-lowercase-hex content. Each test mutates exactly one variable so
    // a failure points at the broken invariant.
    //
    // Temp dirs are std-only (pid + AtomicU64 counter → unique per process and
    // per parallel test thread) with RAII cleanup. chmod is per-path, so the
    // process umask and environment are never mutated; no networking.

    static TEST_DIR_COUNTER: AtomicU64 = AtomicU64::new(0);

    /// Owned temp directory removed on drop. Unique across parallel test
    /// threads (counter) and across processes (pid).
    struct TestDir(PathBuf);
    impl TestDir {
        fn create() -> Self {
            let n = TEST_DIR_COUNTER.fetch_add(1, Ordering::SeqCst);
            let path = std::env::temp_dir()
                .join(format!("fae-credential-test-{}-{n}", std::process::id()));
            std::fs::create_dir(&path)
                .unwrap_or_else(|e| panic!("create test dir {}: {e}", path.display()));
            Self(path)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// `chmod` a path to an exact mode (not umask-masked) so fixtures are
    /// deterministic regardless of the process umask.
    fn chmod(path: &Path, mode: u32) {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
            .unwrap_or_else(|e| panic!("chmod {}: {e}", path.display()));
    }

    /// A fresh temp directory hardened to mode 0700, owned by the test user.
    fn hardened_run_dir() -> TestDir {
        let dir = TestDir::create();
        chmod(dir.path(), 0o700);
        dir
    }

    /// Write `bootstrap.token` into `dir` with `bytes` and harden it to 0600.
    fn write_token(dir: &Path, bytes: &[u8]) {
        let token = dir.join(TOKEN_FILE_NAME);
        std::fs::write(&token, bytes).unwrap_or_else(|e| panic!("write token: {e}"));
        chmod(&token, 0o600);
    }

    /// Extract the error from a `read_token` result without requiring
    /// `SecretBytes: Debug` — the secret type deliberately has no Debug, so
    /// `unwrap_err()` is unavailable. Panics if the token was accepted.
    fn expect_token_err(res: Result<SecretBytes, String>, context: &str) -> String {
        match res {
            Ok(_) => panic!("{context}: expected token rejection, got Ok"),
            Err(msg) => msg,
        }
    }

    /// 64 lowercase hex characters: the only accepted token content shape.
    const VALID_TOKEN_HEX: &str =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    // ── open_private_run_dir ──

    #[test]
    fn open_private_run_dir_accepts_hardened_directory() {
        let dir = hardened_run_dir();
        let file = open_private_run_dir(dir.path())
            .expect("0700 directory owned by the effective user is accepted");
        // The anchored descriptor must itself describe a 0700 directory owned
        // by us — descriptor-relative access hangs off this fd.
        let meta = file.metadata().expect("fstat anchored run-dir fd");
        assert!(meta.is_dir(), "anchored fd is the directory itself");
        assert_eq!(meta.mode() & 0o777, 0o700);
    }

    #[test]
    fn open_private_run_dir_rejects_symlink() {
        // O_NOFOLLOW must refuse even a symlink that points at a valid 0700 dir.
        let base = hardened_run_dir();
        let target = base.path().join("real");
        std::fs::create_dir(&target).unwrap();
        chmod(&target, 0o700);
        let link = base.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let err = open_private_run_dir(&link).unwrap_err();
        assert!(
            err.starts_with("open private run dir"),
            "symlink run dir must be refused at open time: {err}"
        );
    }

    #[test]
    fn open_private_run_dir_rejects_group_readable_mode() {
        let dir = hardened_run_dir();
        chmod(dir.path(), 0o750); // group-readable → insecure
        let err = open_private_run_dir(dir.path()).unwrap_err();
        assert!(
            err.contains("expected 0700"),
            "group/world-readable run dir must be rejected: {err}"
        );
    }

    // ── read_token ──

    #[test]
    fn read_token_accepts_hardened_lowercase_hex() {
        let dir = hardened_run_dir();
        write_token(dir.path(), VALID_TOKEN_HEX.as_bytes());

        // Open the anchored run-dir fd first, then read the token relative to
        // it — the descriptor-relative invariant is exercised end to end.
        let run_dir = open_private_run_dir(dir.path()).expect("run dir opens");
        let token = read_token(&run_dir, dir.path())
            .expect("0600 / nlink 1 / 64 lowercase hex bytes is accepted");
        // Round-trip: exactly the 64 lowercase hex bytes survive, no more.
        let s = token.as_str().expect("valid token is UTF-8");
        assert_eq!(s.len(), TOKEN_HEX_BYTES as usize);
        assert_eq!(s, VALID_TOKEN_HEX);
    }

    #[test]
    fn read_token_rejects_symlink() {
        let dir = hardened_run_dir();
        // A real, valid token elsewhere in the dir; bootstrap.token dangles at it.
        let real = dir.path().join("real");
        std::fs::write(&real, VALID_TOKEN_HEX.as_bytes()).unwrap();
        chmod(&real, 0o600);
        std::os::unix::fs::symlink(&real, dir.path().join(TOKEN_FILE_NAME)).unwrap();

        let run_dir = open_private_run_dir(dir.path()).expect("run dir opens");
        let err = expect_token_err(read_token(&run_dir, dir.path()), "symlink");
        assert!(
            err.starts_with("open token"),
            "token symlink must be refused via openat before any read: {err}"
        );
    }

    #[test]
    fn read_token_rejects_hardlink() {
        let dir = hardened_run_dir();
        write_token(dir.path(), VALID_TOKEN_HEX.as_bytes());
        // A second directory entry for the same inode → link count becomes 2.
        std::fs::hard_link(dir.path().join(TOKEN_FILE_NAME), dir.path().join("alias")).unwrap();

        let run_dir = open_private_run_dir(dir.path()).expect("run dir opens");
        let err = expect_token_err(read_token(&run_dir, dir.path()), "hardlink");
        assert!(
            err.contains("unexpected link count"),
            "hardlinked token must be rejected: {err}"
        );
    }

    #[test]
    fn read_token_rejects_group_readable_mode() {
        let dir = hardened_run_dir();
        write_token(dir.path(), VALID_TOKEN_HEX.as_bytes());
        chmod(&dir.path().join(TOKEN_FILE_NAME), 0o640); // group-readable → insecure

        let run_dir = open_private_run_dir(dir.path()).expect("run dir opens");
        let err = expect_token_err(read_token(&run_dir, dir.path()), "group-readable mode");
        assert!(
            err.contains("expected 0600"),
            "group/world-readable token must be rejected: {err}"
        );
    }

    #[test]
    fn read_token_rejects_invalid_length() {
        // The length check is the invariant under fire, so the bytes are valid
        // lowercase hex (or empty) — only the size is wrong.
        let case = |bytes: &[u8], label: &str| {
            let dir = hardened_run_dir();
            write_token(dir.path(), bytes);
            let run_dir = open_private_run_dir(dir.path()).expect("run dir opens");
            let err = expect_token_err(read_token(&run_dir, dir.path()), label);
            assert!(
                err.contains("invalid length"),
                "{label}: wrong-size token must be rejected on length: {err}"
            );
        };
        case(&[], "empty");
        case(&[b'a'; 63], "undersized (63 bytes)");
        case(&[b'a'; 65], "oversized (65 bytes)");
    }

    #[test]
    fn read_token_rejects_non_hex_content() {
        // Every fixture is exactly 64 bytes so the length check passes and the
        // content check is the invariant under fire.
        let case = |content: &[u8], label: &str| {
            let dir = hardened_run_dir();
            write_token(dir.path(), content);
            let run_dir = open_private_run_dir(dir.path()).expect("run dir opens");
            let err = expect_token_err(read_token(&run_dir, dir.path()), label);
            assert!(
                err.contains("invalid content"),
                "{label}: non-hex token content must be rejected: {err}"
            );
        };
        case(&[b'A'; 64], "uppercase hex (A-F rejected)");
        case(&[b'g'; 64], "out-of-range letter 'g'");
        let mut with_control = vec![b'a'; 64];
        with_control[10] = 0x01; // control byte inside otherwise-valid content
        case(&with_control, "control byte");
    }

    // ── Auth serializer: encode_auth_frame / write_secret_frame ──────────
    //
    // Defend the zeroizing authentication wire path: the bearer is borrowed
    // directly into a single zeroize-backed serialized frame and written by
    // `write_secret_frame` — never routed through `send_command(Value)` (the
    // second protocol path) nor copied into a `serde_json::Value::String`. The
    // expected bytes below are assembled by hand from the protocol constants,
    // NOT by serializing the production `AuthFrame`/`AuthPayload` structs, so a
    // reordered/added/dropped field, a wrong constant, or a reverted
    // `Value`-based encoder reddens these tests. No networking: a local
    // `UnixStream::pair` is fully deterministic.

    /// Exact compact JSON the daemon expects for a bootstrap auth frame, built
    /// independently of the production serializer so the test cannot echo it.
    fn expected_auth_frame_json(token_hex: &str) -> String {
        format!(
            "{{\"v\":{},\"request_id\":\"sub-auth\",\"command\":\"{}\",\
             \"payload\":{{\"client_id\":\"{}\",\"token\":\"{}\"}}}}",
            PROTOCOL_VERSION, AUTHENTICATE_COMMAND, BOOTSTRAP_CLIENT_ID, token_hex,
        )
    }

    #[test]
    fn encode_auth_frame_emits_exact_protocol_authenticate_bytes() {
        let token = SecretBytes::new(VALID_TOKEN_HEX.as_bytes().to_vec());
        // Type-level assertion: the encoder returns the zeroizing buffer, not a
        // serde_json::Value or a plain Vec. Restoring an owned
        // send_command(Value) path fails this binding at compile time.
        let frame: SecretBytes = encode_auth_frame(&token).expect("valid hex token encodes");

        let expected = expected_auth_frame_json(VALID_TOKEN_HEX);

        // Buffer content is read only through the borrowed accessors (no clone,
        // no conversion to an owning type). Both accessors must agree and the
        // bytes must be exact — compact, key order = struct declaration order,
        // and NO trailing newline inside the frame buffer.
        assert_eq!(
            frame.as_bytes(),
            expected.as_bytes(),
            "encoded frame must equal the canonical session.authenticate wire bytes"
        );
        assert_eq!(
            frame.as_str().expect("encoded frame is valid UTF-8"),
            expected.as_str(),
            "borrowed &str view must match the same bytes"
        );
    }

    #[test]
    fn write_secret_frame_writes_frame_then_single_newline_over_pair() {
        // Isolated write contract: the borrowed frame bytes go out followed by
        // exactly one '\n' — no duplication, no second protocol path, no missing
        // newline. Deliberately arbitrary bytes so this pins the writer, not the
        // encoder.
        let (mut writer, mut reader) = UnixStream::pair().expect("unix pair");
        let frame = br#"{"not":"a real frame","just":42}"#;

        write_secret_frame(&mut writer, frame).expect("write succeeds");

        // Signal EOF on the write half so read_to_end returns deterministically
        // rather than racing the socket buffer.
        writer
            .shutdown(std::net::Shutdown::Write)
            .expect("shutdown write half");
        let mut received = Vec::new();
        reader.read_to_end(&mut received).expect("read all bytes");

        let mut expected = frame.to_vec();
        expected.push(b'\n');
        assert_eq!(received, expected, "exact frame bytes + one newline");
        // Exactly one newline guards against a duplicated-frame / trailing-bytes
        // regression in the secret write path.
        assert_eq!(
            received.iter().filter(|&&b| b == b'\n').count(),
            1,
            "exactly one line terminator"
        );
    }

    #[test]
    fn authenticate_writes_exact_zeroizing_auth_wire_over_pair() {
        // End-to-end auth wire contract: authenticate() must encode the borrowed
        // token into one zeroize-backed frame, emit frame + single '\n' via
        // write_secret_frame, then drop the frame — all over the single Unix
        // path. If authenticate reverts to send_command(Value) the emitted bytes
        // diverge (or a second protocol path appears) and this reddens.
        let (mut writer, mut reader) = UnixStream::pair().expect("unix pair");
        let token = SecretBytes::new(VALID_TOKEN_HEX.as_bytes().to_vec());

        authenticate(&mut writer, &token).expect("authenticate writes");

        writer
            .shutdown(std::net::Shutdown::Write)
            .expect("shutdown write half");
        let mut received = Vec::new();
        reader.read_to_end(&mut received).expect("read all bytes");

        let mut expected = expected_auth_frame_json(VALID_TOKEN_HEX).into_bytes();
        expected.push(b'\n');
        assert_eq!(
            received, expected,
            "authenticate must emit the exact auth frame + one newline, nothing else"
        );
    }

    // ── Descriptor anchoring vs ancestor/path replacement (TOCTOU) ────────
    //
    // read_token resolves bootstrap.token via openat(2) against the already-
    // validated run-dir fd, never against the display pathname. So an attacker
    // who renames the real run dir away and plants a replacement directory at
    // the original pathname (carrying a different token) between the fd anchor
    // and the read must NOT redirect which token is read. A reverted path-
    // based open (File::open(display_path) instead of openat(run_dir_fd))
    // reddens this. Everything lives under one TestDir so Drop cleans up the
    // relocated dir, the planted replacement, and both token files.

    #[test]
    fn read_token_anchored_fd_ignores_replacement_at_original_pathname() {
        let root = hardened_run_dir();
        let run_path = root.path().join("run");
        std::fs::create_dir(&run_path).expect("create run dir");
        chmod(&run_path, 0o700);
        write_token(&run_path, VALID_TOKEN_HEX.as_bytes());

        // Anchor the run-dir fd BEFORE any swap.
        let run_dir = open_private_run_dir(&run_path).expect("anchored run-dir fd");

        // Swap the ancestor: move the real token-bearing dir aside, then plant
        // a replacement directory at the original pathname carrying a distinct
        // but equally-valid token.
        let relocated = root.path().join("run-relocated");
        std::fs::rename(&run_path, &relocated).expect("relocate real run dir");
        std::fs::create_dir(&run_path).expect("plant replacement run dir");
        chmod(&run_path, 0o700);
        const REPLACEMENT_HEX: &str =
            "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
        let replacement_token = run_path.join(TOKEN_FILE_NAME);
        std::fs::write(&replacement_token, REPLACEMENT_HEX.as_bytes())
            .expect("write replacement token");
        chmod(&replacement_token, 0o600);

        // The display path now resolves to the REPLACEMENT dir; the anchored fd
        // still resolves to the ORIGINAL. read_token must yield the original.
        let token = read_token(&run_dir, &run_path)
            .expect("anchored fd reads the original token despite pathname swap");

        assert_ne!(
            token.as_bytes(),
            REPLACEMENT_HEX.as_bytes(),
            "must NOT read the planted replacement token"
        );
        assert_eq!(
            token.as_str().expect("valid token is UTF-8"),
            VALID_TOKEN_HEX,
            "anchored fd must read the ORIGINAL token, not the pathname's replacement"
        );
    }

    // ── Socket identity TOCTOU ────────────────────────────────────────────
    //
    // validate_socket_identity re-checks dev/inode right before connect and
    // must reject a socket file swapped in at the same pathname between the
    // pre-connect validate_socket and the re-check. The original socket is
    // RELOCATED via rename (not unlinked) with its listener still bound, so its
    // inode stays allocated and the replacement is GUARANTEED a fresh inode —
    // no sleeps, no flaky inode reuse. Both sockets live under one TestDir.

    #[test]
    fn validate_socket_identity_rejects_replacement_socket_at_same_path() {
        use std::os::unix::net::UnixListener;

        let dir = hardened_run_dir();
        let sock = dir.path().join("bridge.sock");

        // Bind + harden the canonical socket, then capture its identity.
        let listener_original = UnixListener::bind(&sock).expect("bind original socket");
        chmod(&sock, 0o600);
        let original = validate_socket(&sock).expect("validate original socket");

        // Relocate the original socket file via rename — its inode stays
        // allocated (and the listener stays bound) so the replacement is forced
        // onto a fresh inode. No unlink, no sleep, no flake.
        let relocated = dir.path().join("bridge.sock.relocated");
        std::fs::rename(&sock, &relocated).expect("relocate original socket");

        // Plant a replacement listener at the now-free original pathname.
        let listener_replacement = UnixListener::bind(&sock).expect("bind replacement socket");
        chmod(&sock, 0o600);

        // The identity re-check must FAIL: same device (same filesystem) but a
        // different inode — the swap is caught purely by the inode comparison.
        let err = validate_socket_identity(&sock, original).unwrap_err();
        assert!(
            err.contains("changed during connect"),
            "replacement socket must be rejected by dev/inode identity: {err}"
        );

        // The replacement is itself a valid socket — proves the rejection was
        // the identity mismatch, not a generic path/format error, and that the
        // catch is the INODE (device is necessarily equal on one filesystem).
        let replacement = validate_socket(&sock).expect("replacement is itself a valid socket");
        assert_eq!(
            replacement.device, original.device,
            "same filesystem → same device; the catch must be the inode"
        );
        assert_ne!(
            replacement.inode, original.inode,
            "replacement must have a distinct inode from the original"
        );

        // Drop listeners before TestDir removes the directory.
        drop(listener_original);
        drop(listener_replacement);
    }

    // ── Explicit zeroization primitive ────────────────────────────────────
    //
    // wipe() must overwrite every byte of both secret allocations — the source
    // token and the serialized auth frame — with zero, in place (length
    // preserved). A wipe that clear()s or reallocs would leave the old secret
    // bytes in freed memory; the length assertions catch that regression.
    // Drop-time wiping is provided by the inner `Zeroizing<Vec<u8>>` (volatile
    // writes + compiler fence over the full capacity) — confirmed by reading
    // the source, NOT by unsafe post-drop memory inspection, which is
    // forbidden here.

    #[test]
    fn wipe_zeroes_source_token_and_encoded_frame_in_place() {
        // Non-zero secret material in both allocations before wipe; capture
        // lengths so a wipe that truncates/reallocs is caught.
        let mut token = SecretBytes::new(VALID_TOKEN_HEX.as_bytes().to_vec());
        let mut frame: SecretBytes = encode_auth_frame(&token).expect("valid token encodes");

        let token_len = token.as_bytes().len();
        let frame_len = frame.as_bytes().len();
        assert!(
            token.as_bytes().iter().any(|&b| b != 0),
            "fixture must contain non-zero secret bytes to wipe"
        );
        assert!(
            frame.as_bytes().iter().any(|&b| b != 0),
            "encoded frame must contain non-zero secret bytes to wipe"
        );

        token.wipe();
        frame.wipe();

        assert!(
            token.as_bytes().iter().all(|&b| b == 0),
            "source token buffer must be entirely zero after wipe"
        );
        assert!(
            frame.as_bytes().iter().all(|&b| b == 0),
            "encoded frame buffer must be entirely zero after wipe"
        );
        // wipe fills in place — it must never shrink the allocation (a clear()
        // would leave the old secret bytes in the freed tail).
        assert_eq!(
            token.as_bytes().len(),
            token_len,
            "wipe must preserve source token length"
        );
        assert_eq!(
            frame.as_bytes().len(),
            frame_len,
            "wipe must preserve encoded frame length"
        );
    }
}
