//! Unix-domain-socket transport — the thin async shell over [`crate::session`].
//!
//! NDJSON framing (one JSON [`Command`](fae_control_plane::Command) per line);
//! one response line per request. The socket is the default transport for the
//! local Swift frontend. TCP-loopback + WS/SSE diagnostics with single-use
//! stream tickets are a later chunk (2c); this shell deliberately opens no TCP
//! port.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use fae_control_plane::{append_audit_jsonl, ClientRegistry, Response};
use fae_engine::{ProviderAdapter, TtsAdapter};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

use crate::session::{handle_frame, SessionState};
use crate::{next_event_id, now_ms};

/// Reject any single NDJSON frame larger than this **before authentication**.
/// The control socket is same-user (OS-enforced peer credentials), so this is a
/// sanity bound against a runaway/buggy client, not a hard anti-DoS guard — a
/// streaming cap for the less-trusted TCP/WS path lands in chunk 2c. Control
/// frames are sub-kilobyte.
const MAX_FRAME_BYTES_UNAUTHENTICATED: usize = 64 * 1024;

/// Frame ceiling for an **authenticated** session. `conversation.inject_text`
/// can carry a base64 WAV clip (S18 push-to-talk: ~1.3 MB for a 30 s
/// utterance), so authenticated frames get headroom; everything pre-auth stays
/// on the tight control-frame bound.
const MAX_FRAME_BYTES_AUTHENTICATED: usize = 8 * 1024 * 1024;

/// Bind the Unix socket (owner-only) and serve connections until the process is
/// killed. Fails closed: if a stale socket cannot be cleared, the bind fails, or
/// owner-only permissions cannot be set, the daemon refuses to serve.
pub async fn serve_unix(
    socket_path: PathBuf,
    registry: Arc<ClientRegistry>,
    engine: Arc<dyn ProviderAdapter>,
    tts: Arc<dyn TtsAdapter>,
    audit_path: PathBuf,
) -> std::io::Result<()> {
    // Clear any stale socket left by a previous run (bind fails on EADDRINUSE).
    match std::fs::remove_file(&socket_path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let listener = UnixListener::bind(&socket_path)?;
    tighten_socket_permissions(&socket_path)?;
    eprintln!(
        "fae-daemon: listening on {} (NDJSON)",
        socket_path.display()
    );

    loop {
        let (stream, _addr) = listener.accept().await?;
        let registry = Arc::clone(&registry);
        let engine = Arc::clone(&engine);
        let tts = Arc::clone(&tts);
        let audit_path = audit_path.clone();
        tokio::spawn(async move {
            if let Err(error) = handle_connection(
                stream,
                &registry,
                engine.as_ref(),
                tts.as_ref(),
                &audit_path,
            )
            .await
            {
                // One bad connection must never take the daemon down.
                eprintln!("fae-daemon: connection ended: {error}");
            }
        });
    }
}

async fn handle_connection(
    stream: UnixStream,
    registry: &ClientRegistry,
    engine: &dyn ProviderAdapter,
    tts: &dyn TtsAdapter,
    audit_path: &Path,
) -> std::io::Result<()> {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut state = SessionState::Unauthenticated;
    let mut line = String::new();

    loop {
        line.clear();
        let bytes = reader.read_line(&mut line).await?;
        if bytes == 0 {
            return Ok(()); // peer closed
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let max_frame_bytes = match state {
            SessionState::Unauthenticated => MAX_FRAME_BYTES_UNAUTHENTICATED,
            SessionState::Authenticated(_) => MAX_FRAME_BYTES_AUTHENTICATED,
        };
        if trimmed.len() > max_frame_bytes {
            let response =
                Response::error("unknown", "frame_too_large", "command frame exceeds limit");
            write_response(&mut write_half, &response).await?;
            return Ok(());
        }

        let now = now_ms();
        let event_id = next_event_id(now);
        let outcome = handle_frame(registry, engine, tts, &mut state, trimmed, now, event_id).await;

        // Fail closed: a frame must be audited before its response is sent. If
        // the audit write fails, surface an error response and drop the
        // connection rather than answer unaudited.
        if let Err(error) = append_audit_jsonl(audit_path, &outcome.audit) {
            let response = Response::error(
                &outcome.response.request_id,
                "audit_error",
                "audit write failed",
            );
            let _ = write_response(&mut write_half, &response).await;
            return Err(std::io::Error::other(format!(
                "audit write failed: {error}"
            )));
        }

        write_response(&mut write_half, &outcome.response).await?;
        if outcome.close {
            return Ok(());
        }
    }
}

async fn write_response<W>(writer: &mut W, response: &Response) -> std::io::Result<()>
where
    W: AsyncWriteExt + Unpin,
{
    let mut line =
        serde_json::to_vec(response).map_err(|error| std::io::Error::other(error.to_string()))?;
    line.push(b'\n');
    writer.write_all(&line).await?;
    writer.flush().await
}

/// Set the bound socket file to owner-only (`0600`). The parent run dir is
/// already `0700`, but the socket itself is tightened too; fail closed on Unix
/// if it cannot be done.
fn tighten_socket_permissions(socket_path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(not(unix))]
    let _ = socket_path;
    Ok(())
}
