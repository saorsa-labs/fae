//! Headless host bridge binary for stdin/stdout JSON communication.
//!
//! This binary reads `CommandEnvelope` messages as newline-delimited JSON
//! from stdin, dispatches them through the host command channel, and writes
//! `ResponseEnvelope` and `EventEnvelope` messages to stdout.
//!
//! All tracing/diagnostic output goes to stderr so that stdout remains a
//! clean JSON protocol channel.

use fae::host::channel::NoopDeviceTransferHandler;
use fae::host::stdio::run_stdio_bridge;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialise tracing to stderr only (stdout is reserved for the JSON
    // protocol).
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    tracing::info!("fae-host starting");

    run_stdio_bridge(NoopDeviceTransferHandler)
        .await
        .map_err(|e| {
            tracing::error!(error = %e, "fae-host exited with error");
            anyhow::anyhow!("fae-host failed: {e}")
        })?;

    tracing::info!("fae-host shut down cleanly");
    Ok(())
}
