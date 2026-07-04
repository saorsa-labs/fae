//! Live group-of-Fae proof — `#[ignore]`, env-gated, SKIP-not-fail when the
//! prerequisites (a running x0xd + a built `fae-daemon`) are absent. This is the
//! Phase F gate: *a symphony task is claimed, worked by a GROUP of Fae, and
//! returned with signed proofs*.
//!
//! Unlike `runner_headless.rs` (which drives one [`FaeRunner`] against a MOCK
//! daemon socket) and `live_x0xd.rs` (which proves the tracker/signing legs with
//! NO runner), this test stands up the FULL group topology:
//!
//!   * TWO real `fae-daemon` processes, each spawned with `FAE_ENGINE=mock`
//!     (the dev-gated scripted engine: `write tracked.txt` → final answer) so a
//!     REAL daemon serves its control socket with NO model download. Each daemon
//!     gets its own isolated `HOME` → its own run dir / socket / token / store.
//!   * TWO [`FaeRunner`]s, one per daemon, exercising the REAL
//!     `start_session` → `run_turn` → `conversation.delegate` socket path (not a
//!     mock socket).
//!   * ONE shared x0xd TaskList (self-seeded, unique per run) with 2 tasks, two
//!     independent `X0xCrdtTracker`s (required-signing) claiming from it.
//!
//! What it asserts (the group-of-Fae contract):
//!   1. **No double-claim** — once runner A claims a task it leaves the todo
//!      pool, so runner B is never offered it; the two runners claim DISTINCT
//!      tasks.
//!   2. **Worked by a group of Fae** — each runner drives its OWN daemon's
//!      jailed delegation loop, mutating its OWN isolated git workspace
//!      (`tracked.txt` changes; `git diff --name-only` surfaces it).
//!   3. **Signed handoffs** — each runner publishes an ML-DSA-signed handoff via
//!      x0xd `/agent/sign` (required-signing tracker).
//!   4. **Tasks left the todo pool** — both seeded tasks are gone at the end.
//!   5. **Proof artifacts written** — a per-task JSON proof lands on disk.
//!
//! Scope / honest limitation: a single x0xd node exposes ONE ML-DSA identity, so
//! both runners share the node's signing identity here. The distinctness of the
//! two Fae is at the daemon/workspace level (two processes, two jails, two
//! workspaces). True two-IDENTITY claiming across two replicated x0x nodes is a
//! documented multi-node follow-up (see ADR-015).
//!
//! Run (both x0xd :12700 and a built daemon required):
//! ```text
//! cargo build -p fae-daemon
//! X0X_API_TOKEN=$(cat "$HOME/Library/Application Support/x0x/api-token") \
//! FAE_SYMPHONY_X0XD_URL=http://127.0.0.1:12700 \
//!   cargo test -p fae-symphony-runner --test live_group_of_fae -- --ignored --nocapture
//! ```

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fae_control_plane::BOOTSTRAP_CLIENT_ID;
use fae_symphony_runner::FaeRunner;
use x0x_symphony_core::{
    AgentId, Handoff, Issue, IssueState, PollContext, Prompt, Runner, SessionContext, Tracker,
    TurnStatus,
};
use x0x_symphony_signing::{SigningClient, TrustedKeyResolver, X0xdClient as SigningX0xdClient};
use x0x_symphony_tracker_x0x_crdt::{
    client::{AddTaskDraft, X0xdApi, X0xdClient},
    mapping::store_id_for_list,
    X0xCrdtTracker,
};

// ─────────────────────────── spawned real daemon ────────────────────────────

/// A real `fae-daemon` process spawned with the dev scripted engine, in its own
/// isolated `HOME`. Killed + reaped on drop.
struct SpawnedDaemon {
    child: Child,
    _home: tempfile::TempDir,
    socket_path: PathBuf,
    token: String,
}

