//! #36 orphaned `llama-server` — G2 gate test (the post-fix pass criterion).
//!
//! CI-race-safe: an OS-assigned ephemeral port + a per-process temp dir, so
//! parallel `cargo test` runs never collide. Stdlib only (no reqwest/serde_json —
//! those are engine deps, not dev-deps, so unavailable here). Asserts the full
//! no-crash-loop contract:
//!
//! 1. a stale sidecar squatting the port (with a leftover pidfile — the state an
//!    unclean SIGKILL/crash leaves behind) is **reclaimed** (SIGTERM→grace→SIGKILL)
//!    before a fresh sidecar binds;
//! 2. the port is **freed** then bound by the **new** child;
//! 3. the new child is **healthy** and its `/v1/models` identity **matches** the
//!    configured alias (the await_ready identity-gap fix — a stale server is no
//!    longer silently trusted);
//! 4. the new child's pidfile is `0600` in the private run dir, removed on clean
//!    shutdown; **no orphan process remains**.

// Test code: panicking on assertion failure is the point; unwrap/expect are
// permitted for clarity, mirroring the lib's `#[cfg_attr(test, allow(...))]`.
#![allow(clippy::unwrap_used)]
#![allow(clippy::expect_used)]
#![allow(clippy::panic)]

use fae_engine::{
    KvCacheType, LlamaModelSource, LlamaServerAdapter, LlamaServerConfig, ProviderAdapter,
};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

/// Path to the stand-in `llama-server` example (`CARGO_BIN_EXE_<example>`).
const STANDIN: &str = env!("CARGO_BIN_EXE_standin_llama_server");
const ALIAS: &str = "gemma-4";

/// Grab a free loopback port the OS hands us (bind :0, read it, drop). Tiny race
/// window before the orphan rebinds — acceptable + standard for ephemeral ports.
fn ephemeral_port() -> u16 {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    listener.local_addr().unwrap().port()
}

/// Wait until something is accepting TCP on `port`.
fn wait_until_listening(port: u16) {
    for _ in 0..100 {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("nothing ever listened on {port}");
}

/// Minimal HTTP/1.0 GET → response body (stdlib only).
fn http_get(port: u16, path: &str) -> String {
    let mut stream = TcpStream::connect_timeout(
        &format!("127.0.0.1:{port}").parse().unwrap(),
        Duration::from_millis(500),
    )
    .unwrap();
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = stream.write_all(format!("GET {path} HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n").as_bytes());
    let mut buf = Vec::new();
    let _ = stream.read_to_end(&mut buf);
    String::from_utf8_lossy(&buf).to_string()
}

fn standin_config(port: u16, pidfile_root: &Path) -> LlamaServerConfig {
    LlamaServerConfig {
        binary: STANDIN.to_owned(),
        model: LlamaModelSource::Local {
            model_gguf: "/dev/null".to_owned(),
            mmproj: None,
            mtp_draft: None,
        },
        lora_gguf: None,
        alias: ALIAS.to_owned(),
        enable_thinking: false,
        mtp_draft_tokens: None,
        port,
        ctx_size: 4096,
        ngl: 0,
        kv_cache_type: KvCacheType::F16,
        pidfile_root: Some(pidfile_root.to_path_buf()),
    }
}

#[tokio::test]
async fn reclaims_orphan_then_binds_and_identity_verifies() {
    let port = ephemeral_port();
    // Unique per test process → safe under parallel `cargo test`.
    let tmp = std::env::temp_dir().join(format!("fae-orphan-reclaim-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    let pidfile = tmp.join(format!("llama-server.{port}.pid"));

    // ── Set up the orphan: a stale sidecar squatting `port` + a leftover pidfile,
    //    exactly what an unclean daemon death (SIGKILL skips Drop) leaves behind.
    //    Its alias differs from the fresh server's, so a non-reclaiming spawn would
    //    hit the identity check and fail loud.
    let mut orphan = Command::new(STANDIN)
        .args(["--port", &port.to_string(), "--alias", "stale-orphan"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let orphan_pid = orphan.id();
    std::fs::write(&pidfile, orphan_pid.to_string()).unwrap();
    wait_until_listening(port);

    // ── Fresh spawn = next daemon launch. reclaim must read the pidfile, confirm
    //    the holder is our sidecar, kill it, free the port, then launch a NEW child
    //    that binds + becomes healthy + identity-verifies.
    let adapter = LlamaServerAdapter::spawn(standin_config(port, &tmp), ALIAS)
        .await
        .expect("spawn must reclaim the orphan, bind the port, and verify identity");

    // (1) The orphan was reclaimed — killed by reclaim's SIGTERM/SIGKILL.
    let orphan_status = orphan
        .try_wait()
        .expect("polling the orphan must not error");
    assert!(
        orphan_status.is_some(),
        "stale sidecar must be reclaimed (killed), not left squatting the port"
    );

    // (2) The port is bound by the NEW child (something healthy is listening).
    assert!(
        TcpStream::connect(("127.0.0.1", port)).is_ok(),
        "port must be bound by the new child after reclaim"
    );

    // (3) Identity-verified: the new child serves the configured alias (NOT the
    //     orphan's "stale-orphan"). A direct /v1/models GET proves the fresh
    //     server, closing the await_ready identity gap end-to-end.
    let models = http_get(port, "/v1/models");
    assert!(
        models.contains(&format!("\"id\":\"{ALIAS}\"")),
        "new child must serve the configured alias; got: {models}"
    );
    assert!(
        !models.contains("stale-orphan"),
        "must NOT be the orphan server; got: {models}"
    );
    assert_eq!(adapter.describe().model_id, ALIAS);

    // (4) The new child's pidfile exists, is 0600, and lives under the run dir.
    assert!(pidfile.exists(), "fresh sidecar pidfile must be written");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&pidfile).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "pidfile must be 0600 (owner-only)");
    }

    // ── Clean shutdown removes the pidfile + kills the new child; no orphan.
    drop(adapter);
    assert!(
        !pidfile.exists(),
        "pidfile must be removed on clean shutdown"
    );
    for _ in 0..50 {
        if TcpStream::connect(("127.0.0.1", port)).is_err() {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        TcpStream::connect(("127.0.0.1", port)).is_err(),
        "no sidecar (orphan or fresh) must remain after clean shutdown"
    );

    let _ = std::fs::remove_dir_all(&tmp);
    let _ = orphan.wait(); // reap any lingering zombie, just in case
}
