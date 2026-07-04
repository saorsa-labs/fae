//! Headless native-delegation proof (Phase F1 + F2).
//!
//! The gate: *"the daemon's native jailed agentic loop actually generates →
//! executes a tool (jailed, `ToolOrigin::Delegated`) → feeds the result back →
//! finishes, under hard budgets — AND an orchestrator fans out to parallel
//! jailed leaves, proven headlessly."* This driver runs
//! [`crate::delegate::run_delegation`] against scripted mock adapters (no socket,
//! no real model) and asserts, on the running kernel's OS jail:
//!
//! 1. **Completed loop**: iteration 1 emits a `write` tool call into the
//!    workspace, iteration 2 a final answer. The write lands INSIDE the root,
//!    runs under the Delegated origin (audit isolation = `jailed`), the
//!    delegation receipt links the write's mutation-receipt id, and the receipt
//!    was persisted to `delegation_receipts.jsonl`.
//! 2. **Jail confines**: a delegated `bash` write to a path OUTSIDE the root is
//!    blocked by the OS jail (Landlock/seatbelt) — the file never lands.
//! 3. **Budget exhaustion**: `max_iterations = 1` with a tool call every turn
//!    trips `budget_exhausted` with a partial receipt.
//! 4. **Depth**: a delegation at depth 2 is rejected (a leaf cannot fan out).
//! 5. **Fan-out (F2)**: an orchestrator calls the synthetic `delegate` tool with
//!    a 2-leaf batch; each leaf writes a file (jailed) then finishes; the
//!    orchestrator then answers referencing the results. Both leaf writes land
//!    in the root, both leaf receipts carry `parent_id`, and the orchestrator
//!    receipt records both children.
//! 6. **No deadlock at cap = 1**: the same fan-out with a single-permit
//!    delegation-concurrency pool still completes (bounded by a timeout).
//! 7. **Leaf cannot delegate**: a leaf that emits the `delegate` tool is
//!    runtime-rejected and spawns nothing.
//!
//! Every step prints a `PASS`/`FAIL` line; the process exits 0 only if all pass.
//! Fails closed (nonzero exit) if no OS jail backend is available.

use std::collections::VecDeque;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use fae_control_plane::{ClientClass, ClientRecord, Scope};
use fae_engine::{
    AdapterInfo, ChatEvent, ChatRequest, ChatStream, EngineError, MockAdapter, ProviderAdapter,
    Role,
};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;

use crate::conductor::ConductorStore;
use crate::delegate::{
    leaf_permit_with_cap, run_delegation, DelegationDeps, DelegationRequest, DelegationRole,
    DelegationStatus,
};
use crate::toolhost::confirm::{ConfirmReply, ConfirmRequest, ToolConfirmation};
use crate::toolhost::isolation::jail_backend_available;

/// Auto-approving confirmation (see the Phase C harness note: catastrophic-op
/// denies fire BEFORE the confirm, so this cannot bypass damage control).
struct AutoApprove;

#[async_trait]
impl ToolConfirmation for AutoApprove {
    async fn confirm(&self, _req: &ConfirmRequest) -> ConfirmReply {
        ConfirmReply::Approved
    }
}

fn confirm() -> Arc<dyn ToolConfirmation> {
    Arc::new(AutoApprove)
}

fn pass(step: &str) {
    println!("[headless-delegate-test] PASS  {step}");
}

fn check(cond: bool, step: &str, why: &str) -> Result<(), String> {
    if cond {
        pass(step);
        Ok(())
    } else {
        let msg = format!("{step}: {why}");
        eprintln!("[headless-delegate-test] FAIL  {msg}");
        Err(msg)
    }
}

/// A client holding both tool-execute scopes (owner-equivalent for the harness).
fn harness_client() -> ClientRecord {
    ClientRecord {
        client_id: "headless-delegate-test".into(),
        class: ClientClass::TestHarness,
        scopes: [Scope::ToolExecuteSafe, Scope::ToolExecuteDangerous]
            .into_iter()
            .collect(),
        issued_at_ms: 0,
        expires_at_ms: u64::MAX,
        revoked_at_ms: None,
        display_name: "Headless Delegate Test".into(),
    }
}

