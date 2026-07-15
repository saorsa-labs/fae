//! Owner-opt-in supervised `fae-symphony-runner` sidecar (Phase F follow-on).
//!
//! `FAE_SYMPHONY_ENABLED=1` makes the daemon spawn and supervise the
//! `fae-symphony-runner` binary as a child process, turning "this Fae joins a
//! group-of-Fae work queue" into a product lifecycle instead of a manually
//! launched binary. **OFF by default** — joining a swarm is a deliberate owner
//! choice. The runner stays a pure socket CLIENT of this daemon
//! (`conversation.delegate`); the daemon still links no x0x-symphony crate
//! (the quarantine invariant in `fae-symphony-runner/Cargo.toml` holds).
//!
//! Supervision semantics (mirrors the llama-server sidecar prior art):
//! - crash ⇒ restart with exponential backoff, bounded consecutive attempts; a
//!   child that stays up past [`RestartPolicy::healthy_reset`] earns a fresh
//!   restart budget;
//! - daemon shutdown ⇒ child killed (`kill_on_drop` + explicit kill on
//!   cancellation), and the child PID is registered in fae-engine's sidecar
//!   registry so the parent-watch / `exit_fatal` `process::exit` paths (which
//!   skip `Drop`) still reap it;
//! - the child env is the shared scrubbed allowlist (`child_env`) plus the
//!   runner's own `FAE_SYMPHONY_*` config — provider secrets never cross.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio_util::sync::CancellationToken;

use crate::child_env;

/// The runner binary's file name, looked up beside the daemon and on `PATH`.
const RUNNER_BIN_NAME: &str = "fae-symphony-runner";

/// Env-var prefix passed through from the daemon env to the runner (its whole
/// configuration surface — task list, workspace root, poll interval, …).
const PASSTHROUGH_PREFIX: &str = "FAE_SYMPHONY_";

/// Exact extra vars passed through when present (runner control-plane client
/// id override + logging).
const PASSTHROUGH_EXACT: &[&str] = &["FAE_DAEMON_CLIENT_ID", "RUST_LOG"];

// ── Restart policy (pure, unit-testable) ────────────────────────────────────

/// Restart/backoff policy for the supervised sidecar. Parameterised so tests
/// run in milliseconds; production uses [`RestartPolicy::default`].
#[derive(Debug, Clone)]
pub(crate) struct RestartPolicy {
    /// Consecutive restarts allowed after a crash before the supervisor gives up.
    pub max_restarts: u32,
    /// First backoff delay; doubles per consecutive restart.
    pub backoff_base: Duration,
    /// Backoff ceiling.
    pub backoff_max: Duration,
    /// A child that stayed up at least this long resets the restart budget.
    pub healthy_reset: Duration,
}

impl Default for RestartPolicy {
    fn default() -> Self {
        Self {
            max_restarts: 5,
            backoff_base: Duration::from_secs(1),
            backoff_max: Duration::from_secs(30),
            healthy_reset: Duration::from_secs(60),
        }
    }
}

/// What the supervisor does after a child exit.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum SupervisorStep {
    /// Spawn again after this delay.
    Restart(Duration),
    /// Restart budget exhausted — stop supervising.
    GiveUp,
}

/// Decide the next step after a child exit that ran for `ran_for`, updating the
/// consecutive-restart counter. Pure and deterministic so the
/// backoff/give-up/healthy-reset logic is unit-testable without spawning
/// processes or sleeping.
pub(crate) fn plan_after_exit(
    restarts: &mut u32,
    ran_for: Duration,
    policy: &RestartPolicy,
) -> SupervisorStep {
    if ran_for >= policy.healthy_reset {
        *restarts = 0;
    }
    *restarts = restarts.saturating_add(1);
    if *restarts > policy.max_restarts {
        return SupervisorStep::GiveUp;
    }
    // 2^(n-1) × base, capped. Exponent clamped so the shift cannot overflow.
    let exponent = restarts.saturating_sub(1).min(20);
    let millis = policy
        .backoff_base
        .as_millis()
        .saturating_mul(1u128 << exponent)
        .min(policy.backoff_max.as_millis());
    SupervisorStep::Restart(Duration::from_millis(
        u64::try_from(millis).unwrap_or(u64::MAX),
    ))
}

