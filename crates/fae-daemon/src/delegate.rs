//! Native jailed agentic loop (`fae.delegate`, Phase F1).
//!
//! Today the daemon runs ONE turn per `conversation.inject_text` and hands the
//! model's tool calls back to the Swift client, which executes them and feeds
//! results back in a fresh inject. This module gives the daemon its own
//! generate → execute-tool → feed-back loop, **jailed and budget-capped**:
//!
//! * a fresh child history (delegated-worker system prompt + the delegated
//!   prompt + a RESTRICTED set of tool schemas — only the `toolset`'s tools);
//! * each iteration runs [`crate::session::run_turn`]; on tool calls it checks
//!   the `toolset` allowlist, then executes each through the governed
//!   [`ToolHost`] with a NEW [`ToolOrigin::Delegated`] (always OS-jailed), and
//!   appends the results to the child history;
//! * hard budgets — the daemon clamps iterations to [`MAX_ITERATIONS_CEILING`]
//!   and the cumulative output-token budget to [`TOKEN_CEILING`]. Tripping
//!   either yields a `budget_exhausted` status with a PARTIAL receipt.
//!
//! Commit-2 (Phase F2) adds **parallel leaf batches + orchestrator fan-out**:
//!
//! * a process-global **engine permit** ([`Semaphore`], permit = 1) serializes
//!   ALL delegation generations on the single local engine — held ONLY across
//!   the `run_turn` generation call, never across tool execution, so parallel
//!   leaves overlap tool-exec / jail I/O (NOT token throughput);
//! * a **delegation-concurrency cap** ([`DEFAULT_DELEGATION_CONCURRENCY`] = 3,
//!   clamped ≤ [`MAX_DELEGATION_CONCURRENCY`] = 8) bounds live LEAF loops via a
//!   second semaphore. Only leaves consume a slot; an orchestrator (which merely
//!   awaits its children) holds NO slot, so the wait graph is acyclic —
//!   deadlock-free even at cap = 1 (a permit holder never waits on a permit,
//!   because a leaf cannot fan out);
//! * an `Orchestrator`-role delegation at depth 0 sees a synthetic `delegate`
//!   TOOL (exposed ONLY in the orchestrator's schema — never a leaf's). Its
//!   input is a BATCH (≤ [`MAX_BATCH_SIZE`] = 4) of child specs; each child runs
//!   as a `Leaf` at depth + 1 in the SAME `workspace_root`, with a toolset that
//!   must be a SUBSET of the parent's and budgets clamped ≤ the parent's
//!   remaining. Each child is `tokio::spawn`ed and joined; child receipts link
//!   `parent_id`;
//! * depth: an orchestrator at depth 0 may spawn leaves at depth 1; anything at
//!   depth ≥ 1 is a leaf (no `delegate` tool in schema AND runtime-rejected —
//!   defense in depth). Depth > [`MAX_DEPTH`] (i.e. 2+) is rejected.
//!
//! The receipt records `prompt_sha256`, **never the raw prompt**, and lands in
//! the conductor store's isolated JSONL (`delegation_receipts.jsonl`), never
//! `fae.db`.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, LazyLock};
use std::time::Instant;

use fae_control_plane::ClientRecord;
use fae_engine::{ChatMessage, ChatRequest, ProviderAdapter, Role, ToolSpec};
use fluers_core::tool::ToolResult;
use fluers_runtime::Limits;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;

use crate::compaction::{self, PromptBudget, Watermark};
use crate::conductor::ConductorStore;
use crate::mcp::MCP_TOOL_PREFIX;
use crate::toolhost::confirm::ToolConfirmation;
use crate::toolhost::isolation::{jail_backend_available, ToolOrigin};
use crate::toolhost::receipts::sha256_hex;
use crate::toolhost::root_confirm::is_safe_workspace_root;
use crate::toolhost::{ToolHost, ToolHostError, ToolHostRequest};

/// Hard ceiling on delegation iterations (the daemon clamps to this regardless
/// of the caller's request). One tool-executing turn per iteration.
pub const MAX_ITERATIONS_CEILING: u32 = 16;

/// Hard ceiling on the cumulative output-token budget for a whole delegation.
///
/// The plan calls for `tokens ≤ engine context / 2`. This is the conservative
/// fixed cap on the CUMULATIVE output tokens across a whole delegation (distinct
/// from the per-prompt compaction budget, which Phase G1 derives from
/// `AdapterInfo::context_window`). Output tokens are APPROXIMATED (see
/// [`output_tokens`], which delegates to [`crate::compaction::estimate_tokens`]).
pub const TOKEN_CEILING: u32 = 32_768;

/// Per-turn generation cap. Each iteration's `max_tokens` is the smaller of this
/// and the delegation's remaining token budget.
const PER_TURN_MAX_TOKENS: usize = 4096;

/// Maximum nesting depth. An orchestrator at depth 0 spawns leaves at depth 1;
/// depth 2+ (a leaf spawning children) is rejected — leaves cannot fan out.
pub const MAX_DEPTH: u8 = 1;

/// Default cap on concurrent LIVE leaf loops (the delegation-concurrency
/// semaphore's permit count). Bounds jailed-ToolHost / tool-exec resource use.
pub const DEFAULT_DELEGATION_CONCURRENCY: usize = 3;

/// Hard ceiling on the delegation-concurrency cap (clamped daemon-side).
pub const MAX_DELEGATION_CONCURRENCY: usize = 8;

/// Maximum children in one orchestrator fan-out batch.
pub const MAX_BATCH_SIZE: usize = 4;

/// The synthetic fan-out tool name — exposed ONLY in an orchestrator's schema,
/// never a leaf's, and never a real [`ToolHost`] tool.
const DELEGATE_TOOL: &str = "delegate";

/// Process-global **engine permit** (permit = 1): serializes ALL delegation
/// generations on the single local engine. Held ONLY across the `run_turn`
/// generation call — NOT across tool execution — so parallel leaves overlap
/// tool-exec / jail I/O, not token throughput.
static ENGINE_PERMIT: LazyLock<Arc<Semaphore>> = LazyLock::new(|| Arc::new(Semaphore::new(1)));

/// Process-global **delegation-concurrency** semaphore (default cap
/// [`DEFAULT_DELEGATION_CONCURRENCY`]). Only LEAF loops consume a permit.
static LEAF_PERMIT: LazyLock<Arc<Semaphore>> =
    LazyLock::new(|| Arc::new(Semaphore::new(DEFAULT_DELEGATION_CONCURRENCY)));

/// The process-global engine permit (permit = 1). The daemon wires this into
/// every top-level delegation so the whole fan-out tree shares one gate.
#[must_use]
pub fn engine_permit() -> Arc<Semaphore> {
    Arc::clone(&ENGINE_PERMIT)
}

/// The process-global delegation-concurrency semaphore (default cap 3).
#[must_use]
pub fn leaf_permit() -> Arc<Semaphore> {
    Arc::clone(&LEAF_PERMIT)
}

/// A fresh delegation-concurrency semaphore with an explicit cap, clamped to
/// `[1, MAX_DELEGATION_CONCURRENCY]`. Used by tests to prove the no-deadlock
/// invariant at cap = 1.
#[must_use]
pub fn leaf_permit_with_cap(cap: usize) -> Arc<Semaphore> {
    Arc::new(Semaphore::new(cap.clamp(1, MAX_DELEGATION_CONCURRENCY)))
}

/// Whether a delegated agent fans out to child workers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DelegationRole {
    /// A leaf worker: runs tools, returns a result. No children, no `delegate`
    /// tool in its schema, and a runtime-rejected `delegate` call (defense in
    /// depth). Consumes a delegation-concurrency permit for its whole run.
    #[default]
    Leaf,
    /// An orchestrator: at depth 0 it sees the synthetic `delegate` tool and may
    /// fan out to a batch of child leaves (`tokio::spawn` + join). It holds NO
    /// concurrency permit while awaiting children (keeps the wait graph acyclic).
    Orchestrator,
}

/// A request to run one native jailed delegation.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DelegationRequest {
    /// The task for the delegated worker.
    pub prompt: String,
    /// Leaf vs Orchestrator. An `Orchestrator` at depth 0 may fan out.
    #[serde(default)]
    pub role: DelegationRole,
    /// The tools the worker is permitted to call (names). A tool call naming a
    /// tool outside this set is rejected without executing.
    #[serde(default)]
    pub toolset: Vec<String>,
    /// The workspace directory the ephemeral jailed ToolHost is rooted at. This
    /// comes from a TRUSTED orchestrator (the Swift frontend), **never** model
    /// output — it is validated (absolute/exists/dir/not-protected) before use.
    pub workspace_root: PathBuf,
    /// Requested iteration cap (clamped to [`MAX_ITERATIONS_CEILING`]).
    pub max_iterations: u32,
    /// Requested cumulative output-token budget (clamped to [`TOKEN_CEILING`]).
    pub max_output_tokens: u32,
    /// Nesting depth. An orchestrator is submitted at depth 0; its children run
    /// at depth 1. Anything `> `[`MAX_DEPTH`] (i.e. 2+) is rejected.
    #[serde(default)]
    pub depth: u8,
}

