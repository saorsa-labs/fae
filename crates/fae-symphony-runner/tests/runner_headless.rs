//! Headless tests for `fae-symphony-runner` — no real fae-daemon, no x0xd.
//!
//! * `runner_drives_daemon_delegation_and_mutates_workspace` exercises the
//!   [`FaeRunner`] leg directly against a MOCK daemon Unix socket that speaks
//!   the real NDJSON `session.authenticate` + `conversation.delegate` shapes:
//!   the turn authenticates, delegates, and the mock mutates the workspace.
//! * `orchestrator_runs_fae_runner_and_assembles_handoff_with_files_changed`
//!   drives the SAME runner through the stock `x0x-symphony-orchestrator` with
//!   an in-memory tracker + a git-backed workspace. It proves the full chain:
//!   task claimed → runner delegates → workspace mutated → `files_changed`
//!   surfaces from `git diff` → a handoff (with proof dir) is published.
//!
//! The in-memory tracker means NO x0xd is required; the signed-handoff leg
//! against a live x0xd is covered by the `#[ignore]` `live_x0xd.rs` suite.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use x0x_symphony_core::{
    AgentId, Claim, Handoff, Hook, HookEnv, HookOutcome, HookStatus, Issue, IssueId, IssueState,
    PollContext, Prompt, ReleaseReason, Result as CoreResult, Runner, SessionContext, ShardRole,
    SymphonyError, Tracker, TurnStatus, Workspace, WorkspaceHandle,
};
use x0x_symphony_orchestrator::{Config, Orchestrator, SystemClock};

use fae_symphony_runner::FaeRunner;

// ─────────────────────────── mock daemon socket ─────────────────────────────

/// Bind a mock daemon control socket that answers `session.authenticate` and
/// `conversation.delegate`. Every delegation mutates `tracked.txt` in the
/// requested `workspace_root` (so `git diff` in a git workspace surfaces it).
/// Returns once the socket is bound; the accept loop runs detached.
async fn spawn_mock_daemon(socket_path: PathBuf) {
    let listener = UnixListener::bind(&socket_path).expect("bind mock daemon socket");
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(handle_conn(stream));
        }
    });
}

async fn handle_conn(stream: UnixStream) {
    let (read_half, mut write_half) = stream.into_split();
    let mut lines = BufReader::new(read_half).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let id = value
            .get("request_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_owned();
        let command = value.get("command").and_then(|v| v.as_str()).unwrap_or("");
        let response = match command {
            "session.authenticate" => {
                let client_id = value
                    .pointer("/payload/client_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                json!({
                    "v": 2, "request_id": id, "ok": true,
                    "result": { "authenticated": true, "client_id": client_id }
                })
            }
            "conversation.delegate" => {
                if let Some(ws) = value
                    .pointer("/payload/workspace_root")
                    .and_then(|v| v.as_str())
                {
                    let _ = std::fs::write(Path::new(ws).join("tracked.txt"), b"changed\n");
                }
                json!({
                    "v": 2, "request_id": id, "ok": true,
                    "result": {
                        "text": "delegated work complete",
                        "status": "completed",
                        "receipt_id": "del-test-0001",
                        "iterations": 1,
                        "tokens": 12
                    }
                })
            }
            _ => json!({
                "v": 2, "request_id": id, "ok": false,
                "error": { "code": "unknown", "message": "unknown command" }
            }),
        };
        let mut out = response.to_string();
        out.push('\n');
        if write_half.write_all(out.as_bytes()).await.is_err() {
            break;
        }
        let _ = write_half.flush().await;
    }
}

// ───────────────────────────── shared helpers ───────────────────────────────

fn make_issue(id: &str) -> Issue {
    Issue::new(
        IssueId::new(id).expect("issue id"),
        id,
        "headless test issue",
        IssueState::new("todo").expect("state"),
        "2026-07-04T00:00:00Z",
    )
    .expect("issue")
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339()
}

// ─────────────────────────── git-backed workspace ───────────────────────────

/// A workspace whose `create` initialises a real git repo with a committed
/// `tracked.txt`, so a subsequent delegation that MODIFIES that file shows up in
/// `git diff --name-only` (which is how the orchestrator derives `files_changed`).
struct GitWorkspace {
    root: PathBuf,
}