/// The run dir the daemon derives from `HOME` (mirrors `main.rs::data_directory`
/// + `run_directory`, per-OS).
fn run_dir_for_home(home: &Path) -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        home.join("Library/Application Support/fae/run")
    }
    #[cfg(not(target_os = "macos"))]
    {
        home.join(".local/share/fae/run")
    }
}

impl SpawnedDaemon {
    /// Spawn `daemon_bin` on an isolated HOME with `FAE_ENGINE=mock`; wait for
    /// its control socket + bootstrap token to appear (≤ 20 s).
    async fn spawn(daemon_bin: &Path, label: &str) -> Result<SpawnedDaemon, String> {
        // HOME must be SHORT: the daemon's control socket lives at
        // `$HOME/Library/Application Support/fae/run/fae-daemon.sock` (~51 chars),
        // and a Unix socket path must fit `SUN_LEN` (104 on macOS). The default
        // `$TMPDIR` (`/var/folders/…`) is too long, so root the isolated HOME at
        // `/tmp`.
        let home = tempfile::Builder::new()
            .prefix("fg")
            .tempdir_in("/tmp")
            .map_err(|e| format!("tempdir for {label}: {e}"))?;
        let home_path = home.path().to_path_buf();
        let run_dir = run_dir_for_home(&home_path);
        let socket_path = run_dir.join("fae-daemon.sock");
        let token_path = run_dir.join("bootstrap.token");

        let child = Command::new(daemon_bin)
            .env("HOME", &home_path)
            .env_remove("XDG_DATA_HOME")
            // Dev scripted engine: no model, no llama-server, deterministic.
            .env("FAE_DEV", "1")
            .env("FAE_ENGINE", "mock")
            .env("FAE_MODELS_LOCK", "off")
            .env("FAE_AUDIO_FALLBACK", "0")
            // Keep the daemon minimal: no peer ingress, no diagnostic surface.
            .env_remove("FAE_X0X_INGRESS")
            .env_remove("FAE_DIAGNOSTIC_PORT")
            .env_remove("FAE_TOOLHOST_WORKSPACE_GRANT")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("spawn daemon {label} ({}): {e}", daemon_bin.display()))?;

        let mut daemon = SpawnedDaemon {
            child,
            _home: home,
            socket_path,
            token: String::new(),
        };

        // Poll for the socket (bound only once startup fully succeeds) + token.
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        loop {
            if let Some(status) = daemon
                .child
                .try_wait()
                .map_err(|e| format!("try_wait {label}: {e}"))?
            {
                return Err(format!("daemon {label} exited early with {status}"));
            }
            if daemon.socket_path.exists() && token_path.exists() {
                daemon.token = std::fs::read_to_string(&token_path)
                    .map_err(|e| format!("read token {label}: {e}"))?
                    .trim()
                    .to_owned();
                if !daemon.token.is_empty() {
                    return Ok(daemon);
                }
            }
            if std::time::Instant::now() >= deadline {
                return Err(format!(
                    "daemon {label} did not open its socket within 20s ({})",
                    daemon.socket_path.display()
                ));
            }
            tokio::time::sleep(Duration::from_millis(150)).await;
        }
    }

    fn runner(&self) -> FaeRunner {
        FaeRunner::with_defaults(self.socket_path.clone(), BOOTSTRAP_CLIENT_ID, &self.token)
    }
}

impl Drop for SpawnedDaemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

// ───────────────────────────── git workspace ────────────────────────────────

fn run_git(path: &Path, args: &[&str]) -> Result<(), String> {
    let status = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("git {args:?}: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("git {args:?} failed"))
    }
}

/// A per-issue git repo with a committed `tracked.txt` so a delegation that
/// OVERWRITES it surfaces in `git diff --name-only`.
fn init_workspace(root: &Path) -> Result<(), String> {
    std::fs::create_dir_all(root).map_err(|e| format!("create ws {}: {e}", root.display()))?;
    run_git(root, &["init", "-q"])?;
    run_git(root, &["config", "user.email", "runner@example.invalid"])?;
    run_git(root, &["config", "user.name", "Group Of Fae"])?;
    std::fs::write(root.join("tracked.txt"), b"base\n")
        .map_err(|e| format!("seed tracked.txt: {e}"))?;
    run_git(root, &["add", "tracked.txt"])?;
    run_git(root, &["commit", "-q", "-m", "initial"])
}

