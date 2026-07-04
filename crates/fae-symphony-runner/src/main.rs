//! `fae-symphony-runner` binary entry point.
//!
//! Wires a [`FaeRunner`] into the stock `x0x-symphony-orchestrator` with the
//! production `X0xCrdtTracker` (x0xd-backed) and `X0xdClient` signer, then runs
//! the dispatch loop. It **fails closed**: if x0xd's `/agent` endpoint is
//! unreachable at startup, the process refuses to run rather than risk
//! publishing unsigned handoffs.
//!
//! Configuration comes from environment variables, or a TOML file pointed to by
//! `FAE_SYMPHONY_CONFIG`. See `README.md` for the full variable list.

use std::error::Error;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde::Deserialize;
use x0x_symphony_core::{AgentId, IssueState};
use x0x_symphony_orchestrator::{Config, Orchestrator, SystemClock};
use x0x_symphony_signing::{SigningClient, TrustedKeyResolver, X0xdClient as SigningX0xdClient};
use x0x_symphony_tracker_x0x_crdt::X0xCrdtTracker;
use x0x_symphony_workspace::{Config as WorkspaceConfig, Manager};

use fae_symphony_runner::FaeRunner;

/// Resolved runner configuration. Deserialisable from TOML; also buildable
/// purely from environment variables.
#[derive(Debug, Clone, Deserialize)]
struct RunnerConfig {
    /// Base URL of the local x0xd REST API (signing + task list).
    #[serde(default = "default_x0xd_url")]
    x0xd_url: String,
    /// The x0xd `TaskList` id this runner claims from.
    task_list: String,
    /// Optional x0x group scoping the task list (MLS-private lists).
    #[serde(default)]
    group: Option<String>,
    /// Root directory under which per-issue workspaces are created.
    workspace_root: PathBuf,
    /// Directory where dispatch proof artefacts are written.
    #[serde(default = "default_proofs_dir")]
    proofs_dir: PathBuf,
    /// Path to the fae-daemon control socket.
    daemon_socket: PathBuf,
    /// Path to the fae-daemon bootstrap token file (0600, in its run dir).
    daemon_token_path: PathBuf,
    /// Control-plane client id to authenticate as (must hold `agent:delegate`).
    #[serde(default = "default_client_id")]
    daemon_client_id: String,
    /// Poll-loop interval in seconds.
    #[serde(default = "default_poll_secs")]
    polling_interval_secs: u64,
}

fn default_x0xd_url() -> String {
    "http://127.0.0.1:12700".to_owned()
}

fn default_proofs_dir() -> PathBuf {
    PathBuf::from("proofs")
}

fn default_client_id() -> String {
    fae_control_plane::BOOTSTRAP_CLIENT_ID.to_owned()
}

fn default_poll_secs() -> u64 {
    5
}

impl RunnerConfig {
    /// Load from `FAE_SYMPHONY_CONFIG` (TOML) if set, else from environment.
    fn load() -> Result<Self, Box<dyn Error>> {
        if let Ok(path) = std::env::var("FAE_SYMPHONY_CONFIG") {
            let text = std::fs::read_to_string(&path)?;
            let cfg: RunnerConfig = toml::from_str(&text)?;
            return Ok(cfg);
        }
        Self::from_env()
    }