fn run_git(path: &Path, args: &[&str]) -> CoreResult<()> {
    let status = std::process::Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| SymphonyError::Runner(e.to_string()))?;
    if status.success() {
        Ok(())
    } else {
        Err(SymphonyError::Runner(format!("git {args:?} failed")))
    }
}

fn init_tracked_git_repo(path: &Path) -> CoreResult<()> {
    run_git(path, &["init"])?;
    run_git(path, &["config", "user.email", "runner@example.invalid"])?;
    run_git(path, &["config", "user.name", "Test Runner"])?;
    std::fs::write(path.join("tracked.txt"), b"base\n")
        .map_err(|e| SymphonyError::Runner(e.to_string()))?;
    run_git(path, &["add", "tracked.txt"])?;
    run_git(path, &["commit", "-m", "initial"])
}

#[async_trait]
impl Workspace for GitWorkspace {
    fn root(&self) -> &Path {
        &self.root
    }

    async fn create(&self, issue: &Issue) -> CoreResult<WorkspaceHandle> {
        let path = self.root.join(issue.id.as_str());
        std::fs::create_dir_all(&path).map_err(|e| SymphonyError::Runner(e.to_string()))?;
        init_tracked_git_repo(&path)?;
        Ok(WorkspaceHandle::new(issue.id.clone(), path, true))
    }

    async fn run_hook(&self, _hook: &Hook, _env: &HookEnv) -> CoreResult<HookOutcome> {
        Ok(HookOutcome::new(HookStatus::Succeeded))
    }

    async fn destroy(&self, _handle: WorkspaceHandle) -> CoreResult<()> {
        Ok(())
    }
}

// ───────────────────────────── in-memory tracker ────────────────────────────

/// A minimal in-memory [`Tracker`] — no x0xd. Records published handoffs so the
/// test can assert `files_changed` + proof dir.
#[derive(Default)]
struct InMemoryTracker {
    issues: Mutex<Vec<Issue>>,
    handoffs: Mutex<Vec<Handoff>>,
}