/// Build deps with fresh (per-delegation) semaphores. A fan-out orchestrator's
/// children CLONE these deps, so the whole tree shares one engine permit + pool.
fn deps(
    engine: Arc<dyn ProviderAdapter>,
    store: Arc<ConductorStore>,
    now_ms: u64,
) -> DelegationDeps {
    DelegationDeps {
        engine,
        confirmation: confirm(),
        store,
        client: harness_client(),
        home_dir: None,
        cancel: CancellationToken::new(),
        now_ms,
        engine_permit: Arc::new(Semaphore::new(1)),
        leaf_permit: leaf_permit_with_cap(3),
        parent_id: None,
    }
}

/// A completed-turn script: a final answer, no tool calls.
fn final_answer(text: &str) -> Vec<ChatEvent> {
    vec![
        ChatEvent::Token(text.to_owned()),
        ChatEvent::Done {
            finish_reason: "stop".into(),
        },
    ]
}

/// A tool-call turn ending in `tool_calls`.
fn tool_call(name: &str, arguments: &str) -> Vec<ChatEvent> {
    vec![
        ChatEvent::ToolCall {
            name: name.into(),
            arguments: arguments.into(),
        },
        ChatEvent::Done {
            finish_reason: "tool_calls".into(),
        },
    ]
}

/// A [`ProviderAdapter`] that routes each `stream_chat` to the FIRST keyed script
/// whose key is a substring of the last user message, popping that key's FIFO.
/// Concurrency-safe (each delegation selects by its OWN prompt), so an
/// orchestrator + parallel children sharing one engine stay deterministic.
struct KeyedMock {
    scripts: Mutex<Vec<(String, VecDeque<Vec<ChatEvent>>)>>,
}

impl KeyedMock {
    fn new(entries: Vec<(&str, Vec<Vec<ChatEvent>>)>) -> Arc<KeyedMock> {
        Arc::new(KeyedMock {
            scripts: Mutex::new(
                entries
                    .into_iter()
                    .map(|(key, turns)| (key.to_owned(), turns.into()))
                    .collect(),
            ),
        })
    }
}

#[async_trait]
impl ProviderAdapter for KeyedMock {
    fn describe(&self) -> AdapterInfo {
        AdapterInfo {
            backend: "keyed".into(),
            model_id: "keyed".into(),
            context_window: 8192,
        }
    }
    async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError> {
        let last_user = request
            .messages
            .iter()
            .rev()
            .find(|m| m.role == Role::User)
            .map(|m| m.content.clone())
            .unwrap_or_default();
        let turn = {
            let mut guard = self
                .scripts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut chosen = None;
            for (key, queue) in guard.iter_mut() {
                if last_user.contains(key.as_str()) {
                    chosen = queue.pop_front();
                    break;
                }
            }
            chosen.unwrap_or_else(|| final_answer("done"))
        };
        let events = turn.into_iter().map(Ok).collect::<Vec<_>>();
        Ok(Box::pin(futures_util::stream::iter(events)))
    }
}

/// Count non-empty lines in a JSONL file (0 if absent).
fn jsonl_lines(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count())
        .unwrap_or(0)
}

/// Parse a JSONL file into one `Value` per non-empty line (empty on any error).
fn jsonl_values(path: &Path) -> Vec<serde_json::Value> {
    std::fs::read_to_string(path)
        .map(|s| {
            s.lines()
                .filter(|l| !l.trim().is_empty())
                .filter_map(|l| serde_json::from_str(l).ok())
                .collect()
        })
        .unwrap_or_default()
}

/// Single-quote a string for safe inclusion in an `sh -c` command.
fn sh_single_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

/// Run the full proof. Returns `Err` on the first failed assertion.
pub async fn run() -> Result<(), String> {
    println!("[headless-delegate-test] Phase F1+F2 native jailed agentic-loop proof");
    println!(
        "[headless-delegate-test] jail backend available: {}",
        jail_backend_available()
    );
    if !jail_backend_available() {
        return Err(
            "jail_backend_available() is false — cannot prove Delegated-origin isolation".into(),
        );
    }

    // Non-temp base (the jail allows temp writes, so the OUTSIDE probe must live
    // outside temp or the negative test is void) — mirrors the Phase C harness.
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let base = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target")
        .join(format!("headless-delegate-test-{nonce}"));
    let root = base.join("root");
    let outside = base.join("outside");
    let store_dir = base.join("store");
    std::fs::create_dir_all(&root).map_err(|e| format!("create root: {e}"))?;
    std::fs::create_dir_all(&outside).map_err(|e| format!("create outside: {e}"))?;
    std::fs::create_dir_all(&store_dir).map_err(|e| format!("create store: {e}"))?;

    let result = run_inner(&root, &outside, &store_dir).await;
    let _ = std::fs::remove_dir_all(&base);
    result
}

