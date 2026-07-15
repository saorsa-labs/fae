//! `LlamaServerAdapter` — cross-platform serving backend (gap B1).
//!
//! Talks to a `llama-server` (llama.cpp) sidecar over its OpenAI-compatible
//! HTTP/SSE API and re-emits the stream as backend-agnostic [`ChatEvent`]s, the
//! same contract the mistral.rs adapter satisfies. Chosen after the 2026-06-16
//! validation (docs/architecture/cross-platform-brain-llamacpp-2026-06-16.md §A):
//! llama.cpp serves Gemma 4 text + audio + runtime GGUF-LoRA on Metal/CUDA/Vulkan,
//! which mistral.rs cannot do for Gemma 4.
//!
//! Two construction paths:
//! - [`LlamaServerAdapter::connect`] — attach to an already-running server (the
//!   validation bench, tests, or an externally-managed server).
//! - [`LlamaServerAdapter::spawn`] — launch + supervise a `llama-server` child
//!   ([`LlamaServerHandle`], killed on drop) then attach.
//!
//! Gemma specifics proven in §A and encoded here: the server runs with
//! `--reasoning-format none` (and we request it per-call) so the model's full
//! output — including any `<think>`/`<tool_call>` markup — lands in `content`
//! for Fae to self-parse downstream, rather than being split into
//! `reasoning_content` (which left `content` empty).

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use futures_util::StreamExt;

use crate::provider::{
    AdapterInfo, ChatEvent, ChatRequest, ChatStream, EngineError, LoadedAdapter, ProviderAdapter,
    Role,
};

/// llama-server loads `--lora` adapters at a fixed index in load order; the
/// personal adapter is the only one we load, so it is always id 0.
const PERSONAL_LORA_ID: u32 = 0;

/// Process-global registry of live sidecar child PIDs. Maintained by
/// [`LlamaServerHandle`]'s spawn/Drop (and by the daemon's supervised
/// fae-symphony-runner sidecar) so a hard teardown (the daemon's
/// `spawn_parent_watch` calls `process::exit`, which skips `Drop`) can still
/// kill every sidecar before the daemon vanishes. Best-effort: a crashed daemon
/// can't run this, but the common quit/SIGKILL-of-daemon path is covered.
///
/// This lives in the engine (not the daemon) because the llama `Child` is
/// owned here; the daemon registers its own sidecars via
/// [`register_sidecar`]/[`unregister_sidecar`] and calls
/// [`kill_all_registered_sidecars`] at shutdown.
static SIDECAR_PIDS: std::sync::OnceLock<std::sync::Mutex<Vec<u32>>> = std::sync::OnceLock::new();

fn sidecar_pids() -> &'static std::sync::Mutex<Vec<u32>> {
    SIDECAR_PIDS.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}

/// Register a live sidecar child PID for teardown reaping (see
/// [`kill_all_registered_sidecars`]). Never panics.
pub fn register_sidecar(pid: u32) {
    if let Ok(mut guard) = sidecar_pids().lock() {
        guard.push(pid);
    }
}

/// Remove a reaped sidecar child PID from the teardown registry. Never panics.
pub fn unregister_sidecar(pid: u32) {
    if let Ok(mut guard) = sidecar_pids().lock() {
        guard.retain(|&p| p != pid);
    }
}

/// Kill every registered `llama-server` sidecar (best-effort, never panics).
/// Called by the daemon's parent-watch immediately before `process::exit` so a
/// daemon shutdown that skips `Drop` still reaps its children. Sends SIGTERM,
/// waits briefly for graceful exit, then SIGKILL any survivor — a slow or
/// signal-ignoring child must not outlive the daemon (the no-orphan criterion).
/// Uses `/bin/kill` rather than a raw syscall so no `libc` dependency is pulled in.
pub fn kill_all_registered_sidecars() {
    use std::time::{Duration, Instant};
    let pids: Vec<u32> = sidecar_pids()
        .lock()
        .map(|guard| guard.clone())
        .unwrap_or_default();
    if pids.is_empty() {
        return;
    }
    let kill_bin = std::env::var("FAE_KILL_BIN")
        .ok()
        .filter(|b| !b.is_empty())
        .unwrap_or_else(|| "/bin/kill".to_owned());
    let send = |pid: u32, signal: &str| {
        let _ = std::process::Command::new(&kill_bin)
            .arg(format!("-{signal}"))
            .arg(pid.to_string())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    };
    // 1) SIGTERM (graceful) to every sidecar.
    for &pid in &pids {
        send(pid, "TERM");
    }
    // 2) Brief grace window for the children to exit on TERM.
    let deadline = Instant::now() + Duration::from_millis(500);
    while Instant::now() < deadline {
        let any_alive = pids.iter().any(|&pid| process_alive(pid));
        if !any_alive {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    // 3) SIGKILL any survivor (unblockable).
    for &pid in &pids {
        if process_alive(pid) {
            send(pid, "KILL");
        }
    }
}

/// Is `pid` still alive? `kill(pid, 0)`-equivalent via `/bin/kill -0`. Best-effort:
/// on any error we assume alive (so we over-kill, never under-kill).
fn process_alive(pid: u32) -> bool {
    let status = std::process::Command::new(kill_bin())
        .arg("-0")
        .arg(pid.to_string())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    // `kill -0` exits 0 if the process exists, non-zero otherwise.
    matches!(status, Ok(s) if s.success())
}

// ── Facet B: startup port takeover (reclaim a stale sidecar orphan) ───────────

/// Resolve the configured `/bin/kill` binary (`FAE_KILL_BIN` override; default
/// `/bin/kill`). Shared by the reclaim + reaper paths.
fn kill_bin() -> String {
    std::env::var("FAE_KILL_BIN")
        .ok()
        .filter(|b| !b.is_empty())
        .unwrap_or_else(|| "/bin/kill".to_owned())
}

/// Best-effort `-<signal>` to a positive pid. Never panics.
fn send_signal(pid: u32, signal: &str) {
    let _ = std::process::Command::new(kill_bin())
        .arg(format!("-{signal}"))
        .arg(pid.to_string())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

/// Full command line of `pid` (`ps -o command=`), if available. Confirms a stale
/// pidfile entry is still OUR `llama-server` — a recycled PID at an unrelated
/// process must never be killed.
fn process_command_line(pid: u32) -> Option<String> {
    let out = std::process::Command::new("ps")
        .args(["-o", "command=", "-p"])
        .arg(pid.to_string())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// Best-effort port → listener PID via `lsof`. `None` when `lsof` is absent or the
/// port has no listener. Cross-platform best-effort (macOS always; Linux when
/// `lsof` is installed). Secondary reclaim signal — the primary is the pidfile.
fn port_listener_pid(port: u16) -> Option<u32> {
    let out = std::process::Command::new("lsof")
        .args(["-nP", "-sTCP:LISTEN", "-t"])
        .arg(format!("-iTCP:{port}"))
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .and_then(|line| line.trim().parse::<u32>().ok())
}

/// `true` while `127.0.0.1:port` accepts TCP connections (something is listening).
/// Async, no subprocess. Drives the wait-for-port-free step of reclaim.
async fn port_accepts_connection(port: u16) -> bool {
    let addr = format!("127.0.0.1:{port}");
    tokio::net::TcpStream::connect(addr).await.is_ok()
}

/// Does `cmd` (a process command line) belong to OUR sidecar? Requires the FULL
/// path of the binary we are about to spawn — as-configured or its canonicalized
/// (symlink-resolved) form — to appear in the command line. A bare `llama-server`
/// basename is NEVER sufficient: a user's own llama-server instance would
/// otherwise be matched and killed. When the path can't be confirmed as ours
/// (unresolvable / symlink-ambiguous), this returns `false` and the caller fails
/// loud rather than risk killing a stranger.
fn cmdline_is_our_sidecar(cmd: &str, our_binary: &str) -> bool {
    if !our_binary.is_empty() && cmd.contains(our_binary) {
        return true;
    }
    if let Ok(canonical) = std::fs::canonicalize(our_binary) {
        if let Some(resolved) = canonical.to_str() {
            if cmd.contains(resolved) {
                return true;
            }
        }
    }
    false
}

/// Read a pidfile's PID, if present + parseable.
fn read_pidfile(path: &std::path::Path) -> Option<u32> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| raw.trim().parse::<u32>().ok())
}

/// Write a pidfile at mode `0600` (best-effort; its parent is created if needed).
/// `0600` owner bits are immune to umask, so the sidecar PID is never
/// world-readable — matching the private run dir's secret-file discipline. A
/// missing pidfile only weakens reclaim to the `lsof` fallback.
fn write_pidfile(path: &std::path::Path, pid: u32) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)
        {
            let _ = writeln!(file, "{pid}");
        }
    }
    #[cfg(not(unix))]
    {
        let _ = std::fs::write(path, pid.to_string());
    }
}

/// Resolve the pidfile path for a sidecar on `port` under the Fae run dir.
fn sidecar_pidfile(
    pidfile_root: Option<&std::path::Path>,
    port: u16,
) -> Option<std::path::PathBuf> {
    pidfile_root.map(|root| root.join(format!("llama-server.{port}.pid")))
}

fn process_executable(command_line: &str) -> &str {
    command_line
        .split_once(" -")
        .map_or(command_line, |(executable, _)| executable)
        .trim()
        .trim_matches(|character| character == '\'' || character == '"')
}

fn held_port_message(port: u16, our_binary: &str, holder: Option<&(u32, String)>) -> String {
    let Some((pid, command_line)) = holder else {
        return format!(
            "port {port} is still held after reclaim, but the listener process could not be \
             identified; refusing to spawn a colliding sidecar — inspect the port holder and \
             relaunch"
        );
    };
    let executable = process_executable(command_line);
    if std::path::Path::new(executable)
        .file_name()
        .is_some_and(|name| name == "llama-server")
    {
        return format!(
            "port {port} is held by llama-server pid {pid} at {executable:?}, from a different \
             install path than configured {our_binary:?}; the ownership check refused to kill \
             it. Run `just kill-stale-sidecars` to remove stale Fae llama-servers, then relaunch"
        );
    }
    let executable = if executable.is_empty() {
        "<unknown executable>"
    } else {
        executable
    };
    format!(
        "port {port} is held by non-Fae process pid {pid} ({executable:?}); the ownership check \
         refused to kill it. Stop that process or free the port, then relaunch"
    )
}