/// `git diff --name-only` in the workspace (the orchestrator's `files_changed`
/// mechanism).
fn files_changed(root: &Path) -> Result<Vec<String>, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["diff", "--name-only"])
        .output()
        .map_err(|e| format!("git diff: {e}"))?;
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_owned)
        .collect())
}

// ─────────────────────────────── the drive ──────────────────────────────────

/// Locate the compiled `fae-daemon` binary: `FAE_SYMPHONY_DAEMON_BIN` override,
/// else the sibling binary next to this test's target profile dir.
fn locate_daemon_bin() -> Option<PathBuf> {
    if let Some(explicit) = std::env::var_os("FAE_SYMPHONY_DAEMON_BIN") {
        let path = PathBuf::from(explicit);
        return path.exists().then_some(path);
    }
    // current_exe = target/<profile>/deps/live_group_of_fae-<hash>
    // daemon      = target/<profile>/fae-daemon
    let exe = std::env::current_exe().ok()?;
    let profile_dir = exe.parent()?.parent()?; // deps → profile
    let candidate = profile_dir.join("fae-daemon");
    candidate.exists().then_some(candidate)
}

/// Do one task end-to-end for a runner: workspace → real daemon delegation →
/// assert mutation → signed handoff → proof artifact.
#[allow(clippy::too_many_arguments)]
async fn work_task(
    label: &str,
    runner: &FaeRunner,
    tracker: &X0xCrdtTracker,
    agent: &AgentId,
    claim: &x0x_symphony_core::Claim,
    issue: &Issue,
    ws_root: &Path,
    proofs_dir: &Path,
) {
    // 1. Isolated git workspace for this issue.
    let ws = ws_root.join(label).join(issue.id.as_str());
    init_workspace(&ws).expect("init workspace");

    // 2. Drive the REAL daemon delegation via the FaeRunner Runner trait.
    let ctx = SessionContext::new(issue.clone(), ws.clone());
    let mut session = runner
        .start_session(ctx)
        .await
        .expect("start_session against the live daemon");
    let outcome = runner
        .run_turn(
            &mut session,
            Prompt::new(format!("complete task {}", issue.id.as_str())),
        )
        .await
        .expect("run_turn (conversation.delegate) against the live daemon");
    assert_eq!(
        outcome.status,
        TurnStatus::Succeeded,
        "{label}: the delegation must complete (mock write → final answer)"
    );

    // 3. The jailed delegation must have MUTATED this runner's workspace.
    let contents =
        std::fs::read_to_string(ws.join("tracked.txt")).expect("read mutated tracked.txt");
    assert_ne!(
        contents, "base\n",
        "{label}: tracked.txt must have been overwritten by the jailed delegation"
    );
    let changed = files_changed(&ws).expect("git diff");
    assert!(
        changed.iter().any(|f| f == "tracked.txt"),
        "{label}: git diff must surface the workspace mutation; files_changed = {changed:?}"
    );
    eprintln!(
        "live group-of-Fae [{label}]: delegated task {} → workspace mutated (files_changed = {changed:?})",
        issue.id.as_str()
    );

    // 4. Signed handoff: heartbeat → ML-DSA-signed handoff via x0xd.
    tracker.heartbeat(claim).await.expect("heartbeat the claim");
    let handoff = Handoff::new(format!(
        "group-of-Fae [{label}] completed {}",
        issue.id.as_str()
    ))
    .with_file("tracked.txt");
    tracker
        .handoff(claim, handoff)
        .await
        .expect("publish signed handoff to live x0xd");
    eprintln!(
        "live group-of-Fae [{label}]: published a SIGNED handoff for {}",
        issue.id.as_str()
    );

    // 5. Proof artifact.
    let proof = serde_json::json!({
        "runner": label,
        "agent_id": agent.as_str(),
        "task_id": issue.id.as_str(),
        "status": format!("{:?}", outcome.status),
        "files_changed": changed,
        "delegated_text": outcome.summary,
    });
    let proof_path = proofs_dir.join(format!("{label}-{}.json", issue.id.as_str()));
    std::fs::write(
        &proof_path,
        serde_json::to_vec_pretty(&proof).expect("serialize proof"),
    )
    .expect("write proof artifact");
    assert!(
        proof_path.exists(),
        "{label}: proof artifact must be written"
    );
}

