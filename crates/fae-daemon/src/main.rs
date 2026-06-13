//! Fae headless-core daemon — **Phase 1, chunk 2a**.
//!
//! Control-plane-first: every byte a client sends is routed through
//! [`fae_control_plane`]. Chunk 1 built + tested the transport-free
//! authorization core; chunk 2a adds the **Unix-domain-socket** transport
//! (NDJSON), per-connection token authentication, per-message `authorize`, a
//! read-only command dispatch stub, and fail-closed audit. No TCP port is
//! opened — TCP-loopback + WS/SSE diagnostics with single-use stream tickets
//! are chunk 2c; the mistral.rs engine adapter is chunk 3.
//!
//! Run: `cargo run -p fae-daemon`. It bootstraps a private run dir + token,
//! then serves the socket until killed.
#![forbid(unsafe_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use fae_audio::AudioManager;
use fae_control_plane::{
    generate_token, hash_token, ClientClass, ClientRecord, ClientRegistry, TicketStore,
    PROTOCOL_VERSION,
};
use fae_engine::{
    LocalMistralrsAdapter, MockAdapter, MockTtsAdapter, ModelsLock, ProviderAdapter, TtsAdapter,
};

mod diagnostic;
mod session;
mod transport;

const THIRTY_DAYS_MS: u64 = 30 * 24 * 60 * 60 * 1000;

type DaemonResult<T> = Result<T, Box<dyn std::error::Error>>;

#[tokio::main]
async fn main() -> DaemonResult<()> {
    if std::env::args().any(|arg| arg == "--version") {
        println!(
            "fae-daemon {} — protocol v{PROTOCOL_VERSION}",
            env!("CARGO_PKG_VERSION")
        );
        return Ok(());
    }

    println!("fae-daemon (Phase 1, chunk 2a) — protocol v{PROTOCOL_VERSION}");

    spawn_parent_watch();

    let run_dir = run_directory()?;
    create_private_dir(&run_dir)?;
    let socket_path = run_dir.join("fae-daemon.sock");
    let audit_path = run_dir.join("audit.jsonl");
    println!("run dir : {} (0700)", run_dir.display());

    // ── Bootstrap the first client (the Swift frontend launched by the owner) ──
    let now = now_ms();
    let token = generate_token()?;
    let token_hash = hash_token(&token);
    let token_path = run_dir.join("bootstrap.token");
    write_secret_file(&token_path, &token)?; // file fallback; CHUNK 2c: macOS Keychain
    println!("token   : {} (0600)", token_path.display());

    let client = ClientRecord {
        client_id: "swift-frontend-bootstrap".to_owned(),
        class: ClientClass::SwiftFrontend,
        scopes: ClientClass::SwiftFrontend
            .default_scopes()
            .into_iter()
            .collect(),
        issued_at_ms: now,
        expires_at_ms: now.saturating_add(THIRTY_DAYS_MS),
        revoked_at_ms: None,
        display_name: "Fae (this Mac)".to_owned(),
    };

    let mut registry = ClientRegistry::new();
    registry.insert(client, token_hash);
    let registry = Arc::new(registry);
    let tickets = Arc::new(Mutex::new(TicketStore::new()));

    let engine = build_engine().await;
    let info = engine.describe();
    println!("engine  : {} ({})", info.backend, info.model_id);
    let tts = build_tts_engine();
    let tts_info = tts.describe();
    println!("tts     : {} ({})", tts_info.backend, tts_info.model_id);
    let audio = Arc::new(AudioManager::new());
    println!("audit   : {} (jsonl)", audit_path.display());
    println!("client  : authenticate with {{\"command\":\"session.authenticate\",\"payload\":{{\"client_id\":\"swift-frontend-bootstrap\",\"token\":<file>}}}}");

    // Optional TCP-loopback HTTP/WS diagnostic surface (opt-in, never default).
    if let Some(port) = diagnostic_port() {
        let state = Arc::new(diagnostic::DiagnosticState {
            registry: Arc::clone(&registry),
            engine: Arc::clone(&engine),
            tts: Arc::clone(&tts),
            audio: Arc::clone(&audio),
            tickets: Arc::clone(&tickets),
            audit_path: audit_path.clone(),
            port,
        });
        println!("diag    : TCP loopback diagnostic enabled on port {port} (opt-in)");
        tokio::spawn(async move {
            if let Err(error) = diagnostic::serve_tcp(state).await {
                eprintln!("fae-daemon: diagnostic listener stopped: {error}");
            }
        });
    }
    println!();

    // Serves until the process is killed. Fails closed on bind/permission error.
    transport::serve_unix(socket_path, registry, engine, tts, audio, audit_path).await?;
    Ok(())
}