impl InMemoryTracker {
    fn with(issues: Vec<Issue>) -> Self {
        Self {
            issues: Mutex::new(issues),
            handoffs: Mutex::new(Vec::new()),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> CoreResult<std::sync::MutexGuard<'_, T>> {
    m.lock()
        .map_err(|e| SymphonyError::Tracker(format!("poisoned: {e}")))
}

fn set_state(issue: &mut Issue, name: &str) -> CoreResult<()> {
    issue.state = IssueState::new(name).map_err(|e| SymphonyError::Tracker(e.to_string()))?;
    Ok(())
}

#[async_trait]
impl Tracker for InMemoryTracker {
    async fn fetch_candidates(&self, ctx: &PollContext) -> CoreResult<Vec<Issue>> {
        let active: Vec<IssueState> = ctx.active_states.clone();
        Ok(lock(&self.issues)?
            .iter()
            .filter(|i| active.contains(&i.state))
            .cloned()
            .collect())
    }

    async fn fetch_by_ids(&self, ids: &[IssueId]) -> CoreResult<Vec<Issue>> {
        Ok(lock(&self.issues)?
            .iter()
            .filter(|i| ids.contains(&i.id))
            .cloned()
            .collect())
    }

    async fn fetch_claimed(&self, agent_id: Option<&AgentId>) -> CoreResult<Vec<Issue>> {
        Ok(lock(&self.issues)?
            .iter()
            .filter(|i| i.claim.is_some())
            .filter(|i| agent_id.is_none_or(|a| i.claim.as_ref().is_some_and(|c| &c.by == a)))
            .cloned()
            .collect())
    }

    async fn claim(&self, id: &IssueId, agent_id: &AgentId) -> CoreResult<Claim> {
        let mut issues = lock(&self.issues)?;
        let issue = issues
            .iter_mut()
            .find(|i| &i.id == id)
            .ok_or_else(|| SymphonyError::Tracker("issue not found".into()))?;
        if issue.claim.is_some() {
            return Err(SymphonyError::Tracker("already claimed".into()));
        }
        let claim = Claim::new(
            Some(id.clone()),
            agent_id.clone(),
            now_iso(),
            ShardRole::ManualM1,
        );
        set_state(issue, "in_progress")?;
        issue.claim = Some(claim.clone());
        Ok(claim)
    }

    async fn heartbeat(&self, _claim: &Claim) -> CoreResult<()> {
        Ok(())
    }

    async fn release(&self, claim: &Claim, _reason: ReleaseReason) -> CoreResult<()> {
        let mut issues = lock(&self.issues)?;
        if let Some(id) = &claim.issue_id {
            if let Some(issue) = issues.iter_mut().find(|i| &i.id == id) {
                issue.claim = None;
                set_state(issue, "todo")?;
            }
        }
        Ok(())
    }

    async fn handoff(&self, claim: &Claim, handoff: Handoff) -> CoreResult<()> {
        let mut issues = lock(&self.issues)?;
        if let Some(id) = &claim.issue_id {
            if let Some(issue) = issues.iter_mut().find(|i| &i.id == id) {
                issue.claim = None;
                set_state(issue, "review")?;
            }
        }
        drop(issues);
        lock(&self.handoffs)?.push(handoff);
        Ok(())
    }
}

// ───────────────────────────────── tests ────────────────────────────────────

#[tokio::test]
async fn runner_drives_daemon_delegation_and_mutates_workspace() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let socket = tmp.path().join("daemon.sock");
    let workspace = tmp.path().join("ws");
    std::fs::create_dir_all(&workspace).expect("ws dir");
    spawn_mock_daemon(socket.clone()).await;

    let runner = FaeRunner::with_defaults(socket, "bootstrap-client", "test-token");
    let ctx = SessionContext::new(make_issue("FAE-1"), workspace.clone());
    let mut session = runner.start_session(ctx).await.expect("start_session");
    let outcome = runner
        .run_turn(&mut session, Prompt::new("implement the thing"))
        .await
        .expect("run_turn");

    assert_eq!(outcome.status, TurnStatus::Succeeded);
    assert_eq!(outcome.usage.output_tokens, Some(12));
    assert_eq!(outcome.summary.as_deref(), Some("delegated work complete"));
    assert!(
        workspace.join("tracked.txt").exists(),
        "the delegation must have mutated the workspace via the daemon socket"
    );
}

#[tokio::test]
async fn orchestrator_runs_fae_runner_and_assembles_handoff_with_files_changed() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let socket = tmp.path().join("daemon.sock");
    let ws_root = tmp.path().join("workspaces");
    std::fs::create_dir_all(&ws_root).expect("ws root");
    let proofs = tmp.path().join("proofs");
    spawn_mock_daemon(socket.clone()).await;

    let tracker = Arc::new(InMemoryTracker::with(vec![make_issue("FAE-2")]));
    let runner = Arc::new(FaeRunner::with_defaults(
        socket,
        "bootstrap-client",
        "test-token",
    ));
    let workspace = Arc::new(GitWorkspace {
        root: ws_root.clone(),
    });
    let clock = Arc::new(SystemClock);
    let config = Config::builder(AgentId::new("agent-fae").expect("agent"))
        .active_states(vec![IssueState::new("todo").expect("todo")])
        .terminal_states(vec![IssueState::new("done").expect("done")])
        .proofs_dir(proofs.clone())
        .polling_interval(Duration::from_millis(50))
        .global_concurrency(1)
        .build();

    let orchestrator = Orchestrator::new(Arc::clone(&tracker), runner, workspace, clock, config);
    let resolution = orchestrator.run_once().await.expect("run_once");

    assert!(
        resolution.is_some(),
        "the todo issue should have been dispatched"
    );

    let handoffs = lock(&tracker.handoffs).expect("handoffs");
    assert_eq!(
        handoffs.len(),
        1,
        "exactly one handoff should be published for the single issue"
    );
    let handoff = &handoffs[0];
    assert!(
        handoff.files_changed.iter().any(|f| f == "tracked.txt"),
        "git diff must surface the workspace mutation; files_changed = {:?}",
        handoff.files_changed
    );
    assert!(
        handoff.proofs_dir.is_some(),
        "the handoff should reference written proof artefacts"
    );
    assert!(proofs.exists(), "the proofs directory should be created");
}
