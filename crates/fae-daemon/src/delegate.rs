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
//! Commit-1 scope: `role` (Leaf/Orchestrator) is CARRIED into the receipt but
//! Leaf and Orchestrator behave identically here — fan-out lands in commit 2,
//! which is also why `depth > 0` is rejected for now.
//!
//! The receipt records `prompt_sha256`, **never the raw prompt**, and lands in
//! the conductor store's isolated JSONL (`delegation_receipts.jsonl`), never
//! `fae.db`.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use fae_control_plane::ClientRecord;
use fae_engine::{ChatMessage, ChatRequest, ProviderAdapter, Role, ToolSpec};
use fluers_core::tool::ToolResult;
use fluers_runtime::Limits;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

use crate::conductor::ConductorStore;
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
/// The plan calls for `tokens ≤ engine context / 2`. The daemon's
/// [`ProviderAdapter`] does not (yet) surface a context size, so this is a
/// conservative fixed fallback (a plausible half-context for a 64K-context
/// model). When `AdapterInfo` carries the real context window, derive this from
/// it. Output tokens are APPROXIMATED (see [`approx_output_tokens`]).
pub const TOKEN_CEILING: u32 = 32_768;

/// Per-turn generation cap. Each iteration's `max_tokens` is the smaller of this
/// and the delegation's remaining token budget.
const PER_TURN_MAX_TOKENS: usize = 4096;

/// Whether a delegated agent fans out to child workers. Commit-1 carries this
/// into the receipt but treats both identically (fan-out = commit 2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DelegationRole {
    /// A leaf worker: runs tools, returns a result. No children.
    #[default]
    Leaf,
    /// An orchestrator: (commit 2) fans out to child delegations. Commit-1
    /// behaves identically to [`Leaf`](DelegationRole::Leaf).
    Orchestrator,
}

/// A request to run one native jailed delegation.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DelegationRequest {
    /// The task for the delegated worker.
    pub prompt: String,
    /// Leaf vs Orchestrator (identical in commit 1).
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
    /// Nesting depth. Commit-1 rejects anything `> 0` (commit 2 raises it).
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
}

impl DelegationStatus {
    /// Wire label.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            DelegationStatus::Completed => "completed",
            DelegationStatus::BudgetExhausted => "budget_exhausted",
            DelegationStatus::Failed => "failed",
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
    /// Leaf vs Orchestrator (identical behaviour in commit 1).
    pub role: DelegationRole,
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
    /// `depth > 0` — fan-out lands in commit 2.
    #[error("delegation depth {0} exceeds the commit-1 maximum of 0 (fan-out lands in commit 2)")]
    DepthExceeded(u8),
    /// The prompt was empty/whitespace.
    #[error("delegation prompt is empty")]
    EmptyPrompt,
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
            DelegationError::InvalidWorkspace(_) => "unsafe_root",
            DelegationError::JailUnavailable => "jail_unavailable",
            DelegationError::ToolHostBuild(_) => "sandbox_error",
        }
    }
}

/// The backends a delegation needs. Borrowed for the duration of the loop.
pub struct DelegationDeps<'a> {
    /// The inference engine (drives each iteration's turn).
    pub engine: &'a dyn ProviderAdapter,
    /// The tool-confirmation channel (dangerous ops still round-trip to the
    /// owner; the caller spawns delegation off the read loop so the reply routes).
    pub confirmation: &'a dyn ToolConfirmation,
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
}