/// Build the TTS backend (S19). On macOS: Kokoro via voice-tts/mlx-rs, with
/// weights loading lazily on the first `tts.synthesize`. `FAE_TTS_MODEL_ID`
/// overrides the repo; `FAE_TTS=mock` forces the mock. Elsewhere: mock until
/// the candle port lands.
fn build_tts_engine() -> Arc<dyn TtsAdapter> {
    if std::env::var("FAE_TTS").is_ok_and(|value| value == "mock") {
        return Arc::new(MockTtsAdapter::new("mock-tts"));
    }
    #[cfg(target_os = "macos")]
    {
        let model_repo = std::env::var("FAE_TTS_MODEL_ID")
            .ok()
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| "prince-canuma/Kokoro-82M".to_owned());
        let voices_dir = local_voices_directory();
        if let Some(dir) = &voices_dir {
            println!("voices  : {} (custom voices, optional)", dir.display());
        }
        match fae_engine::VoiceTtsAdapter::spawn(model_repo, voices_dir) {
            Ok(adapter) => return Arc::new(adapter),
            Err(error) => {
                eprintln!("fae-daemon: tts worker spawn failed ({error}); using mock tts");
            }
        }
    }
    Arc::new(MockTtsAdapter::new("mock-tts"))
}

/// Directory holding custom voice embeddings (`{voice}.safetensors`) checked
/// before the HF repo — `<fae data dir>/voices`, sibling of the run dir. The
/// Swift frontend installs Fae's own voice here. `None` when HOME is unset
/// (the adapter then serves HF repo voices only).
#[cfg(target_os = "macos")]
fn local_voices_directory() -> Option<PathBuf> {
    run_directory()
        .ok()
        .and_then(|run| run.parent().map(|base| base.join("voices")))
}

/// Build the inference backend. With `FAE_MODEL_ID` set, load that mistral.rs
/// text model (the real engine); otherwise (and on load failure) use the mock
/// echo engine so the daemon still serves without ~GB of weights present.
async fn build_engine() -> Arc<dyn ProviderAdapter> {
    match std::env::var("FAE_MODEL_ID")
        .ok()
        .filter(|id| !id.is_empty())
    {
        Some(model_id) => {
            let pinned_revision = match verify_models_lock(&model_id) {
                Ok(revision) => revision,
                Err(error) => exit_models_lock_fatal(&model_id, &error.to_string()),
            };
            println!("engine  : loading mistral.rs model {model_id} (this can take a while)…");
            let loaded = match pinned_revision.as_deref() {
                Some(revision) => {
                    LocalMistralrsAdapter::load_with_revision(&model_id, revision).await
                }
                None => LocalMistralrsAdapter::load(&model_id).await,
            };
            match loaded {
                Ok(adapter) => Arc::new(adapter),
                Err(error) => {
                    eprintln!("fae-daemon: model load failed ({error}); using mock engine");
                    Arc::new(MockAdapter::new("mock-echo"))
                }
            }
        }
        None => Arc::new(MockAdapter::new("mock-echo")),
    }
}

fn verify_models_lock(model_id: &str) -> DaemonResult<Option<String>> {
    if std::env::var("FAE_MODELS_LOCK").is_ok_and(|value| value == "off") {
        eprintln!("fae-daemon: WARNING: FAE_MODELS_LOCK=off — skipping models.lock verification");
        return Ok(None);
    }

    let lock_path = models_lock_path()?;
    let lock = ModelsLock::load(&lock_path)?;
    let (models_dir, revision) = resolve_models_dir(model_id, &lock)?;
    let mut verified = 0usize;
    for artifact in lock
        .artifacts
        .iter()
        .filter(|artifact| artifact.source_repo == model_id)
    {
        artifact.verify(&models_dir)?;
        verified += 1;
    }
    if verified == 0 {
        return Err(std::io::Error::other(format!(
            "models.lock contains no artifacts for {model_id}"
        ))
        .into());
    }
    println!(
        "models.lock: verified {verified} artifact(s) for {model_id} revision {revision} at {}",
        models_dir.display()
    );
    Ok(Some(revision))
}

fn models_lock_path() -> DaemonResult<PathBuf> {
    if let Some(path) = std::env::var_os("FAE_MODELS_LOCK_PATH") {
        return Ok(PathBuf::from(path));
    }
    Ok(data_directory()?.join("models.lock"))
}

