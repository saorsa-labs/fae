//! Lightweight latency harness utilities for host boundary benchmarking.

use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::hint::black_box;
use std::time::{Duration, Instant};

/// Benchmark configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BenchConfig {
    /// Number of timing samples to collect.
    pub samples: usize,
    /// Size of payload in bytes for message-based benches.
    pub payload_bytes: usize,
}

/// Summary statistics for a benchmark scenario.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BenchReport {
    pub scenario: String,
    pub samples: usize,
    pub payload_bytes: usize,
    pub p50_micros: u64,
    pub p95_micros: u64,
    pub p99_micros: u64,
}

/// Baseline report for v0 host latency checks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BaselineReport {
    pub generated_at_epoch_ms: u64,
    pub noop_dispatch: BenchReport,
    pub channel_ipc_roundtrip: BenchReport,
    pub local_ipc_roundtrip: BenchReport,
}

/// Run a no-op dispatch benchmark for in-process command handling overhead.
pub fn run_noop_dispatch_bench(config: BenchConfig) -> Result<BenchReport> {
    validate_config(config)?;

    let payload = vec![0_u8; config.payload_bytes];
    let mut samples = Vec::with_capacity(config.samples);

    for _ in 0..config.samples {
        let start = Instant::now();
        let len = payload.len();
        black_box(len);
        samples.push(elapsed_micros(start));
    }

    Ok(build_report(
        "noop_dispatch",
        config.samples,
        config.payload_bytes,
        samples,
    ))
}

/// Run a local channel roundtrip benchmark to approximate local IPC overhead.
pub fn run_channel_ipc_roundtrip_bench(config: BenchConfig) -> Result<BenchReport> {
    validate_config(config)?;

    let payload = vec![0_u8; config.payload_bytes];
    let (req_tx, req_rx) = std::sync::mpsc::channel::<Vec<u8>>();
    let (res_tx, res_rx) = std::sync::mpsc::channel::<usize>();

    let worker = std::thread::spawn(move || {
        while let Ok(msg) = req_rx.recv() {
            if res_tx.send(msg.len()).is_err() {
                break;
            }
        }
    });

    let mut samples = Vec::with_capacity(config.samples);
    for _ in 0..config.samples {
        let start = Instant::now();
        req_tx
            .send(payload.clone())
            .map_err(|e| SpeechError::Pipeline(format!("failed to send bench request: {e}")))?;
        let echoed = res_rx
            .recv_timeout(Duration::from_secs(5))
            .map_err(|e| SpeechError::Pipeline(format!("failed to receive bench response: {e}")))?;
        black_box(echoed);
        samples.push(elapsed_micros(start));
    }

    drop(req_tx);
    if worker.join().is_err() {
        return Err(SpeechError::Pipeline(
            "bench worker thread panicked".to_owned(),
        ));
    }

    Ok(build_report(
        "channel_ipc_roundtrip",
        config.samples,
        config.payload_bytes,
        samples,
    ))
}

/// Run a benchmark through the target-native local IPC transport.
///
/// On Unix targets this uses Unix Domain Sockets (UDS).
/// On non-Unix targets this currently returns an unsupported-target error.
pub fn run_local_ipc_roundtrip_bench(config: BenchConfig) -> Result<BenchReport> {
    #[cfg(unix)]
    {
        run_uds_ipc_roundtrip_bench(config)
    }

    #[cfg(not(unix))]
    {
        let _ = config;
        Err(SpeechError::Pipeline(
            "local IPC benchmark is currently only implemented for unix-domain sockets".to_owned(),
        ))
    }
}

/// Generate a full v0 baseline report for host-boundary latency.
pub fn generate_baseline_report(config: BenchConfig) -> Result<BaselineReport> {
    let noop_dispatch = run_noop_dispatch_bench(config)?;
    let channel_ipc_roundtrip = run_channel_ipc_roundtrip_bench(config)?;
    let local_ipc_roundtrip = run_local_ipc_roundtrip_bench(config)?;
    Ok(BaselineReport {
        generated_at_epoch_ms: now_epoch_millis(),
        noop_dispatch,
        channel_ipc_roundtrip,
        local_ipc_roundtrip,
    })
}

/// Write a baseline report as pretty JSON.
pub fn write_baseline_report(report: &BaselineReport, output: &std::path::Path) -> Result<()> {
    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(report)
        .map_err(|e| SpeechError::Pipeline(format!("failed to serialize baseline report: {e}")))?;
    std::fs::write(output, json)?;
    Ok(())
}

fn validate_config(config: BenchConfig) -> Result<()> {
    if config.samples == 0 {
        return Err(SpeechError::Pipeline(
            "bench samples must be greater than zero".to_owned(),
        ));
    }
    Ok(())
}

fn build_report(
    scenario: &str,
    samples: usize,
    payload_bytes: usize,
    mut timings_micros: Vec<u64>,
) -> BenchReport {
    timings_micros.sort_unstable();
    BenchReport {
        scenario: scenario.to_owned(),
        samples,
        payload_bytes,
        p50_micros: percentile(&timings_micros, 50),
        p95_micros: percentile(&timings_micros, 95),
        p99_micros: percentile(&timings_micros, 99),
    }
}

fn percentile(sorted: &[u64], pct: usize) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    let idx = (sorted.len().saturating_sub(1) * pct) / 100;
    sorted[idx]
}