// ── Configuration ────────────────────────────────────────────────────────────

/// Resolved sidecar configuration: which binary to run and its complete
/// (scrubbed + explicit) child environment.
#[derive(Debug, Clone)]
pub(crate) struct SymphonyConfig {
    /// The `fae-symphony-runner` binary to spawn.
    pub runner_bin: PathBuf,
    /// The child's COMPLETE env (used with `env_clear`).
    pub env: HashMap<String, String>,
}

impl SymphonyConfig {
    /// Read the opt-in from the daemon's environment. `None` ⇒ lane off (the
    /// default). `Some(Err)` ⇒ the owner opted in but the config is unusable —
    /// loud, never blocks daemon startup.
    pub(crate) fn from_env(socket_path: &Path, token_path: &Path) -> Option<Result<Self, String>> {
        let vars: HashMap<String, String> = std::env::vars().collect();
        let exe_dir = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(Path::to_path_buf));
        Self::from_vars(&vars, exe_dir.as_deref(), socket_path, token_path)
    }

    /// Pure worker behind [`Self::from_env`] — takes an env snapshot instead of
    /// reading the process env, so tests never mutate env vars (env mutation
    /// races parallel tests).
    fn from_vars(
        vars: &HashMap<String, String>,
        exe_dir: Option<&Path>,
        socket_path: &Path,
        token_path: &Path,
    ) -> Option<Result<Self, String>> {
        let enabled = vars.get("FAE_SYMPHONY_ENABLED").is_some_and(|v| {
            v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("yes")
        });
        if !enabled {
            return None;
        }
        // The runner itself fails closed on missing required config; pre-validate
        // here so a misconfigured opt-in is one loud line, not a restart loop.
        let non_empty = |key: &str| vars.get(key).is_some_and(|v| !v.trim().is_empty());
        let has_config_file = non_empty("FAE_SYMPHONY_CONFIG");
        let has_env_config =
            non_empty("FAE_SYMPHONY_TASK_LIST") && non_empty("FAE_SYMPHONY_WORKSPACE_ROOT");
        if !has_config_file && !has_env_config {
            return Some(Err(
                "FAE_SYMPHONY_ENABLED is set but neither FAE_SYMPHONY_CONFIG nor \
                 FAE_SYMPHONY_TASK_LIST + FAE_SYMPHONY_WORKSPACE_ROOT are — the runner \
                 has no task list / workspace to work on"
                    .to_owned(),
            ));
        }
        let Some(runner_bin) = resolve_runner_bin(
            vars.get("FAE_SYMPHONY_RUNNER_BIN").map(String::as_str),
            exe_dir,
            vars.get("PATH").map(String::as_str),
        ) else {
            return Some(Err(format!(
                "{RUNNER_BIN_NAME} binary not found (set FAE_SYMPHONY_RUNNER_BIN, or \
                 install it beside fae-daemon or on PATH)"
            )));
        };
        // Child env: the shared scrubbed allowlist (no provider secrets), plus
        // the runner's own FAE_SYMPHONY_* config surface. Defense in depth: a
        // passthrough name carrying a secret marker is still refused.
        let mut env = child_env::scrubbed_child_env();
        for (key, value) in vars {
            let passthrough =
                key.starts_with(PASSTHROUGH_PREFIX) || PASSTHROUGH_EXACT.contains(&key.as_str());
            if passthrough && !child_env::is_sensitive_name(key) {
                env.insert(key.clone(), value.clone());
            }
        }
        // Supervised means "delegate to THIS daemon": inject our own socket and
        // bootstrap-token path (a path to a 0600 file, not a secret value —
        // inserted explicitly because its name carries the TOKEN marker).
        env.insert(
            "FAE_DAEMON_SOCKET".to_owned(),
            socket_path.display().to_string(),
        );
        env.insert(
            "FAE_DAEMON_TOKEN_PATH".to_owned(),
            token_path.display().to_string(),
        );
        Some(Ok(Self { runner_bin, env }))
    }
}