fn resolve_models_dir(model_id: &str, lock: &ModelsLock) -> DaemonResult<(PathBuf, String)> {
    let revision = lock
        .artifacts
        .iter()
        .find(|artifact| artifact.source_repo == model_id && !artifact.source_revision.is_empty())
        .map(|artifact| artifact.source_revision.clone())
        .ok_or_else(|| {
            std::io::Error::other(format!(
                "models.lock contains no source_revision for {model_id}"
            ))
        })?;
    if let Some(path) = std::env::var_os("FAE_MODELS_DIR") {
        return Ok((PathBuf::from(path), revision));
    }
    let repo_dir = model_id.replace('/', "--");
    let models_dir = huggingface_home()?
        .join("hub")
        .join(format!("models--{repo_dir}"))
        .join("snapshots")
        .join(&revision);
    if !models_dir.is_dir() {
        return Err(std::io::Error::other(format!(
            "Hugging Face snapshot directory not found: {}",
            models_dir.display()
        ))
        .into());
    }
    Ok((models_dir, revision))
}

fn huggingface_home() -> DaemonResult<PathBuf> {
    if let Some(path) = std::env::var_os("HF_HOME") {
        return Ok(PathBuf::from(path));
    }
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(PathBuf::from(home).join(".cache/huggingface"))
}

fn exit_models_lock_fatal(model_id: &str, detail: &str) -> ! {
    let event = serde_json::json!({
        "event": "fatal",
        "component": "models_lock",
        "model_id": model_id,
        "error": detail,
    });
    eprintln!("fae-daemon: fatal: {event}");
    std::process::exit(78);
}

/// Exit when the launching parent dies. The daemon must never outlive the
/// app that spawned it (recurring orphan bug: fae-daemon survived app quit
/// holding the model in RAM). When the parent exits, the daemon is reparented
/// (getppid changes), which a 2 s poll catches — this also covers parent
/// crashes and SIGKILL, where no clean shutdown command ever arrives.
/// `FAE_NO_PARENT_WATCH=1` disables it for standalone/diagnostic runs.
fn spawn_parent_watch() {
    if std::env::var_os("FAE_NO_PARENT_WATCH").is_some() {
        return;
    }
    let parent = std::os::unix::process::parent_id();
    if parent <= 1 {
        return; // already daemonized — nothing meaningful to watch
    }
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(2));
        if std::os::unix::process::parent_id() != parent {
            // stderr is a pipe into the parent — it is gone too, so this
            // write may fail with EPIPE. eprintln! would PANIC on that and
            // kill only this thread, leaving the orphan alive; write
            // best-effort instead and exit unconditionally.
            use std::io::Write;
            let _ = writeln!(
                std::io::stderr(),
                "fae-daemon: parent process {parent} exited — shutting down"
            );
            std::process::exit(0);
        }
    });
}

/// Diagnostic TCP port from `FAE_DIAGNOSTIC_TCP_PORT`, if set to a non-zero
/// value. Absent/invalid/zero → the diagnostic surface stays off.
fn diagnostic_port() -> Option<u16> {
    std::env::var("FAE_DIAGNOSTIC_TCP_PORT")
        .ok()
        .and_then(|raw| raw.parse::<u16>().ok())
        .filter(|port| *port != 0)
}

/// Owner-private run directory: `~/Library/Application Support/fae/run` on macOS,
/// `$XDG_DATA_HOME/fae/run` (or `~/.local/share/fae/run`) on Linux.
fn data_directory() -> DaemonResult<PathBuf> {
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    let home = PathBuf::from(home);
    #[cfg(target_os = "macos")]
    let base = home.join("Library/Application Support/fae");
    #[cfg(not(target_os = "macos"))]
    let base = match std::env::var_os("XDG_DATA_HOME") {
        Some(xdg) => PathBuf::from(xdg).join("fae"),
        None => home.join(".local/share/fae"),
    };
    Ok(base)
}

fn run_directory() -> DaemonResult<PathBuf> {
    Ok(data_directory()?.join("run"))
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

/// Current wall clock in epoch-ms. Infallible: a pre-1970 clock yields 0 and an
/// impossibly-far-future clock saturates — never panics.
pub(crate) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|dur| u64::try_from(dur.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// Monotonic, non-secret audit correlation id. An event id only needs to be
/// unique and ordered — never use a CSPRNG bearer token here (that conflates
/// secret material with log fields and makes every command pay a `getrandom`
/// syscall that could fail the command).
pub(crate) fn next_event_id(now_ms: u64) -> String {
    static EVENT_SEQ: AtomicU64 = AtomicU64::new(0);
    let seq = EVENT_SEQ.fetch_add(1, Ordering::Relaxed);
    format!("evt-{now_ms}-{seq}")
}