fn elapsed_micros(start: Instant) -> u64 {
    let micros = start.elapsed().as_micros();
    u64::try_from(micros).unwrap_or(u64::MAX)
}

fn now_epoch_millis() -> u64 {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => u64::try_from(d.as_millis()).unwrap_or(u64::MAX),
        Err(_) => 0,
    }
}

#[cfg(unix)]
fn run_uds_ipc_roundtrip_bench(config: BenchConfig) -> Result<BenchReport> {
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};

    validate_config(config)?;

    let socket_path = unique_uds_bench_path();
    let _ = std::fs::remove_file(&socket_path);

    let listener = UnixListener::bind(&socket_path).map_err(|e| {
        SpeechError::Pipeline(format!(
            "failed to bind UDS benchmark socket {}: {e}",
            socket_path.display()
        ))
    })?;

    let worker = std::thread::spawn(move || -> Result<()> {
        let (mut stream, _addr) = listener.accept().map_err(|e| {
            SpeechError::Pipeline(format!("failed to accept UDS benchmark connection: {e}"))
        })?;

        loop {
            let mut len_buf = [0_u8; 4];
            match stream.read_exact(&mut len_buf) {
                Ok(()) => {}
                Err(e)
                    if e.kind() == std::io::ErrorKind::UnexpectedEof
                        || e.kind() == std::io::ErrorKind::ConnectionReset =>
                {
                    break;
                }
                Err(e) => {
                    return Err(SpeechError::Pipeline(format!(
                        "failed to read UDS request length: {e}"
                    )));
                }
            }

            let payload_len_u32 = u32::from_le_bytes(len_buf);
            let payload_len = usize::try_from(payload_len_u32).map_err(|e| {
                SpeechError::Pipeline(format!("invalid UDS request length conversion: {e}"))
            })?;
            let mut payload = vec![0_u8; payload_len];
            stream.read_exact(&mut payload).map_err(|e| {
                SpeechError::Pipeline(format!("failed to read UDS request payload: {e}"))
            })?;

            let echoed_u32 = u32::try_from(payload.len()).map_err(|e| {
                SpeechError::Pipeline(format!("UDS response length out of range: {e}"))
            })?;
            stream
                .write_all(&echoed_u32.to_le_bytes())
                .map_err(|e| SpeechError::Pipeline(format!("failed to write UDS response: {e}")))?;
            stream
                .flush()
                .map_err(|e| SpeechError::Pipeline(format!("failed to flush UDS response: {e}")))?;
        }
        Ok(())
    });

    let mut stream = UnixStream::connect(&socket_path).map_err(|e| {
        SpeechError::Pipeline(format!(
            "failed to connect UDS benchmark client {}: {e}",
            socket_path.display()
        ))
    })?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| SpeechError::Pipeline(format!("failed to set UDS read timeout: {e}")))?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| SpeechError::Pipeline(format!("failed to set UDS write timeout: {e}")))?;

    let payload = vec![0_u8; config.payload_bytes];
    let payload_len_u32 = u32::try_from(payload.len()).map_err(|e| {
        SpeechError::Pipeline(format!(
            "payload length {} is too large for UDS benchmark frame: {e}",
            payload.len()
        ))
    })?;
    let payload_len_bytes = payload_len_u32.to_le_bytes();

    let mut samples = Vec::with_capacity(config.samples);
    for _ in 0..config.samples {
        let start = Instant::now();
        stream.write_all(&payload_len_bytes).map_err(|e| {
            SpeechError::Pipeline(format!("failed to write UDS request length: {e}"))
        })?;
        stream.write_all(&payload).map_err(|e| {
            SpeechError::Pipeline(format!("failed to write UDS request payload: {e}"))
        })?;
        stream
            .flush()
            .map_err(|e| SpeechError::Pipeline(format!("failed to flush UDS request: {e}")))?;

        let mut echoed_bytes = [0_u8; 4];
        stream.read_exact(&mut echoed_bytes).map_err(|e| {
            SpeechError::Pipeline(format!("failed to read UDS response payload length: {e}"))
        })?;
        let echoed_len_u32 = u32::from_le_bytes(echoed_bytes);
        let echoed_len = usize::try_from(echoed_len_u32)
            .map_err(|e| SpeechError::Pipeline(format!("invalid UDS response length: {e}")))?;
        if echoed_len != payload.len() {
            return Err(SpeechError::Pipeline(format!(
                "UDS benchmark response length mismatch: expected {}, got {}",
                payload.len(),
                echoed_len
            )));
        }

        black_box(echoed_len);
        samples.push(elapsed_micros(start));
    }

    drop(stream);

    let worker_result = worker
        .join()
        .map_err(|_| SpeechError::Pipeline("UDS benchmark worker thread panicked".to_owned()))?;
    worker_result?;

    let _ = std::fs::remove_file(&socket_path);

    Ok(build_report(
        "uds_ipc_roundtrip",
        config.samples,
        config.payload_bytes,
        samples,
    ))
}

#[cfg(unix)]
fn unique_uds_bench_path() -> std::path::PathBuf {
    let pid = std::process::id();
    let stamp = now_epoch_millis();
    std::env::temp_dir().join(format!("fae-latency-{pid}-{stamp}.sock"))
}