#[tokio::test]
#[ignore = "requires a live x0xd (FAE_SYMPHONY_X0XD_URL + X0X_API_TOKEN) and a built fae-daemon"]
async fn live_group_of_fae_claims_works_and_signs() {
    // ── preconditions (SKIP, not fail) ──────────────────────────────────────
    let Ok(base_url) = std::env::var("FAE_SYMPHONY_X0XD_URL") else {
        eprintln!("SKIP: FAE_SYMPHONY_X0XD_URL not set — live x0xd required");
        return;
    };
    let Some(daemon_bin) = locate_daemon_bin() else {
        eprintln!(
            "SKIP: fae-daemon binary not found — run `cargo build -p fae-daemon` \
             or set FAE_SYMPHONY_DAEMON_BIN"
        );
        return;
    };
    eprintln!(
        "live group-of-Fae: daemon binary = {}",
        daemon_bin.display()
    );

    // Signer leg (fail-closed check): x0xd `/agent` reachable + returns our id.
    let signing = Arc::new(match SigningX0xdClient::new(&base_url) {
        Ok(client) => client,
        Err(e) => {
            eprintln!("SKIP: could not construct x0xd signing client: {e}");
            return;
        }
    });
    let agent = match signing.agent_identity().await {
        Ok(identity) => AgentId::new(identity.agent_id).expect("agent id"),
        Err(e) => {
            eprintln!("SKIP: x0xd /agent unreachable ({e}) — is x0xd running on {base_url}?");
            return;
        }
    };
    eprintln!(
        "live group-of-Fae: signer verified, agent_id = {}",
        agent.as_str()
    );

    // ── seed ONE shared task list with 2 tasks ──────────────────────────────
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock after epoch")
        .as_millis();
    let task_list = format!("fae-group-of-fae-{suffix}");
    let store_id = store_id_for_list(&task_list);
    let rest = X0xdClient::new(&base_url).expect("construct x0xd REST client");
    rest.create_task_list(&task_list, &task_list)
        .await
        .expect("create live task list");
    rest.create_kv_store(&store_id, &store_id)
        .await
        .expect("create live kv store");
    for n in 1..=2 {
        let id = rest
            .add_task(
                &task_list,
                AddTaskDraft::new(format!("group-of-Fae task {n}"))
                    .with_description("seeded by the Phase F live group-of-Fae proof"),
            )
            .await
            .expect("seed live task");
        eprintln!("live group-of-Fae: seeded task {id} ({n}/2) on list {task_list}");
    }

    // ── two independent required-signing trackers over the shared list ───────
    let ctx = PollContext::new(
        vec![IssueState::new("todo").expect("todo state")],
        vec![IssueState::new("done").expect("done state")],
    );
    let build_tracker = || {
        let signing_client: Arc<dyn SigningClient> = signing.clone();
        let resolver: Arc<dyn TrustedKeyResolver> = signing.clone();
        X0xCrdtTracker::builder(&base_url, &task_list, agent.clone())
            .required_signing(signing_client, resolver)
            .build()
            .expect("build tracker")
    };
    let tracker_a = build_tracker();
    let tracker_b = build_tracker();

    // Initial candidates (retry briefly for the seed to be visible).
    let mut candidates = Vec::new();
    for _ in 0..10 {
        candidates = tracker_a
            .fetch_candidates(&ctx)
            .await
            .expect("fetch_candidates against live x0xd");
        if candidates.len() >= 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    assert!(
        candidates.len() >= 2,
        "expected ≥2 seeded todo candidates, saw {}",
        candidates.len()
    );
    eprintln!(
        "live group-of-Fae: {} trust-gated candidate(s) offered",
        candidates.len()
    );

    // ── spawn TWO real daemons (mock engine) ────────────────────────────────
    let daemon_a = SpawnedDaemon::spawn(&daemon_bin, "fae-a")
        .await
        .expect("spawn daemon fae-a");
    let daemon_b = SpawnedDaemon::spawn(&daemon_bin, "fae-b")
        .await
        .expect("spawn daemon fae-b");
    eprintln!(
        "live group-of-Fae: daemon fae-a @ {} + daemon fae-b @ {} — both serving (mock engine)",
        daemon_a.socket_path.display(),
        daemon_b.socket_path.display()
    );
    let runner_a = daemon_a.runner();
    let runner_b = daemon_b.runner();

    // ── no-double-claim: A claims a task; B is NOT offered it ────────────────
    let task_x = candidates[0].clone();
    let claim_a = tracker_a
        .claim(&task_x.id, &agent)
        .await
        .expect("runner A claims task_x");
    eprintln!("live group-of-Fae [fae-a]: claimed {}", task_x.id.as_str());

    let candidates_b = tracker_b
        .fetch_candidates(&ctx)
        .await
        .expect("runner B fetch_candidates");
    assert!(
        candidates_b.iter().all(|i| i.id != task_x.id),
        "NO-DOUBLE-CLAIM VIOLATED: a claimed task was still offered to runner B ({})",
        task_x.id.as_str()
    );
    let task_y = candidates_b
        .into_iter()
        .next()
        .expect("runner B must still be offered a distinct task");
    assert_ne!(
        task_x.id, task_y.id,
        "the two runners must claim DISTINCT tasks"
    );
    let claim_b = tracker_b
        .claim(&task_y.id, &agent)
        .await
        .expect("runner B claims task_y");
    eprintln!(
        "live group-of-Fae [fae-b]: claimed {} (distinct from fae-a's {})",
        task_y.id.as_str(),
        task_x.id.as_str()
    );

    // ── work both tasks on the two daemons, publish signed handoffs ──────────
    let ws_root = tempfile::tempdir().expect("workspaces tempdir");
    let proofs = tempfile::tempdir().expect("proofs tempdir");
    work_task(
        "fae-a",
        &runner_a,
        &tracker_a,
        &agent,
        &claim_a,
        &task_x,
        ws_root.path(),
        proofs.path(),
    )
    .await;
    work_task(
        "fae-b",
        &runner_b,
        &tracker_b,
        &agent,
        &claim_b,
        &task_y,
        ws_root.path(),
        proofs.path(),
    )
    .await;

    // ── both tasks left the todo pool ───────────────────────────────────────
    let remaining = tracker_a
        .fetch_candidates(&ctx)
        .await
        .expect("re-fetch candidates");
    assert!(
        remaining
            .iter()
            .all(|i| i.id != task_x.id && i.id != task_y.id),
        "both handed-off tasks must have left the todo pool; remaining = {:?}",
        remaining
            .iter()
            .map(|i| i.id.as_str().to_owned())
            .collect::<Vec<_>>()
    );

    // ── proof artifacts on disk ─────────────────────────────────────────────
    let proof_a = proofs
        .path()
        .join(format!("fae-a-{}.json", task_x.id.as_str()));
    let proof_b = proofs
        .path()
        .join(format!("fae-b-{}.json", task_y.id.as_str()));
    assert!(
        proof_a.exists() && proof_b.exists(),
        "both proof artifacts written"
    );

    eprintln!(
        "live group-of-Fae: PHASE F GATE GREEN — 2 tasks claimed (no double-claim) by a group of \
         2 Fae daemons, workspaces mutated, SIGNED handoffs published, tasks left the pool, \
         proofs written."
    );
}
