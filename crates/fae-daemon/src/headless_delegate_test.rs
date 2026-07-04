//! Headless native-delegation proof (Phase F1).
//!
//! The F1 gate: *"the daemon's native jailed agentic loop actually generates →
//! executes a tool (jailed, `ToolOrigin::Delegated`) → feeds the result back →
//! finishes, under hard budgets, proven headlessly."* This driver runs
//! [`crate::delegate::run_delegation`] against a **scripted** [`MockAdapter`]
//! (no socket, no real model) and asserts, on the running kernel's OS jail:
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
//!
//! Every step prints a `PASS`/`FAIL` line; the process exits 0 only if all pass.
//! Fails closed (nonzero exit) if no OS jail backend is available.

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use fae_control_plane::{ClientClass, ClientRecord, Scope};
use fae_engine::{ChatEvent, MockAdapter};
use tokio_util::sync::CancellationToken;

use crate::conductor::ConductorStore;
use crate::delegate::{
    run_delegation, DelegationDeps, DelegationRequest, DelegationRole, DelegationStatus,
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

fn deps<'a>(
    engine: &'a MockAdapter,
    confirm: &'a AutoApprove,
    store: Arc<ConductorStore>,
    now_ms: u64,
) -> DelegationDeps<'a> {
    DelegationDeps {
        engine,
        confirmation: confirm,
        store,
        client: harness_client(),
        home_dir: None,
        cancel: CancellationToken::new(),
        now_ms,
    }
}

/// Count non-empty lines in a JSONL file (0 if absent).
fn jsonl_lines(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count())
        .unwrap_or(0)
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

/// Run the full F1 proof. Returns `Err` on the first failed assertion.
pub async fn run() -> Result<(), String> {
    println!("[headless-delegate-test] Phase F1 native jailed agentic-loop proof");
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
    let confirm = AutoApprove;

    // ── 1. Completed loop: jailed write inside the root, then a final answer ──
    let engine_a = MockAdapter::scripted(
        "mock-delegate",
        vec![
            vec![
                ChatEvent::ToolCall {
                    name: "write".into(),
                    arguments: "{\"path\":\"inside.txt\",\"content\":\"DELEGATE-OK\"}".into(),
                },
                ChatEvent::Done {
                    finish_reason: "tool_calls".into(),
                },
            ],
            vec![
                ChatEvent::Token("wrote the file".into()),
                ChatEvent::Done {
                    finish_reason: "stop".into(),
                },
            ],
        ],
    );
    let request_a = DelegationRequest {
        prompt: "write inside.txt then finish".into(),
        role: DelegationRole::Leaf,
        toolset: vec!["write".into()],
        workspace_root: root.to_path_buf(),
        max_iterations: 8,
        max_output_tokens: 2000,
        depth: 0,
    };
    let outcome_a = run_delegation(
        &deps(&engine_a, &confirm, Arc::clone(&store), 100),
        request_a,
    )
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
    let engine_b = MockAdapter::scripted(
        "mock-delegate",
        vec![
            vec![
                ChatEvent::ToolCall {
                    name: "bash".into(),
                    arguments: format!("{{\"command\":{}}}", json_string(&outside_cmd)),
                },
                ChatEvent::Done {
                    finish_reason: "tool_calls".into(),
                },
            ],
            vec![
                ChatEvent::Token("attempted the write".into()),
                ChatEvent::Done {
                    finish_reason: "stop".into(),
                },
            ],
        ],
    );
    let request_b = DelegationRequest {
        prompt: "try to escape the root".into(),
        role: DelegationRole::Leaf,
        toolset: vec!["bash".into()],
        workspace_root: root.to_path_buf(),
        max_iterations: 8,
        max_output_tokens: 2000,
        depth: 0,
    };
    let _outcome_b = run_delegation(
        &deps(&engine_b, &confirm, Arc::clone(&store), 200),
        request_b,
    )
    .await
    .map_err(|e| format!("delegation B failed to run: {e}"))?;
    check(
        !outside_file.exists(),
        "jail.write_outside_denied",
        "a delegated write escaped the root — the OS jail did NOT confine it",
    )?;

    // ── 3. Budget exhaustion: max_iterations = 1 with a tool call every turn ──
    let engine_c = MockAdapter::scripted(
        "mock-delegate",
        vec![vec![
            ChatEvent::ToolCall {
                name: "write".into(),
                arguments: "{\"path\":\"again.txt\",\"content\":\"y\"}".into(),
            },
            ChatEvent::Done {
                finish_reason: "tool_calls".into(),
            },
        ]],
    );
    let request_c = DelegationRequest {
        prompt: "keep going".into(),
        role: DelegationRole::Leaf,
        toolset: vec!["write".into()],
        workspace_root: root.to_path_buf(),
        max_iterations: 1,
        max_output_tokens: 2000,
        depth: 0,
    };
    let outcome_c = run_delegation(
        &deps(&engine_c, &confirm, Arc::clone(&store), 300),
        request_c,
    )
    .await
    .map_err(|e| format!("delegation C failed to run: {e}"))?;
    check(
        outcome_c.status == DelegationStatus::BudgetExhausted
            && outcome_c.receipt.iterations_used == 1,
        "budget.exhaustion_trips",
        "max_iterations=1 with a tool call should trip budget_exhausted after 1 iteration",
    )?;

    // ── 4. Depth rejection (fan-out is commit 2) ──────────────────────────────
    let engine_d = MockAdapter::new("mock-delegate");
    let request_d = DelegationRequest {
        prompt: "nested".into(),
        role: DelegationRole::Orchestrator,
        toolset: vec![],
        workspace_root: root.to_path_buf(),
        max_iterations: 4,
        max_output_tokens: 1000,
        depth: 1,
    };
    let rejected = run_delegation(
        &deps(&engine_d, &confirm, Arc::clone(&store), 400),
        request_d,
    )
    .await;
    check(
        rejected.is_err(),
        "depth.rejected",
        "depth > 0 must be rejected in commit 1",
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