/// Run one native jailed delegation. Validation failures fail closed with
/// `Err` (nothing ran); a delegation that RAN — whether it completed, exhausted
/// its budget, or the engine failed mid-loop — returns `Ok` with a receipt.
pub async fn run_delegation(
    deps: &DelegationDeps<'_>,
    request: DelegationRequest,
) -> Result<DelegationOutcome, DelegationError> {
    // ── 1. Validate (fail closed BEFORE building anything) ────────────────────
    if request.depth > 0 {
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

    // ── 4. Child history + RESTRICTED tool schemas (only the toolset's tools) ─
    let prompt_sha256 = sha256_hex(prompt.as_bytes());
    let tool_specs = build_tool_specs(&host, &request.toolset);
    let system = delegated_worker_system_prompt();
    let mut history: Vec<ChatMessage> = vec![ChatMessage::text(Role::User, prompt.clone())];

    // ── 5. Loop ───────────────────────────────────────────────────────────────
    let start = Instant::now();
    let hash_prefix_len = prompt_sha256.len().min(12);
    let id = format!("del-{}-{}", deps.now_ms, &prompt_sha256[..hash_prefix_len]);
    let mut tool_events: Vec<DelegationToolEvent> = Vec::new();
    let mut final_text = String::new();
    // Default status if the loop hits its iteration cap without a final answer.
    let mut status = DelegationStatus::BudgetExhausted;

    for iteration in 0..budget.max_iterations {
        if budget.tokens_remaining() == 0 {
            status = DelegationStatus::BudgetExhausted;
            break;
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
        let turn = match crate::session::run_turn(deps.engine, req).await {
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
        budget.tokens_used = budget
            .tokens_used
            .saturating_add(approx_output_tokens(&text));
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
            match host.execute_governed(tool_req, deps.confirmation).await {
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
fn build_tool_specs(host: &ToolHost, toolset: &[String]) -> Vec<ToolSpec> {
    host.tool_definitions(toolset)
        .into_iter()
        .map(|def| ToolSpec {
            name: def.name,
            description: def.description,
            parameters: serde_json::to_value(&def.parameters)
                .unwrap_or_else(|_| Value::Object(serde_json::Map::new())),
        })
        .collect()
}

/// Is `name` in the delegated toolset?
fn tool_allowed(toolset: &[String], name: &str) -> bool {
    toolset.iter().any(|tool| tool == name)
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

/// Approximate output tokens for a completed turn. The engine does not surface a
/// token count, so this is a documented heuristic (~4 chars/token). It only
/// gates the cumulative budget — an approximation is acceptable there.
fn approx_output_tokens(text: &str) -> u32 {
    u32::try_from(text.chars().count().div_ceil(4)).unwrap_or(u32::MAX)
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
    use fae_engine::{ChatEvent, MockAdapter};

    /// Auto-approving confirmation for tests (dangerous ops still fire their
    /// damage-control deny BEFORE the confirm is reached).
    struct AutoApprove;
    #[async_trait]
    impl ToolConfirmation for AutoApprove {
        async fn confirm(&self, _req: &ConfirmRequest) -> ConfirmReply {
            ConfirmReply::Approved
        }
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
    fn approx_tokens_is_char_quarter_ceiling() {
        assert_eq!(approx_output_tokens(""), 0);
        assert_eq!(approx_output_tokens("abcd"), 1);
        assert_eq!(approx_output_tokens("abcde"), 2);
    }

    #[tokio::test]
    async fn depth_greater_than_zero_is_rejected() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let engine = MockAdapter::new("m");
        let confirm = AutoApprove;
        let deps = DelegationDeps {
            engine: &engine,
            confirmation: &confirm,
            store: store_at(tmp.path()),
            client: client(),
            home_dir: None,
            cancel: CancellationToken::new(),
            now_ms: 1,
        };
        let request = DelegationRequest {
            prompt: "do a thing".into(),
            role: DelegationRole::Leaf,
            toolset: vec!["write".into()],
            workspace_root: tmp.path().to_path_buf(),
            max_iterations: 4,
            max_output_tokens: 1000,
            depth: 1,
        };
        let err = run_delegation(&deps, request)
            .await
            .expect_err("depth>0 rejected");
        assert!(matches!(err, DelegationError::DepthExceeded(1)));
        assert_eq!(err.code(), "delegation_depth_exceeded");
    }

    #[tokio::test]
    async fn empty_prompt_is_rejected() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let engine = MockAdapter::new("m");
        let confirm = AutoApprove;
        let deps = DelegationDeps {
            engine: &engine,
            confirmation: &confirm,
            store: store_at(tmp.path()),
            client: client(),
            home_dir: None,
            cancel: CancellationToken::new(),
            now_ms: 1,
        };
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
        let engine = MockAdapter::scripted(
            "m",
            vec![
                vec![
                    ChatEvent::ToolCall {
                        name: "write".into(),
                        arguments: "{\"path\":\"note.txt\",\"content\":\"hello-delegate\"}".into(),
                    },
                    ChatEvent::Done {
                        finish_reason: "tool_calls".into(),
                    },
                ],
                vec![
                    ChatEvent::Token("wrote the note".into()),
                    ChatEvent::Done {
                        finish_reason: "stop".into(),
                    },
                ],
            ],
        );
        let confirm = AutoApprove;
        let secret_prompt = "please write a note about SECRET-XYZZY";
        let deps = DelegationDeps {
            engine: &engine,
            confirmation: &confirm,
            store: store_at(tmp.path()),
            client: client(),
            home_dir: None,
            cancel: CancellationToken::new(),
            now_ms: 42,
        };
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
        let engine = MockAdapter::scripted(
            "m",
            vec![vec![
                ChatEvent::ToolCall {
                    name: "write".into(),
                    arguments: "{\"path\":\"a.txt\",\"content\":\"x\"}".into(),
                },
                ChatEvent::Done {
                    finish_reason: "tool_calls".into(),
                },
            ]],
        );
        let confirm = AutoApprove;
        let deps = DelegationDeps {
            engine: &engine,
            confirmation: &confirm,
            store: store_at(tmp.path()),
            client: client(),
            home_dir: None,
            cancel: CancellationToken::new(),
            now_ms: 7,
        };
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
}