/// Reclaim `port` if it is squatted by a stale `llama-server` from a prior
/// unclean daemon death (SIGKILL / crash / jetsam). Called by
/// [`LlamaServerHandle::spawn`] BEFORE launching a fresh sidecar, so the new
/// child never collides with an orphan.
///
/// Identification — positively OUR orphan, never a stranger: the primary signal
/// is the Fae-owned pidfile written at the previous spawn; `lsof` is a secondary
/// fallback when no pidfile exists. Either way the candidate PID must be alive
/// AND its command line must contain the FULL path of OUR configured binary
/// ([`cmdline_is_our_sidecar`]: as-configured or canonicalized — a bare
/// `llama-server` basename is never sufficient, so a user's own llama-server is
/// never killed). If the path can't be confirmed as ours, nothing is killed and
/// the port-free gate below fails loud.
///
/// Kill sequence (meta-orchestrator gate condition): `SIGTERM` → ~2 s grace →
/// `SIGKILL`, then wait for the port to go free WITH a timeout. On timeout — or
/// when the port is held by a process we refuse to kill — this returns `Err` and
/// the caller MUST fail loud; it NEVER spawns anyway (a silent two-server
/// collision would be worse than a loud launch failure).
async fn reclaim_port_if_held(
    port: u16,
    pidfile: Option<&std::path::Path>,
    our_binary: &str,
) -> Result<(), EngineError> {
    let candidate = pidfile
        .and_then(read_pidfile)
        .or_else(|| port_listener_pid(port));
    if let Some(pid) = candidate {
        if process_alive(pid) {
            let cmd = process_command_line(pid).unwrap_or_default();
            if cmdline_is_our_sidecar(&cmd, our_binary) {
                // Confirmed stale sidecar: SIGTERM → ~2 s grace → SIGKILL.
                send_signal(pid, "TERM");
                let term_deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
                while std::time::Instant::now() < term_deadline {
                    if !process_alive(pid) {
                        break;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
                if process_alive(pid) {
                    send_signal(pid, "KILL");
                }
            }
            // Full-path mismatch: preserve the fail-closed ownership gate. The
            // timeout path queries the actual listener PID before reporting it.
        }
    }
    // Wait for the port to go free WITH a timeout. Never bind on a held port.
    let free_deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        if !port_accepts_connection(port).await {
            if let Some(path) = pidfile {
                let _ = std::fs::remove_file(path);
            }
            return Ok(());
        }
        if std::time::Instant::now() >= free_deadline {
            let holder = port_listener_pid(port)
                .map(|pid| (pid, process_command_line(pid).unwrap_or_default()));
            return Err(EngineError::Load(held_port_message(
                port,
                our_binary,
                holder.as_ref(),
            )));
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

/// A pinned remote artifact. Downloaded on request into Fae-owned storage and
/// verified fail-closed before `llama-server` can load it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteModelArtifact {
    pub filename: String,
    pub size_bytes: u64,
    pub sha256: String,
}

/// Model source for a daemon-owned `llama-server` sidecar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LlamaModelSource {
    /// Load a local GGUF (plus optional mmproj) from Fae-managed storage.
    Local {
        model_gguf: String,
        mmproj: Option<String>,
        mtp_draft: Option<String>,
    },
    /// Download missing HF artifacts on request, verify size+SHA, then load the
    /// verified local GGUF/mmproj/MTP files. This replaces raw llama.cpp `-hf`
    /// for production: no unverified model bytes are ever executed.
    PinnedHuggingFace {
        repo: String,
        revision: String,
        cache_dir: String,
        model: RemoteModelArtifact,
        mmproj: RemoteModelArtifact,
        mtp_draft: Option<RemoteModelArtifact>,
    },
}

/// KV-cache element type for the `llama-server` sidecar (`--cache-type-k/-v`).
///
/// Only two vetted lanes are exposed: `F16` (llama.cpp's default, exact) and
/// `Q8` (`q8_0`, 8-bit — roughly half the KV memory, near-lossless upstream;
/// lower-bit types measurably degrade quality and are intentionally not
/// offered). Quantized V-cache requires flash attention, which
/// [`LlamaServerConfig::args`] always passes (`-fa on`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KvCacheType {
    /// fp16 KV cache — llama.cpp default, bit-exact attention state.
    F16,
    /// `q8_0` quantized KV cache — ~2x smaller, near-lossless.
    Q8,
}

impl KvCacheType {
    /// The llama-server `--cache-type-k/-v` value for this type.
    pub fn as_str(self) -> &'static str {
        match self {
            KvCacheType::F16 => "f16",
            KvCacheType::Q8 => "q8_0",
        }
    }
}

impl std::fmt::Display for KvCacheType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// System-RAM threshold below which the KV cache defaults to quantized `q8_0`
/// (production-readiness audit 2026-07-05, MEDIUM: fp16 KV with a 32K window on
/// an 8–16 GB machine oversubscribes memory). At or above 32 GiB, fp16 stays
/// the default — memory headroom is ample and exactness wins.
pub const KV_QUANT_RAM_THRESHOLD_BYTES: u64 = 32 * 1024 * 1024 * 1024;

/// Choose the sidecar KV-cache type from an explicit override and detected RAM.
///
/// - `override_raw` (the `FAE_KV_CACHE` env var): `"fp16"`/`"f16"` forces exact,
///   `"q8"`/`"q8_0"` forces quantized; any other non-empty value is a hard
///   error (fail loud — this knob is set by operators, not end users).
/// - No override: total RAM below [`KV_QUANT_RAM_THRESHOLD_BYTES`] selects
///   [`KvCacheType::Q8`]; at/above the threshold — or when RAM could not be
///   detected — [`KvCacheType::F16`] keeps today's exact behavior rather than
///   silently trading quality on an unknown machine.
pub fn select_kv_cache_type(
    override_raw: Option<&str>,
    total_ram_bytes: Option<u64>,
) -> Result<KvCacheType, String> {
    if let Some(raw) = override_raw {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            return match trimmed.to_ascii_lowercase().as_str() {
                "fp16" | "f16" => Ok(KvCacheType::F16),
                "q8" | "q8_0" => Ok(KvCacheType::Q8),
                other => Err(format!(
                    "invalid FAE_KV_CACHE={other:?} — valid values are 'fp16' and 'q8'"
                )),
            };
        }
    }
    Ok(match total_ram_bytes {
        Some(bytes) if bytes < KV_QUANT_RAM_THRESHOLD_BYTES => KvCacheType::Q8,
        _ => KvCacheType::F16,
    })
}

/// How to launch a `llama-server` sidecar. The daemon resolves the binary and
/// model source; this struct only assembles the command line.
#[derive(Debug, Clone)]
pub struct LlamaServerConfig {
    /// Path to the `llama-server` binary.
    pub binary: String,
    /// Local GGUF path or HF `repo:quant` source.
    pub model: LlamaModelSource,
    /// Optional personal LoRA adapter GGUF (runtime, unmerged). Loaded inactive
    /// (`--lora-init-without-apply`); per-request scale turns it on.
    pub lora_gguf: Option<String>,
    /// OpenAI model alias exposed by the server / request body.
    pub alias: String,
    /// Whether Gemma's served thinking is enabled in the chat template.
    pub enable_thinking: bool,
    /// Optional Gemma 4 MTP speculative decoding draft token count. Fae passes a
    /// verified E4B-matched drafter via `--model-draft` when this is enabled.
    pub mtp_draft_tokens: Option<u32>,
    /// Loopback port.
    pub port: u16,
    /// Context window.
    pub ctx_size: u32,
    /// GPU layers to offload (`999` = all on Metal/CUDA/Vulkan).
    pub ngl: u32,
    /// KV-cache element type (`--cache-type-k/-v`). RAM-tiered by the daemon
    /// via [`select_kv_cache_type`]; `F16` emits no flags (llama.cpp default).
    pub kv_cache_type: KvCacheType,
    /// Root directory for the sidecar pidfile (`<root>/llama-server.<port>.pid`),
    /// used by [`LlamaServerHandle::spawn`] to reclaim a stale sidecar left by a
    /// prior unclean daemon death (Facet B — the crash-loop gate-closer). `None`
    /// disables pidfile-based reclaim (the `lsof` fallback still runs); the daemon
    /// sets this to its private run dir.
    pub pidfile_root: Option<std::path::PathBuf>,
}

impl LlamaServerConfig {
    /// Preflight any pinned model artifacts: download missing files, verify cached
    /// files, and fail closed before the daemon advertises the engine as usable.
    /// `FAE_MODELS_LOCK=off` is honored only for `FAE_DEV=1|true`; production
    /// attempts to disable the lock are rejected as load errors.
    pub fn preflight_pinned_artifacts(&self) -> Result<(), EngineError> {
        match &self.model {
            LlamaModelSource::Local { .. } => Ok(()),
            LlamaModelSource::PinnedHuggingFace {
                repo,
                revision,
                cache_dir,
                model,
                mmproj,
                mtp_draft,
            } => {
                let root = pinned_artifact_root(cache_dir, repo, revision);
                ensure_remote_artifact(repo, revision, &root, model)?;
                ensure_remote_artifact(repo, revision, &root, mmproj)?;
                if let (Some(_), Some(artifact)) = (self.mtp_draft_tokens, mtp_draft) {
                    ensure_remote_artifact(repo, revision, &root, artifact)?;
                }
                Ok(())
            }
        }
    }

    fn materialized(&self) -> Result<LlamaServerConfig, EngineError> {
        let model = match &self.model {
            LlamaModelSource::Local { .. } => self.model.clone(),
            LlamaModelSource::PinnedHuggingFace {
                repo,
                revision,
                cache_dir,
                model,
                mmproj,
                mtp_draft,
            } => {
                let root = pinned_artifact_root(cache_dir, repo, revision);
                let model_gguf = ensure_remote_artifact(repo, revision, &root, model)?;
                let mmproj_path = ensure_remote_artifact(repo, revision, &root, mmproj)?;
                let mtp_path = match (self.mtp_draft_tokens, mtp_draft) {
                    (Some(_), Some(artifact)) => {
                        Some(ensure_remote_artifact(repo, revision, &root, artifact)?)
                    }
                    _ => None,
                };
                LlamaModelSource::Local {
                    model_gguf: model_gguf.to_string_lossy().to_string(),
                    mmproj: Some(mmproj_path.to_string_lossy().to_string()),
                    mtp_draft: mtp_path.map(|p| p.to_string_lossy().to_string()),
                }
            }
        };
        let mut config = self.clone();
        config.model = model;
        Ok(config)
    }

    fn args(&self) -> Vec<String> {
        let mut args = Vec::new();
        match &self.model {
            LlamaModelSource::Local {
                model_gguf,
                mmproj,
                mtp_draft,
            } => {
                args.push("-m".to_owned());
                args.push(model_gguf.clone());
                if let Some(mmproj) = mmproj {
                    args.push("--mmproj".to_owned());
                    args.push(mmproj.clone());
                }
                if let Some(mtp_draft) = mtp_draft {
                    args.push("--model-draft".to_owned());
                    args.push(mtp_draft.clone());
                }
            }
            LlamaModelSource::PinnedHuggingFace { .. } => {
                // `spawn` materializes pinned HF artifacts into a Local source
                // before calling `args`; raw `-hf` is intentionally not used in
                // production because it lacks a digest gate.
                args.push("-m".to_owned());
                args.push("<unmaterialized-pinned-hf>".to_owned());
            }
        }
        args.extend([
            "--host".to_owned(),
            "127.0.0.1".to_owned(),
            "--port".to_owned(),
            self.port.to_string(),
            "-c".to_owned(),
            self.ctx_size.to_string(),
            "-ngl".to_owned(),
            self.ngl.to_string(),
            "-fa".to_owned(),
            "on".to_owned(),
            "--jinja".to_owned(),
            "--alias".to_owned(),
            self.alias.clone(),
            "--reasoning".to_owned(),
            if self.enable_thinking { "on" } else { "off" }.to_owned(),
            // Keep reasoning inline in `content` so Fae self-parses (§A).
            "--reasoning-format".to_owned(),
            "none".to_owned(),
        ]);
        // F16 is llama-server's own default — emit nothing so the high-RAM
        // command line is byte-identical to the pre-quantization one.
        // Quantized V-cache requires flash attention; `-fa on` above satisfies it.
        if self.kv_cache_type != KvCacheType::F16 {
            args.push("--cache-type-k".to_owned());
            args.push(self.kv_cache_type.as_str().to_owned());
            args.push("--cache-type-v".to_owned());
            args.push(self.kv_cache_type.as_str().to_owned());
        }
        if let Some(tokens) = self.mtp_draft_tokens {
            args.push("--spec-type".to_owned());
            args.push("draft-mtp".to_owned());
            args.push("--spec-draft-n-max".to_owned());
            args.push(tokens.to_string());
        }
        if let Some(lora) = &self.lora_gguf {
            args.push("--lora".to_owned());
            args.push(lora.clone());
            // Loaded but inactive; per-request `lora` scale activates it.
            args.push("--lora-init-without-apply".to_owned());
        }
        args
    }
}