/// The hard budget for a delegation: a per-iteration counter and a cumulative
/// output-token cap, both clamped daemon-side.
#[derive(Debug, Clone, Copy)]
pub struct DelegationBudget {
    /// Clamped iteration cap.
    pub max_iterations: u32,
    /// Clamped cumulative output-token cap.
    pub max_output_tokens: u32,
    /// Iterations consumed so far.
    pub iterations_used: u32,
    /// Approximate output tokens consumed so far.
    pub tokens_used: u32,
}

impl DelegationBudget {
    /// Build a budget from a caller's request, clamping BOTH limits daemon-side.
    /// The iteration floor is 1 (a zero-iteration delegation is meaningless).
    #[must_use]
    pub fn clamped(max_iterations: u32, max_output_tokens: u32) -> Self {
        Self {
            max_iterations: max_iterations.clamp(1, MAX_ITERATIONS_CEILING),
            max_output_tokens: max_output_tokens.clamp(1, TOKEN_CEILING),
            iterations_used: 0,
            tokens_used: 0,
        }
    }

    /// Remaining output-token budget.
    #[must_use]
    fn tokens_remaining(&self) -> u32 {
        self.max_output_tokens.saturating_sub(self.tokens_used)
    }
}

/// One tool call within a delegation, in execution order.
#[derive(Debug, Clone, Serialize)]
pub struct DelegationToolEvent {
    /// The tool name the model called.
    pub tool: String,
    /// The mutation-receipt correlation id (the ToolHost `call_id`) when a
    /// MUTATING tool (`write`/`edit`/`bash`) actually executed — this links the
    /// delegation receipt to the `toolhost_receipts.jsonl` mutation receipt.
    /// `None` for a non-mutating tool, a rejected (not-in-toolset) call, or a
    /// tool that failed before mutating.
    pub mutation_receipt_id: Option<String>,
    /// Outcome: `ok` | `denied_not_in_toolset` | `denied` | `unknown_tool` |
    /// `tool_failed` | `sandbox_error`.
    pub status: String,
}

/// The terminal status of a delegation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DelegationStatus {
    /// The worker produced a final answer (a turn with no tool calls).
    Completed,
    /// The iteration or token budget tripped before a final answer — the
    /// receipt is PARTIAL.
    BudgetExhausted,
    /// The engine failed mid-loop.
    Failed,
    /// The parent cancelled this delegation between turns (CR-H2) — the receipt
    /// is PARTIAL and any in-flight children were aborted.
    Cancelled,
}

impl DelegationStatus {
    /// Wire label.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            DelegationStatus::Completed => "completed",
            DelegationStatus::BudgetExhausted => "budget_exhausted",
            DelegationStatus::Failed => "failed",
            DelegationStatus::Cancelled => "cancelled",
        }
    }
}

/// The auditable record of one delegation. Carries `prompt_sha256`, NEVER the
/// raw prompt. Serialized to `delegation_receipts.jsonl`.
#[derive(Debug, Clone, Serialize)]
pub struct DelegationReceipt {
    /// Always the literal `"delegation"` (fast grep/filter).
    pub event_type: &'static str,
    /// Delegation id (`del-<ts>-<prompt-hash-prefix>`).
    pub id: String,
    /// Receipt time, ms since UNIX epoch.
    pub ts_ms: u64,
    /// Leaf vs Orchestrator.
    pub role: DelegationRole,
    /// The parent orchestrator's delegation id when this is a spawned child
    /// leaf; `None` for a top-level delegation. Links a child to its parent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    /// For an orchestrator that fanned out: the delegation ids of the children
    /// it spawned (records the batch). Empty for a leaf / a non-fan-out run.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub child_ids: Vec<String>,
    /// SHA-256 hex of the delegated prompt — the raw prompt is NEVER stored.
    pub prompt_sha256: String,
    /// The permitted toolset (names).
    pub toolset: Vec<String>,
    /// Iterations consumed.
    pub iterations_used: u32,
    /// Approximate output tokens consumed.
    pub tokens_used: u32,
    /// Every tool call, in order, with its mutation-receipt link + status.
    pub tool_events: Vec<DelegationToolEvent>,
    /// Terminal status.
    pub status: DelegationStatus,
    /// Wall-clock duration.
    pub wall_ms: u64,
}

/// The outcome of [`run_delegation`].
#[derive(Debug, Clone)]
pub struct DelegationOutcome {
    /// The worker's final (or last) visible text.
    pub text: String,
    /// Terminal status.
    pub status: DelegationStatus,
    /// The persisted receipt.
    pub receipt: DelegationReceipt,
}

/// A fail-closed delegation rejection (nothing ran, no receipt).
#[derive(Debug, thiserror::Error)]
pub enum DelegationError {
    /// `depth > MAX_DEPTH` — a leaf cannot fan out.
    #[error("delegation depth {0} exceeds the maximum of {max} (a leaf cannot fan out)", max = MAX_DEPTH)]
    DepthExceeded(u8),
    /// The prompt was empty/whitespace.
    #[error("delegation prompt is empty")]
    EmptyPrompt,
    /// A process concurrency semaphore was closed (never happens in normal
    /// operation — the daemon never closes the engine/leaf permits — but we
    /// fail closed rather than `unwrap`).
    #[error("delegation concurrency permit unavailable (semaphore closed)")]
    PermitUnavailable,
    /// The workspace root failed validation (absolute/exists/dir/not-protected).
    #[error("workspace root rejected: {0}")]
    InvalidWorkspace(String),
    /// No OS jail backend on this host — a delegated loop MUST run jailed.
    #[error("execution isolation (OS jail) is unavailable; a delegated loop must run jailed")]
    JailUnavailable,
    /// The ephemeral jailed ToolHost could not be built.
    #[error("ephemeral delegation ToolHost build failed: {0}")]
    ToolHostBuild(String),
}

impl DelegationError {
    /// A stable wire error code for the `conversation.delegate` response.
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            DelegationError::DepthExceeded(_) => "delegation_depth_exceeded",
            DelegationError::EmptyPrompt => "bad_request",
            DelegationError::PermitUnavailable => "delegation_unavailable",
            DelegationError::InvalidWorkspace(_) => "unsafe_root",
            DelegationError::JailUnavailable => "jail_unavailable",
            DelegationError::ToolHostBuild(_) => "sandbox_error",
        }
    }
}

/// The backends a delegation needs. Owned (shared via `Arc`) so an orchestrator
/// can `tokio::spawn` children that share the SAME engine, confirmation channel,
/// store, and BOTH semaphores. `Clone` builds a child's deps from the parent's.
#[derive(Clone)]
pub struct DelegationDeps {
    /// The inference engine (drives each iteration's turn).
    pub engine: Arc<dyn ProviderAdapter>,
    /// The tool-confirmation channel (dangerous ops still round-trip to the
    /// owner; the caller spawns delegation off the read loop so the reply routes).
    pub confirmation: Arc<dyn ToolConfirmation>,
    /// The shared conductor store — the ephemeral ToolHost's audit/receipts AND
    /// the delegation receipt land here (isolated JSONL, never `fae.db`).
    pub store: Arc<ConductorStore>,
    /// The control-plane identity the tool calls run as.
    pub client: ClientRecord,
    /// Resolved home dir, bounding the workspace blast-radius guard.
    pub home_dir: Option<PathBuf>,
    /// Cooperative cancellation (propagates to each tool's `InvokeContext`).
    pub cancel: CancellationToken,
    /// Per-request wall clock (the receipt timestamp).
    pub now_ms: u64,
    /// The process-global engine permit (permit = 1) serializing ALL generation.
    /// Shared across the whole fan-out tree.
    pub engine_permit: Arc<Semaphore>,
    /// The delegation-concurrency semaphore bounding live LEAF loops. Shared
    /// across the whole fan-out tree.
    pub leaf_permit: Arc<Semaphore>,
    /// The parent orchestrator's delegation id when THIS run is a spawned child;
    /// `None` at the top level. Recorded on the receipt to link child → parent.
    pub parent_id: Option<String>,
}

