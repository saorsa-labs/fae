//! Fae headless-core daemon — **Phase 1 skeleton**.
//!
//! Control-plane-first discipline: this skeleton wires up the *authorization*
//! path (bootstrap a session token, build a client record, decide + audit a
//! command) **before** any network listener exists. The Unix-socket/WebSocket
//! server and the mistral.rs engine adapter are explicit subsequent chunks
//! (marked `CHUNK 2` / `CHUNK 3` below) and are gated by the same
//! `fae-control-plane` authorization the demo exercises here.
//!
//! Run: `cargo run -p fae-daemon`. It bootstraps a private run directory + token
//! and prints a sample authorized command flow. No ports are opened.
#![forbid(unsafe_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use fae_control_plane::{
    append_audit_jsonl, authorize, generate_token, hash_token, AuditEvent, ClientClass,
    ClientRecord, Command, PROTOCOL_VERSION,
};

const THIRTY_DAYS_MS: u64 = 30 * 24 * 60 * 60 * 1000;

type DaemonResult<T> = Result<T, Box<dyn std::error::Error>>;

fn main() -> DaemonResult<()> {
    println!("fae-daemon (Phase 1 skeleton) — protocol v{PROTOCOL_VERSION}");

    let run_dir = run_directory()?;
    create_private_dir(&run_dir)?;
    let socket_path = run_dir.join("fae-daemon.sock");
    println!("run dir : {} (0700)", run_dir.display());
    println!(
        "socket  : {} (CHUNK 2: bind + serve)",
        socket_path.display()
    );

    // ── Bootstrap the first client (the Swift frontend launched by the owner) ──
    let now_ms = now_ms()?;
    let token = generate_token()?;
    let token_hash = hash_token(&token);
    let token_path = run_dir.join("bootstrap.token");
    write_secret_file(&token_path, &token)?; // file fallback; CHUNK 2: macOS Keychain
    println!(
        "token   : {} (0600, hash {}…)",
        token_path.display(),
        &token_hash.to_hex()[..12]
    );

    let client = ClientRecord {
        client_id: "swift-frontend-bootstrap".to_owned(),
        class: ClientClass::SwiftFrontend,
        scopes: ClientClass::SwiftFrontend
            .default_scopes()
            .into_iter()
            .collect(),
        issued_at_ms: now_ms,
        expires_at_ms: now_ms + THIRTY_DAYS_MS,
        revoked_at_ms: None,
        display_name: "Fae (this Mac)".to_owned(),
    };

    let audit_path = run_dir.join("audit.jsonl");

    // ── Demonstrate the chokepoint: an allowed command and a denied one ──
    let allowed = Command {
        v: PROTOCOL_VERSION,
        request_id: "demo-1".to_owned(),
        command: "conversation.inject_text".to_owned(),
        payload: serde_json::json!({ "text": "hello" }),
    };
    let denied = Command {
        v: PROTOCOL_VERSION,
        request_id: "demo-2".to_owned(),
        command: "runtime.shutdown".to_owned(), // needs `admin`, which the frontend lacks
        payload: serde_json::Value::Null,
    };

    for cmd in [&allowed, &denied] {
        let decision = authorize(&client, cmd, now_ms);
        let event = AuditEvent::from_authz(
            next_event_id(now_ms),
            now_ms,
            Some(client.client_id.clone()),
            cmd,
            &decision,
        );
        append_audit_jsonl(&audit_path, &event)?;
        println!("authz   : {:<28} -> {:?}", cmd.command, decision);
    }
    println!("audit   : {} (jsonl)", audit_path.display());

    println!();
    println!("NEXT (gated by this control plane):");
    println!("  CHUNK 2 — Unix-socket + WS listener: Host/Origin checks, single-use stream");
    println!("            tickets, per-message authorize(), peer input via fae-envelope-gate.");
    println!("  CHUNK 3 — engine adapter: mistral.rs (E4B + Qwen3-14B) + llama.cpp fallback,");
    println!("            models.lock fail-closed loader.");
    Ok(())
}

/// Owner-private run directory: `~/Library/Application Support/fae/run` on macOS,
/// `$XDG_DATA_HOME/fae/run` (or `~/.local/share/fae/run`) on Linux.
fn run_directory() -> DaemonResult<PathBuf> {
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    let home = PathBuf::from(home);
    #[cfg(target_os = "macos")]
    let base = home.join("Library/Application Support/fae");
    #[cfg(not(target_os = "macos"))]
    let base = match std::env::var_os("XDG_DATA_HOME") {
        Some(xdg) => PathBuf::from(xdg).join("fae"),
        None => home.join(".local/share/fae"),
    };
    Ok(base.join("run"))
}

/// Create the private run directory with `0700` from birth. The leaf is created
/// in a single syscall at mode `0700` (no world-readable window between
/// `create` and `chmod`); only its ancestors go through `create_dir_all`. If
/// the leaf already exists we re-tighten it.
fn create_private_dir(path: &Path) -> DaemonResult<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        match std::fs::DirBuilder::new().mode(0o700).create(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
            }
            Err(error) => return Err(error.into()),
        }
    }
    #[cfg(not(unix))]
    std::fs::create_dir_all(path)?;
    Ok(())
}

/// Write a secret to a `0600` file that is created fresh and exclusively. Any
/// stale file is removed first, then `create_new` (`O_EXCL`) + `mode(0600)`
/// creates the file atomically at the right permissions — there is no window
/// where the plaintext lives in a pre-existing, looser-permissioned file. On
/// `0600` the owner bits are immune to umask, so no post-chmod is needed.
fn write_secret_file(path: &Path, contents: &str) -> DaemonResult<()> {
    use std::io::Write;
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    let mut open = std::fs::OpenOptions::new();
    open.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        open.mode(0o600);
    }
    let mut file = open.open(path)?;
    file.write_all(contents.as_bytes())?;
    Ok(())
}

fn now_ms() -> DaemonResult<u64> {
    let dur = SystemTime::now().duration_since(UNIX_EPOCH)?;
    Ok(u64::try_from(dur.as_millis())?)
}

/// Monotonic, non-secret audit correlation id. An event id only needs to be
/// unique and ordered — never use a CSPRNG bearer token here (that conflates
/// secret material with log fields and makes every command pay a `getrandom`
/// syscall that could fail the command).
fn next_event_id(now_ms: u64) -> String {
    static EVENT_SEQ: AtomicU64 = AtomicU64::new(0);
    let seq = EVENT_SEQ.fetch_add(1, Ordering::Relaxed);
    format!("evt-{now_ms}-{seq}")
}