fn pinned_artifact_root(cache_dir: &str, repo: &str, revision: &str) -> std::path::PathBuf {
    std::path::Path::new(cache_dir)
        .join(repo.replace('/', "--"))
        .join(revision)
}

fn ensure_remote_artifact(
    repo: &str,
    revision: &str,
    root: &std::path::Path,
    artifact: &RemoteModelArtifact,
) -> Result<std::path::PathBuf, EngineError> {
    let path = root.join(&artifact.filename);
    if path.is_file() {
        verify_artifact_file(&path, artifact)?;
        return Ok(path);
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| {
            EngineError::Load(format!(
                "create model cache dir {}: {error}",
                parent.display()
            ))
        })?;
    }
    let tmp = path.with_extension("download.tmp");
    let url = format!(
        "https://huggingface.co/{repo}/resolve/{revision}/{}",
        artifact.filename
    );
    eprintln!(
        "llama.cpp model: downloading pinned artifact {} ({} bytes) from {url}",
        artifact.filename, artifact.size_bytes
    );
    let status = std::process::Command::new("/usr/bin/curl")
        .args(["-fL", "--retry", "3", "--output"])
        .arg(&tmp)
        .arg(&url)
        .status()
        .map_err(|error| EngineError::Load(format!("spawn curl for {url}: {error}")))?;
    if !status.success() {
        let _ = std::fs::remove_file(&tmp);
        return Err(EngineError::Load(format!(
            "download pinned model artifact failed ({status}): {url}"
        )));
    }
    verify_artifact_file(&tmp, artifact)?;
    std::fs::rename(&tmp, &path).map_err(|error| {
        EngineError::Load(format!(
            "install verified artifact {} -> {}: {error}",
            tmp.display(),
            path.display()
        ))
    })?;
    Ok(path)
}

fn verify_artifact_file(
    path: &std::path::Path,
    artifact: &RemoteModelArtifact,
) -> Result<(), EngineError> {
    if models_lock_disabled_for_dev()? {
        return Ok(());
    }
    let metadata = std::fs::metadata(path).map_err(|error| {
        EngineError::Load(format!("stat model artifact {}: {error}", path.display()))
    })?;
    if metadata.len() != artifact.size_bytes {
        return Err(EngineError::Load(format!(
            "model artifact size mismatch for {}: expected {}, got {}",
            path.display(),
            artifact.size_bytes,
            metadata.len()
        )));
    }
    let expected = artifact.sha256.trim().to_ascii_lowercase();
    if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(EngineError::Load(format!(
            "model artifact {} has invalid pinned sha256",
            artifact.filename
        )));
    }
    let actual = sha256_file(path).map_err(|error| {
        EngineError::Load(format!("hash model artifact {}: {error}", path.display()))
    })?;
    if actual != expected {
        return Err(EngineError::Load(format!(
            "model artifact sha256 mismatch for {}: expected {}, got {}",
            path.display(),
            expected,
            actual
        )));
    }
    Ok(())
}

fn models_lock_disabled_for_dev() -> Result<bool, EngineError> {
    let disabled =
        std::env::var("FAE_MODELS_LOCK").is_ok_and(|value| value.eq_ignore_ascii_case("off"));
    if !disabled {
        return Ok(false);
    }
    let dev = std::env::var("FAE_DEV")
        .is_ok_and(|value| value == "1" || value.eq_ignore_ascii_case("true"));
    if dev {
        eprintln!("llama.cpp model: WARNING: FAE_DEV allows FAE_MODELS_LOCK=off; skipping artifact digest verification");
        Ok(true)
    } else {
        Err(EngineError::Load(
            "FAE_MODELS_LOCK=off is only allowed when FAE_DEV=1".to_owned(),
        ))
    }
}

/// Confinement root for runtime personal adapters: the Swift app writes GGUFs to
/// `<data dir>/models/personal/` (`FaeDirectories.personalModelsDirectory`); the
/// daemon serves them from the same place. `FAE_PERSONAL_ADAPTERS_DIR` overrides
/// it (tests, and a dev install with a relocated data dir).
fn personal_adapters_root() -> Result<std::path::PathBuf, EngineError> {
    if let Some(dir) = std::env::var_os("FAE_PERSONAL_ADAPTERS_DIR") {
        return Ok(std::path::PathBuf::from(dir));
    }
    let home = std::env::var_os("HOME")
        .ok_or_else(|| EngineError::AdapterPath("HOME is not set".to_owned()))?;
    let home = std::path::PathBuf::from(home);
    #[cfg(target_os = "macos")]
    let base = home.join("Library/Application Support/fae");
    #[cfg(not(target_os = "macos"))]
    let base = match std::env::var_os("XDG_DATA_HOME") {
        Some(xdg) => std::path::PathBuf::from(xdg).join("fae"),
        None => home.join(".local/share/fae"),
    };
    Ok(base.join("models").join("personal"))
}

/// Validate a personal-adapter path before it reaches `llama-server` (gap P3/C3
/// Stage 4). The path arrives over NDJSON (`engine.reload`), so it is untrusted:
/// it must (a) exist as a readable regular file and (b) resolve INSIDE the
/// confined personal-adapters directory — no arbitrary absolute path, no `..`
/// escape. Returns the canonicalized absolute path the sidecar should load.
///
/// Note: this is path-confinement + existence + a local trust record (the caller
/// hashes the file), NOT a static `models.lock` SHA pin — a runtime-generated
/// adapter does not exist at build time and so cannot be pinned. The existing
/// model/mmproj `models.lock` gate is untouched.
fn validate_personal_adapter(path: &str) -> Result<std::path::PathBuf, EngineError> {
    let root = personal_adapters_root()?;
    // Canonicalize the root if it exists; if it does not, the adapter cannot be
    // inside it, so reject. Canonicalizing both sides defeats `..` and symlink
    // escapes.
    let canonical_root = root.canonicalize().map_err(|error| {
        EngineError::AdapterPath(format!(
            "personal-adapters dir {} is unavailable: {error}",
            root.display()
        ))
    })?;
    let requested = std::path::Path::new(path);
    let canonical = requested.canonicalize().map_err(|error| {
        EngineError::AdapterPath(format!("{path} is not a readable file: {error}"))
    })?;
    if !canonical.is_file() {
        return Err(EngineError::AdapterPath(format!(
            "{} is not a regular file",
            canonical.display()
        )));
    }
    if !canonical.starts_with(&canonical_root) {
        return Err(EngineError::AdapterPath(format!(
            "{} is outside the personal-adapters directory {}",
            canonical.display(),
            canonical_root.display()
        )));
    }
    Ok(canonical)
}

fn sha256_file(path: &std::path::Path) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;

    let mut file = std::fs::File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(hex::encode(digest.finalize()))
}

/// A supervised `llama-server` child. Killed on drop so the sidecar never
/// outlives the daemon during a clean shutdown; combined with the daemon's
/// parent-watch this keeps the app → daemon → llama-server chain tidy. (A hard
/// SIGKILL of the daemon can still orphan it — process-group hardening is a
/// follow-up, tracked with the B-series gaps.)
pub struct LlamaServerHandle {
    child: std::process::Child,
    base_url: String,
    /// Pidfile recording this sidecar's PID; removed on clean shutdown (Drop) so a
    /// surviving pidfile unambiguously means an orphan from an unclean death.
    pidfile: Option<std::path::PathBuf>,
}

impl LlamaServerHandle {
    /// Spawn the server and block until `/health` is ok (or `timeout`).
    pub async fn spawn(
        config: &LlamaServerConfig,
        timeout: std::time::Duration,
    ) -> Result<LlamaServerHandle, EngineError> {
        let materialized = config.materialized()?;
        let port = materialized.port;
        let base_url = format!("http://127.0.0.1:{}", port);
        let pidfile = sidecar_pidfile(config.pidfile_root.as_deref(), port);
        // Facet B (mandatory — the crash-loop gate-closer): reclaim any stale
        // sidecar squatting our port BEFORE we bind, so an unclean daemon death
        // (SIGKILL/crash/jetsam) cannot crash-loop the next launch. Returns Err
        // (→ no spawn) when the port stays held — we NEVER bind on a squatted port.
        reclaim_port_if_held(port, pidfile.as_deref(), &materialized.binary).await?;
        let mut command = std::process::Command::new(&materialized.binary);
        command.args(materialized.args());
        // Facet A (recommended hardening): isolate the sidecar in its own process
        // group so it is not a member of the daemon's group. Group-kill of any
        // grandchildren is intentionally NOT performed here — see the Drop note.
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        // Inherit stdout/stderr so daemon/app logs show llama.cpp download,
        // load, and token/runtime diagnostics. This evidence is required for
        // live validation and makes first-run HF downloads debuggable.
        command.stdout(std::process::Stdio::inherit());
        command.stderr(std::process::Stdio::inherit());
        let child = command.spawn().map_err(|error| {
            EngineError::Load(format!(
                "spawn llama-server ({}): {error}",
                materialized.binary
            ))
        })?;
        let pid = child.id();
        register_sidecar(pid);
        if let Some(ref pf) = pidfile {
            write_pidfile(pf, pid);
        }
        let mut handle = LlamaServerHandle {
            child,
            base_url,
            pidfile,
        };
        handle.await_ready(timeout, &materialized.alias).await?;
        Ok(handle)
    }