/// Run one native jailed delegation. Validation failures fail closed with
/// `Err` (nothing ran); a delegation that RAN — whether it completed, exhausted
/// its budget, or the engine failed mid-loop — returns `Ok` with a receipt.
pub async fn run_delegation(
    deps: &DelegationDeps,
    request: DelegationRequest,
) -> Result<DelegationOutcome, DelegationError> {
    // ── 1. Validate (fail closed BEFORE building anything) ────────────────────
    if request.depth > MAX_DEPTH {
        return Err(DelegationError::DepthExceeded(request.depth));
    }
    let prompt = request.prompt.trim().to_owned();
    if prompt.is_empty() {
        return Err(DelegationError::EmptyPrompt);
    }
    // The root is supplied by a trusted orchestrator, NEVER model output — but
    // validate defensively regardless (absolute, exists, dir, blast-radius-safe).
    validate_workspace_root(&request.workspace_root, deps.home_dir.as_deref())?;
    // Delegated origin REQUIRES the jail; refuse rather than degrade to host.
    if !jail_backend_available() {
        return Err(DelegationError::JailUnavailable);
    }

    // Fan-out is enabled ONLY for an orchestrator submitted at depth 0. A leaf
    // (or anything at depth ≥ 1) never gets the `delegate` tool in its schema
    // AND is runtime-rejected if it emits one — defense in depth.
    let fan_out_enabled = request.role == DelegationRole::Orchestrator && request.depth == 0;

    // ── 1b. Delegation-concurrency cap ────────────────────────────────────────
    // A LEAF loop holds one permit for its WHOLE run; an orchestrator holds NONE
    // (it only awaits children). Because a permit holder (a leaf) can never fan
    // out, the wait graph is acyclic — this is deadlock-free even at cap = 1: the
    // orchestrator waits on children, each child waits only on the leaf permit,
    // and the leaf permit is released by OTHER leaves that wait on nothing. We
    // never close the semaphore, so `acquire_owned` failing is unreachable in
    // practice; fail closed rather than `unwrap`.
    let _leaf_guard: Option<OwnedSemaphorePermit> = if fan_out_enabled {
        None
    } else {
        Some(
            Arc::clone(&deps.leaf_permit)
                .acquire_owned()
                .await
                .map_err(|_| DelegationError::PermitUnavailable)?,
        )
    };

    // ── 2. Budget (clamped daemon-side) ───────────────────────────────────────
    let mut budget = DelegationBudget::clamped(request.max_iterations, request.max_output_tokens);

    // ── 3. Ephemeral jailed ToolHost rooted at the validated workspace, WITHOUT
    //       the interactive `toolhost.set_root` confirm card (new_durable takes
    //       the owner-approved root directly). ────────────────────────────────
    let host = ToolHost::new_durable(
        request.workspace_root.clone(),
        Limits::default(),
        Arc::clone(&deps.store),
    )
    .await
    .map_err(|error| DelegationError::ToolHostBuild(error.to_string()))?;

    // ── 4. Child history + RESTRICTED tool schemas (only the toolset's tools;
    //       an orchestrator ALSO sees the synthetic `delegate` fan-out tool). ─
    let prompt_sha256 = sha256_hex(prompt.as_bytes());
    let mut tool_specs = build_tool_specs(&host, &request.toolset);
    if fan_out_enabled {
        tool_specs.push(delegate_tool_spec());
    }
    let system = delegated_worker_system_prompt();
    let mut history: Vec<ChatMessage> = vec![ChatMessage::text(Role::User, prompt.clone())];

    // ── 5. Loop ───────────────────────────────────────────────────────────────
    // Phase G1: the child history is the ONLY daemon-owned conversation state
    // that can outgrow the context window, so it is compacted between iterations.
    // The prompt budget is derived from the engine's real context window; the
    // watermark carries hysteresis so we do not re-summarize every turn.
    let prompt_budget = PromptBudget::new(deps.engine.describe().context_window);
    let mut watermark = Watermark::default();
    let start = Instant::now();
    let hash_prefix_len = prompt_sha256.len().min(12);
    let id = format!("del-{}-{}", deps.now_ms, &prompt_sha256[..hash_prefix_len]);
    let mut tool_events: Vec<DelegationToolEvent> = Vec::new();
    // The delegation ids of children this run spawned (orchestrator fan-out).
    let mut child_ids: Vec<String> = Vec::new();
    let mut final_text = String::new();
    // Default status if the loop hits its iteration cap without a final answer.
    let mut status = DelegationStatus::BudgetExhausted;

    for iteration in 0..budget.max_iterations {
        // CR-H2: stop between turns when the parent (or the transport
        // `session_cancel`) cancels — otherwise a disconnected orchestrator's
        // child would run its remaining turns to completion (orphaned engine
        // use). Checked at the loop top so cancellation is observed before the
        // next generation is issued.
        if deps.cancel.is_cancelled() {
            status = DelegationStatus::Cancelled;
            break;
        }
        if budget.tokens_remaining() == 0 {
            status = DelegationStatus::BudgetExhausted;
            break;
        }

        // Phase G1: compact the child history before this generation if it has
        // outgrown the prompt budget. Iteration 0's history is just the task, so
        // nothing is evictable until enough turns accumulate.
        if iteration > 0 {
            watermark.turns_since_summary = watermark.turns_since_summary.saturating_add(1);
            let plan = compaction::plan_compaction(&history, prompt_budget, watermark);
            if plan.recompute {
                let cutoff = plan.evict.len();
                if cutoff > 0 && cutoff < history.len() {
                    let evicted: Vec<ChatMessage> = history[..cutoff].to_vec();
                    // The SAME bounded summarizer path as `conversation.compact`.
                    // Hold the engine permit across the generation (serialize on
                    // the single local engine), then drop it before continuing.
                    let summary = {
                        let _gen = Arc::clone(&deps.engine_permit).acquire_owned().await.ok();
                        crate::session::summarize_conversation(deps.engine.as_ref(), evicted).await
                    };
                    if let Ok(summary_text) = summary {
                        // The summary generation's own output counts against the
                        // cumulative budget so compaction cannot mask overrun.
                        budget.tokens_used = budget
                            .tokens_used
                            .saturating_add(output_tokens(&summary_text));
                        let pinned = ChatMessage::text(
                            Role::User,
                            format!("[summary of earlier turns]\n{summary_text}"),
                        );
                        history.splice(..cutoff, std::iter::once(pinned));
                        watermark.turns_since_summary = 0;
                    }
                    // A summarizer failure is non-fatal: continue on the
                    // un-compacted history — the hard token/iteration budget
                    // still bounds the loop.
                }
            }
        }

        let per_turn = PER_TURN_MAX_TOKENS
            .min(budget.tokens_remaining() as usize)
            .max(1);
        let req = ChatRequest {
            system: Some(system.clone()),
            messages: history.clone(),
            tools: tool_specs.clone(),
            max_tokens: per_turn,
        };
        // The engine permit (permit = 1) is held ONLY across this generation
        // call — dropped at the end of this block, BEFORE tool execution — so a
        // parallel leaf can run its jailed tools while this one generates.
        let turn = {
            let _gen = match Arc::clone(&deps.engine_permit).acquire_owned().await {
                Ok(permit) => permit,
                Err(_) => {
                    status = DelegationStatus::Failed;
                    break;
                }
            };
            crate::session::run_turn(deps.engine.as_ref(), req).await
        };
        let turn = match turn {
            Ok(value) => value,
            Err(detail) => {
                eprintln!("fae-daemon: delegation turn failed: {detail}");
                status = DelegationStatus::Failed;
                break;
            }
        };
        budget.iterations_used = iteration + 1;
        let text = turn
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        budget.tokens_used = budget.tokens_used.saturating_add(output_tokens(&text));
        final_text = text.clone();

        let calls = turn
            .get("tool_calls")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        // Record the assistant turn so the model sees its own context next round.
        history.push(ChatMessage::text(
            Role::Assistant,
            assistant_record(&text, &calls),
        ));

        if calls.is_empty() {
            status = DelegationStatus::Completed;
            break;
        }

        for (idx, call) in calls.iter().enumerate() {
            let name = call
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let call_id = format!("{id}-i{iteration}-t{idx}");

            // The synthetic `delegate` fan-out tool is intercepted BEFORE the
            // ToolHost path (it is not a real tool). Available ONLY to an
            // orchestrator at depth 0; a leaf emitting it is runtime-rejected.
            if name == DELEGATE_TOOL {
                if fan_out_enabled {
                    let remaining_iters =
                        budget.max_iterations.saturating_sub(budget.iterations_used);
                    let args = parse_tool_arguments(call);
                    match run_fan_out(
                        deps,
                        &id,
                        &request.toolset,
                        &request.workspace_root,
                        request.depth + 1,
                        remaining_iters,
                        budget.tokens_remaining(),
                        &args,
                    )
                    .await
                    {
                        Ok(fan) => {
                            history.push(ChatMessage::text(Role::Tool, fan.result_text));
                            // Children's output tokens count against the parent's
                            // remaining budget so an orchestrator cannot spawn
                            // unbounded work.
                            budget.tokens_used =
                                budget.tokens_used.saturating_add(fan.child_tokens);
                            child_ids.extend(fan.child_ids);
                            tool_events.push(DelegationToolEvent {
                                tool: name,
                                mutation_receipt_id: None,
                                status: "ok".to_owned(),
                            });
                        }
                        Err(reason) => {
                            history.push(ChatMessage::text(Role::Tool, format!("error: {reason}")));
                            tool_events.push(DelegationToolEvent {
                                tool: name,
                                mutation_receipt_id: None,
                                status: "denied_batch".to_owned(),
                            });
                        }
                    }
                } else {
                    history.push(ChatMessage::text(
                        Role::Tool,
                        "error: the `delegate` tool is only available to an orchestrator at depth 0"
                            .to_owned(),
                    ));
                    tool_events.push(DelegationToolEvent {
                        tool: name,
                        mutation_receipt_id: None,
                        status: "denied_leaf_cannot_delegate".to_owned(),
                    });
                }
                continue;
            }

            if !tool_allowed(&request.toolset, &name) {
                history.push(ChatMessage::text(
                    Role::Tool,
                    format!("error: tool `{name}` is not in the delegated toolset"),
                ));
                tool_events.push(DelegationToolEvent {
                    tool: name,
                    mutation_receipt_id: None,
                    status: "denied_not_in_toolset".to_owned(),
                });
                continue;
            }

            let input = parse_tool_arguments(call);
            let tool_req = ToolHostRequest {
                client: deps.client.clone(),
                tool: name.clone(),
                input,
                call_id: call_id.clone(),
                cancel: deps.cancel.clone(),
                origin: ToolOrigin::Delegated,
            };
            match host
                .execute_governed(tool_req, deps.confirmation.as_ref())
                .await
            {
                Ok(result) => {
                    history.push(ChatMessage::text(Role::Tool, content_text(&result.output)));
                    let mutation_receipt_id = if is_mutating_tool(&name) {
                        Some(call_id)
                    } else {
                        None
                    };
                    tool_events.push(DelegationToolEvent {
                        tool: name,
                        mutation_receipt_id,
                        status: "ok".to_owned(),
                    });
                }
                Err(error) => {
                    history.push(ChatMessage::text(Role::Tool, format!("error: {error}")));
                    tool_events.push(DelegationToolEvent {
                        tool: name,
                        mutation_receipt_id: None,
                        status: tool_error_status(&error).to_owned(),
                    });
                }
            }
        }

        // Budget checks AFTER this iteration's tools: trip = partial receipt.
        if budget.iterations_used >= budget.max_iterations || budget.tokens_remaining() == 0 {
            status = DelegationStatus::BudgetExhausted;
            break;
        }
    }

    let receipt = DelegationReceipt {
        event_type: "delegation",
        id,
        ts_ms: deps.now_ms,
        role: request.role,
        parent_id: deps.parent_id.clone(),
        child_ids,
        prompt_sha256,
        toolset: request.toolset,
        iterations_used: budget.iterations_used,
        tokens_used: budget.tokens_used,
        tool_events,
        status,
        wall_ms: u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX),
    };
    // The loop already ran; unlike a pre-mutation receipt there is nothing to
    // roll back if the append fails, so surface loudly but still return.
    if let Err(error) = deps.store.append_delegation_receipt(&receipt) {
        eprintln!("fae-daemon: delegation receipt append failed: {error}");
    }

    Ok(DelegationOutcome {
        text: final_text,
        status,
        receipt,
    })
}