    fn from_env() -> Result<Self, Box<dyn Error>> {
        Ok(Self {
            x0xd_url: std::env::var("FAE_SYMPHONY_X0XD_URL").unwrap_or_else(|_| default_x0xd_url()),
            task_list: env_required("FAE_SYMPHONY_TASK_LIST")?,
            group: std::env::var("FAE_SYMPHONY_GROUP")
                .ok()
                .filter(|g| !g.is_empty()),
            workspace_root: PathBuf::from(env_required("FAE_SYMPHONY_WORKSPACE_ROOT")?),
            proofs_dir: std::env::var("FAE_SYMPHONY_PROOFS_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|_| default_proofs_dir()),
            daemon_socket: PathBuf::from(env_required("FAE_DAEMON_SOCKET")?),
            daemon_token_path: PathBuf::from(env_required("FAE_DAEMON_TOKEN_PATH")?),
            daemon_client_id: std::env::var("FAE_DAEMON_CLIENT_ID")
                .unwrap_or_else(|_| default_client_id()),
            polling_interval_secs: std::env::var("FAE_SYMPHONY_POLL_SECS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or_else(default_poll_secs),
        })
    }
}

fn env_required(key: &str) -> Result<String, Box<dyn Error>> {
    std::env::var(key).map_err(|_| {
        format!("missing required env var {key} (or provide FAE_SYMPHONY_CONFIG)").into()
    })
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let _ = tracing_subscriber::fmt::try_init();

    let cfg = RunnerConfig::load()?;
    tracing::info!(
        x0xd = %cfg.x0xd_url,
        task_list = %cfg.task_list,
        socket = %cfg.daemon_socket.display(),
        "fae-symphony-runner starting"
    );

    // ── Signing client (shared as both SigningClient and key resolver) ───────
    let signing = Arc::new(SigningX0xdClient::new(&cfg.x0xd_url)?);

    // ── FAIL CLOSED: refuse to start if x0xd /agent is unreachable ───────────
    // No signer means no signed handoffs; a runner that cannot sign must not
    // claim work. This call doubles as fetching our own agent identity.
    let agent_id = match signing.agent_identity().await {
        Ok(info) => AgentId::new(info.agent_id)?,
        Err(error) => {
            eprintln!(
                "fatal: x0xd /agent unreachable at {} ({error}). Refusing to start: \
                 a runner that cannot sign handoffs must not claim work.",
                cfg.x0xd_url
            );
            std::process::exit(1);
        }
    };
    tracing::info!(agent_id = %agent_id.as_str(), "x0xd signer verified");

    // ── Tracker: x0xd-backed, required signing enforced ──────────────────────
    let signing_client: Arc<dyn SigningClient> = signing.clone();
    let resolver: Arc<dyn TrustedKeyResolver> = signing.clone();
    let mut tracker_builder =
        X0xCrdtTracker::builder(&cfg.x0xd_url, &cfg.task_list, agent_id.clone())
            .required_signing(signing_client, resolver);
    if let Some(group) = &cfg.group {
        tracker_builder = tracker_builder.group(group.clone());
    }
    let tracker = Arc::new(tracker_builder.build()?);

    // ── Runner: drives the fae-daemon delegation socket ──────────────────────
    let token = std::fs::read_to_string(&cfg.daemon_token_path)
        .map_err(|error| {
            format!(
                "cannot read daemon token at {}: {error}",
                cfg.daemon_token_path.display()
            )
        })?
        .trim()
        .to_owned();
    let runner = Arc::new(FaeRunner::with_defaults(
        cfg.daemon_socket.clone(),
        cfg.daemon_client_id.clone(),
        token,
    ));

    // ── Workspace + clock + config ───────────────────────────────────────────
    let workspace = Arc::new(Manager::new(WorkspaceConfig::new(
        cfg.workspace_root.clone(),
    ))?);
    let clock = Arc::new(SystemClock);
    let config = Config::builder(agent_id)
        .active_states(vec![IssueState::new("todo")?])
        .terminal_states(vec![
            IssueState::new("done")?,
            IssueState::new("cancelled")?,
        ])
        .proofs_dir(cfg.proofs_dir.clone())
        .polling_interval(Duration::from_secs(cfg.polling_interval_secs))
        .global_concurrency(1)
        .build();

    let orchestrator = Orchestrator::new(tracker, runner, workspace, clock, config);

    tracing::info!("entering dispatch loop (Ctrl-C to stop)");
    tokio::select! {
        result = orchestrator.run() => result?,
        signal = tokio::signal::ctrl_c() => {
            signal?;
            tracing::info!("shutdown signal received; stopping dispatch loop");
        }
    }

    Ok(())
}