async fn run_inner(root: &Path, outside: &Path, store_dir: &Path) -> Result<(), String> {
    let store = Arc::new(ConductorStore::open(store_dir).map_err(|e| format!("store open: {e}"))?);

    // ── 1. Completed loop: jailed write inside the root, then a final answer ──
    let engine_a: Arc<dyn ProviderAdapter> = Arc::new(MockAdapter::scripted(
        "mock-delegate",
        vec![
            tool_call(
                "write",
                "{\"path\":\"inside.txt\",\"content\":\"DELEGATE-OK\"}",
            ),
            final_answer("wrote the file"),
        ],
    ));
    let request_a = DelegationRequest {
        prompt: "write inside.txt then finish".into(),
        role: DelegationRole::Leaf,
        toolset: vec!["write".into()],
        workspace_root: root.to_path_buf(),
        max_iterations: 8,
        max_output_tokens: 2000,
        depth: 0,
    };
    let outcome_a = run_delegation(&deps(engine_a, Arc::clone(&store), 100), request_a)
        .await
        .map_err(|e| format!("delegation A failed to run: {e}"))?;

    check(
        outcome_a.status == DelegationStatus::Completed,
        "loop.completed",
        "expected the two-iteration loop to complete with a final answer",
    )?;
    check(
        root.join("inside.txt").exists(),
        "loop.jailed_write_landed",
        "the delegated write did not land inside the root",
    )?;
    check(
        outcome_a.receipt.iterations_used == 2,
        "loop.iterations",
        "expected exactly 2 iterations",
    )?;
    check(
        outcome_a
            .receipt
            .tool_events
            .first()
            .and_then(|e| e.mutation_receipt_id.as_ref())
            .is_some(),
        "loop.mutation_receipt_linked",
        "the delegation receipt did not link the write's mutation-receipt id",
    )?;

    // The delegation receipt + the write's mutation receipt were persisted.
    check(
        jsonl_lines(&store.dir().join("delegation_receipts.jsonl")) >= 1,
        "receipt.delegation_recorded",
        "no delegation receipt persisted",
    )?;
    check(
        jsonl_lines(&store.dir().join("toolhost_receipts.jsonl")) >= 1,
        "receipt.mutation_recorded",
        "no mutation receipt persisted for the jailed write",
    )?;
    // The write ran under the Delegated origin → the OS jail (audit label).
    let audit =
        std::fs::read_to_string(store.dir().join("toolhost_audit.jsonl")).unwrap_or_default();
    check(
        audit.contains("\"isolation\":\"jailed\""),
        "loop.delegated_origin_jailed",
        "the delegated write was not audited as jailed",
    )?;

    // ── 2. Jail confines: a delegated bash write OUTSIDE the root is blocked ──
    let outside_file = outside.join("leak.txt");
    let outside_cmd = format!(
        "printf x > {}",
        sh_single_quote(&outside_file.to_string_lossy())
    );
    let engine_b: Arc<dyn ProviderAdapter> = Arc::new(MockAdapter::scripted(
        "mock-delegate",
        vec![
            tool_call(
                "bash",
                &format!("{{\"command\":{}}}", json_string(&outside_cmd)),
            ),
            final_answer("attempted the write"),
        ],
    ));
    let request_b = DelegationRequest {
        prompt: "try to escape the root".into(),
        role: DelegationRole::Leaf,
        toolset: vec!["bash".into()],
        workspace_root: root.to_path_buf(),
        max_iterations: 8,
        max_output_tokens: 2000,
        depth: 0,
    };
    let _outcome_b = run_delegation(&deps(engine_b, Arc::clone(&store), 200), request_b)
        .await
        .map_err(|e| format!("delegation B failed to run: {e}"))?;
    check(
        !outside_file.exists(),
        "jail.write_outside_denied",
        "a delegated write escaped the root — the OS jail did NOT confine it",
    )?;

    // ── 3. Budget exhaustion: max_iterations = 1 with a tool call every turn ──
    let engine_c: Arc<dyn ProviderAdapter> = Arc::new(MockAdapter::scripted(
        "mock-delegate",
        vec![tool_call(
            "write",
            "{\"path\":\"again.txt\",\"content\":\"y\"}",
        )],
    ));
    let request_c = DelegationRequest {
        prompt: "keep going".into(),
        role: DelegationRole::Leaf,
        toolset: vec!["write".into()],
        workspace_root: root.to_path_buf(),
        max_iterations: 1,
        max_output_tokens: 2000,
        depth: 0,
    };
    let outcome_c = run_delegation(&deps(engine_c, Arc::clone(&store), 300), request_c)
        .await
        .map_err(|e| format!("delegation C failed to run: {e}"))?;
    check(
        outcome_c.status == DelegationStatus::BudgetExhausted
            && outcome_c.receipt.iterations_used == 1,
        "budget.exhaustion_trips",
        "max_iterations=1 with a tool call should trip budget_exhausted after 1 iteration",
    )?;

    // ── 4. Depth rejection (a leaf cannot fan out — depth 2 rejected) ─────────
    let engine_d: Arc<dyn ProviderAdapter> = Arc::new(MockAdapter::new("mock-delegate"));
    let request_d = DelegationRequest {
        prompt: "nested".into(),
        role: DelegationRole::Orchestrator,
        toolset: vec![],
        workspace_root: root.to_path_buf(),
        max_iterations: 4,
        max_output_tokens: 1000,
        depth: 2,
    };
    let rejected = run_delegation(&deps(engine_d, Arc::clone(&store), 400), request_d).await;
    check(
        rejected.is_err(),
        "depth.rejected",
        "depth > MAX_DEPTH must be rejected",
    )?;

    // ── 5. Orchestrator fan-out: 2 parallel jailed leaves, each writes ───────
    let batch_args = serde_json::json!({
        "batch": [
            { "prompt": "LEAF-ONE write leaf-one.txt", "toolset": ["write"],
              "max_iterations": 4, "max_output_tokens": 500 },
            { "prompt": "LEAF-TWO write leaf-two.txt", "toolset": ["write"],
              "max_iterations": 4, "max_output_tokens": 500 }
        ]
    })
    .to_string();
    let engine_e: Arc<dyn ProviderAdapter> = KeyedMock::new(vec![
        (
            "ORCHESTRATE",
            vec![
                tool_call("delegate", &batch_args),
                final_answer("both leaves finished"),
            ],
        ),
        (
            "LEAF-ONE",
            vec![
                tool_call("write", "{\"path\":\"leaf-one.txt\",\"content\":\"ONE\"}"),
                final_answer("wrote leaf one"),
            ],
        ),
        (
            "LEAF-TWO",
            vec![
                tool_call("write", "{\"path\":\"leaf-two.txt\",\"content\":\"TWO\"}"),
                final_answer("wrote leaf two"),
            ],
        ),
    ]);
    let request_e = DelegationRequest {
        prompt: "ORCHESTRATE split the writes across two leaves".into(),
        role: DelegationRole::Orchestrator,
        toolset: vec!["write".into()],
        workspace_root: root.to_path_buf(),
        max_iterations: 6,
        max_output_tokens: 5000,
        depth: 0,
    };
    let outcome_e = run_delegation(&deps(engine_e, Arc::clone(&store), 500), request_e)
        .await
        .map_err(|e| format!("delegation E (fan-out) failed to run: {e}"))?;

    check(
        outcome_e.status == DelegationStatus::Completed,
        "fanout.orchestrator_completed",
        "the orchestrator did not complete after fan-out",
    )?;
    check(
        root.join("leaf-one.txt").exists() && root.join("leaf-two.txt").exists(),
        "fanout.both_leaf_writes_landed",
        "one or both parallel leaf writes did not land in the jailed root",
    )?;
    check(
        outcome_e.receipt.child_ids.len() == 2,
        "fanout.orchestrator_records_batch",
        "the orchestrator receipt did not record both children",
    )?;
    // Both leaf receipts persisted with parent_id == the orchestrator id.
    let orch_id = outcome_e.receipt.id.clone();
    let leaf_receipts: Vec<serde_json::Value> =
        jsonl_values(&store.dir().join("delegation_receipts.jsonl"))
            .into_iter()
            .filter(|v| {
                v.get("parent_id").and_then(serde_json::Value::as_str) == Some(orch_id.as_str())
            })
            .collect();
    check(
        leaf_receipts.len() == 2,
        "fanout.leaf_receipts_link_parent",
        "expected exactly 2 persisted leaf receipts carrying the orchestrator's parent_id",
    )?;

    // ── 6. No deadlock at cap = 1: the same fan-out with a single-permit pool ─
    let engine_f: Arc<dyn ProviderAdapter> = KeyedMock::new(vec![
        (
            "CAP1",
            vec![
                tool_call(
                    "delegate",
                    &serde_json::json!({
                        "batch": [
                            { "prompt": "CAP1-A answer", "toolset": [],
                              "max_iterations": 2, "max_output_tokens": 100 },
                            { "prompt": "CAP1-B answer", "toolset": [],
                              "max_iterations": 2, "max_output_tokens": 100 }
                        ]
                    })
                    .to_string(),
                ),
                final_answer("both children finished at cap 1"),
            ],
        ),
        ("CAP1-A", vec![final_answer("child A done")]),
        ("CAP1-B", vec![final_answer("child B done")]),
    ]);
    let deps_f = DelegationDeps {
        engine: engine_f,
        confirmation: confirm(),
        store: Arc::clone(&store),
        client: harness_client(),
        home_dir: None,
        cancel: CancellationToken::new(),
        now_ms: 600,
        engine_permit: Arc::new(Semaphore::new(1)),
        leaf_permit: leaf_permit_with_cap(1), // the starvation stress
        parent_id: None,
    };
    let request_f = DelegationRequest {
        prompt: "CAP1 split at cap one".into(),
        role: DelegationRole::Orchestrator,
        toolset: vec![],
        workspace_root: root.to_path_buf(),
        max_iterations: 6,
        max_output_tokens: 5000,
        depth: 0,
    };
    let outcome_f =
        tokio::time::timeout(Duration::from_secs(20), run_delegation(&deps_f, request_f))
            .await
            .map_err(|_| "fan-out at cap=1 DEADLOCKED (timed out)".to_owned())?
            .map_err(|e| format!("delegation F (cap=1) failed to run: {e}"))?;
    check(
        outcome_f.status == DelegationStatus::Completed && outcome_f.receipt.child_ids.len() == 2,
        "fanout.no_deadlock_at_cap_1",
        "fan-out at cap=1 did not complete with both children",
    )?;

    // ── 7. Leaf cannot delegate: a leaf emitting `delegate` is rejected ──────
    let engine_g: Arc<dyn ProviderAdapter> = Arc::new(MockAdapter::scripted(
        "mock-delegate",
        vec![
            tool_call(
                "delegate",
                "{\"batch\":[{\"prompt\":\"x\",\"toolset\":[],\"max_iterations\":1,\"max_output_tokens\":10}]}",
            ),
            final_answer("cannot delegate as a leaf"),
        ],
    ));
    let request_g = DelegationRequest {
        prompt: "leaf tries to delegate".into(),
        role: DelegationRole::Leaf,
        toolset: vec![],
        workspace_root: root.to_path_buf(),
        max_iterations: 4,
        max_output_tokens: 1000,
        depth: 0,
    };
    let outcome_g = run_delegation(&deps(engine_g, Arc::clone(&store), 700), request_g)
        .await
        .map_err(|e| format!("delegation G failed to run: {e}"))?;
    let leaf_delegate_denied = outcome_g
        .receipt
        .tool_events
        .iter()
        .any(|e| e.tool == "delegate" && e.status == "denied_leaf_cannot_delegate");
    check(
        leaf_delegate_denied && outcome_g.receipt.child_ids.is_empty(),
        "fanout.leaf_cannot_delegate",
        "a leaf's delegate call was not rejected (or it spawned children)",
    )?;

    println!("[headless-delegate-test] all native-delegation steps passed");
    Ok(())
}

/// Minimal JSON string encoder for embedding a shell command into a tool-call
/// `arguments` object (escapes `"` and `\`).
fn json_string(s: &str) -> String {
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}