/// The delegated-worker system prompt: a small, task-focused instruction that
/// is deliberately NOT Fae's full companion persona — a delegated worker exists
/// to complete a bounded task with its permitted tools and report back.
fn delegated_worker_system_prompt() -> String {
    "You are a delegated worker completing a single bounded task. \
     Use only the tools you have been given. Work step by step: call a tool, \
     read its result, then decide the next step. When the task is done, reply \
     with a short final answer and no further tool calls. Be concise."
        .to_owned()
}

/// Build the RESTRICTED model tool schemas for `toolset` from the host's tool
/// definitions. A `ParameterSchema` that cannot serialize degrades to an empty
/// object rather than dropping the tool.
///
/// (#18) An `mcp:<server>:<tool>` name is NOT a fluers registry tool — it routes
/// to the governed MCP tier. Its raw JSON schema is emitted verbatim (MCP schemas
/// may not round-trip fluers `ParameterSchema`), and it surfaces ONLY when the
/// host's catalog declares + allowlists it — the SAME fail-closed gate
/// `ToolHost::execute_mcp` applies. The `Delegated` origin is already permitted for
/// MCP, so a declared tool in the toolset is genuinely callable; a name the catalog
/// does not hold (MCP absent or not declared) is dropped rather than advertised as a
/// tool the worker cannot actually invoke. No permission is widened: the toolset
/// still gates membership and the runtime `execute_mcp` gate still runs per call.
fn build_tool_specs(host: &ToolHost, toolset: &[String]) -> Vec<ToolSpec> {
    toolset
        .iter()
        .filter_map(|name| {
            if name.starts_with(MCP_TOOL_PREFIX) {
                return host.mcp_tool_spec(name).map(|spec| ToolSpec {
                    name: name.clone(),
                    description: spec.description,
                    parameters: spec.parameters,
                });
            }
            host.tool_definition(name).map(|def| ToolSpec {
                name: def.name,
                description: def.description,
                parameters: serde_json::to_value(&def.parameters)
                    .unwrap_or_else(|_| Value::Object(serde_json::Map::new())),
            })
        })
        .collect()
}

/// Is `name` in the delegated toolset?
fn tool_allowed(toolset: &[String], name: &str) -> bool {
    toolset.iter().any(|tool| tool == name)
}

/// One child spec inside an orchestrator's `delegate` batch. Deserialized from
/// the model's tool-call arguments (never trusted for the workspace root, which
/// is inherited from the parent).
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct DelegationBatchSpec {
    /// The child leaf's task.
    prompt: String,
    /// The child's toolset. Must be a SUBSET of the parent orchestrator's.
    #[serde(default)]
    toolset: Vec<String>,
    /// Requested child iteration cap (clamped ≤ parent remaining, then daemon
    /// ceiling).
    max_iterations: u32,
    /// Requested child token budget (clamped ≤ parent remaining, then ceiling).
    max_output_tokens: u32,
}

/// The aggregate result of one orchestrator fan-out.
struct FanOutResult {
    /// A JSON summary of each child's status + final text, fed back to the
    /// orchestrator as the `delegate` tool result.
    result_text: String,
    /// The spawned children's delegation ids (recorded on the orchestrator
    /// receipt as the batch).
    child_ids: Vec<String>,
    /// The children's combined approximate output tokens (debited from the
    /// parent's remaining budget).
    child_tokens: u32,
}

/// The synthetic fan-out tool schema, exposed ONLY in an orchestrator's tool
/// set. Its input is a `batch` array of child specs (bounded to
/// [`MAX_BATCH_SIZE`] at execution time).
fn delegate_tool_spec() -> ToolSpec {
    ToolSpec {
        name: DELEGATE_TOOL.to_owned(),
        description: format!(
            "Fan out to a batch of up to {MAX_BATCH_SIZE} child worker(s) that run in \
             parallel in the same workspace. Each child's `toolset` must be a subset of \
             yours. Use this to split independent sub-tasks; wait for all results, then \
             give your final answer."
        ),
        parameters: serde_json::json!({
            "type": "object",
            "properties": {
                "batch": {
                    "type": "array",
                    "maxItems": MAX_BATCH_SIZE,
                    "items": {
                        "type": "object",
                        "properties": {
                            "prompt": { "type": "string", "description": "the child's task" },
                            "toolset": {
                                "type": "array",
                                "items": { "type": "string" },
                                "description": "tools the child may use (subset of yours)"
                            },
                            "max_iterations": { "type": "integer" },
                            "max_output_tokens": { "type": "integer" }
                        },
                        "required": ["prompt", "max_iterations", "max_output_tokens"]
                    }
                }
            },
            "required": ["batch"]
        }),
    }
}

/// Parse the `delegate` tool arguments into a validated batch of child specs.
/// Accepts either `{ "batch": [...] }` or a bare array. Returns `Err(reason)`
/// (fed back to the model, NOT a hard delegation failure) on any shape,
/// batch-size, subset, or empty-prompt violation — validated up front so NO
/// child is spawned when the batch is malformed.
fn parse_batch(
    args: &Value,
    parent_toolset: &[String],
) -> Result<Vec<DelegationBatchSpec>, String> {
    let raw = match args.get("batch") {
        Some(value) => value.clone(),
        None if args.is_array() => args.clone(),
        None => return Err("delegate requires a `batch` array".to_owned()),
    };
    let batch: Vec<DelegationBatchSpec> = serde_json::from_value(raw)
        .map_err(|error| format!("malformed delegate batch: {error}"))?;
    if batch.is_empty() {
        return Err("delegate batch is empty".to_owned());
    }
    if batch.len() > MAX_BATCH_SIZE {
        return Err(format!(
            "delegate batch size {} exceeds the maximum of {MAX_BATCH_SIZE}",
            batch.len()
        ));
    }
    for spec in &batch {
        if spec.prompt.trim().is_empty() {
            return Err("a delegate child has an empty prompt".to_owned());
        }
        for tool in &spec.toolset {
            if tool == DELEGATE_TOOL {
                return Err("a delegate child toolset may not contain `delegate`".to_owned());
            }
            if !tool_allowed(parent_toolset, tool) {
                return Err(format!(
                    "child tool `{tool}` is not a subset of the parent toolset"
                ));
            }
        }
    }
    Ok(batch)
}