    async fn await_ready(
        &mut self,
        timeout: std::time::Duration,
        expected_alias: &str,
    ) -> Result<(), EngineError> {
        let client = reqwest::Client::new();
        let health = format!("{}/health", self.base_url);
        let models = format!("{}/v1/models", self.base_url);
        let deadline = std::time::Instant::now() + timeout;
        loop {
            // Fail loud if the child exited during startup (bad GGUF, OOM, bind
            // failure) instead of polling a dead server for the full timeout.
            match self.child.try_wait() {
                Ok(Some(status)) => {
                    return Err(EngineError::Load(format!(
                        "llama-server exited during startup: {status}"
                    )));
                }
                Ok(None) => {}
                Err(error) => {
                    return Err(EngineError::Load(format!(
                        "failed to poll llama-server during startup: {error}"
                    )));
                }
            }
            if let Ok(response) = client.get(&health).send().await {
                if response.status().is_success() {
                    // Identity check (gap fix): confirm this is OUR fresh server —
                    // not a stale orphan still answering /health on the reclaimed
                    // port. A healthy fresh llama-server exposes /v1/models with
                    // data[0].id == the configured --alias. A non-empty mismatch is
                    // a stale sidecar (fail loud); an empty id means the model list
                    // is not populated yet (keep polling).
                    if let Ok(models_resp) = client.get(&models).send().await {
                        if models_resp.status().is_success() {
                            if let Ok(json) = models_resp.json::<serde_json::Value>().await {
                                let id = json
                                    .get("data")
                                    .and_then(|d| d.get(0))
                                    .and_then(|m| m.get("id"))
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("");
                                if !id.is_empty() && id != expected_alias {
                                    return Err(EngineError::Load(format!(
                                        "port answered /health but serves model id {id:?} \
                                         (expected {expected_alias:?}); a stale llama-server may \
                                         be squatting the port"
                                    )));
                                }
                                if id == expected_alias {
                                    return Ok(());
                                }
                            }
                        }
                    }
                }
            }
            if std::time::Instant::now() >= deadline {
                return Err(EngineError::Load(format!(
                    "llama-server did not become ready within {timeout:?}"
                )));
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
    }
}

impl Drop for LlamaServerHandle {
    fn drop(&mut self) {
        // Best-effort; never panic. Graceful: SIGTERM → brief grace → SIGKILL the
        // direct child, then reap so we leave neither a zombie nor an orphaned
        // model holding GPU memory. Then remove the pidfile: a surviving pidfile
        // must unambiguously mean an orphan from an UNCLEAN death (SIGKILL skips
        // Drop), which is what reclaim keys off on the next launch.
        //
        // The sidecar runs in its own process group via spawn's `process_group(0)`;
        // killing the direct child removes the single-process llama-server. Killing
        // the whole GROUP for grandchildren would need `libc::kill(-pgid)` — blocked
        // by `#![forbid(unsafe_code)]` and the macOS `/bin/kill -PGID` quirk; the
        // sidecar is single-process so there are none, and Facet B reclaims any
        // survivor on the next launch regardless.
        let pid = self.child.id();
        unregister_sidecar(pid);
        send_signal(pid, "TERM");
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(1000);
        while std::time::Instant::now() < deadline {
            if !process_alive(pid) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        if process_alive(pid) {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
        if let Some(ref pidfile) = self.pidfile {
            let _ = std::fs::remove_file(pidfile);
        }
    }
}

/// Interior-mutable sidecar state, so `engine.reload` can restart the child with
/// a new personal adapter behind a shared `Arc<dyn ProviderAdapter>`.
struct Sidecar {
    /// `Some` when this adapter owns a spawned child; `None` for an attached
    /// external server (which cannot be reloaded).
    handle: Option<LlamaServerHandle>,
    /// The spawn config — needed to restart with a different `--lora`. `None`
    /// in attach (`connect`) mode.
    config: Option<LlamaServerConfig>,
}

/// Conservative context window reported for an ATTACHED (not daemon-spawned)
/// `llama-server`, whose real `--ctx-size` we cannot observe (Phase G1). Matches
/// the common small-model default; the spawned/lazy paths report the real value.
pub const DEFAULT_LLAMA_CONTEXT_WINDOW: usize = 8192;

/// A `llama-server` behind the [`ProviderAdapter`] contract.
pub struct LlamaServerAdapter {
    http: reqwest::Client,
    base_url: String,
    info: AdapterInfo,
    /// Whether a personal LoRA is loaded — gates the per-request `lora` field.
    /// Interior-mutable so `engine.reload` can toggle presence at runtime.
    lora_present: AtomicBool,
    /// Personal-LoRA scale (f32 bits); meaningful only when `lora_present`.
    /// Interior-mutable so `set_adapter_scale` works through `Arc<dyn …>`.
    lora_scale: AtomicU32,
    /// The supervised child + its config, swapped on `reload_adapter`.
    sidecar: Mutex<Sidecar>,
    /// The confined path + content hash of the loaded personal adapter (gap
    /// P3/C3 Stage 4), for `runtime.status` audit. `None` when serving base.
    loaded_adapter: Mutex<Option<(String, String)>>,
}

impl LlamaServerAdapter {
    /// Attach to an already-running server at `base_url` (e.g. `http://127.0.0.1:18082`).
    /// No personal adapter is assumed; use [`Self::with_lora`] to mark one loaded.
    /// An attached server is not daemon-managed, so it cannot be reloaded.
    pub fn connect(base_url: impl Into<String>, model_id: impl Into<String>) -> LlamaServerAdapter {
        LlamaServerAdapter {
            http: reqwest::Client::new(),
            base_url: base_url.into().trim_end_matches('/').to_owned(),
            info: AdapterInfo {
                backend: "llama.cpp".to_owned(),
                model_id: model_id.into(),
                // An attached server's `--ctx-size` is not known here (we did not
                // spawn it), so report a conservative documented default (Phase
                // G1). The spawned/lazy constructors below carry the real value.
                context_window: DEFAULT_LLAMA_CONTEXT_WINDOW,
            },
            lora_present: AtomicBool::new(false),
            lora_scale: AtomicU32::new(1.0_f32.to_bits()),
            sidecar: Mutex::new(Sidecar {
                handle: None,
                config: None,
            }),
            loaded_adapter: Mutex::new(None),
        }
    }

    /// Mark that a personal LoRA is loaded (at [`PERSONAL_LORA_ID`]) with an
    /// initial scale, so every request carries `lora:[{id,scale}]` and the
    /// runtime toggle has something to control. Scale is clamped to `0.0..=2.0`.
    #[must_use]
    pub fn with_lora(self, initial_scale: f32) -> LlamaServerAdapter {
        self.lora_scale
            .store(initial_scale.clamp(0.0, 2.0).to_bits(), Ordering::Relaxed);
        self.lora_present.store(true, Ordering::Relaxed);
        self
    }

    /// Spawn + supervise a `llama-server` child, then attach to it. When the
    /// config loads a personal LoRA, personalization is on by default
    /// (scale `1.0`).
    pub async fn spawn(
        config: LlamaServerConfig,
        model_id: impl Into<String>,
    ) -> Result<LlamaServerAdapter, EngineError> {
        Self::spawn_with_timeout(config, model_id, std::time::Duration::from_secs(120)).await
    }

    /// Spawn + supervise a `llama-server` child with an explicit readiness
    /// timeout. Used by the lazy HF-download path: first launch can legitimately
    /// download gigabytes before `/health` turns green.
    pub async fn spawn_with_timeout(
        config: LlamaServerConfig,
        model_id: impl Into<String>,
        timeout: std::time::Duration,
    ) -> Result<LlamaServerAdapter, EngineError> {
        let has_lora = config.lora_gguf.is_some();
        let context_window = config.ctx_size as usize;
        let handle = LlamaServerHandle::spawn(&config, timeout).await?;
        let base_url = handle.base_url.clone();
        let adapter = LlamaServerAdapter {
            http: reqwest::Client::new(),
            base_url,
            info: AdapterInfo {
                backend: "llama.cpp".to_owned(),
                model_id: model_id.into(),
                // The sidecar is launched with `--ctx-size <ctx_size>` (Phase G1).
                context_window,
            },
            lora_present: AtomicBool::new(false),
            lora_scale: AtomicU32::new(1.0_f32.to_bits()),
            sidecar: Mutex::new(Sidecar {
                handle: Some(handle),
                config: Some(config),
            }),
            loaded_adapter: Mutex::new(None),
        };
        Ok(if has_lora {
            adapter.with_lora(1.0)
        } else {
            adapter
        })
    }

    /// Current personal-LoRA scale, or `None` when no adapter is loaded.
    fn current_scale(&self) -> Option<f32> {
        if self.lora_present.load(Ordering::Relaxed) {
            Some(f32::from_bits(self.lora_scale.load(Ordering::Relaxed)))
        } else {
            None
        }
    }

    /// True if this adapter owns a spawned sidecar whose child process has exited
    /// (reaping it via `try_wait`). `false` for an attached (`connect`) server —
    /// we do not own that process — or when the child is still running or its
    /// status is unknowable (assume alive rather than thrash a respawn).
    fn child_exited(&self) -> bool {
        let mut guard = self.sidecar.lock().unwrap_or_else(PoisonError::into_inner);
        match guard.handle.as_mut() {
            Some(handle) => matches!(handle.child.try_wait(), Ok(Some(_))),
            None => false,
        }
    }
}

/// Cap on consecutive sidecar respawns within [`RESPAWN_WINDOW`]. A `llama-server`
/// (~5 GB) that dies on every launch — Metal assert, corrupt GGUF, jetsam — must
/// fail loud, not respawn forever.
const MAX_CONSECUTIVE_RESPAWNS: u32 = 3;

/// Rolling window for the respawn cap. A death that arrives after the window has
/// elapsed since the first one resets the counter, so isolated crashes spread
/// over time never trip the crash-loop guard.
const RESPAWN_WINDOW: std::time::Duration = std::time::Duration::from_secs(60);

/// Respawn accounting for the crash-loop guard: how many sidecar deaths have been
/// recovered within the current [`RESPAWN_WINDOW`].
struct RespawnLedger {
    count: u32,
    window_start: std::time::Instant,
}

/// Lazy daemon-owned llama.cpp adapter. Construction is cheap and does not spawn
/// or download anything; the first `stream_chat` / `reload_adapter` call starts
/// `llama-server`. This keeps daemon/control-plane startup responsive while
/// still supporting llama.cpp `-hf` on-demand downloads into `LLAMA_CACHE`.
///
/// The spawned sidecar is supervised for crash recovery: a connection-level
/// failure against a dead child clears the cache so the NEXT turn respawns a
/// fresh sidecar from the stored config, capped by the crash-loop guard.
pub struct LazyLlamaServerAdapter {
    config: LlamaServerConfig,
    model_id: String,
    timeout: std::time::Duration,
    info: AdapterInfo,
    spawned: Mutex<Option<Arc<LlamaServerAdapter>>>,
    spawn_lock: tokio::sync::Mutex<()>,
    pending_scale: AtomicU32,
    respawn_ledger: Mutex<RespawnLedger>,
    /// Canonical path of the last personal adapter successfully loaded via
    /// `reload_adapter` (`None` = base model). Replayed on crash-respawn so a
    /// deployed personalization survives a sidecar crash instead of silently
    /// reverting to the base model with `pending_scale` re-applied to nothing.
    last_adapter: Mutex<Option<String>>,
}

impl LazyLlamaServerAdapter {
    #[must_use]
    pub fn new(
        config: LlamaServerConfig,
        model_id: impl Into<String>,
        timeout: std::time::Duration,
    ) -> LazyLlamaServerAdapter {
        let model_id = model_id.into();
        let initial_adapter = config.lora_gguf.clone();
        let context_window = config.ctx_size as usize;
        LazyLlamaServerAdapter {
            config,
            model_id: model_id.clone(),
            timeout,
            info: AdapterInfo {
                backend: "llama.cpp".to_owned(),
                model_id,
                // The stored config spawns the sidecar with `--ctx-size` (Phase G1).
                context_window,
            },
            spawned: Mutex::new(None),
            spawn_lock: tokio::sync::Mutex::new(()),
            pending_scale: AtomicU32::new(1.0_f32.to_bits()),
            respawn_ledger: Mutex::new(RespawnLedger {
                count: 0,
                window_start: std::time::Instant::now(),
            }),
            last_adapter: Mutex::new(initial_adapter),
        }
    }

    async fn ensure_spawned(&self) -> Result<Arc<LlamaServerAdapter>, EngineError> {
        // Fast path: a cached, live sidecar. A cached-but-dead sidecar (the child
        // crashed since we spawned it) falls through to the respawn path below.
        {
            let guard = self.spawned.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(adapter) = guard.as_ref() {
                if !adapter.child_exited() {
                    return Ok(Arc::clone(adapter));
                }
            }
        }
        // Serialize (re)spawn so concurrent first/again requests do not race and
        // start two llama-server children on the same port.
        let _spawn_guard = self.spawn_lock.lock().await;
        let mut respawn = false;
        {
            let guard = self.spawned.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(adapter) = guard.as_ref() {
                if adapter.child_exited() {
                    // The previous sidecar crashed; a fresh spawn is a respawn,
                    // subject to the crash-loop cap. Leave the dead adapter cached
                    // so a capped loop keeps failing loud (via `note_respawn`)
                    // instead of silently spawning again.
                    respawn = true;
                } else {
                    return Ok(Arc::clone(adapter));
                }
            }
        }
        if respawn {
            self.note_respawn()?;
        }
        // Replay a previously deployed personal adapter across the (re)spawn.
        // ensure_spawned otherwise spawns from `self.config` (base model,
        // lora_gguf: None) because reload_adapter only mutates the inner
        // sidecar's config — after a crash-respawn that would silently revert to
        // the base model with `pending_scale` re-applied to nothing. Re-validate +
        // re-hash the recorded path here (it may have been removed/tampered since
        // deploy); fail loud rather than silently serving base.
        let last_adapter = self
            .last_adapter
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let mut spawn_config = self.config.clone();
        if let Some(path) = &last_adapter {
            let canonical = validate_personal_adapter(path)?;
            // Re-hash so a tampered/replaced adapter fails loud instead of being
            // served silently. The digest is recorded on the inner adapter below.
            sha256_file(&canonical).map_err(|error| {
                EngineError::AdapterPath(format!("hash adapter {}: {error}", canonical.display()))
            })?;
            spawn_config.lora_gguf = Some(canonical.to_string_lossy().into_owned());
        } else {
            spawn_config.lora_gguf = None;
        }
        let adapter = Arc::new(
            LlamaServerAdapter::spawn_with_timeout(
                spawn_config,
                self.model_id.clone(),
                self.timeout,
            )
            .await?,
        );
        adapter.set_adapter_scale(f32::from_bits(self.pending_scale.load(Ordering::Relaxed)))?;
        // We hold `spawn_lock`, the only writer of `spawned`, so no other task can
        // have installed a sidecar meanwhile — replace the None/dead entry.
        let mut guard = self.spawned.lock().unwrap_or_else(PoisonError::into_inner);
        *guard = Some(Arc::clone(&adapter));
        Ok(adapter)
    }

    /// Record a respawn and enforce the crash-loop cap. Returns an error (and does
    /// NOT respawn) once more than [`MAX_CONSECUTIVE_RESPAWNS`] deaths occur inside
    /// [`RESPAWN_WINDOW`], so a sidecar that dies on every launch fails loudly.
    fn note_respawn(&self) -> Result<(), EngineError> {
        let now = std::time::Instant::now();
        let mut ledger = self
            .respawn_ledger
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if now.duration_since(ledger.window_start) > RESPAWN_WINDOW {
            ledger.count = 0;
            ledger.window_start = now;
        }
        ledger.count = ledger.count.saturating_add(1);
        if ledger.count > MAX_CONSECUTIVE_RESPAWNS {
            return Err(EngineError::Inference(format!(
                "llama-server sidecar crash loop: {} deaths within {}s; not respawning",
                ledger.count,
                RESPAWN_WINDOW.as_secs()
            )));
        }
        Ok(())
    }
}

#[async_trait]
impl ProviderAdapter for LazyLlamaServerAdapter {
    fn describe(&self) -> AdapterInfo {
        self.info.clone()
    }

    fn set_adapter_scale(&self, scale: f32) -> Result<(), EngineError> {
        self.pending_scale
            .store(scale.clamp(0.0, 2.0).to_bits(), Ordering::Relaxed);
        if let Some(adapter) = self
            .spawned
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
        {
            adapter.set_adapter_scale(scale)?;
        }
        Ok(())
    }

    async fn reload_adapter(&self, personal_adapter: Option<String>) -> Result<(), EngineError> {
        let adapter = self.ensure_spawned().await?;
        adapter.reload_adapter(personal_adapter).await?;
        // Record the canonical (confinement-checked) path the inner adapter
        // actually loaded so a later crash-respawn replays THIS adapter, not the
        // construction-time config. `loaded_adapter()` is `None` for the base
        // model, which is exactly what we want to persist for a base reload.
        let loaded = adapter.loaded_adapter().map(|loaded| loaded.path);
        *self
            .last_adapter
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = loaded;
        Ok(())
    }

    fn loaded_adapter(&self) -> Option<LoadedAdapter> {
        // Only a spawned sidecar can hold an adapter; before first spawn there is
        // none. Don't force a spawn just to answer a status query.
        self.spawned
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .and_then(|adapter| adapter.loaded_adapter())
    }

    async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError> {
        self.ensure_spawned().await?.stream_chat(request).await
    }
}

#[async_trait]
impl ProviderAdapter for LlamaServerAdapter {
    fn describe(&self) -> AdapterInfo {
        self.info.clone()
    }

    fn set_adapter_scale(&self, scale: f32) -> Result<(), EngineError> {
        // Stored regardless; it only takes effect while a personal LoRA is loaded
        // (see `current_scale`). 0.0 = base, 1.0 = personalized.
        self.lora_scale
            .store(scale.clamp(0.0, 2.0).to_bits(), Ordering::Relaxed);
        Ok(())
    }

    async fn reload_adapter(&self, personal_adapter: Option<String>) -> Result<(), EngineError> {
        // Reload only works for a daemon-managed sidecar (we own the child + its
        // config). An attached external server has no config to restart with.
        let mut config = {
            let guard = self.sidecar.lock().unwrap_or_else(PoisonError::into_inner);
            guard.config.clone()
        }
        .ok_or_else(|| {
            EngineError::Inference(
                "engine.reload requires a daemon-managed llama-server (not an attached URL)"
                    .to_owned(),
            )
        })?;

        // Gap P3/C3 Stage 4: validate + hash the adapter BEFORE tearing the old
        // child down. The path is untrusted (arrives over NDJSON), and a bad path
        // that fails *after* the kill would leave the daemon deaf. Validating
        // first means a rejected reload leaves the running sidecar untouched.
        let validated: Option<(String, String)> = match &personal_adapter {
            Some(path) => {
                let canonical = validate_personal_adapter(path)?;
                let sha = sha256_file(&canonical).map_err(|error| {
                    EngineError::AdapterPath(format!(
                        "hash adapter {}: {error}",
                        canonical.display()
                    ))
                })?;
                Some((canonical.to_string_lossy().into_owned(), sha))
            }
            None => None,
        };
        // Load the canonical (confinement-checked) path, not the raw request.
        config.lora_gguf = validated.as_ref().map(|(path, _)| path.clone());

        // Kill the old child FIRST so the loopback port is free before re-binding.
        {
            let mut guard = self.sidecar.lock().unwrap_or_else(PoisonError::into_inner);
            guard.handle = None; // Drop → kill + wait (blocks until reaped)
        }
        let handle = LlamaServerHandle::spawn(&config, std::time::Duration::from_secs(120)).await?;
        {
            let mut guard = self.sidecar.lock().unwrap_or_else(PoisonError::into_inner);
            guard.handle = Some(handle);
            guard.config = Some(config);
        }
        // Personalization follows whether an adapter was supplied; the scale keeps
        // its last value (1.0 unless toggled). Same port ⇒ `base_url` unchanged.
        self.lora_present
            .store(personal_adapter.is_some(), Ordering::Relaxed);
        *self
            .loaded_adapter
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = validated;
        Ok(())
    }

    fn loaded_adapter(&self) -> Option<LoadedAdapter> {
        let guard = self
            .loaded_adapter
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        guard.as_ref().map(|(path, sha256)| LoadedAdapter {
            path: path.clone(),
            sha256: sha256.clone(),
            scale: f32::from_bits(self.lora_scale.load(Ordering::Relaxed)),
        })
    }

    async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError> {
        let body = build_chat_body(&request, &self.info.model_id, self.current_scale())?;
        let url = format!("{}/v1/chat/completions", self.base_url);

        // Send the request eagerly (here, where `&self` is in scope) so a
        // connection-level failure can consult the child via `try_wait` and
        // surface a distinct "sidecar died" error — the lazy wrapper then
        // respawns on the next turn. Only the successful `response` (owned,
        // 'static) is moved into the stream, so the returned `ChatStream` stays
        // self-contained, matching the mistral.rs adapter shape.
        let response = match self.http.post(&url).json(&body).send().await {
            Ok(response) => response,
            Err(error) => {
                // A connect/request-level failure (refused/reset) usually means
                // the sidecar process died. Distinguish it from HTTP/generation
                // errors and check the child so the message tells the caller a
                // respawn is coming; the lazy adapter reaps + respawns next turn.
                if (error.is_connect() || error.is_request()) && self.child_exited() {
                    return Err(EngineError::Inference(
                        "llama-server sidecar died; respawning on next turn".to_owned(),
                    ));
                }
                return Err(EngineError::Inference(format!(
                    "llama-server request failed: {error}"
                )));
            }
        };
        if !response.status().is_success() {
            let status = response.status();
            let detail = response.text().await.unwrap_or_default();
            return Err(EngineError::Inference(format!(
                "llama-server {status}: {detail}"
            )));
        }

        let mapped = async_stream::stream! {
            // SSE: events are `data: {json}\n\n`, plus `data: [DONE]`. Buffer
            // across chunk boundaries and emit one ChatEvent per delta.
            let mut byte_stream = response.bytes_stream();
            let mut buffer = String::new();
            let mut saw_done = false;
            let mut pending_tool_calls: BTreeMap<usize, PendingToolCall> = BTreeMap::new();
            while let Some(chunk) = byte_stream.next().await {
                let bytes = match chunk {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        yield Err(EngineError::Inference(format!("llama-server stream error: {error}")));
                        return;
                    }
                };
                buffer.push_str(&String::from_utf8_lossy(&bytes));
                while let Some(newline) = buffer.find('\n') {
                    let line: String = buffer.drain(..=newline).collect();
                    let line = line.trim_end_matches(['\r', '\n']);
                    let Some(data) = line.strip_prefix("data: ") else { continue };
                    if data == "[DONE]" {
                        saw_done = true;
                        continue;
                    }
                    let Ok(value) = serde_json::from_str::<serde_json::Value>(data) else {
                        continue; // keep-alive / non-JSON line
                    };
                    for event in events_from_chunk_with_pending_tools(&value, &mut pending_tool_calls) {
                        yield Ok(event);
                    }
                }
            }
            // A byte stream that ends without `data: [DONE]` is a truncated turn
            // (mid-turn llama-server crash / dropped connection), not a complete
            // answer. Fail loud so the caller doesn't speak a partial reply or
            // capture it to memory as a normal turn — and do NOT flush pending
            // tool calls from an interrupted stream.
            if !saw_done {
                yield Err(EngineError::Inference(
                    "llama-server stream ended without [DONE]".to_owned(),
                ));
                return;
            }
            for call in finish_pending_tool_calls(&mut pending_tool_calls) {
                yield Ok(call);
            }
            yield Ok(ChatEvent::Done { finish_reason: "stop".to_owned() });
        };
        Ok(Box::pin(mapped))
    }
}

pub(crate) fn role_str(role: Role) -> &'static str {
    match role {
        Role::System => "system",
        Role::User => "user",
        Role::Assistant => "assistant",
        Role::Tool => "tool",
    }
}

/// Translate a [`ChatRequest`] into an OpenAI `/v1/chat/completions` body. Pure,
/// so it is unit-tested without a server. A message carrying push-to-talk audio
/// (S18) is validated (fail loud on bad base64) and attached as an `input_audio`
/// content part — Gemma 4's audio pass (validation §A).
fn build_chat_body(
    request: &ChatRequest,
    model_id: &str,
    lora_scale: Option<f32>,
) -> Result<serde_json::Value, EngineError> {
    let mut messages = Vec::new();
    if let Some(system) = &request.system {
        messages.push(serde_json::json!({ "role": "system", "content": system }));
    }
    for message in &request.messages {
        let role = role_str(message.role);
        // Validate any attached audio up front — never silently drop a clip.
        match message.decode_audio()? {
            Some(_) => {
                let encoded = message.audio_wav_base64.as_deref().unwrap_or_default();
                messages.push(serde_json::json!({
                    "role": role,
                    "content": [
                        { "type": "input_audio", "input_audio": { "data": encoded, "format": "wav" } },
                        { "type": "text", "text": message.content },
                    ],
                }));
            }
            None => {
                messages.push(serde_json::json!({ "role": role, "content": message.content }));
            }
        }
    }

    let mut body = serde_json::json!({
        "model": model_id,
        "messages": messages,
        "max_tokens": request.max_tokens,
        "stream": true,
        // Keep reasoning inline in `content`; Fae self-parses think/tool markup.
        "reasoning_format": "none",
    });
    // Per-request personal-LoRA scale (gap B3): 0.0 = base, 1.0 = personalized.
    // Only sent when an adapter is loaded — llama-server rejects a `lora` entry
    // for an id it never loaded.
    if let Some(scale) = lora_scale {
        body["lora"] = serde_json::json!([{ "id": PERSONAL_LORA_ID, "scale": scale }]);
    }
    if !request.tools.is_empty() {
        let tools: Vec<serde_json::Value> = request
            .tools
            .iter()
            .map(|spec| {
                serde_json::json!({
                    "type": "function",
                    "function": {
                        "name": spec.name,
                        "description": spec.description,
                        "parameters": spec.parameters,
                    }
                })
            })
            .collect();
        body["tools"] = serde_json::Value::Array(tools);
        body["tool_choice"] = serde_json::Value::String("auto".to_owned());
    }
    Ok(body)
}

#[derive(Default)]
pub(crate) struct PendingToolCall {
    name: String,
    arguments: String,
}

pub(crate) fn finish_pending_tool_calls(
    pending: &mut BTreeMap<usize, PendingToolCall>,
) -> Vec<ChatEvent> {
    let drained = std::mem::take(pending);
    drained
        .into_values()
        .filter(|call| !call.name.is_empty())
        .map(|call| ChatEvent::ToolCall {
            name: call.name,
            arguments: call.arguments,
        })
        .collect()
}

pub(crate) fn events_from_chunk_with_pending_tools(
    value: &serde_json::Value,
    pending_tool_calls: &mut BTreeMap<usize, PendingToolCall>,
) -> Vec<ChatEvent> {
    let mut events = Vec::new();
    let Some(delta) = value
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("delta"))
    else {
        return events;
    };
    if let Some(text) = delta.get("content").and_then(|v| v.as_str()) {
        if !text.is_empty() {
            events.push(ChatEvent::Token(text.to_owned()));
        }
    }
    if let Some(calls) = delta.get("tool_calls").and_then(|v| v.as_array()) {
        for call in calls {
            let index = call
                .get("index")
                .and_then(|v| v.as_u64())
                .and_then(|raw| usize::try_from(raw).ok())
                .unwrap_or(0);
            let pending = pending_tool_calls.entry(index).or_default();
            let function = call.get("function");
            if let Some(name) = function
                .and_then(|f| f.get("name"))
                .and_then(|v| v.as_str())
            {
                pending.name.push_str(name);
            }
            if let Some(arguments) = function
                .and_then(|f| f.get("arguments"))
                .and_then(|v| v.as_str())
            {
                pending.arguments.push_str(arguments);
            }
        }
    }
    events
}

/// Map one streamed chunk's `choices[0].delta` to immediate token events plus
/// fully accumulated tool calls for single-chunk tests.
#[cfg(test)]
fn events_from_chunk(value: &serde_json::Value) -> Vec<ChatEvent> {
    let mut pending = BTreeMap::new();
    let mut events = events_from_chunk_with_pending_tools(value, &mut pending);
    events.extend(finish_pending_tool_calls(&mut pending));
    events
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{ChatMessage, ToolSpec};
    use std::sync::Mutex;

    static ENV_GUARD: Mutex<()> = Mutex::new(());

    fn weather_tool() -> ToolSpec {
        ToolSpec {
            name: "get_weather".to_owned(),
            description: "Get the weather for a city".to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": { "city": { "type": "string" } },
                "required": ["city"]
            }),
        }
    }

    #[test]
    fn held_port_message_identifies_stale_fae_llama_server_from_different_install() {
        let holder = (
            4242,
            "/old/Fae.app/Contents/Resources/LlamaCpp/llama-server -m model.gguf".to_owned(),
        );
        let configured_binary = "/new/Fae.app/Contents/Resources/LlamaCpp/llama-server";

        let message = held_port_message(18080, configured_binary, Some(&holder));

        assert!(message.contains("port 18080"));
        assert!(message.contains("pid 4242"));
        assert!(message.contains("llama-server"));
        assert!(message.contains("/old/Fae.app/Contents/Resources/LlamaCpp/llama-server"));
        assert!(message.contains(configured_binary));
        assert!(message.contains("different install path"));
        assert!(message.contains("ownership check refused to kill it"));
        assert!(message.contains("just kill-stale-sidecars"));
    }

    #[test]
    fn held_port_message_identifies_non_fae_holder_without_fae_kill_recipe() {
        let holder = (25509, "/opt/homebrew/bin/llama serve".to_owned());

        let message = held_port_message(
            18080,
            "/new/Fae.app/Contents/Resources/LlamaCpp/llama-server",
            Some(&holder),
        );

        assert!(message.contains("pid 25509"));
        assert!(message.contains("/opt/homebrew/bin/llama serve"));
        assert!(message.contains("ownership check refused to kill it"));
        assert!(!message.contains("llama-server"));
        assert!(!message.contains("just kill-stale-sidecars"));
    }

    #[test]
    fn held_port_message_reports_unidentified_listener_without_holder() {
        let message = held_port_message(
            18080,
            "/new/Fae.app/Contents/Resources/LlamaCpp/llama-server",
            None,
        );

        assert!(message.contains("listener process could not be identified"));
    }

    #[test]
    fn config_args_use_verified_local_source_not_raw_hf() {
        let config = LlamaServerConfig {
            binary: "/tmp/llama-server".to_owned(),
            model: LlamaModelSource::Local {
                model_gguf: "/tmp/fae-cache/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf".to_owned(),
                mmproj: Some("/tmp/fae-cache/mmproj-BF16.gguf".to_owned()),
                mtp_draft: Some("/tmp/fae-cache/mtp-gemma-4-E4B-it.gguf".to_owned()),
            },
            lora_gguf: None,
            alias: "gemma-4".to_owned(),
            enable_thinking: true,
            mtp_draft_tokens: Some(4),
            port: 18080,
            ctx_size: 8192,
            ngl: 999,
            kv_cache_type: KvCacheType::F16,
            pidfile_root: None,
        };
        let args = config.args();
        assert!(!args.iter().any(|arg| arg == "-hf"));
        assert!(args
            .windows(2)
            .any(|w| w == ["-m", "/tmp/fae-cache/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf"]));
        assert!(args
            .windows(2)
            .any(|w| w == ["--mmproj", "/tmp/fae-cache/mmproj-BF16.gguf"]));
        assert!(args
            .windows(2)
            .any(|w| w == ["--model-draft", "/tmp/fae-cache/mtp-gemma-4-E4B-it.gguf"]));
        assert!(args.windows(2).any(|w| w == ["--alias", "gemma-4"]));
        assert!(args.windows(2).any(|w| w == ["--jinja", "--alias"]));
        assert!(args.windows(2).any(|w| w == ["-ngl", "999"]));
        assert!(args.windows(2).any(|w| w == ["--spec-type", "draft-mtp"]));
        assert!(args.windows(2).any(|w| w == ["--spec-draft-n-max", "4"]));
        assert!(args.windows(2).any(|w| w == ["--reasoning", "on"]));
    }

    #[test]
    fn config_args_use_local_source_with_mmproj() {
        let config = LlamaServerConfig {
            binary: "/tmp/llama-server".to_owned(),
            model: LlamaModelSource::Local {
                model_gguf: "/tmp/model.gguf".to_owned(),
                mmproj: Some("/tmp/mmproj.gguf".to_owned()),
                mtp_draft: None,
            },
            lora_gguf: None,
            alias: "gemma-4".to_owned(),
            enable_thinking: false,
            mtp_draft_tokens: None,
            port: 18080,
            ctx_size: 8192,
            ngl: 999,
            kv_cache_type: KvCacheType::F16,
            pidfile_root: None,
        };
        let args = config.args();
        assert!(args.windows(2).any(|w| w == ["-m", "/tmp/model.gguf"]));
        assert!(args
            .windows(2)
            .any(|w| w == ["--mmproj", "/tmp/mmproj.gguf"]));
        assert!(args.windows(2).any(|w| w == ["--reasoning", "off"]));
        // F16 KV cache is the llama-server default — no cache-type flags, so the
        // high-RAM command line is unchanged from the pre-quantization one.
        assert!(!args.iter().any(|arg| arg.starts_with("--cache-type")));
    }

    #[test]
    fn config_args_emit_quantized_kv_cache_flags() {
        let config = LlamaServerConfig {
            binary: "/tmp/llama-server".to_owned(),
            model: LlamaModelSource::Local {
                model_gguf: "/tmp/model.gguf".to_owned(),
                mmproj: None,
                mtp_draft: None,
            },
            lora_gguf: None,
            alias: "gemma-4".to_owned(),
            enable_thinking: false,
            mtp_draft_tokens: None,
            port: 18080,
            ctx_size: 8192,
            ngl: 999,
            kv_cache_type: KvCacheType::Q8,
            pidfile_root: None,
        };
        let args = config.args();
        assert!(args.windows(2).any(|w| w == ["--cache-type-k", "q8_0"]));
        assert!(args.windows(2).any(|w| w == ["--cache-type-v", "q8_0"]));
        // Quantized V-cache requires flash attention — args must keep `-fa on`.
        assert!(args.windows(2).any(|w| w == ["-fa", "on"]));
    }

    // Why these matter (audit 2026-07-05 MEDIUM): fp16 KV with a 32K window
    // oversubscribes an 8 GB machine. Below 32 GiB the daemon must default to
    // q8_0; at/above (or when RAM is unknown) it must keep today's exact fp16
    // so quality never changes silently on capable machines.
    #[test]
    fn kv_cache_tier_quantizes_below_32gb_only() {
        const GIB: u64 = 1024 * 1024 * 1024;
        assert_eq!(
            select_kv_cache_type(None, Some(8 * GIB)),
            Ok(KvCacheType::Q8)
        );
        assert_eq!(
            select_kv_cache_type(None, Some(16 * GIB)),
            Ok(KvCacheType::Q8)
        );
        assert_eq!(
            select_kv_cache_type(None, Some(KV_QUANT_RAM_THRESHOLD_BYTES - 1)),
            Ok(KvCacheType::Q8)
        );
        assert_eq!(
            select_kv_cache_type(None, Some(KV_QUANT_RAM_THRESHOLD_BYTES)),
            Ok(KvCacheType::F16)
        );
        assert_eq!(
            select_kv_cache_type(None, Some(64 * GIB)),
            Ok(KvCacheType::F16)
        );
        // Unknown RAM keeps the exact fp16 default (no silent quality change).
        assert_eq!(select_kv_cache_type(None, None), Ok(KvCacheType::F16));
    }

    #[test]
    fn kv_cache_override_beats_ram_tier_and_rejects_garbage() {
        const GIB: u64 = 1024 * 1024 * 1024;
        // Force fp16 on a low-RAM machine; force q8 on a high-RAM one.
        assert_eq!(
            select_kv_cache_type(Some("fp16"), Some(8 * GIB)),
            Ok(KvCacheType::F16)
        );
        assert_eq!(
            select_kv_cache_type(Some("q8"), Some(64 * GIB)),
            Ok(KvCacheType::Q8)
        );
        // Aliases, case, and whitespace are accepted.
        assert_eq!(
            select_kv_cache_type(Some("f16"), None),
            Ok(KvCacheType::F16)
        );
        assert_eq!(
            select_kv_cache_type(Some(" Q8_0 "), None),
            Ok(KvCacheType::Q8)
        );
        // Empty/blank override falls through to the RAM tier.
        assert_eq!(
            select_kv_cache_type(Some(""), Some(8 * GIB)),
            Ok(KvCacheType::Q8)
        );
        // A typo must fail loud, not silently pick a cache type.
        let err = select_kv_cache_type(Some("q4_0"), None).expect_err("garbage rejected");
        assert!(err.contains("FAE_KV_CACHE"));
        assert!(err.contains("q4_0"));
    }

    fn sha256_hex(bytes: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        hex::encode(Sha256::digest(bytes))
    }

    fn pinned_test_config(cache_dir: &std::path::Path, model_bytes: &[u8]) -> LlamaServerConfig {
        LlamaServerConfig {
            binary: "/tmp/llama-server".to_owned(),
            model: LlamaModelSource::PinnedHuggingFace {
                repo: "test/repo".to_owned(),
                revision: "rev".to_owned(),
                cache_dir: cache_dir.to_string_lossy().to_string(),
                model: RemoteModelArtifact {
                    filename: "model.gguf".to_owned(),
                    size_bytes: model_bytes.len() as u64,
                    sha256: sha256_hex(model_bytes),
                },
                mmproj: RemoteModelArtifact {
                    filename: "mmproj.gguf".to_owned(),
                    size_bytes: 6,
                    sha256: sha256_hex(b"mmproj"),
                },
                mtp_draft: Some(RemoteModelArtifact {
                    filename: "mtp.gguf".to_owned(),
                    size_bytes: 3,
                    sha256: sha256_hex(b"mtp"),
                }),
            },
            lora_gguf: None,
            alias: "gemma-4".to_owned(),
            enable_thinking: true,
            mtp_draft_tokens: Some(4),
            port: 18080,
            ctx_size: 8192,
            ngl: 999,
            kv_cache_type: KvCacheType::F16,
            pidfile_root: None,
        }
    }

    #[test]
    fn pinned_hf_preflights_and_materializes_from_verified_cache(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let _guard = ENV_GUARD.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile_dir("ok")?;
        let root = dir.join("test--repo/rev");
        std::fs::create_dir_all(&root)?;
        std::fs::write(root.join("model.gguf"), b"model")?;
        std::fs::write(root.join("mmproj.gguf"), b"mmproj")?;
        std::fs::write(root.join("mtp.gguf"), b"mtp")?;
        let config = pinned_test_config(&dir, b"model");
        config.preflight_pinned_artifacts()?;
        let materialized = config.materialized()?;
        let LlamaModelSource::Local {
            model_gguf,
            mmproj,
            mtp_draft,
        } = materialized.model
        else {
            return Err("expected local source".into());
        };
        assert!(model_gguf.ends_with("model.gguf"));
        assert!(mmproj
            .as_deref()
            .unwrap_or_default()
            .ends_with("mmproj.gguf"));
        assert!(mtp_draft
            .as_deref()
            .unwrap_or_default()
            .ends_with("mtp.gguf"));
        std::fs::remove_dir_all(&dir).ok();
        Ok(())
    }

    #[test]
    fn pinned_hf_fails_closed_on_tampered_cached_gguf() -> Result<(), Box<dyn std::error::Error>> {
        let _guard = ENV_GUARD.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile_dir("tamper")?;
        let root = dir.join("test--repo/rev");
        std::fs::create_dir_all(&root)?;
        std::fs::write(root.join("model.gguf"), b"modem")?;
        std::fs::write(root.join("mmproj.gguf"), b"mmproj")?;
        std::fs::write(root.join("mtp.gguf"), b"mtp")?;
        let config = pinned_test_config(&dir, b"model");
        let err = config
            .preflight_pinned_artifacts()
            .expect_err("tampered cache must fail");
        assert!(err.to_string().contains("sha256 mismatch"));
        std::fs::remove_dir_all(&dir).ok();
        Ok(())
    }

    #[test]
    fn models_lock_off_is_dev_only() -> Result<(), Box<dyn std::error::Error>> {
        let _guard = ENV_GUARD.lock().map_err(|_| "env guard poisoned")?;
        let dir = tempfile_dir("lock-off")?;
        let root = dir.join("test--repo/rev");
        std::fs::create_dir_all(&root)?;
        std::fs::write(root.join("model.gguf"), b"tampered")?;
        std::fs::write(root.join("mmproj.gguf"), b"tampered")?;
        std::fs::write(root.join("mtp.gguf"), b"bad")?;
        let config = pinned_test_config(&dir, b"model");
        std::env::set_var("FAE_MODELS_LOCK", "off");
        std::env::remove_var("FAE_DEV");
        let prod_err = config
            .preflight_pinned_artifacts()
            .expect_err("prod off rejected");
        assert!(prod_err.to_string().contains("FAE_DEV=1"));
        std::env::set_var("FAE_DEV", "1");
        config.preflight_pinned_artifacts()?;
        std::env::remove_var("FAE_MODELS_LOCK");
        std::env::remove_var("FAE_DEV");
        std::fs::remove_dir_all(&dir).ok();
        Ok(())
    }

    fn tempfile_dir(tag: &str) -> std::io::Result<std::path::PathBuf> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |duration| duration.as_nanos());
        let dir = std::env::temp_dir().join(format!("fae-llama-{tag}-{nanos}"));
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }

    #[tokio::test]
    async fn lazy_adapter_construction_does_not_spawn_until_first_stream() {
        let config = LlamaServerConfig {
            binary: "/definitely/missing/llama-server".to_owned(),
            model: LlamaModelSource::Local {
                model_gguf: "/tmp/model.gguf".to_owned(),
                mmproj: None,
                mtp_draft: None,
            },
            lora_gguf: None,
            alias: "gemma-4".to_owned(),
            enable_thinking: true,
            mtp_draft_tokens: None,
            port: 1,
            ctx_size: 8192,
            ngl: 999,
            kv_cache_type: KvCacheType::F16,
            pidfile_root: None,
        };
        let adapter =
            LazyLlamaServerAdapter::new(config, "gemma-4", std::time::Duration::from_millis(1));
        assert_eq!(adapter.describe().backend, "llama.cpp");
        // First actual stream attempts to spawn and fails because the binary is
        // intentionally missing. Construction/describe above did not touch it.
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage::text(Role::User, "hi")],
            tools: Vec::new(),
            max_tokens: 1,
        };
        assert!(matches!(
            adapter.stream_chat(request).await,
            Err(EngineError::Load(_))
        ));
    }

    #[test]
    fn build_body_maps_system_messages_and_tools() {
        let request = ChatRequest {
            system: Some("You are Fae.".to_owned()),
            messages: vec![ChatMessage::text(Role::User, "weather in Paris?")],
            tools: vec![weather_tool()],
            max_tokens: 128,
        };
        let body = build_chat_body(&request, "gemma-4", None).expect("body");
        assert_eq!(body["model"], "gemma-4");
        assert_eq!(body["stream"], true);
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(body["tools"][0]["function"]["name"], "get_weather");
        assert_eq!(body["tool_choice"], "auto");
    }

    #[test]
    fn build_body_without_tools_omits_tool_fields() {
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage::text(Role::User, "hi")],
            tools: Vec::new(),
            max_tokens: 32,
        };
        let body = build_chat_body(&request, "gemma-4", None).expect("body");
        assert!(body.get("tools").is_none());
        assert_eq!(body["messages"][0]["content"], "hi");
    }

    #[test]
    fn build_body_lora_scale_only_when_loaded() {
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage::text(Role::User, "hi")],
            tools: Vec::new(),
            max_tokens: 32,
        };
        // No adapter loaded ⇒ no `lora` field (llama-server rejects an unloaded id).
        let base = build_chat_body(&request, "gemma-4", None).expect("body");
        assert!(base.get("lora").is_none());
        // Loaded ⇒ per-request scale on the personal adapter id.
        let on = build_chat_body(&request, "gemma-4", Some(1.0)).expect("body");
        assert_eq!(on["lora"][0]["id"], PERSONAL_LORA_ID);
        assert_eq!(on["lora"][0]["scale"], 1.0);
        let off = build_chat_body(&request, "gemma-4", Some(0.0)).expect("body");
        assert_eq!(off["lora"][0]["scale"], 0.0);
    }

    #[test]
    fn adapter_scale_toggle_round_trips_and_clamps() {
        let adapter = LlamaServerAdapter::connect("http://127.0.0.1:1", "m").with_lora(1.0);
        assert_eq!(adapter.current_scale(), Some(1.0));
        adapter.set_adapter_scale(0.0).expect("rollback");
        assert_eq!(adapter.current_scale(), Some(0.0));
        adapter.set_adapter_scale(5.0).expect("clamped");
        assert_eq!(adapter.current_scale(), Some(2.0));
        // An adapter with no personal LoRA loaded: the toggle is a harmless no-op.
        let base = LlamaServerAdapter::connect("http://127.0.0.1:1", "m");
        assert_eq!(base.current_scale(), None);
        base.set_adapter_scale(1.0).expect("noop");
        assert_eq!(base.current_scale(), None);
    }

    // LlamaServerAdapter::reload_adapter on a connect adapter returns Err at the
    // sidecar check before any internal .await, so the sync MutexGuard is never
    // held across a real yield point. The lint is suppressed on this function only.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn reload_without_managed_sidecar_errors() {
        // An attached (connect) adapter owns no child/config, so reload is rejected
        // — it cannot restart a server it does not manage. Use a confined path so
        // the failure is the managed-sidecar check, not the Stage-4 path gate.
        let _guard = ENV_GUARD.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("fae-adapter-{}", uuid_like()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        std::env::set_var("FAE_PERSONAL_ADAPTERS_DIR", &dir);
        let gguf = dir.join("p.gguf");
        std::fs::write(&gguf, b"GGUF").expect("write");
        let adapter = LlamaServerAdapter::connect("http://127.0.0.1:1", "m");
        let result = adapter
            .reload_adapter(Some(gguf.to_string_lossy().into_owned()))
            .await;
        assert!(matches!(result, Err(EngineError::Inference(_))));
        std::env::remove_var("FAE_PERSONAL_ADAPTERS_DIR");
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn crash_loop_test_config() -> LlamaServerConfig {
        LlamaServerConfig {
            binary: "/definitely/missing/llama-server".to_owned(),
            model: LlamaModelSource::Local {
                model_gguf: "/tmp/model.gguf".to_owned(),
                mmproj: None,
                mtp_draft: None,
            },
            lora_gguf: None,
            alias: "gemma-4".to_owned(),
            enable_thinking: true,
            mtp_draft_tokens: None,
            port: 1,
            ctx_size: 8192,
            ngl: 999,
            kv_cache_type: KvCacheType::F16,
            pidfile_root: None,
        }
    }

    #[test]
    fn respawn_cap_fails_loud_after_consecutive_deaths() {
        let adapter = LazyLlamaServerAdapter::new(
            crash_loop_test_config(),
            "gemma-4",
            std::time::Duration::from_millis(1),
        );
        // Up to the cap, deaths in the window recover silently (a real respawn).
        for _ in 0..MAX_CONSECUTIVE_RESPAWNS {
            adapter.note_respawn().expect("within cap recovers");
        }
        // One more within the same window is a crash loop → loud, distinct error
        // instead of respawning forever.
        let err = adapter.note_respawn().expect_err("over-cap must fail loud");
        assert!(err.to_string().contains("crash loop"));
    }

    #[test]
    fn child_exited_is_false_for_attached_server() {
        // A connect (attached) adapter owns no child, so it is never reported dead
        // — the lazy respawn path only supervises sidecars it spawned.
        let adapter = LlamaServerAdapter::connect("http://127.0.0.1:1", "m");
        assert!(!adapter.child_exited());
    }

    // ── Gap P3/C3 Stage 4: personal-adapter path confinement ─────────────────

    /// A weak temp-name helper (the crate avoids a uuid dep in tests).
    fn uuid_like() -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        format!("{nanos}-{:?}", std::thread::current().id()).replace(['(', ')', ' '], "")
    }

    #[test]
    fn validate_personal_adapter_accepts_confined_file() {
        let _guard = ENV_GUARD.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("fae-conf-{}", uuid_like()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        std::env::set_var("FAE_PERSONAL_ADAPTERS_DIR", &dir);
        let gguf = dir.join("personal.gguf");
        std::fs::write(&gguf, b"GGUFDATA").expect("write");

        let validated = validate_personal_adapter(&gguf.to_string_lossy())
            .expect("a real file inside the confined dir is accepted");
        assert!(validated.ends_with("personal.gguf"));

        std::env::remove_var("FAE_PERSONAL_ADAPTERS_DIR");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn validate_personal_adapter_rejects_missing_file() {
        let _guard = ENV_GUARD.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("fae-miss-{}", uuid_like()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        std::env::set_var("FAE_PERSONAL_ADAPTERS_DIR", &dir);

        let result = validate_personal_adapter(&dir.join("nope.gguf").to_string_lossy());
        assert!(matches!(result, Err(EngineError::AdapterPath(_))));

        std::env::remove_var("FAE_PERSONAL_ADAPTERS_DIR");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn validate_personal_adapter_rejects_out_of_confinement_path() {
        let _guard = ENV_GUARD.lock().unwrap_or_else(|e| e.into_inner());
        // An attacker-supplied absolute path OUTSIDE the personal-adapters dir
        // (the remotely-reachable injection this gate exists to stop) is rejected
        // even though the file exists and is readable.
        let confined = std::env::temp_dir().join(format!("fae-root-{}", uuid_like()));
        let elsewhere = std::env::temp_dir().join(format!("fae-evil-{}", uuid_like()));
        std::fs::create_dir_all(&confined).expect("mkdir confined");
        std::fs::create_dir_all(&elsewhere).expect("mkdir elsewhere");
        std::env::set_var("FAE_PERSONAL_ADAPTERS_DIR", &confined);
        let outside = elsewhere.join("evil.gguf");
        std::fs::write(&outside, b"GGUF").expect("write");

        let result = validate_personal_adapter(&outside.to_string_lossy());
        assert!(
            matches!(result, Err(EngineError::AdapterPath(_))),
            "a path outside the confined dir must be rejected"
        );

        std::env::remove_var("FAE_PERSONAL_ADAPTERS_DIR");
        let _ = std::fs::remove_dir_all(&confined);
        let _ = std::fs::remove_dir_all(&elsewhere);
    }

    #[test]
    fn validate_personal_adapter_rejects_directory() {
        let _guard = ENV_GUARD.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("fae-dir-{}", uuid_like()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        std::env::set_var("FAE_PERSONAL_ADAPTERS_DIR", &dir);
        let subdir = dir.join("notafile");
        std::fs::create_dir_all(&subdir).expect("mkdir subdir");

        let result = validate_personal_adapter(&subdir.to_string_lossy());
        assert!(matches!(result, Err(EngineError::AdapterPath(_))));

        std::env::remove_var("FAE_PERSONAL_ADAPTERS_DIR");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn loaded_adapter_is_none_for_base_serving() {
        // A connect adapter with no LoRA reports no loaded adapter (runtime.status
        // → adapter: null).
        let adapter = LlamaServerAdapter::connect("http://127.0.0.1:1", "m");
        assert!(adapter.loaded_adapter().is_none());
    }

    fn tiny_wav() -> Vec<u8> {
        let samples: [i16; 4] = [0, 1000, -1000, 0];
        let data_len = (samples.len() * 2) as u32;
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_len).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&16_000u32.to_le_bytes());
        wav.extend_from_slice(&32_000u32.to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_len.to_le_bytes());
        for sample in samples {
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        wav
    }

    #[test]
    fn build_body_attaches_audio_as_input_audio_part() {
        use base64::Engine as _;
        let encoded = base64::engine::general_purpose::STANDARD.encode(tiny_wav());
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage {
                role: Role::User,
                content: "what did I say?".to_owned(),
                audio_wav_base64: Some(encoded),
            }],
            tools: Vec::new(),
            max_tokens: 64,
        };
        let body = build_chat_body(&request, "gemma-4", None).expect("body");
        let content = &body["messages"][0]["content"];
        assert_eq!(content[0]["type"], "input_audio");
        assert_eq!(content[0]["input_audio"]["format"], "wav");
        assert_eq!(content[1]["type"], "text");
        assert_eq!(content[1]["text"], "what did I say?");
    }

    #[test]
    fn build_body_rejects_malformed_audio() {
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage {
                role: Role::User,
                content: "x".to_owned(),
                audio_wav_base64: Some("not-base64!!!".to_owned()),
            }],
            tools: Vec::new(),
            max_tokens: 16,
        };
        assert!(matches!(
            build_chat_body(&request, "gemma-4", None),
            Err(EngineError::Inference(_))
        ));
    }

    #[test]
    fn events_from_chunk_extracts_token() {
        let chunk = serde_json::json!({
            "choices": [{ "delta": { "content": "Edinburgh" } }]
        });
        assert_eq!(
            events_from_chunk(&chunk),
            vec![ChatEvent::Token("Edinburgh".to_owned())]
        );
    }

    #[test]
    fn events_from_chunk_accumulates_streamed_tool_call_fragments() {
        let mut pending = BTreeMap::new();
        let first = serde_json::json!({
            "choices": [{ "delta": { "tool_calls": [
                { "index": 0, "function": { "name": "get_weather", "arguments": "{\"city\"" } }
            ] } }]
        });
        let second = serde_json::json!({
            "choices": [{ "delta": { "tool_calls": [
                { "index": 0, "function": { "arguments": ":\"Paris\"}" } }
            ] } }]
        });
        assert!(events_from_chunk_with_pending_tools(&first, &mut pending).is_empty());
        assert!(events_from_chunk_with_pending_tools(&second, &mut pending).is_empty());
        assert_eq!(
            finish_pending_tool_calls(&mut pending),
            vec![ChatEvent::ToolCall {
                name: "get_weather".to_owned(),
                arguments: "{\"city\":\"Paris\"}".to_owned(),
            }]
        );
    }

    #[test]
    fn events_from_chunk_extracts_tool_call() {
        let chunk = serde_json::json!({
            "choices": [{ "delta": { "tool_calls": [
                { "function": { "name": "get_weather", "arguments": "{\"city\":\"Paris\"}" } }
            ] } }]
        });
        assert_eq!(
            events_from_chunk(&chunk),
            vec![ChatEvent::ToolCall {
                name: "get_weather".to_owned(),
                arguments: "{\"city\":\"Paris\"}".to_owned(),
            }]
        );
    }

    #[test]
    fn events_from_chunk_empty_delta_yields_nothing() {
        let chunk = serde_json::json!({ "choices": [{ "delta": {} }] });
        assert!(events_from_chunk(&chunk).is_empty());
        let role_only = serde_json::json!({ "choices": [{ "delta": { "role": "assistant" } }] });
        assert!(events_from_chunk(&role_only).is_empty());
    }
}