/// Locate the runner binary: explicit override → beside the daemon binary →
/// first `PATH` hit. Only the explicit override skips the existence check (the
/// owner pointed at it deliberately; a bad path fails loudly at spawn).
fn resolve_runner_bin(
    explicit: Option<&str>,
    exe_dir: Option<&Path>,
    path_var: Option<&str>,
) -> Option<PathBuf> {
    if let Some(explicit) = explicit.filter(|v| !v.trim().is_empty()) {
        return Some(PathBuf::from(explicit));
    }
    if let Some(dir) = exe_dir {
        let sibling = dir.join(RUNNER_BIN_NAME);
        if sibling.is_file() {
            return Some(sibling);
        }
    }
    if let Some(path_var) = path_var {
        for dir in std::env::split_paths(path_var) {
            let candidate = dir.join(RUNNER_BIN_NAME);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

// ── Supervisor ───────────────────────────────────────────────────────────────

/// Handle to a supervised sidecar. Held by `main` for the daemon's lifetime;
/// dropping it (or calling [`SidecarHandle::shutdown`]) cancels the restart
/// loop and kills the child.
pub(crate) struct SidecarHandle {
    cancel: CancellationToken,
    task: tokio::task::JoinHandle<()>,
}

impl SidecarHandle {
    /// Kill the child and stop the supervisor, waiting for the loop to finish
    /// (graceful-shutdown seam, mirroring the peer-ingress cancel pattern).
    /// `main` currently runs the sidecar for the daemon's whole life — the
    /// parent-watch / `exit_fatal` `process::exit` paths reap the child via
    /// fae-engine's sidecar registry instead.
    #[allow(dead_code)]
    pub(crate) async fn shutdown(mut self) {
        self.cancel.cancel();
        let _ = (&mut self.task).await;
    }

    /// Wait for the supervisor loop to stop on its own (the give-up path).
    #[cfg(test)]
    async fn stopped(&mut self) {
        let _ = (&mut self.task).await;
    }
}

impl Drop for SidecarHandle {
    fn drop(&mut self) {
        // Belt: a handle dropped without `shutdown()` still stops the loop;
        // `kill_on_drop(true)` reaps the child when the supervisor task drops.
        self.cancel.cancel();
    }
}

/// Spawn `command_factory`'s child under supervision: restart with exponential
/// backoff per `policy`, kill the child on cancellation, register/unregister
/// its PID in fae-engine's sidecar registry (so `process::exit` teardown paths
/// reap it). Generic over the command so tests supervise a stub script instead
/// of the real runner binary.
pub(crate) fn spawn_supervised<F>(
    label: &'static str,
    command_factory: F,
    policy: RestartPolicy,
) -> SidecarHandle
where
    F: Fn() -> tokio::process::Command + Send + 'static,
{
    let cancel = CancellationToken::new();
    let loop_cancel = cancel.clone();
    let task = tokio::spawn(async move {
        let mut restarts: u32 = 0;
        loop {
            let mut command = command_factory();
            command.kill_on_drop(true);
            let mut child = match command.spawn() {
                Ok(child) => child,
                Err(error) => {
                    tracing::error!("{label}: spawn failed: {error}");
                    match plan_after_exit(&mut restarts, Duration::ZERO, &policy) {
                        SupervisorStep::GiveUp => {
                            tracing::error!(
                                "{label}: giving up after {} consecutive failures",
                                policy.max_restarts
                            );
                            return;
                        }
                        SupervisorStep::Restart(delay) => {
                            if sleep_or_cancelled(delay, &loop_cancel).await {
                                return;
                            }
                            continue;
                        }
                    }
                }
            };
            let pid = child.id();
            if let Some(pid) = pid {
                fae_engine::register_sidecar(pid);
            }
            tracing::info!("{label}: started (pid {pid:?})");
            let started = std::time::Instant::now();
            tokio::select! {
                status = child.wait() => {
                    if let Some(pid) = pid {
                        fae_engine::unregister_sidecar(pid);
                    }
                    match status {
                        Ok(status) => tracing::warn!("{label}: exited ({status})"),
                        Err(error) => tracing::warn!("{label}: wait failed: {error}"),
                    }
                    match plan_after_exit(&mut restarts, started.elapsed(), &policy) {
                        SupervisorStep::GiveUp => {
                            tracing::error!(
                                "{label}: giving up after {} consecutive crashes — fix the \
                                 runner config and restart the daemon",
                                policy.max_restarts
                            );
                            return;
                        }
                        SupervisorStep::Restart(delay) => {
                            tracing::info!(
                                "{label}: restarting in {delay:?} (attempt {restarts}/{})",
                                policy.max_restarts
                            );
                            if sleep_or_cancelled(delay, &loop_cancel).await {
                                return;
                            }
                        }
                    }
                }
                () = loop_cancel.cancelled() => {
                    tracing::info!("{label}: shutdown — killing child");
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                    if let Some(pid) = pid {
                        fae_engine::unregister_sidecar(pid);
                    }
                    return;
                }
            }
        }
    });
    SidecarHandle { cancel, task }
}

/// Sleep for `delay` unless cancelled first; `true` ⇒ cancelled.
async fn sleep_or_cancelled(delay: Duration, cancel: &CancellationToken) -> bool {
    tokio::select! {
        () = tokio::time::sleep(delay) => false,
        () = cancel.cancelled() => true,
    }
}

// ── Wiring ───────────────────────────────────────────────────────────────────

/// Resolve the opt-in and spawn the supervised runner. `None` ⇒ lane off (the
/// default) or misconfigured (loud); the daemon proceeds normally either way.
pub(crate) fn setup(socket_path: &Path, token_path: &Path) -> Option<SidecarHandle> {
    match SymphonyConfig::from_env(socket_path, token_path)? {
        Err(error) => {
            eprintln!("fae-daemon: symphony sidecar disabled: {error}");
            None
        }
        Ok(config) => {
            println!(
                "symphony: runner sidecar ENABLED ({}) — supervised, owner-opt-in",
                config.runner_bin.display()
            );
            let factory = move || {
                let mut command = tokio::process::Command::new(&config.runner_bin);
                command.env_clear();
                command.envs(&config.env);
                // Same hardening as the llama-server sidecar: own process group;
                // stdout/stderr inherited so runner logs land in the daemon log.
                #[cfg(unix)]
                command.process_group(0);
                command.stdout(std::process::Stdio::inherit());
                command.stderr(std::process::Stdio::inherit());
                command
            };
            Some(spawn_supervised(
                "symphony-runner",
                factory,
                RestartPolicy::default(),
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fast_policy(max_restarts: u32) -> RestartPolicy {
        RestartPolicy {
            max_restarts,
            backoff_base: Duration::from_millis(1),
            backoff_max: Duration::from_millis(4),
            // Effectively never: crash-loop tests must not reset the budget.
            healthy_reset: Duration::from_secs(3600),
        }
    }

    // ── plan_after_exit (pure) ───────────────────────────────────────────────

    #[test]
    fn backoff_doubles_then_caps() {
        let policy = RestartPolicy {
            max_restarts: 10,
            backoff_base: Duration::from_millis(100),
            backoff_max: Duration::from_millis(350),
            healthy_reset: Duration::from_secs(3600),
        };
        let mut restarts = 0;
        let crash = Duration::from_millis(1);
        assert_eq!(
            plan_after_exit(&mut restarts, crash, &policy),
            SupervisorStep::Restart(Duration::from_millis(100))
        );
        assert_eq!(
            plan_after_exit(&mut restarts, crash, &policy),
            SupervisorStep::Restart(Duration::from_millis(200))
        );
        // 400ms is over the 350ms ceiling → capped.
        assert_eq!(
            plan_after_exit(&mut restarts, crash, &policy),
            SupervisorStep::Restart(Duration::from_millis(350))
        );
    }

    #[test]
    fn gives_up_after_budget_exhausted() {
        // WHY: a broken runner config must not restart-loop forever — bounded
        // attempts turn a crash loop into one loud give-up line.
        let policy = fast_policy(2);
        let mut restarts = 0;
        let crash = Duration::from_millis(1);
        assert!(matches!(
            plan_after_exit(&mut restarts, crash, &policy),
            SupervisorStep::Restart(_)
        ));
        assert!(matches!(
            plan_after_exit(&mut restarts, crash, &policy),
            SupervisorStep::Restart(_)
        ));
        assert_eq!(
            plan_after_exit(&mut restarts, crash, &policy),
            SupervisorStep::GiveUp
        );
    }

    #[test]
    fn healthy_run_resets_budget() {
        // WHY: a runner that worked for an hour and then crashed is not a crash
        // loop — it deserves a fresh restart budget (and the base backoff).
        let policy = RestartPolicy {
            max_restarts: 2,
            backoff_base: Duration::from_millis(100),
            backoff_max: Duration::from_millis(400),
            healthy_reset: Duration::from_secs(60),
        };
        let mut restarts = 2; // budget nearly exhausted
        assert_eq!(
            plan_after_exit(&mut restarts, Duration::from_secs(61), &policy),
            SupervisorStep::Restart(Duration::from_millis(100))
        );
        assert_eq!(restarts, 1);
    }

    // ── resolve_runner_bin ───────────────────────────────────────────────────

    #[test]
    fn explicit_override_wins_without_existence_check() {
        let resolved = resolve_runner_bin(Some("/nonexistent/custom-runner"), None, None);
        assert_eq!(resolved, Some(PathBuf::from("/nonexistent/custom-runner")));
    }

    #[test]
    fn sibling_beats_path_and_missing_is_none() {
        let exe_dir = tempfile::tempdir().expect("tempdir");
        let path_dir = tempfile::tempdir().expect("tempdir");
        // Nothing anywhere → None.
        assert_eq!(
            resolve_runner_bin(
                None,
                Some(exe_dir.path()),
                Some(&path_dir.path().display().to_string())
            ),
            None
        );
        // On PATH only → PATH hit.
        let on_path = path_dir.path().join(RUNNER_BIN_NAME);
        std::fs::write(&on_path, b"#!/bin/sh\n").expect("write stub");
        assert_eq!(
            resolve_runner_bin(
                None,
                Some(exe_dir.path()),
                Some(&path_dir.path().display().to_string())
            ),
            Some(on_path.clone())
        );
        // Beside the daemon too → sibling wins.
        let sibling = exe_dir.path().join(RUNNER_BIN_NAME);
        std::fs::write(&sibling, b"#!/bin/sh\n").expect("write stub");
        assert_eq!(
            resolve_runner_bin(
                None,
                Some(exe_dir.path()),
                Some(&path_dir.path().display().to_string())
            ),
            Some(sibling)
        );
    }

    // ── SymphonyConfig::from_vars (pure — no process-env mutation) ──────────

    fn base_vars() -> HashMap<String, String> {
        HashMap::from([
            ("FAE_SYMPHONY_ENABLED".to_owned(), "1".to_owned()),
            ("FAE_SYMPHONY_TASK_LIST".to_owned(), "list-1".to_owned()),
            (
                "FAE_SYMPHONY_WORKSPACE_ROOT".to_owned(),
                "/tmp/ws".to_owned(),
            ),
            (
                "FAE_SYMPHONY_RUNNER_BIN".to_owned(),
                "/opt/fae/fae-symphony-runner".to_owned(),
            ),
        ])
    }

    #[test]
    fn off_by_default() {
        // WHY: joining a swarm is owner-opt-in — an unset env must mean OFF.
        let socket = Path::new("/run/fae/fae-daemon.sock");
        let token = Path::new("/run/fae/bootstrap.token");
        assert!(SymphonyConfig::from_vars(&HashMap::new(), None, socket, token).is_none());
        let disabled = HashMap::from([("FAE_SYMPHONY_ENABLED".to_owned(), "0".to_owned())]);
        assert!(SymphonyConfig::from_vars(&disabled, None, socket, token).is_none());
    }

    #[test]
    fn enabled_without_task_config_is_loud_error() {
        let socket = Path::new("/run/fae/fae-daemon.sock");
        let token = Path::new("/run/fae/bootstrap.token");
        let vars = HashMap::from([("FAE_SYMPHONY_ENABLED".to_owned(), "1".to_owned())]);
        let result = SymphonyConfig::from_vars(&vars, None, socket, token)
            .expect("enabled ⇒ Some")
            .expect_err("missing config must be an error, not a silent no-op");
        assert!(result.contains("FAE_SYMPHONY_TASK_LIST"));
    }

    #[test]
    fn child_env_gets_daemon_wiring_and_passthrough_but_no_secrets() {
        // WHY: the supervised runner must talk to THIS daemon (socket + token
        // path injected), receive its own FAE_SYMPHONY_* config, and NEVER
        // inherit provider secrets or secret-marked passthrough names.
        let socket = Path::new("/run/fae/fae-daemon.sock");
        let token = Path::new("/run/fae/bootstrap.token");
        let mut vars = base_vars();
        vars.insert("FAE_SYMPHONY_POLL_SECS".to_owned(), "9".to_owned());
        let planted_secret = format!("FAE_SYMPHONY_X0XD_{}", "TOKEN");
        vars.insert(planted_secret.clone(), "must-not-cross".to_owned());
        let config = SymphonyConfig::from_vars(&vars, None, socket, token)
            .expect("enabled ⇒ Some")
            .expect("valid config");
        assert_eq!(
            config.runner_bin,
            PathBuf::from("/opt/fae/fae-symphony-runner")
        );
        assert_eq!(
            config.env.get("FAE_DAEMON_SOCKET").map(String::as_str),
            Some("/run/fae/fae-daemon.sock")
        );
        assert_eq!(
            config.env.get("FAE_DAEMON_TOKEN_PATH").map(String::as_str),
            Some("/run/fae/bootstrap.token")
        );
        assert_eq!(
            config.env.get("FAE_SYMPHONY_POLL_SECS").map(String::as_str),
            Some("9")
        );
        assert!(
            !config.env.contains_key(&planted_secret),
            "secret-marked passthrough name leaked into the child env"
        );
    }

    // ── Live supervision (stub scripts, millisecond backoffs) ───────────────

    #[tokio::test]
    async fn crash_loop_restarts_bounded_then_gives_up() {
        // WHY: restart-with-backoff is the whole point of supervision — and the
        // bound is what keeps a broken config from looping forever.
        let dir = tempfile::tempdir().expect("tempdir");
        let marker = dir.path().join("spawns");
        let script = format!("echo x >> '{}'; exit 1", marker.display());
        let mut handle = spawn_supervised(
            "test-crashloop",
            move || {
                let mut command = tokio::process::Command::new("/bin/sh");
                command.arg("-c").arg(script.clone());
                command
            },
            fast_policy(3),
        );
        tokio::time::timeout(Duration::from_secs(10), handle.stopped())
            .await
            .expect("supervisor must give up, not loop forever");
        let spawns = std::fs::read_to_string(&marker).expect("marker file");
        assert_eq!(
            spawns.lines().count(),
            4,
            "initial spawn + max_restarts(3) restarts"
        );
    }

    #[tokio::test]
    async fn shutdown_kills_running_child() {
        // WHY: the sidecar must never outlive the daemon on a clean shutdown.
        let dir = tempfile::tempdir().expect("tempdir");
        let pidfile = dir.path().join("pid");
        let script = format!("echo $$ > '{}'; exec sleep 30", pidfile.display());
        let handle = spawn_supervised(
            "test-shutdown",
            move || {
                let mut command = tokio::process::Command::new("/bin/sh");
                command.arg("-c").arg(script.clone());
                command
            },
            fast_policy(0),
        );
        // Bounded poll for the child to report its PID (5ms steps).
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let pid = loop {
            if let Ok(text) = std::fs::read_to_string(&pidfile) {
                let trimmed = text.trim().to_owned();
                if !trimmed.is_empty() {
                    break trimmed;
                }
            }
            assert!(std::time::Instant::now() < deadline, "child never started");
            tokio::time::sleep(Duration::from_millis(5)).await;
        };
        handle.shutdown().await;
        // shutdown() reaped the child (wait() returned), so a kill -0 probe on
        // the PID must now fail — no zombie, no survivor.
        let alive = std::process::Command::new("kill")
            .args(["-0", &pid])
            .status()
            .expect("kill probe")
            .success();
        assert!(!alive, "child {pid} survived shutdown");
    }
}