/// Fan out an orchestrator's batch: validate, spawn each child as a `Leaf` at
/// `child_depth` in the SAME `workspace_root` (budgets clamped ≤ the parent's
/// remaining), then join. `tokio::spawn` gives real parallelism so children
/// overlap tool-exec / jail I/O (generation is still serialized by the engine
/// permit). Each child shares the parent's semaphores + store + engine.
#[allow(clippy::too_many_arguments)]
async fn run_fan_out(
    deps: &DelegationDeps,
    parent_id: &str,
    parent_toolset: &[String],
    workspace_root: &Path,
    child_depth: u8,
    remaining_iterations: u32,
    remaining_tokens: u32,
    args: &Value,
) -> Result<FanOutResult, String> {
    let batch = parse_batch(args, parent_toolset)?;

    let child_count = batch.len();
    // CR-H2: spawn children into a `JoinSet` (not detached `tokio::spawn`
    // handles). If this future is dropped — the orchestrator was cancelled or
    // its transport task aborted — the `JoinSet`'s Drop ABORTS every child
    // instead of orphaning it to run to completion. Each child returns its
    // `idx` so ordered summaries survive out-of-order completion.
    let mut set: tokio::task::JoinSet<(usize, Result<DelegationOutcome, DelegationError>)> =
        tokio::task::JoinSet::new();
    for (idx, spec) in batch.into_iter().enumerate() {
        // Clamp child budgets to the parent's remaining (the child then applies
        // the daemon ceilings itself in `DelegationBudget::clamped`).
        let child_iters = clamp_child_budget(spec.max_iterations, remaining_iterations);
        let child_tokens = clamp_child_budget(spec.max_output_tokens, remaining_tokens);
        let child_req = DelegationRequest {
            prompt: spec.prompt,
            role: DelegationRole::Leaf,
            toolset: spec.toolset,
            workspace_root: workspace_root.to_path_buf(),
            max_iterations: child_iters,
            max_output_tokens: child_tokens,
            depth: child_depth,
        };
        let mut child_deps = deps.clone();
        child_deps.parent_id = Some(parent_id.to_owned());
        set.spawn(async move { (idx, boxed_delegation(child_deps, child_req).await) });
    }

    let mut ordered: Vec<Option<Value>> = vec![None; child_count];
    let mut child_ids = Vec::with_capacity(child_count);
    let mut child_tokens_total: u32 = 0;
    // Drain the set, but observe `deps.cancel` WHILE awaiting so an in-flight
    // fan-out is torn down promptly: the early `break` drops `set`, aborting
    // every child still running (CR-H2 — no orphaned run to completion).
    loop {
        let joined = tokio::select! {
            biased;
            () = deps.cancel.cancelled() => break,
            next = set.join_next() => next,
        };
        let Some(joined) = joined else { break };
        match joined {
            Ok((idx, Ok(outcome))) => {
                child_ids.push(outcome.receipt.id.clone());
                child_tokens_total = child_tokens_total.saturating_add(outcome.receipt.tokens_used);
                if let Some(slot) = ordered.get_mut(idx) {
                    *slot = Some(serde_json::json!({
                        "index": idx,
                        "status": outcome.status.as_str(),
                        "text": outcome.text,
                    }));
                }
            }
            Ok((idx, Err(error))) => {
                if let Some(slot) = ordered.get_mut(idx) {
                    *slot = Some(serde_json::json!({
                        "index": idx,
                        "status": "failed",
                        "error": error.to_string(),
                    }));
                }
            }
            Err(join_error) => {
                // A panicked/aborted child carries no `idx`; record it at the
                // first open slot so the summary count stays honest.
                if let Some(slot) = ordered.iter_mut().find(|s| s.is_none()) {
                    *slot = Some(serde_json::json!({
                        "status": "failed",
                        "error": format!("child task join error: {join_error}"),
                    }));
                }
            }
        }
    }
    let summaries: Vec<Value> = ordered.into_iter().flatten().collect();
    let result_text =
        serde_json::to_string(&summaries).unwrap_or_else(|_| "[child summaries]".to_owned());
    Ok(FanOutResult {
        result_text,
        child_ids,
        child_tokens: child_tokens_total,
    })
}

/// Clamp a child's requested budget to the parent's `remaining` — a child can
/// never be granted MORE than the parent has left. The floor of 1 keeps a child
/// meaningful even when the parent is nearly spent.
fn clamp_child_budget(requested: u32, remaining: u32) -> u32 {
    requested.min(remaining).max(1)
}

/// Box a recursive child delegation so it can be `tokio::spawn`ed. The async
/// block OWNS `deps` and borrows it only internally, so the returned future is
/// `'static`; boxing type-erases it, breaking the otherwise-infinite recursive
/// future type (an orchestrator's future would contain its children's).
fn boxed_delegation(
    deps: DelegationDeps,
    request: DelegationRequest,
) -> Pin<Box<dyn Future<Output = Result<DelegationOutcome, DelegationError>> + Send>> {
    Box::pin(async move { run_delegation(&deps, request).await })
}

/// The mutating tools that produce a mutation receipt (mirrors the private
/// `toolhost::is_mutating_tool`; a delegated tool event links to the receipt
/// only for these).
fn is_mutating_tool(name: &str) -> bool {
    matches!(name, "write" | "edit" | "bash")
}

/// Parse a `run_turn` tool call's `arguments` (a JSON string) into an input
/// value. A malformed / absent argument degrades to an empty object (the tool's
/// own required-key validation then rejects it).
fn parse_tool_arguments(call: &Value) -> Value {
    match call.get("arguments") {
        Some(Value::String(raw)) => {
            serde_json::from_str(raw).unwrap_or_else(|_| Value::Object(serde_json::Map::new()))
        }
        Some(other) => other.clone(),
        None => Value::Object(serde_json::Map::new()),
    }
}

