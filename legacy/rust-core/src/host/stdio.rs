//! Stdin/stdout JSON bridge for the host command channel.
//!
//! Reads newline-delimited JSON `CommandEnvelope` messages from stdin,
//! dispatches them through the `HostCommandServer` router, and writes
//! `ResponseEnvelope` and `EventEnvelope` messages as newline-delimited
//! JSON to stdout.
//!
//! Stdout is exclusively reserved for the JSON protocol; all diagnostic
//! output (tracing, logs) must be routed to stderr.

use crate::host::channel::{DeviceTransferHandler, HostCommandClient, command_channel};
use crate::host::contract::{CommandEnvelope, CommandName, ResponseEnvelope};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};
use tokio::sync::Mutex;

/// Default request channel capacity for the stdio bridge.
const REQUEST_CAPACITY: usize = 64;

/// Default event broadcast channel capacity for the stdio bridge.
const EVENT_CAPACITY: usize = 128;

/// Run the stdin/stdout JSON bridge until stdin closes or a `runtime.stop`
/// command is received.
///
/// Three concurrent tasks operate in parallel:
///
/// 1. **Reader** -- reads newline-delimited JSON from stdin, dispatches each
///    `CommandEnvelope` through the host command client, and writes the
///    resulting `ResponseEnvelope` to stdout.
/// 2. **Event forwarder** -- receives broadcast `EventEnvelope` messages
///    from the server and writes them as JSON lines to stdout.
/// 3. **Server** -- runs the `HostCommandServer` router loop.
///
/// The bridge exits when the reader task finishes (either stdin EOF or
/// `runtime.stop`). Dropping the client causes the server task to exit
/// naturally.
pub async fn run_stdio_bridge<H: DeviceTransferHandler>(handler: H) -> crate::Result<()> {
    let (client, server) = command_channel(REQUEST_CAPACITY, EVENT_CAPACITY, handler);

    let stdout = tokio::io::stdout();
    let writer = Arc::new(Mutex::new(BufWriter::new(stdout)));

    // Spawn the command-router server task.
    let server_handle = tokio::spawn(async move {
        server.run().await;
    });

    // Spawn the event forwarder task.
    let event_writer = Arc::clone(&writer);
    let mut event_rx = client.subscribe_events();
    let event_handle = tokio::spawn(async move {
        loop {
            match event_rx.recv().await {
                Ok(event_envelope) => match serde_json::to_string(&event_envelope) {
                    Ok(json) => {
                        let mut w = event_writer.lock().await;
                        if let Err(e) = write_line(&mut w, &json).await {
                            tracing::warn!(
                                error = %e,
                                "failed to write event envelope to stdout; stopping event forwarder"
                            );
                            break;
                        }
                    }
                    Err(e) => {
                        tracing::error!(
                            error = %e,
                            "failed to serialize event envelope; skipping"
                        );
                    }
                },
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!(
                        lagged = n,
                        "event forwarder lagged; some events were dropped"
                    );
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    tracing::info!("event broadcast channel closed; stopping event forwarder");
                    break;
                }
            }
        }
    });

    // Run the reader task on the current task (not spawned) so that when it
    // finishes we can cleanly shut down.
    let reader_result = run_reader(client, Arc::clone(&writer)).await;

    // Reader finished -- abort the event forwarder and wait for server to
    // drain. The client is dropped by `run_reader`, which closes the request
    // channel and causes the server to exit.
    event_handle.abort();
    let _ = event_handle.await;
    let _ = server_handle.await;

    reader_result
}

/// Read stdin line-by-line, dispatch each command, and write responses.
async fn run_reader(
    client: HostCommandClient,
    writer: Arc<Mutex<BufWriter<tokio::io::Stdout>>>,
) -> crate::Result<()> {
    let stdin = tokio::io::stdin();
    let mut reader = BufReader::new(stdin);
    let mut line = String::new();

    loop {
        line.clear();
        let bytes_read = reader
            .read_line(&mut line)
            .await
            .map_err(|e| crate::SpeechError::Channel(format!("failed to read from stdin: {e}")))?;

        // EOF
        if bytes_read == 0 {
            tracing::info!("stdin closed (EOF); shutting down stdio bridge");
            break;
        }

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let envelope: CommandEnvelope = match serde_json::from_str(trimmed) {
            Ok(env) => env,
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    raw_line = %trimmed,
                    "failed to parse command envelope from stdin"
                );
                let error_response = ResponseEnvelope::error(
                    "parse-error",
                    format!("failed to parse command envelope: {e}"),
                );
                let json = serde_json::to_string(&error_response).map_err(|se| {
                    crate::SpeechError::Pipeline(format!(
                        "failed to serialize parse-error response: {se}"
                    ))
                })?;
                let mut w = writer.lock().await;
                write_line(&mut w, &json).await?;
                continue;
            }
        };

        let is_stop = envelope.command == CommandName::RuntimeStop;

        let response = match client.send(envelope).await {
            Ok(resp) => resp,
            Err(e) => {
                tracing::error!(error = %e, "host command dispatch failed");
                ResponseEnvelope::error("dispatch-error", format!("dispatch failed: {e}"))
            }
        };

        let json = serde_json::to_string(&response).map_err(|e| {
            crate::SpeechError::Pipeline(format!("failed to serialize response envelope: {e}"))
        })?;

        {
            let mut w = writer.lock().await;
            write_line(&mut w, &json).await?;
        }

        if is_stop {
            tracing::info!("runtime.stop received; shutting down stdio bridge");
            break;
        }
    }

    Ok(())
}

/// Write a single JSON line to the buffered writer and flush.
async fn write_line(writer: &mut BufWriter<tokio::io::Stdout>, json: &str) -> crate::Result<()> {
    writer
        .write_all(json.as_bytes())
        .await
        .map_err(|e| crate::SpeechError::Channel(format!("failed to write to stdout: {e}")))?;
    writer.write_all(b"\n").await.map_err(|e| {
        crate::SpeechError::Channel(format!("failed to write newline to stdout: {e}"))
    })?;
    writer
        .flush()
        .await
        .map_err(|e| crate::SpeechError::Channel(format!("failed to flush stdout: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::contract::{CommandName, EVENT_VERSION};

    #[test]
    fn parse_error_response_is_well_formed() {
        let resp = ResponseEnvelope::error("parse-error", "bad json");
        assert!(!resp.ok);
        assert_eq!(resp.request_id, "parse-error");
        assert_eq!(resp.v, EVENT_VERSION);
        assert!(resp.error.is_some());
    }

    #[test]
    fn command_envelope_roundtrip_json() {
        let envelope = CommandEnvelope::new("req-1", CommandName::HostPing, serde_json::json!({}));
        let json = serde_json::to_string(&envelope).expect("serialize in test");
        let parsed: CommandEnvelope = serde_json::from_str(&json).expect("deserialize in test");
        assert_eq!(parsed, envelope);
    }

    #[test]
    fn response_envelope_roundtrip_json() {
        let resp = ResponseEnvelope::ok("req-1", serde_json::json!({"pong": true}));
        let json = serde_json::to_string(&resp).expect("serialize in test");
        let parsed: ResponseEnvelope = serde_json::from_str(&json).expect("deserialize in test");
        assert_eq!(parsed, resp);
    }
}