/// Concatenate every text content block a tool returned (mirrors the headless
/// harness helper).
fn content_text(out: &ToolResult) -> String {
    out.content
        .iter()
        .filter_map(|value| value.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

/// A compact assistant-turn record for the child history: the visible text plus
/// a note of any tool names it called (so the next turn has continuity).
fn assistant_record(text: &str, calls: &[Value]) -> String {
    if calls.is_empty() {
        return text.to_owned();
    }
    let names = calls
        .iter()
        .filter_map(|call| call.get("name").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join(", ");
    if text.is_empty() {
        format!("[called tools: {names}]")
    } else {
        format!("{text}\n[called tools: {names}]")
    }
}

/// Approximate output tokens for a completed turn, as a saturating `u32` for the
/// cumulative budget. Delegates to the shared [`crate::compaction::estimate_tokens`]
/// (Phase G1) so budget accounting and compaction planning use one heuristic.
fn output_tokens(text: &str) -> u32 {
    u32::try_from(compaction::estimate_tokens(text)).unwrap_or(u32::MAX)
}

/// Map a ToolHost error to a delegation tool-event status label.
fn tool_error_status(error: &ToolHostError) -> &'static str {
    match error {
        ToolHostError::Denied(_) => "denied",
        ToolHostError::UnknownTool(_) => "unknown_tool",
        ToolHostError::Tool(_) => "tool_failed",
        ToolHostError::Sandbox(_) => "sandbox_error",
    }
}

/// Validate a delegation workspace root: absolute, exists, a directory, and
/// blast-radius-safe (not the home/system root, not a protected path — reuses
/// the same guard the interactive `toolhost.set_root` path uses).
fn validate_workspace_root(root: &Path, home_dir: Option<&Path>) -> Result<(), DelegationError> {
    if !root.is_absolute() {
        return Err(DelegationError::InvalidWorkspace(format!(
            "workspace root must be absolute: {}",
            root.display()
        )));
    }
    if !root.is_dir() {
        return Err(DelegationError::InvalidWorkspace(format!(
            "workspace root does not exist or is not a directory: {}",
            root.display()
        )));
    }
    if !is_safe_workspace_root(root, home_dir) {
        return Err(DelegationError::InvalidWorkspace(format!(
            "workspace root is too broad (home/system root) or protected: {}",
            root.display()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::toolhost::confirm::{ConfirmReply, ConfirmRequest};
    use async_trait::async_trait;
    use fae_control_plane::{ClientClass, Scope};
    use fae_engine::{AdapterInfo, ChatEvent, ChatStream, EngineError, MockAdapter};
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex as StdMutex;
    use std::time::{Duration, Instant};

    /// Auto-approving confirmation for tests (dangerous ops still fire their
    /// damage-control deny BEFORE the confirm is reached).
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

    fn client() -> ClientRecord {
        ClientRecord {
            client_id: "delegate-test".into(),
            class: ClientClass::TestHarness,
            scopes: [Scope::ToolExecuteSafe, Scope::ToolExecuteDangerous]
                .into_iter()
                .collect(),
            issued_at_ms: 0,
            expires_at_ms: u64::MAX,
            revoked_at_ms: None,
            display_name: "Delegate Test".into(),
        }
    }

    fn store_at(dir: &Path) -> Arc<ConductorStore> {
        Arc::new(ConductorStore::open(dir.join("store")).expect("store open"))
    }

    /// Build deps with fresh (unshared) semaphores — the common single-delegation
    /// case. Concurrency tests build deps manually to SHARE semaphores.
    fn deps(
        engine: Arc<dyn ProviderAdapter>,
        store: Arc<ConductorStore>,
        now_ms: u64,
    ) -> DelegationDeps {
        DelegationDeps {
            engine,
            confirmation: confirm(),
            store,
            client: client(),
            home_dir: None,
            cancel: CancellationToken::new(),
            now_ms,
            engine_permit: Arc::new(Semaphore::new(1)),
            leaf_permit: leaf_permit_with_cap(DEFAULT_DELEGATION_CONCURRENCY),
            parent_id: None,
        }
    }

    /// A completed-turn script: a final answer, no tool calls (1 iteration).
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

    /// A [`ProviderAdapter`] that routes each `stream_chat` to the FIRST keyed
    /// script whose key is a substring of the last user message, popping that
    /// key's FIFO. Concurrency-safe (each delegation selects by its own prompt),
    /// so an orchestrator + parallel children can be scripted deterministically
    /// even though they share one engine. Unmatched / exhausted ⇒ a bare answer.
    struct KeyedMock {
        scripts: StdMutex<Vec<(String, VecDeque<Vec<ChatEvent>>)>>,
    }

    impl KeyedMock {
        fn new(entries: Vec<(&str, Vec<Vec<ChatEvent>>)>) -> Arc<KeyedMock> {
            Arc::new(KeyedMock {
                scripts: StdMutex::new(
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

    /// A [`ProviderAdapter`] that records the [start, end] wall-clock interval of
    /// each generation (with a fixed delay) into a shared vec, then returns a
    /// bare final answer. Used to prove the engine permit serializes generation.
    struct TimedAdapter {
        intervals: Arc<StdMutex<Vec<(Instant, Instant)>>>,
        delay: Duration,
    }

    #[async_trait]
    impl ProviderAdapter for TimedAdapter {
        fn describe(&self) -> AdapterInfo {
            AdapterInfo {
                backend: "timed".into(),
                model_id: "timed".into(),
                context_window: 8192,
            }
        }
        async fn stream_chat(&self, _request: ChatRequest) -> Result<ChatStream, EngineError> {
            let start = Instant::now();
            tokio::time::sleep(self.delay).await;
            let end = Instant::now();
            self.intervals
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push((start, end));
            let events = final_answer("done").into_iter().map(Ok).collect::<Vec<_>>();
            Ok(Box::pin(futures_util::stream::iter(events)))
        }
    }

    // -- pure helpers -------------------------------------------------------

    #[test]
    fn toolset_allowlist_admits_only_named_tools() {
        let set = vec!["write".to_owned(), "read".to_owned()];
        assert!(tool_allowed(&set, "write"));
        assert!(tool_allowed(&set, "read"));
        assert!(!tool_allowed(&set, "bash"));
        assert!(!tool_allowed(&[], "write"));
    }

    #[test]
    fn budget_clamps_to_daemon_ceilings() {
        let over = DelegationBudget::clamped(999, 9_999_999);
        assert_eq!(over.max_iterations, MAX_ITERATIONS_CEILING);
        assert_eq!(over.max_output_tokens, TOKEN_CEILING);
        // Zero iterations floors to 1; a modest token budget passes through.
        let low = DelegationBudget::clamped(0, 100);
        assert_eq!(low.max_iterations, 1);
        assert_eq!(low.max_output_tokens, 100);
    }

    #[test]
    fn output_tokens_is_char_quarter_ceiling() {
        // The budget heuristic delegates to compaction::estimate_tokens.
        assert_eq!(output_tokens(""), 0);
        assert_eq!(output_tokens("abcd"), 1);
        assert_eq!(output_tokens("abcde"), 2);
    }

    /// A child budget can NEVER exceed the parent's remaining (floor 1).
    #[test]
    fn child_budget_is_clamped_to_parent_remaining() {
        // Requested far exceeds remaining ⇒ clamped down to remaining.
        assert_eq!(clamp_child_budget(1_000, 3), 3);
        // Requested below remaining ⇒ passes through.
        assert_eq!(clamp_child_budget(2, 10), 2);
        // Parent has nothing left ⇒ floor 1 keeps the child meaningful.
        assert_eq!(clamp_child_budget(50, 0), 1);
    }

    /// A child toolset must be a SUBSET of the parent's; a non-subset tool (or
    /// `delegate` itself) is rejected before any child spawns.
    #[test]
    fn parse_batch_rejects_subset_violation() {
        let args = serde_json::json!({
            "batch": [
                { "prompt": "x", "toolset": ["bash"], "max_iterations": 1, "max_output_tokens": 10 }
            ]
        });
        let err = parse_batch(&args, &["write".to_owned()]).expect_err("subset violation");
        assert!(err.contains("subset"), "unexpected reason: {err}");

        let nested = serde_json::json!({
            "batch": [
                { "prompt": "x", "toolset": ["delegate"], "max_iterations": 1, "max_output_tokens": 10 }
            ]
        });
        let err = parse_batch(&nested, &["delegate".to_owned(), "write".to_owned()])
            .expect_err("nested delegate rejected");
        assert!(err.contains("delegate"), "unexpected reason: {err}");
    }

    /// A batch larger than [`MAX_BATCH_SIZE`] is rejected.
    #[test]
    fn parse_batch_rejects_oversized_batch() {
        let child = serde_json::json!({ "prompt": "x", "toolset": [], "max_iterations": 1, "max_output_tokens": 10 });
        let batch: Vec<Value> = std::iter::repeat_n(child, MAX_BATCH_SIZE + 1).collect();
        let args = serde_json::json!({ "batch": batch });
        let err = parse_batch(&args, &[]).expect_err("oversized batch");
        assert!(err.contains("exceeds"), "unexpected reason: {err}");
    }

    #[test]
    fn parse_batch_accepts_subset_and_bare_array() {
        let obj = serde_json::json!({
            "batch": [
                { "prompt": "a", "toolset": ["write"], "max_iterations": 2, "max_output_tokens": 50 }
            ]
        });
        let parsed = parse_batch(&obj, &["write".to_owned(), "read".to_owned()]).expect("valid");
        assert_eq!(parsed.len(), 1);
        // A bare array (no `batch` wrapper) is also accepted.
        let bare = serde_json::json!([
            { "prompt": "a", "toolset": [], "max_iterations": 1, "max_output_tokens": 10 }
        ]);
        assert_eq!(parse_batch(&bare, &[]).expect("valid bare").len(), 1);
    }

    #[tokio::test]
    async fn depth_beyond_max_is_rejected() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let engine = Arc::new(MockAdapter::new("m"));
        let deps = deps(engine, store_at(tmp.path()), 1);
        let request = DelegationRequest {
            prompt: "do a thing".into(),
            role: DelegationRole::Leaf,
            toolset: vec!["write".into()],
            workspace_root: tmp.path().to_path_buf(),
            max_iterations: 4,
            max_output_tokens: 1000,
            depth: 2, // depth 1 (a leaf child) is allowed; depth 2 is not.
        };
        let err = run_delegation(&deps, request)
            .await
            .expect_err("depth>MAX_DEPTH rejected");
        assert!(matches!(err, DelegationError::DepthExceeded(2)));
        assert_eq!(err.code(), "delegation_depth_exceeded");
    }

    #[tokio::test]
    async fn empty_prompt_is_rejected() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let engine = Arc::new(MockAdapter::new("m"));
        let deps = deps(engine, store_at(tmp.path()), 1);
        let request = DelegationRequest {
            prompt: "   ".into(),
            role: DelegationRole::Leaf,
            toolset: vec![],
            workspace_root: tmp.path().to_path_buf(),
            max_iterations: 4,
            max_output_tokens: 1000,
            depth: 0,
        };
        assert!(matches!(
            run_delegation(&deps, request).await,
            Err(DelegationError::EmptyPrompt)
        ));
    }

    /// The receipt carries prompt_sha256, NEVER the raw prompt, and links the
    /// mutating write to a mutation-receipt id. Skips if the OS jail is
    /// unavailable on this host (Delegated origin requires it).
    #[tokio::test]
    async fn completed_delegation_receipt_shape_and_no_raw_prompt() {
        if !jail_backend_available() {
            eprintln!("skip: OS jail unavailable on this host");
            return;
        }
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path().join("ws");
        std::fs::create_dir_all(&root).expect("mkdir ws");

        // Iteration 1: write a file. Iteration 2: final answer.
        let engine = Arc::new(MockAdapter::scripted(
            "m",
            vec![
                tool_call(
                    "write",
                    "{\"path\":\"note.txt\",\"content\":\"hello-delegate\"}",
                ),
                final_answer("wrote the note"),
            ],
        ));
        let secret_prompt = "please write a note about SECRET-XYZZY";
        let deps = deps(engine, store_at(tmp.path()), 42);
        let request = DelegationRequest {
            prompt: secret_prompt.into(),
            role: DelegationRole::Leaf,
            toolset: vec!["write".into()],
            workspace_root: root.clone(),
            max_iterations: 8,
            max_output_tokens: 1000,
            depth: 0,
        };
        let outcome = run_delegation(&deps, request)
            .await
            .expect("delegation ran");
        assert_eq!(outcome.status, DelegationStatus::Completed);
        assert!(root.join("note.txt").exists(), "the delegated write landed");
        let receipt = &outcome.receipt;
        assert_eq!(receipt.prompt_sha256, sha256_hex(secret_prompt.as_bytes()));
        assert_eq!(receipt.iterations_used, 2);
        assert!(receipt.parent_id.is_none(), "a top-level run has no parent");
        assert!(receipt.child_ids.is_empty(), "a leaf spawns no children");
        // Exactly one tool event: the write, linked to a mutation receipt id.
        assert_eq!(receipt.tool_events.len(), 1);
        assert_eq!(receipt.tool_events[0].tool, "write");
        assert_eq!(receipt.tool_events[0].status, "ok");
        assert!(receipt.tool_events[0].mutation_receipt_id.is_some());
        // The serialized receipt must NOT leak the raw prompt.
        let json = serde_json::to_string(receipt).expect("serialize receipt");
        assert!(
            !json.contains("SECRET-XYZZY"),
            "raw prompt leaked into receipt"
        );
        assert!(json.contains(&receipt.prompt_sha256));
    }

    /// max_iterations = 1 with a tool call every turn trips budget_exhausted
    /// (partial receipt). Skips without the OS jail.
    #[tokio::test]
    async fn budget_exhaustion_trips_on_iteration_cap() {
        if !jail_backend_available() {
            eprintln!("skip: OS jail unavailable on this host");
            return;
        }
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path().join("ws");
        std::fs::create_dir_all(&root).expect("mkdir ws");
        // The single permitted iteration emits a tool call → never reaches a
        // final answer.
        let engine = Arc::new(MockAdapter::scripted(
            "m",
            vec![tool_call("write", "{\"path\":\"a.txt\",\"content\":\"x\"}")],
        ));
        let deps = deps(engine, store_at(tmp.path()), 7);
        let request = DelegationRequest {
            prompt: "loop forever".into(),
            role: DelegationRole::Leaf,
            toolset: vec!["write".into()],
            workspace_root: root,
            max_iterations: 1,
            max_output_tokens: 1000,
            depth: 0,
        };
        let outcome = run_delegation(&deps, request)
            .await
            .expect("delegation ran");
        assert_eq!(outcome.status, DelegationStatus::BudgetExhausted);
        assert_eq!(outcome.receipt.iterations_used, 1);
    }

    /// A mock that returns tool calls for the first `tool_iters` LOOP generations
    /// and a final answer after, plus a recognizable summary for any SUMMARIZER
    /// generation (distinguished by the summarizer system prompt). Its context
    /// window is tiny so the delegate's compaction path is exercised (Phase G1).
    struct CompactionMock {
        loop_calls: AtomicUsize,
        summarizer_calls: Arc<AtomicUsize>,
        tool_iters: usize,
        window: usize,
    }

    #[async_trait]
    impl ProviderAdapter for CompactionMock {
        fn describe(&self) -> AdapterInfo {
            AdapterInfo {
                backend: "compaction".into(),
                model_id: "compaction".into(),
                context_window: self.window,
            }
        }
        async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError> {
            let is_summarizer = request
                .system
                .as_deref()
                .is_some_and(|system| system.contains("Summarize this conversation"));
            let turn = if is_summarizer {
                self.summarizer_calls.fetch_add(1, Ordering::SeqCst);
                final_answer("earlier turns summarized")
            } else {
                let n = self.loop_calls.fetch_add(1, Ordering::SeqCst);
                if n < self.tool_iters {
                    tool_call("read", "{\"path\":\"note.txt\"}")
                } else {
                    final_answer("all done")
                }
            };
            let events = turn.into_iter().map(Ok).collect::<Vec<_>>();
            Ok(Box::pin(futures_util::stream::iter(events)))
        }
    }

    /// A long scripted delegation compacts its child history (a tiny context
    /// window forces the tail over budget) yet still completes within budget:
    /// the loop reaches its final answer and at least one summary was folded in.
    /// Skips without the OS jail (the loop runs real jailed tools).
    #[tokio::test]
    async fn long_history_compacts_and_loop_completes() {
        if !jail_backend_available() {
            eprintln!("skip: OS jail unavailable on this host");
            return;
        }
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path().join("ws");
        std::fs::create_dir_all(&root).expect("mkdir ws");
        // A large file so each `read` result inflates the child history past the
        // tiny window, tripping the tail-over-budget compaction path.
        std::fs::write(root.join("note.txt"), "x".repeat(2000)).expect("seed file");

        let summarizer_calls = Arc::new(AtomicUsize::new(0));
        let engine = Arc::new(CompactionMock {
            loop_calls: AtomicUsize::new(0),
            summarizer_calls: Arc::clone(&summarizer_calls),
            tool_iters: 12,
            window: 64, // ceiling 51 — a few big tool results exceed it fast.
        });
        let deps = deps(engine, store_at(tmp.path()), 99);
        let request = DelegationRequest {
            prompt: "read the note repeatedly".into(),
            role: DelegationRole::Leaf,
            toolset: vec!["read".into()],
            workspace_root: root,
            max_iterations: 16,
            max_output_tokens: 100_000,
            depth: 0,
        };
        let outcome = run_delegation(&deps, request)
            .await
            .expect("delegation ran");
        assert_eq!(outcome.status, DelegationStatus::Completed);
        assert_eq!(outcome.text, "all done");
        assert!(
            summarizer_calls.load(Ordering::SeqCst) > 0,
            "compaction must have folded earlier turns into at least one summary"
        );
    }

    /// A leaf at depth 1 that emits the `delegate` tool is runtime-rejected (the
    /// tool is not even in its schema, but defense-in-depth rejects it anyway),
    /// and no children are spawned. Skips without the OS jail.
    #[tokio::test]
    async fn depth_one_leaf_cannot_delegate() {
        if !jail_backend_available() {
            eprintln!("skip: OS jail unavailable on this host");
            return;
        }
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path().join("ws");
        std::fs::create_dir_all(&root).expect("mkdir ws");
        // A leaf whose (misbehaving) model emits a delegate tool call, then a
        // final answer.
        let engine = Arc::new(MockAdapter::scripted(
            "m",
            vec![
                tool_call(
                    "delegate",
                    "{\"batch\":[{\"prompt\":\"x\",\"toolset\":[],\"max_iterations\":1,\"max_output_tokens\":10}]}",
                ),
                final_answer("cannot delegate"),
            ],
        ));
        let deps = deps(engine, store_at(tmp.path()), 9);
        let request = DelegationRequest {
            prompt: "try to delegate as a leaf".into(),
            role: DelegationRole::Leaf,
            toolset: vec![],
            workspace_root: root,
            max_iterations: 4,
            max_output_tokens: 1000,
            depth: 1,
        };
        let outcome = run_delegation(&deps, request)
            .await
            .expect("delegation ran");
        assert!(outcome.receipt.child_ids.is_empty(), "no children spawned");
        let event = outcome
            .receipt
            .tool_events
            .iter()
            .find(|e| e.tool == "delegate")
            .expect("a delegate tool event was recorded");
        assert_eq!(event.status, "denied_leaf_cannot_delegate");
    }

    /// The engine permit (permit = 1) serializes generation: two concurrent
    /// leaf delegations sharing one engine permit must NOT overlap their
    /// generation intervals, even though their leaf permits allow both loops to
    /// be live. Skips without the OS jail (run_delegation requires it).
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn engine_permit_serializes_generation() {
        if !jail_backend_available() {
            eprintln!("skip: OS jail unavailable on this host");
            return;
        }
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path().join("ws");
        std::fs::create_dir_all(&root).expect("mkdir ws");
        let store = store_at(tmp.path());

        let intervals = Arc::new(StdMutex::new(Vec::new()));
        let engine: Arc<dyn ProviderAdapter> = Arc::new(TimedAdapter {
            intervals: Arc::clone(&intervals),
            delay: Duration::from_millis(80),
        });
        // ONE shared engine permit (the point of the test); a wide leaf pool so
        // both loops are live concurrently.
        let engine_permit = Arc::new(Semaphore::new(1));
        let leaf_permit = leaf_permit_with_cap(MAX_DELEGATION_CONCURRENCY);
        let mk = |now: u64| DelegationDeps {
            engine: Arc::clone(&engine),
            confirmation: confirm(),
            store: Arc::clone(&store),
            client: client(),
            home_dir: None,
            cancel: CancellationToken::new(),
            now_ms: now,
            engine_permit: Arc::clone(&engine_permit),
            leaf_permit: Arc::clone(&leaf_permit),
            parent_id: None,
        };
        let req = |prompt: &str| DelegationRequest {
            prompt: prompt.into(),
            role: DelegationRole::Leaf,
            toolset: vec![],
            workspace_root: root.clone(),
            max_iterations: 1,
            max_output_tokens: 100,
            depth: 0,
        };
        let d1 = mk(1);
        let d2 = mk(2);
        let (r1, r2) = tokio::join!(
            run_delegation(&d1, req("alpha")),
            run_delegation(&d2, req("beta")),
        );
        r1.expect("delegation 1 ran");
        r2.expect("delegation 2 ran");

        let mut ivals = intervals
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        assert_eq!(ivals.len(), 2, "each delegation generated exactly once");
        ivals.sort_by_key(|(start, _)| *start);
        assert!(
            ivals[0].1 <= ivals[1].0,
            "generation intervals overlapped — engine permit did not serialize: {:?} vs {:?}",
            ivals[0],
            ivals[1]
        );
    }

    /// No starvation at cap = 1: an orchestrator that fans out two leaves must
    /// complete even when the delegation-concurrency pool has a SINGLE permit.
    /// The orchestrator holds NO permit (it only awaits children), so the two
    /// leaves take the single permit in turn and both finish. A hard timeout
    /// converts any deadlock into a test failure. Skips without the OS jail.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn orchestrator_fan_out_no_deadlock_at_cap_one() {
        if !jail_backend_available() {
            eprintln!("skip: OS jail unavailable on this host");
            return;
        }
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path().join("ws");
        std::fs::create_dir_all(&root).expect("mkdir ws");

        let engine: Arc<dyn ProviderAdapter> = KeyedMock::new(vec![
            (
                "ORCH",
                vec![
                    tool_call(
                        "delegate",
                        "{\"batch\":[\
                         {\"prompt\":\"CHILD-A answer\",\"toolset\":[],\"max_iterations\":2,\"max_output_tokens\":100},\
                         {\"prompt\":\"CHILD-B answer\",\"toolset\":[],\"max_iterations\":2,\"max_output_tokens\":100}]}",
                    ),
                    final_answer("both children finished"),
                ],
            ),
            ("CHILD-A", vec![final_answer("child A done")]),
            ("CHILD-B", vec![final_answer("child B done")]),
        ]);

        let deps = DelegationDeps {
            engine,
            confirmation: confirm(),
            store: store_at(tmp.path()),
            client: client(),
            home_dir: None,
            cancel: CancellationToken::new(),
            now_ms: 100,
            engine_permit: Arc::new(Semaphore::new(1)),
            leaf_permit: leaf_permit_with_cap(1), // the starvation stress
            parent_id: None,
        };
        let request = DelegationRequest {
            prompt: "ORCH split the work".into(),
            role: DelegationRole::Orchestrator,
            toolset: vec![],
            workspace_root: root,
            max_iterations: 4,
            max_output_tokens: 5000,
            depth: 0,
        };
        let outcome = tokio::time::timeout(Duration::from_secs(20), run_delegation(&deps, request))
            .await
            .expect("fan-out completed (no deadlock at cap=1)")
            .expect("delegation ran");
        assert_eq!(outcome.status, DelegationStatus::Completed);
        assert_eq!(
            outcome.receipt.child_ids.len(),
            2,
            "the orchestrator receipt records both children"
        );
    }

    /// (#18) `build_tool_specs` surfaces an `mcp:` tool's raw schema into the
    /// delegate loop's tool list ONLY when the host's catalog declares +
    /// allowlists it — the same fail-closed gate `execute_mcp` applies. A tool the
    /// catalog does not hold (offered but not allowlisted, or MCP absent entirely)
    /// must NOT appear even when named in the toolset, so a delegated turn is never
    /// advertised a tool it cannot actually invoke. No permission is widened.
    #[tokio::test]
    async fn build_tool_specs_surfaces_mcp_only_when_declared() {
        use crate::mcp::{catalog_from_mock, MockConn};

        let dir = tempfile::tempdir().expect("tempdir");
        let store = store_at(dir.path());
        let host = ToolHost::new_durable(dir.path().to_path_buf(), Limits::default(), store)
            .await
            .expect("host build");

        // The mock server offers `echo` (allowlisted) + `secret` (offered but NOT
        // allowlisted → never enters the catalog, mirroring a policy that does not
        // permit the Delegated origin for it).
        let conn = MockConn::new(
            "fs",
            vec![("echo", "echo it back"), ("secret", "must not leak")],
            "mcp-result",
        );
        let catalog = Arc::new(catalog_from_mock("fs", conn, &["echo"]).await);
        let host = host.with_mcp_catalog(catalog);

        let toolset = vec![
            "mcp:fs:echo".to_owned(),   // declared + allowlisted → surfaces
            "mcp:fs:secret".to_owned(), // offered but not allowlisted → dropped
            "read".to_owned(),          // a normal fluers registry tool
        ];
        let specs = build_tool_specs(&host, &toolset);

        let echo = specs
            .iter()
            .find(|s| s.name == "mcp:fs:echo")
            .expect("a declared+allowlisted mcp tool must surface");
        assert_eq!(echo.description, "echo it back");
        // The raw MCP input schema is emitted verbatim (the mock lists this).
        assert_eq!(echo.parameters, serde_json::json!({"type": "object"}));

        assert!(
            specs.iter().all(|s| s.name != "mcp:fs:secret"),
            "a non-declared mcp tool must NOT surface even when named in the toolset"
        );
        assert!(
            specs.iter().any(|s| s.name == "read"),
            "a normal fluers registry tool still surfaces alongside mcp tools"
        );

        // A host with NO catalog drops the SAME declared name (execute_mcp would
        // deny `mcp_not_configured`), proving the schema path is catalog-gated.
        let bare = ToolHost::new_durable(
            dir.path().to_path_buf(),
            Limits::default(),
            store_at(dir.path()),
        )
        .await
        .expect("bare host build");
        let bare_specs = build_tool_specs(&bare, &["mcp:fs:echo".to_owned()]);
        assert!(
            bare_specs.is_empty(),
            "with no MCP catalog, an mcp: tool must not be advertised"
        );
    }

    /// A [`ProviderAdapter`] for the CR-H2 cancellation test: an orchestrator
    /// prompt returns a fan-out tool call immediately; each CHILD prompt SLEEPS
    /// for `child_delay` before recording completion. A child that is aborted
    /// mid-sleep never reaches the increment.
    struct SlowChildMock {
        completed: Arc<AtomicUsize>,
        child_delay: Duration,
    }

    #[async_trait]
    impl ProviderAdapter for SlowChildMock {
        fn describe(&self) -> AdapterInfo {
            AdapterInfo {
                backend: "slow-child".into(),
                model_id: "slow-child".into(),
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
            let turn = if last_user.contains("ORCH") {
                tool_call(
                    "delegate",
                    "{\"batch\":[\
                     {\"prompt\":\"CHILD-A slow\",\"toolset\":[],\"max_iterations\":2,\"max_output_tokens\":100},\
                     {\"prompt\":\"CHILD-B slow\",\"toolset\":[],\"max_iterations\":2,\"max_output_tokens\":100}]}",
                )
            } else {
                // A child generation completes only AFTER the delay, so an
                // aborted child never records completion.
                tokio::time::sleep(self.child_delay).await;
                self.completed.fetch_add(1, Ordering::SeqCst);
                final_answer("child done")
            };
            let events = turn.into_iter().map(Ok).collect::<Vec<_>>();
            Ok(Box::pin(futures_util::stream::iter(events)))
        }
    }

    /// CR-H2: a cancelled parent (orchestrator) delegation must ABORT its
    /// in-flight children, not orphan them to run to completion. The children
    /// sleep far longer than the cancel deadline; the fix converts the fan-out
    /// spawns to a `JoinSet` whose drop aborts them, plus a loop-top cancel
    /// check that ends the delegation between turns. Skips without the OS jail
    /// (`run_delegation` requires it).
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn cancelled_parent_aborts_in_flight_children() {
        if !jail_backend_available() {
            eprintln!("skip: OS jail unavailable on this host");
            return;
        }
        let tmp = tempfile::tempdir().expect("tempdir");
        let root = tmp.path().join("ws");
        std::fs::create_dir_all(&root).expect("mkdir ws");

        let completed = Arc::new(AtomicUsize::new(0));
        let engine: Arc<dyn ProviderAdapter> = Arc::new(SlowChildMock {
            completed: Arc::clone(&completed),
            child_delay: Duration::from_secs(30),
        });

        let deps = DelegationDeps {
            engine,
            confirmation: confirm(),
            store: store_at(tmp.path()),
            client: client(),
            home_dir: None,
            cancel: CancellationToken::new(),
            now_ms: 100,
            engine_permit: Arc::new(Semaphore::new(1)),
            leaf_permit: leaf_permit_with_cap(DEFAULT_DELEGATION_CONCURRENCY),
            parent_id: None,
        };
        let request = DelegationRequest {
            prompt: "ORCH split the work".into(),
            role: DelegationRole::Orchestrator,
            toolset: vec![],
            workspace_root: root,
            max_iterations: 4,
            max_output_tokens: 5000,
            depth: 0,
        };

        // Cancel shortly after the children start their long generation.
        let canceller = deps.cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            canceller.cancel();
        });

        let start = Instant::now();
        let outcome = tokio::time::timeout(Duration::from_secs(10), run_delegation(&deps, request))
            .await
            .expect("cancelled delegation must return well before the 30s child sleep")
            .expect("delegation ran");
        let elapsed = start.elapsed();

        assert_eq!(
            outcome.status,
            DelegationStatus::Cancelled,
            "a parent cancelled mid-fan-out reports Cancelled"
        );
        assert_eq!(
            completed.load(Ordering::SeqCst),
            0,
            "no child ran to completion — in-flight children were aborted, not orphaned"
        );
        assert!(
            elapsed < Duration::from_secs(10),
            "teardown was prompt (elapsed {elapsed:?}), not blocked on the child sleep"
        );
    }
}
