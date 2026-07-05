# Fae Changelog

Detailed version history moved from CLAUDE.md. For current architecture, see `CLAUDE.md`.

## Unreleased — UX Wave 2 (structural credential withholding + memory-capture redaction)

### Security
- **Structural credential detector (`SensitiveDataRedactor.looksLikeCredential`)**: extends
  `SensitiveDataRedactor` with a boolean detector that classifies a value as a probable
  credential via three signal classes: known provider prefixes (sk-, ghp_, AIza, xox[baprs]-),
  high-entropy heuristic (≥ 20 compact alphanumeric chars, no whitespace), and request-context
  hint (prompt/title contains a credential keyword + value ≥ 8 chars no spaces).
- **Structural withholding in `InputRequestTool.execute`**: before any raw value is returned to
  the LLM, `looksLikeCredential` runs against the value and the combined prompt+title hint.
  If it fires and no `store_key` is set, the value is discarded and the model receives an
  instructive error directing it to re-ask with `secure:true` and `store_key:<name>`. This
  fires even when the model sets `secure:false` or `returnToModel:true` — protection is
  structural, not model-driven.
- **Memory-capture redaction choke point (`MemoryOrchestrator.capture`)**: the existing
  `SensitiveContentPolicy.redactForStorage` pass is now composed with
  `SensitiveDataRedactor.redact` at lines 617–620, forming a two-layer redaction at the single
  authority point used by all nine capture steps. Neither layer's gap can allow a raw credential
  to reach durable SQLite storage.
- **Prompt rule (`PersonalityManager`)**: new SECRETS RULE bullet in the tools-available prompt
  section instructs the model to always use `input_request(secure:true, store_key:<name>)` for
  API keys/passwords/tokens, never ask the user to speak a secret aloud, and refer to stored
  credentials only by key name.

### Testing
- `Tests/HandoffTests/CredentialWithholdingTests.swift`: 20 tests across three suites —
  `CredentialDetectorTests` (known-prefix positives, entropy heuristic, hint-context, negatives),
  `InputRequestWithholdPathTests` (withhold message contract, secure+returnToModel coverage,
  store_key bypass), `MemoryCaptureRedactionTests` (sk-, ghp_, high-entropy, normal text,
  composed two-layer chain).

## Unreleased — Phase G commit 2 (main-lane pinned-summary compression)

### New Features
- **Daemon pinned-summary prompt assembly (`crates/fae-daemon/src/session.rs`)**: `conversation.inject_text` now accepts an optional `pinned_summary` string. `parse_chat_request` folds it — via the single assembly authority `assemble_system_with_pinned` — into the system prompt as ONE stable block (`PINNED_SUMMARY_HEADER` + summary) placed immediately after the base system text, before the retained turns. Absent (or all-whitespace, normalized by `payload_pinned_summary`) ⇒ the request is byte-identical to today's, so a non-compacted turn is unchanged. The interactive-path telemetry (`context.last_turn`) now reports `compacted: true` + `pinned_summary_tokens` exactly when the turn carried a non-empty summary.
- **Cache-stability rule (documented + tested)**: the assembled prompt prefix is `system ++ pinned_summary ++ kept_turns`; between recompactions `system` and `pinned_summary` are byte-identical and `kept_turns` only appends, so the mistral.rs / llama.cpp prefix cache keeps hitting on the `system ++ pinned` head — the reason the summary is pinned rather than re-threaded. Documented on `assemble_system_with_pinned` and in the `compaction` module header.
- **Swift main-lane compression protocol**: `GenerationOptions.pinnedSummary` rides the daemon `inject_text` payload as `pinned_summary` (`DaemonWire.injectTextPayload`; the audio pass-1 transcription drops it — reasoning context only). `LLMEngine.compactConversation(evicted:priorSummary:)` (default no-op; the daemon lane sends `conversation.compact` and returns the cumulative summary, folding a prior summary in first). `ConversationStateTracker` now BUFFERS turns evicted at the `recommendedMaxHistory` trim site instead of dropping them silently: the current turn proceeds on the hard-truncated window (never blocks on summarization — ttfa guard), and `PipelineCoordinator` fires an after-turn, reentrancy-guarded `conversation.compact` (off the hot path) that installs a pinned summary resent on subsequent turns. Recompaction is gated by a caller-side hysteresis watermark mirroring the daemon's `RECOMPUTE_EVICTION_THRESHOLD = 8` (the first summary is never gated, so evicted turns are never silently lost). On any compact failure or an engine without a summarizer: hard-truncate + loud `NSLog`, retain the backlog for retry, never block, never drop silently.

### Testing
- **`session.rs`**: `parse_chat_request_pinned_summary_folds_after_system` (base system first, header + summary appended, kept turns untouched); the MANDATORY `parse_chat_request_pinned_summary_prefix_is_byte_stable_across_turns` (two turns sharing system + pinned but differing by one appended user turn have a BYTE-IDENTICAL `system ++ pinned` prefix and append-only kept turns); `parse_chat_request_absent_or_blank_pinned_summary_is_byte_identical` (back-compat).
- **Swift**: `DaemonWireTests` — payload carries `pinned_summary` when cached, omits the key when absent or all-whitespace. `ConversationStateTaggingTests` — evicted turns are buffered (not dropped), applying a result installs the summary + drains the backlog, hysteresis gates recompaction (first summary immediate; re-compaction waits for the watermark and folds on the prior summary), and the fallback invariant (a failed compaction leaves the hard-truncated window + retains the backlog). `ConversationCompactionEngineTests` — a compact error leaves turn state intact and retains the backlog; success installs the summary via the engine; an engine without a summarizer returns nil.

## Unreleased — Phase G commit 3 (MCP as a governed external tool tier)

### New Features
- **External MCP servers as a governed ToolHost tool source (`crates/fae-daemon/src/mcp/`)**: declared MCP (Model Context Protocol) servers become a THIRD tool source alongside the host + jailed fluers registries, exposed as `mcp:<server>:<tool>` names routed through `ToolHost::execute_governed`. **Honest trust model: MCP servers are external trusted subprocesses — the OS jail does NOT confine them.** The whole gate is *declaration + allowlist + scope + origin*: only servers named in `FAE_MCP_CONFIG` are spawned; only per-server `allowed_tools` enter the catalog; the ToolHost re-checks the new `Scope::McpInvoke` per call (inner gate behind the `toolhost.execute → ToolExecuteSafe` envelope); and only `OwnerInteractive`/`Delegated` origins may invoke (proactive/scheduler/auto-skill/script-block deny fail-closed — an autonomous loop must never reach an unconfined external process). Every decision writes an audit row stamped `isolation:"external"` (NOT `host`/`jailed`); an allowed call also records a mutation-style receipt naming the external server before invocation. Per-call timeout (30s); a server crash surfaces a typed `McpError::Invoke`.
- **Wire client = vendored `mistralrs-mcp` (zero new external dependency)**: consumes only the low-level `ProcessMcpConnection` (stdio) + `list_tools`/`call_tool` primitives, NOT its automatic tool-call loop. `mistralrs-mcp` is already in the build graph (`mistralrs-core → mistralrs-mcp`, patched to `../vendor`), so the direct edge adds ZERO compilation. **No cargo feature gate**: the dep compiles unconditionally regardless, so the real (and stronger, always-tested) gate is runtime config presence — no `FAE_MCP_CONFIG` ⇒ `None` catalog ⇒ every `mcp:` call denies `mcp_not_configured`.
- **`FAE_MCP_CONFIG` declaration file (TOML)**: `[servers.<name>] command = "...", args = [...], allowed_tools = ["..."]` (unknown fields rejected fail-closed). A missing/empty env var silently disables MCP; a malformed file is loud but never blocks daemon startup.
- **`mcp.list` command**: read-only namespaced catalog + per-server health (for Swift to surface later), gated by the safe envelope scope (mirrors `skillhost.list`). An absent catalog returns an empty listing, never an error.
- **`Scope::McpInvoke` (`mcp:invoke`)** added to `fae-control-plane`; `SwiftFrontend::default_scopes` gains it (owner opt-in, inert until servers are declared) following the F7a minimal-grant-extension pattern.

### Testing
- **Unit — catalog (`mcp/mod.rs`)**: config parse + `deny_unknown_fields`, allowlist filtering (a server-offered-but-unallowlisted tool never enters the catalog), invoke round trip via a mock `McpServerConnection`, undeclared-tool deny WITHOUT touching the server, and server-error → typed `McpError::Invoke`.
- **Unit — governed gate (`toolhost/mod.rs`)**: owner-interactive invoke runs + records an `isolation:"external"` audit row and an external receipt; proactive origin denies `mcp_origin_forbidden` without invoking; missing `McpInvoke` scope denies `missing_scope`; non-allowlisted tool denies `mcp_tool_not_declared`; no-catalog host denies `mcp_not_configured`.
- **Integration (`tests/mcp_stdio.rs`)**: a REAL stdio spawn → initialize → tools/list → tools/call round trip against an in-repo `mock_mcp_server` bin, via the vendored `ProcessMcpConnection` (the exact transport `McpCatalog::spawn` uses).

## Unreleased — Phase G commit 1 (context-compaction foundation)

### New Features
- **Pure compaction module (`crates/fae-daemon/src/compaction.rs`)**: side-effect-free planning shared by the delegate child loop and the new `conversation.compact` command. `estimate_tokens(&str)` — the workspace's single ~4-chars/token heuristic, promoted from `delegate.rs`'s old `approx_output_tokens`; `PromptBudget` — a model context window with an 80% compaction ceiling (integer `× 4 / 5`, no float drift); `plan_compaction(messages, budget, watermark)` — evicts oldest-first beyond a retained tail (`RETAINED_TAIL_MESSAGES = 4`) with a hysteresis `Watermark` (recompute only when the turn counter reaches `RECOMPUTE_EVICTION_THRESHOLD = 8`, or the retained tail alone exceeds the ceiling). No I/O; the caller performs the summarizer generation and history mutation.
- **`AdapterInfo::context_window` (`fae-engine`)**: every `ProviderAdapter`/`TtsAdapter` now reports its context window. Sources: mistral.rs → `configured_max_seq_len()` (its real KV-cache window); llama.cpp → the spawned/lazy sidecar's `--ctx-size` (`config.ctx_size`), or `DEFAULT_LLAMA_CONTEXT_WINDOW = 8192` for an attached server whose size we cannot observe; OpenRouter → a new `OpenRouterConfig.context_window` field (`DEFAULT_OPENROUTER_CONTEXT_WINDOW = 8192` when the model's window is unknown); mock → configurable (`with_context_window`, `DEFAULT_MOCK_CONTEXT_WINDOW = 8192`); TTS adapters → `0` (no text context).
- **`runtime.status` context telemetry (`session.rs`)**: the status response gains a `context` block — `{ window, last_turn: { prompt_tokens_est, completion_tokens_est, compacted, pinned_summary_tokens } }`. `window` comes straight from the adapter; `last_turn` is an ephemeral in-process snapshot recorded by `inject_text_core` after each turn (zeros/`null` before the first turn, but the keys are ALWAYS present so a client can rely on the shape).
- **`conversation.compact` command (`session.rs`, `ConversationWrite`-scoped)**: `{ messages }` → ONE bounded summarizer generation (dedicated system prompt, `max_tokens = SUMMARY_MAX_TOKENS = 256`, no tools) → `{ summary, tokens_est }`. A summarizer failure surfaces a typed error (`summarize_failed` / `summarize_empty`) so the caller falls back to hard truncation — a blank summary never silently erases context. The `ChatRequest` contract has no temperature knob, so "low temperature" is left to the adapter default; boundedness is enforced by the token cap.
- **Delegate child-loop compaction (`delegate.rs`)**: between iterations the loop runs `plan_compaction` over its child history and, when the plan says recompute, folds the evicted prefix into one pinned `[summary of earlier turns]` message via the SAME bounded summarizer path (`session::summarize_conversation`). The prompt budget is derived from the engine's real `context_window`; the summary generation's own output counts against the cumulative token budget. A summarizer failure is non-fatal (the loop continues on the un-compacted history; the hard token/iteration budget still bounds it). `approx_output_tokens` is replaced by `output_tokens`, which delegates to `compaction::estimate_tokens`.

### Testing
- **`compaction.rs` unit tests**: monotonic estimates, char-quarter ceiling, 80% budget ceiling (incl. integer truncation), oldest-first prefix eviction, watermark hysteresis (no recompute below threshold; fires at/above), tail-over-budget hard trip, empty history, and the single-oversized-message edge (nothing evictable ⇒ caller must hard-truncate).
- **`session.rs`**: `runtime.status` context-telemetry keys-always-present (mirrors the adapter-key contract), summarizer boundedness (a recording adapter asserts `max_tokens == 256`, no tools, dedicated prompt), empty-summary typed error, and `conversation.compact` end-to-end returning `{ summary, tokens_est }`.
- **`delegate.rs`**: `long_history_compacts_and_loop_completes` — a tiny-window mock forces the tail over budget across a 12-iteration scripted run; the loop still reaches its final answer and at least one summary was folded in (skips without the OS jail).

## Unreleased — Phase F commit 4 (live group-of-Fae proof + ADR-015)

### New Features
- **`FAE_ENGINE=mock` — dev-gated scripted engine (`fae-daemon`)**: `build_engine` now recognises `FAE_ENGINE=mock`, which swaps the real llama.cpp engine for a deterministic scripted `MockAdapter` (a `write tracked.txt` tool call → final answer, several pairs queued) so a REAL daemon can serve its control socket with NO model download. Gated exactly like `FAE_MODELS_LOCK=off`: valid only under `FAE_DEV=1`; `engine_selection` fails closed (exit 78) if requested without it, so a production build can never run a mock brain. This is the substrate the live group-of-Fae proof spawns two of.
- **Runner answers the delegation's `tool.confirm` (`fae-symphony-runner`)**: `DaemonClient` now recognises daemon-initiated `{server_request_id, method, params}` frames. During `conversation.delegate` the daemon round-trips a `tool.confirm` before running a dangerous (write/edit/bash) tool inside the jailed loop; an autonomous symphony worker **pre-authorizes its own delegation** (it pinned a conservative leaf toolset and the daemon confines every mutation to the issue workspace via the OS jail — the jail, not an interactive owner card, is the boundary) and replies `{approved: true}`. Any other server-initiated method fails closed (`{approved: false}`).

### Testing
- **Live group-of-Fae proof (`crates/fae-symphony-runner/tests/live_group_of_fae.rs`, `#[ignore]`, SKIP-not-fail)**: the Phase F gate. Spawns TWO real `fae-daemon` processes (each with `FAE_ENGINE=mock` on its own isolated `HOME` → its own run dir / socket / token / store), stands up TWO `FaeRunner`s over them, and shares ONE self-seeded x0xd TaskList (2 tasks) between two required-signing `X0xCrdtTracker`s. Asserts: **no double-claim** (a claimed task leaves the todo pool and is never offered to the second runner; the two runners claim DISTINCT tasks), **worked by a group of Fae** (each runner drives its OWN daemon's jailed delegation, mutating its OWN isolated git workspace — `git diff --name-only` surfaces `tracked.txt`), **signed handoffs** (ML-DSA-signed via x0xd `/agent/sign`), **tasks left the todo pool**, and **proof artifacts written**. Verified live against x0xd :12700. Locates the daemon via `FAE_SYMPHONY_DAEMON_BIN` or the sibling binary next to the test's target profile dir. Honest scope: a single x0xd node exposes one identity, so no-double-claim is proven at the task-lease level under one shared signing identity — two-identity claiming across two replicated x0x nodes is a documented multi-node follow-up (ADR-015).
- **ADR-015 (Proposed)**: records the `conversation.delegate` native-loop placement + jailed `Delegated` origin + budget model, the runner as a separate quarantined binary, x0xd-signs-everything (no Fae keys), the leaf-only-permit no-starvation design, single-engine throughput honesty, and the F4 `FAE_ENGINE=mock` substrate + runner confirm pre-authorization.

## Unreleased — Phase F commit 2 (`fae.delegate` — parallel leaf batches + orchestrator role)

### New Features
- **Engine serialization (process-global permit = 1)**: all delegation generations now acquire a shared `tokio::sync::Semaphore` (`delegate::engine_permit()`) held ONLY across the `run_turn` generation call — never across tool execution. On the single local engine, generation cannot run concurrently, but parallel leaves DO overlap tool-exec / jail I/O (not token throughput — documented honestly). Wired into every top-level delegation and shared across the whole fan-out tree.
- **Delegation-concurrency cap (default 3, clamped ≤ 8)**: a second process-global semaphore (`delegate::leaf_permit()`) bounds live LEAF loops. Only leaves consume a permit (for their whole run); an orchestrator holds NONE while it awaits children. Because a permit holder (a leaf) can never fan out, the wait graph is acyclic — deadlock-free even at cap = 1 (proven by `orchestrator_fan_out_no_deadlock_at_cap_one` + the headless `fanout.no_deadlock_at_cap_1` step with a single permit and a timeout guard).
- **Orchestrator fan-out (`role: Orchestrator` at depth 0)**: an orchestrator's restricted schema gains a synthetic `delegate` TOOL (never exposed to a leaf). Its input is a `batch` of up to `MAX_BATCH_SIZE` (4) child specs `{prompt, toolset, max_iterations, max_output_tokens}`. Each child runs as a `Leaf` at depth + 1 in the SAME `workspace_root`; its toolset must be a SUBSET of the parent's (and may not contain `delegate`); its budgets are clamped ≤ the parent's remaining. Children are `tokio::spawn`ed (real parallelism) and joined; their combined tokens debit the parent's budget. The batch is fully validated up front — a malformed batch, an oversized batch, or a subset violation is fed back to the model as a tool error and spawns NO child.
- **Receipt linkage**: `DelegationReceipt` gains `parent_id` (a spawned child's link to its orchestrator; omitted for top-level) and `child_ids` (an orchestrator's record of the batch it spawned; omitted for leaves). Both are `skip_serializing_if`-empty so a leaf receipt is unchanged on the wire.
- **Depth**: `MAX_DEPTH` raised to 1 — an orchestrator at depth 0 may spawn leaves at depth 1; anything at depth ≥ 1 is a leaf with no `delegate` tool in its schema AND a runtime rejection if it emits one (defense in depth). Depth 2+ is rejected with `delegation_depth_exceeded`.
- **API**: `DelegationDeps` is now owned (`Arc<dyn ProviderAdapter>` + `Arc<dyn ToolConfirmation>` + the two semaphores + `parent_id`) and `Clone`, so an orchestrator builds each child's deps from its own — sharing one engine, confirmation channel, store, and both permits across the tree. `run_authorized_delegate` + the transport spawn pass the owned Arcs.

### Testing
- **Headless proof extended (`--headless-delegate-test`)**: two new scenarios on the running kernel's OS jail — a fan-out where an orchestrator's 2-leaf batch writes two files (both land jailed, both leaf receipts carry `parent_id`, the orchestrator receipt records both children) and the orchestrator then answers; plus a cap = 1 run (no deadlock, timeout-guarded) and a leaf that emits `delegate` being rejected. 16 PASS lines total.
- **Unit tests (`delegate.rs`)**: subset-toolset violation + nested-`delegate` rejection, oversized-batch rejection, bare-array acceptance, child-budget clamp to parent remaining, depth-2 rejection, depth-1 leaf cannot delegate, no-deadlock at cap = 1, and `engine_permit_serializes_generation` (two concurrent delegations against a timestamp-recording adapter — asserts the generation intervals do NOT overlap).

## Unreleased — Phase F commit 3 (`fae-symphony-runner` — symphony Runner over the daemon socket)

### New Features
- **`fae-symphony-runner` crate (`crates/fae-symphony-runner`)**: a standalone binary that lets a Fae instance join a group-of-Fae task swarm. It implements x0x-symphony's `Runner` trait over the local `fae-daemon` control socket — claiming a `TaskItem` from x0xd (trust-gated, ML-DSA-signed by x0xd), executing the work by driving `fae-daemon`'s native jailed agentic loop (`conversation.delegate`, Phase F1) inside an isolated workspace, and letting the stock `x0x-symphony-orchestrator` publish a signed handoff + proof artefacts.
- **`FaeRunner` (`Runner` impl)**: `start_session` verifies the daemon socket + token (fail fast); `run_turn` opens an authenticated connection and delegates the issue description into the daemon's jailed loop rooted at the issue workspace (leaf role, depth 0, conservative default toolset `[read, write, edit, bash, glob, grep]`), mapping `completed` → `Succeeded` and `budget_exhausted` → `Failed`; `stream_events` is `stream::empty` for v1 (structured-event fidelity is a documented fast-follow); `stop_session` returns an empty usage report. The orchestrator derives `files_changed` from `git diff` in the workspace and assembles the signed handoff verbatim (`ProofRun` + `build_success_handoff`) — no custom handoff format.
- **`DaemonClient` (authenticated NDJSON socket client)**: connects to the daemon Unix socket, sends `session.authenticate` (`{ client_id, token }`), then `conversation.delegate`, decoding the `{ text, status, receipt_id, iterations, tokens }` result. Uses the internal `fae-control-plane` `Command`/`Response` envelope; it does **not** depend on `fae-daemon` — the runner is a pure client of the daemon's existing wire protocol (verified via `cargo tree -i x0x-symphony-core`: only `fae-symphony-runner` depends on any `x0x-symphony-*` crate; `fae-daemon` stays symphony-clean).
- **Fail-closed startup**: the binary constructs the x0xd signer and calls `/agent` before claiming any work; if x0xd is unreachable it refuses to start (no unsigned handoffs). Configuration comes from environment variables or a TOML file (`FAE_SYMPHONY_CONFIG`).
- **Dependency mechanics**: the `x0x-symphony-*` crates are consumed as **git-rev deps pinned to the sibling's pushed HEAD**, quarantined in this crate. git-rev (not path) is deliberate — the crate is developed in a git worktree whose depth differs from the folded checkout, so a relative path dep would resolve to two different places; a git-rev pin is location-independent. A `dev override` path form and a `TODO(publish)` crates.io pin are documented in `Cargo.toml`.

### Testing
- **Headless (CI-safe, no x0xd, no model)**: `runner_headless.rs` drives (a) `FaeRunner` directly against a MOCK daemon Unix-socket server speaking the real `session.authenticate` + `conversation.delegate` NDJSON shapes (asserts the turn authenticates, delegates, and mutates the workspace), and (b) the SAME runner through `x0x-symphony-orchestrator` with an in-memory tracker + a git-backed workspace — asserting task→claim→delegate→workspace-mutated→`files_changed` (non-empty, contains `tracked.txt`)→handoff published with a proof dir.
- **Live (`#[ignore]`, env-gated)**: `live_x0xd.rs` proves the signer leg (`/agent` reachable + ML-DSA identity), the tracker leg (`X0xCrdtTracker` with `required_signing` fetching trust-gated candidates), and — when a candidate is present — the signed-handoff leg (claim → heartbeat → signed `handoff`). The runner leg (real fae-daemon + model) is the documented manual two-Fae live path.

## Unreleased — Phase F commit 1 (`fae.delegate` — native jailed agentic loop)

### New Features
- **Native jailed agentic loop (`conversation.delegate`, `fae-daemon` `delegate::run_delegation`)**: the daemon now runs its OWN generate → execute-tool → feed-back loop instead of returning tool calls to the Swift client for out-of-process execution. A fresh child history (a bounded delegated-worker system prompt + the delegated prompt + a RESTRICTED set of tool schemas — only the request's `toolset`) is looped through the production `run_turn`; each iteration's tool calls are checked against the toolset allowlist, then executed through the governed `ToolHost` with a NEW `ToolOrigin::Delegated` (always OS-jailed, like every autonomous origin), with results appended to the child history. Hard budgets: the daemon clamps iterations to ≤ 16 and the cumulative output-token budget to ≤ 32768 (a conservative "engine context / 2" fallback until `AdapterInfo` carries the real window); tripping either yields a `budget_exhausted` status with a PARTIAL receipt. Commit-1 scope: `role` (Leaf/Orchestrator) is carried into the receipt but behaves identically (fan-out is commit 2), and `depth > 0` is rejected with a clear error.
- **Ephemeral jailed ToolHost at a caller-supplied workspace**: `run_delegation` builds a `ToolHost::new_durable` rooted at the request's `workspace_root` WITHOUT the interactive `toolhost.set_root` confirm card. The root comes from a trusted orchestrator (the Swift frontend), never model output, and is still validated defensively (absolute, exists, is a directory, blast-radius-safe via the same `is_safe_workspace_root` guard the interactive path uses) and gated on `jail_backend_available()` — a delegated loop that cannot be jailed fails closed.
- **`DelegationReceipt` (isolated JSONL, never `fae.db`)**: every delegation appends one receipt to `delegation_receipts.jsonl` in the conductor store (sibling of the ToolHost/SkillHost receipts). It records the delegation id, role, `prompt_sha256` (NEVER the raw prompt), toolset, iterations + approximate tokens used, an ordered list of `(tool, mutation_receipt_id, status)` events (mutating tools link their `toolhost_receipts.jsonl` mutation receipt by `call_id`), the terminal status, and wall-clock duration.
- **`Scope::AgentDelegate` (`agent:delegate`)**: the envelope permission for `conversation.delegate`, granted to `SwiftFrontend` by default (owner opt-in, same minimal grant-extension pattern as F7a/Phase E). A single scope authorizes both running the loop and rooting its ephemeral jailed ToolHost — the OS jail + per-tool `FaeToolPolicy` remain the trust boundary. The command spawns off the transport read loop (like `agent.prompt`/`toolhost.execute`) so a mid-loop `tool.confirm` round-trip does not deadlock.
- **Scripted `MockAdapter`**: `MockAdapter::scripted(model_id, scripts)` emits a programmed `ChatEvent` sequence per `stream_chat` call (FIFO, then falls back to echo), so a multi-iteration agentic loop can be driven deterministically with no model.

### Testing
- **Headless native-delegation proof (`fae-daemon --headless-delegate-test`)**: drives `run_delegation` against a scripted `MockAdapter` with NO socket + NO model and asserts — on the running kernel's OS jail — that a completed loop's write lands INSIDE the root and is audited as `jailed` (Delegated origin), the delegation receipt links the write's mutation-receipt id and was persisted, a delegated `bash` write OUTSIDE the root is blocked by the jail (the file never lands), the budget-exhaustion path trips at `max_iterations = 1`, and `depth > 0` is rejected. Wired into `ci-linux.yml` next to the Phase C proof (amd64 + arm64, real Landlock kernel).
- Deterministic unit tests (`delegate.rs`, `fae-control-plane`): toolset allowlist rejection, budget clamping, `depth > 0` rejection, empty-prompt rejection, receipt shape + `prompt_sha256` (asserts the serialized receipt does NOT leak the raw prompt), budget-exhaustion, and `AgentDelegate` scope round-trip + `conversation.delegate` scope denial without the scope.

## Unreleased — Phase E commit 3 (Swift surface: peer messages, consent + handoff cards, owner-fleet config)

### New Features
- **`[x0x]` FaeConfig section**: three keys (`enabled`, `ownerFleet`, `allowList`); fully round-tripped through parse → serialize → re-parse. `X0xConfig` struct added to `FaeConfig`; wired into `DaemonLLMEngine.setX0xConfig()` (called by `FaeCore` before `load()`) so `FAE_X0X_INGRESS`, `FAE_X0X_OWNER_FLEET`, and `FAE_X0X_ALLOW` are injected into the daemon environment automatically.
- **`peer.*` event decode**: `DaemonEventSubscriber.dispatchEvent()` now forwards any `peer.*` event it receives onto `.faeBackendEvent` (previously dropped silently). `BackendEventRouter` routes `peer.message`, `peer.consent`, `peer.handoff_offer`, and `peer.presence` to the new `.faePeerEvent` notification. `peer.consent_result` / `peer.info` are logged.
- **Peer event rendering in `ConversationEventBridgeController`**: subscribes to `.faePeerEvent`. `peer.message` appends an attributed remote message to the conversation surface and subtitle overlay. `peer.consent` shows a subtitle notification identifying the sender and consent direction (authorized / revoked). `peer.handoff_offer` presents an `NSAlert` (Accept / Decline) — Accept injects any `pending_turn` via `.faeConversationInjectText` and appends a status message.
- **"Hand off to…" menu in Edit**: when `[x0x] ownerFleet` is non-empty, a `Menu("Hand off to…")` is appended to `CommandMenu("Edit")` listing each fleet agent ID (truncated to 12 chars). Selecting one calls `FaeAppDelegate.sendX0xHandoff(to:)`, which snapshots the current conversation and sends `peer.handoff_send` to the daemon.
- **`FaeCore.sendPeerCommand(_:payload:)`**: public helper that casts `llmEngine` to `DaemonLLMEngine` and calls `sendPeerCommand(_:payload:)` on it; logs loudly if the daemon engine is not active. `DaemonLLMEngine.sendPeerCommand` is a thin public wrapper over `sendAdapterCommand`.
- **"x0x Connections" settings section**: new `Section.x0x` in `SettingsModelsPrivacyTab` with a toggle, owner-fleet text editor, and allow-list text editor. Hydrated from `FaeConfig.load()` on appear.

### Tests
- `FaeConfigParsingTests`: five new tests — `testX0xEnabledDefaultIsFalse`, `testX0xEnabledRoundTrip`, `testX0xOwnerFleetRoundTrip`, `testX0xAllowListRoundTrip`, `testX0xSerializationRoundTrip`.

### Deviations from spec
- `peer.consent` carries no `envelope_id` in the wire payload — it is a `ConsentReceipt`/`ConsentRevocation` notification, not a consent request. Rendered as subtitle notification only (no approval card).
- `peer.handoff_offer` omits `conversation_tail` in the wire event (only `tail_len` is sent); only `pending_turn` is injected into the input path.

## Unreleased — Phase E commit 2 (x0x SSE peer ingress + outbound commands)

### New Features
- **x0x peer-ingress supervisor (`fae-daemon` `peer::PeerIngress`)**: the SINGLE governed inbound entry point for peer content. An SSE task connects x0xd's `GET /direct/events` and, for every frame, (1) transport-pre-checks `verified == true`, (2) runs the base64-decoded envelope through `fae_envelope_gate::gate_and_audit` — THE GATE RUNS BEFORE ANY OTHER PROCESSING — writing accept/reject rows to `<fae data dir>/peer_envelope_audit.jsonl`, (3) cross-checks the signed `sender_id` against the transport-attested sender (case-insensitive; a mismatch appends a clearly-marked rejected audit row and drops), then (4) dispatches via commit 1's `handler::dispatch` onto the daemon event bus as `peer.*` events (`ConversationRead`-scoped, the orb host's existing subscribe grant). Reconnects with jittered exponential backoff (base 2s, cap 60s). Spawned at startup only when `PeerConfig::from_env()` is `Some` (opt-in via `FAE_X0X_INGRESS`) and x0xd answers `/health`; fully fail-quiet otherwise.
- **x0xd REST/SSE client (`peer::x0x_client::X0xPeerClient`)**: `own_agent_id()` (`GET /agent`), `direct_send()` (base64-wraps the raw envelope into `POST /direct/send`), `direct_events()` (an async `Stream` of decoded `DirectEventFrame`s parsed from the SSE `bytes_stream`, filtering `event: direct_message`, joining multi-line `data:`, skipping keepalives), and `health()`. Bearer-token auth only; every call timeout-bounded except the long-lived event stream; zero retries inside the client (the supervisor owns backoff).
- **Optional auto-reply**: with `FAE_X0X_AUTO_REPLY=1`, an accepted `direct_message` is answered as a tool-less GUEST turn through the exact governed `inject_text_core` path (an inject payload with no `tools` key ⇒ zero tool access), and the reply is sent back wrapped in a `direct_message` envelope. Best-effort — any failure warns and drops; default off.
- **Outbound `peer.*` control-plane commands** (`session.rs`): `peer.send {to_agent_id, text}` (→ `direct_message` envelope), `peer.handoff_send {to_agent_id, snapshot}` (→ `session_handoff` envelope via commit 1's builder; the target MUST be in the owner-fleet allowlist — rejected otherwise), and `peer.consent_respond {envelope_id, accept}` (appends an owner decision to the peer audit log + emits a `peer.consent_result` event; the allowlist itself is config-file based in v1). Gated by new `x0x:message` / `x0x:admin` scope registrations; the `SwiftFrontend` client class now holds both (same minimal grant-extension pattern as F7a).

### Testing
- **`crates/fae-daemon/tests/peer_x0x_live.rs`** (`#[ignore]`d): drives two live x0xd daemons end-to-end — A→B `direct_message` (gated + accepted + audited), B→A `session_handoff` (owner-fleet accepted + payload decoded), plus deterministic gate negatives (non-allowlisted sender → `SignatureRejected`, unknown kind → `InvalidJson`, >64 KiB → `TooLarge`). Skips cleanly when x0xd is absent. Deterministic unit tests cover the SSE line-parser, backoff sequence, transport pre-check, sender cross-check, and the outbound envelope builders (round-tripped through the real gate).

## Unreleased — Production readiness Phase C (governed execution proven headlessly)

### New Features
- **Headless governed-execution proof (`fae-daemon --headless-tool-test`)**: a new CLI mode that builds the same governed `ToolHost`/`SkillHost` the protocol path builds and, WITHOUT a socket or a model, runs read → write → edit → bash on the host tier (asserting every output plus that fail-closed mutation receipts landed), then the jailed tier — a jailed write INSIDE the workspace root succeeds while a jailed write OUTSIDE it is REJECTED by the OS sandbox (Landlock on Linux, seatbelt on macOS), proving the jail actually confines. Finally it discovers → activates → `prepare_run`s a fixture skill and executes its `uv run --script` command through the governed bash path under the jail, asserting the deterministic marker survives. Exits nonzero on any failed assertion.
- **`ci-linux.yml` Phase C gate**: the `build-linux` matrix (amd64 + arm64) now installs `uv` and runs `--headless-tool-test` against the committed fixture skills after the daemon build, so the DONE criterion — "a Linux daemon build actually executes read/write/edit/bash + a run_skill end-to-end, through the governed host" — is enforced per-PR on the real Landlock kernel.
- **`ci-proof` test-fixture skill** (`crates/fae-daemon/test-fixtures/skills/ci-proof/`): a minimal executable skill (`SKILL.md` + `MANIFEST.json` with real SHA-256 checksums + a stdlib-only `scripts/hello.py`) used only by the headless proof — kept out of the app's bundled Resources.

### Changed
- **Autonomous origin wiring (Phase C)**: `toolhost.execute` and `skillhost.run` now accept an optional `origin` field. A missing origin defaults to `owner_interactive` (host tier) — backward-compatible with existing callers — while an autonomous origin (`proactive`/`scheduler`/`auto_skill`/`script_block`) maps to a jail-requiring tier, so a scheduler/proactive skill run can never inherit the daemon's ambient host authority. Closes the "wired in Phase C" placeholders in `session.rs`.

## Unreleased — Production readiness Phase A (green board)

### Fixed
- **Linux release job unblocked**: replaced the fail-closed placeholder SHA-256 sentinels in `.github/workflows/release-linux.yml` with the real digests of the pinned appimagetool 1.9.0 release assets (x86_64 `46fdd785…`, aarch64 `04f45ea4…`), computed from the canonical GitHub release downloads.
- **Restore from Vault is now user-reachable**: rescue mode's Recovery tab gains a "Restore from Vault" section (visible only while rescue mode is active) that lists vault snapshots (date · message · short hash), confirms with a destructive dialog, drives the hardened `GitVaultManager.restore()` copy-then-swap path, and ends with an explicit "Quit Fae to load the restored data" step. `FaeCore` hands the vault to `RescueMode` both when rescue mode is registered and when the vault is created in `start()` (registration happens before `start()`, so the `didSet` alone would hand `nil` and the panel would silently show no backups).

## Unreleased — Connect Account (portable, Python-first)

### New Features
- **Portable `connect-account` executable skill** (`Resources/Skills/connect-account/`): one cross-platform engine that connects the user's mail/calendar/contacts from just their email + ONE app-specific password. Runs anywhere via `uv run --script` (PEP 723 inline metadata; sole dependency is cross-platform `keyring` — macOS Keychain / Linux SecretService). On macOS the keyring items land under the same service/account the existing productivity skills read via `CredentialManager`, so the script and the Swift skills interoperate.
- **Gmail provider** (Stage 1 of the in-app onboarding plan): `gmail.com`/`googlemail.com` → `imap.gmail.com`/`smtp.gmail.com` with the correct `[Gmail]/Sent Mail` etc. folder aliases (the generic aliases break save-to-Sent on Gmail), guidance pointing at the Google App-Passwords page (2-Step Verification required). Gmail is mail-only here — Google calendar/contacts need OAuth (app-password CalDAV/CardDAV is deprecated), reserved for a later method.
- **Two inputs, everything else derived**: detects iCloud (`@icloud.com`/`@me.com`/`@mac.com`), Gmail, or generic from the email domain, opens the provider's app-password page, derives the full config (iCloud servers + the seven keyring keys the productivity skills read + a himalaya `config.toml` whose `auth.cmd` reads the password from `$HIMALAYA_PASSWORD` — never `auth.raw`), stores it, and verifies mail live. Handles iCloud custom domains (mail sent from the alias, authenticated with the primary Apple ID) and spec-compliant TOML escaping.
- **Fae installs the `himalaya` mail CLI herself** — no terminal for the user. Portable on every OS: downloads the pinned himalaya release (v1.2.0), verifies its SHA-256 against embedded digests (fail-closed on mismatch, like models.lock), and drops the binary in `~/.local/bin` (already on Fae's PATH). `connect` auto-installs when himalaya is missing; a failed install (offline/unsupported arch) defers mail verification without rolling back a correct password. New `ensure_tools` action exposes it directly.
- **Actions**: `start` (detect + open page + guidance), `connect` (derive → store in keyring → write himalaya config → auto-install himalaya → verify mail live → transactional rollback on auth failure), `ensure_tools` (install himalaya), `status`, `selftest` (validates derivation with no account/secret/network — 11/11).
- **Secret hygiene**: the password is never read from argv or the request JSON — it arrives via `FAE_APP_PASSWORD` (injected on macOS by `input_request`+`secret_bindings`, i.e. straight to the Keychain) or a no-echo `getpass` terminal prompt on Linux/CLI, and flows only into the system keyring and the himalaya child env. Never printed, logged, or surfaced (himalaya stderr suppressed).
- Ships as an executable skill with `MANIFEST.json` (SHA-256 integrity). macOS calendar/contacts continue to use the built-in `calendar`/`contacts` (EventKit) tools — no password, local access — while off-macOS they use the stored CalDAV/CardDAV credentials.

## Unreleased — Task #11 Prompt budget (levers 2/3 + gate)

### Changed
- Tool-call no-regression gate (the plan's deferred FaeBenchmark gate): added a deterministic `TurnHelpers` coverage battery asserting 11 high-frequency spoken intents (calendar/reminders/mail/web/screenshot/camera/read/bash/session_search) keep a full native schema on cold turns, and that niche tools (roleplay/delegate_agent/agent_session/plugin_manage) stay intentionally index-only. Lever 1 is no longer provisional — no regression on the high-frequency surface, CI-guarded.
- Lever 2 (memory recall budget): the recall block already enforced a hardcoded 2000-char cap; made it the config knob `memory.maxRecallChars` (default 2000, floored at 200) — no behavior change, now tunable.
- Lever 3 (prefix cache): added `FAE_PREFIX_CACHE_N` env knob in fae-engine (`configured_prefix_cache_n`), default OFF (unchanged). Re-enables the prefix cache for live A/B; MUST pass an audio-turn regression suite before any default-on (a cache hit across audio turns previously corrupted output).

## Unreleased — Task #11 Prompt budget

### Changed
- Added native progressive tool disclosure: ordinary turns keep a compact index of all allowed tools but send full JSON schemas only for a conservative working set plus explicit/inferred long-tail tools.
- Added daemon prompt-budget metrics logging (`prompt_budget`) with approximate text-token, payload-byte, and tool-schema counts per turn.
- Added regression coverage for generic/core tool working sets, inferred long-tail expansion, proactive allowlist narrowing, strict-local filtering, and prompt-budget metric reductions.

## Unreleased — Task #10 Thinking liveness

### Fixed
- Silent awareness/proactive generations are now tracked for token-stream isolation without driving the orb's user-visible `assistantGenerating` / "Thinking" indicator.
- Stale or superseded generations can no longer strand the Thinking pill: ending an old generation only removes that generation, while the indicator is forced idle once no visible generation or approval pause remains.
- Added regression coverage for overlapping silent proactive generations, visible-generation guard semantics, and approval pauses.

## Unreleased — Skills-first cross-platform P5

### CI / Build
- Release workflow dry-runs can now build a reviewable macOS bundle without notarization or GitHub Release publishing.
- `release.yml` builds `fae-daemon` and `fae-ui-shell` as Rust auxiliary binaries, embeds them in `Contents/MacOS`, signs helpers, and verifies the embedded daemon with `codesign` plus `fae-daemon --version`.
- The no-Rust-reintroduction guard now allows Rust only in the explicit Linux render-spike workflow and this release auxiliary embedding workflow.

### Security
- Added a generated `models.lock` for the reviewed `google/gemma-4-E4B-it` Hugging Face snapshot and wired daemon startup to fail closed before model load on missing, mismatched, or unpinned artifacts.
- Daemon model loading now passes the verified HF revision into mistral.rs so the runtime cannot silently move to a newer snapshot than the one hashed in `models.lock`.
- Swift installs the bundled lock into `<fae data dir>/models.lock`; `FAE_MODELS_LOCK=off` remains a loud dev-only escape hatch under `FAE_DEV=1`.

## Unreleased — Skills-first cross-platform P4

### CI / Build
- Added a dedicated `linux-render-spike` GitHub Actions workflow for Ubuntu WebKitGTK shell builds and ALSA-backed daemon builds.
- Added an Xvfb smoke mode for the Rust UI shell that opens the opaque Settings panel, captures a WebKitGTK screenshot artifact in CI, and rejects blank captures via ImageMagick color-count validation.
- Folded the P1-deferred Linux `fae-daemon` build proof into the same Ubuntu job with `libasound2-dev`, `pkg-config`, and `cargo zigbuild`.
- Switched Linux `wry` panels to `WebViewBuilderExtUnix::build_gtk` against tao's GTK container after the generic `build(&window)` path produced blank Xvfb captures.

### Docs
- Added `docs/architecture/linux-render-spike-2026-06.md` to track opaque Settings panel, pill transparency, and Linux shell go/no-go findings.

## Unreleased — Skills-first cross-platform P3

### New Features
- Added an orb-owned Settings panel in `fae-ui-shell` with `settings_snapshot` / `settings_set` bridge sync to Swift `FaeCore.patchConfig`.
- Added adjustable Settings controls for tool access, thinking depth, LLM temperature, TTS speed, awareness cadence, and privacy posture, plus informational always-on capability cards.
- Kept the SwiftUI Settings window available as **Settings (legacy)…** during parity migration.

### Tests
- Added Rust bridge protocol coverage for `settings_snapshot` and the legacy settings menu action.
- Live-verified panel-driven `tts.speed` persistence plus Right Option and orb long-press PTT regressions.

## Unreleased — Skills-first cross-platform P2

### New Features
- Added executable built-in skills `mail-himalaya`, `calendar-caldav`, and `contacts-carddav` with agentskills.io-compatible frontmatter plus Fae SHA-256 manifests.
- Added PEP 723 Python CalDAV/CardDAV scripts for portable calendar/contact workflows with Keychain-injected environment variables.
- Added `himalaya` to the extended tool augmentation registry for portable IMAP/SMTP mail.

### Tests
- Extended bundled skill discovery/manifest coverage for the productivity skills and added registry coverage for `himalaya`.

## Unreleased — Skills-first cross-platform P1

### New Features
- Added `fae-audio`, a cpal-backed daemon audio crate for portable PTT capture and WAV playback.
- Added daemon NDJSON commands `audio.devices`, `audio.capture_start`, `audio.capture_stop`, and `audio.play` behind the existing control-plane auth/scopes.
- Added a live repro script at `crates/fae-daemon/scripts/fae_audio_repro.py` for capture → playback → audio turn → TTS → playback validation.
- Added capture gain normalization plus `FAE_AUDIO_INPUT_DEVICE` / `FAE_AUDIO_OUTPUT_DEVICE` overrides for reproducible cpal diagnostics.

### Tests
- Added WAV encode round-trip, 48 kHz → 16 kHz sine resampling, capture gain, capture-cap reaping, audio command scope, and daemon auth rejection coverage.

## v0.8.183 — Autonomous Self-Improvement Loop (2026-03-30)

### New Features
- **Autonomous self-improvement loop**: Fae can now train, evaluate, and deploy LoRA adapters overnight without human intervention. Collects conversation corrections during the day, trains via mlx-tune, evaluates with FaeBenchmark (pure Swift), gets external agent review, and proposes improvements next morning.
- **LoRA adapter loading**: MLXLLMEngine gains `loadAdapter(from:)`, `unloadAdapter()`, and `swapAdapter(to:)` methods via mlx-swift-lm's built-in LoRA support. Supports hot-swap without app restart.
- **Adapter deployment via SelfConfigTool**: New `training.personal_adapter_path` and `training.adapter_auto_load_enabled` adjustable settings. FaeCore.patchConfig hot-swaps adapters on the running pipeline.
- **FaeBenchmark --adapter flag**: Benchmark a LoRA adapter against the base model with per-metric comparison JSON output. Pre-flight path validation.
- **ImprovementStore**: New `improvement.db` SQLite database (separate from fae.db and scheduler.db) with 5 tables: feedback_events, improvement_baselines, improvement_state, capability_gaps, shadow_eval.
- **ImprovementCycleCoordinator**: Deterministic state machine actor (IDLE -> COLLECTING -> TRAINING -> EVALUATING -> PROPOSING -> DEPLOYING) with scheduler integration at 03:00 daily. Minimum data thresholds prevent overfitting on sparse data.
- **Semi-automatic deployment**: Morning proposals tell the user specifically what improved. After 5 user-approved cycles, earns fully automatic deployment. Adapter rollback via current/previous path tracking.
- **ImplicitFeedbackDetector**: 7 signal types captured from every conversation turn: re-ask, abandonment, follow-through, interruption, praise, topic change, silence acceptance. Feeds into ImprovementStore for DPO pair generation.
- **ExternalReviewGate**: 3-provider fallback chain (Codex -> Claude Code -> internal self-review) with PASS/FAIL/CONCERN gate and 3-deferral maximum before force-deploy.
- **DirectiveFastTuner**: Pattern-based directive amendments (every 7th cycle). Detects repeated corrections, persistent re-asks, abandonment clusters, and style preferences. Reversible via Git Vault.
- **ShadowEvaluator**: Overnight-only replay on alternate nights from training. Compares base vs adapter responses. Promotion gate at 60% adapter win rate.
- **ImprovementHealthReporter**: Self-diagnostic integration reports improvement loop health (last cycle, adapter version, eval scores, failed cycles).
- **Git Vault backup**: improvement.db and trained adapter directory added to vault backup manifest.

### Tests
- 168 new improvement-related tests across 8 test suites
- Integration tests covering full feedback -> training -> eval -> deploy round-trip

---

## v0.8.181 — ASR Resilience + Self-Healing Skills + ACP Delegation (2026-03-30)

### Bug fixes
- **ASR pipeline deaf after overnight**: VAD EMA silence threshold, noise floor, echo suppressor baseline, and wake detector state now reset on idle timeout — prevents the pipeline from going "deaf" after long-running sessions
- **Name garbled as "Peer-to-peer"**: `CorrectionDetector` no longer false-triggers on conversational phrases like "it's peer-to-peer"; added `isPlausibleName()` gate that rejects non-name words, oversized strings, and punctuation
- **Name resolution negation bug**: `extractStoredName()` now rejects "Primary user name is not X" patterns that previously resolved as valid names
- **Plugin agent skills reported broken**: health check now recognises plugin-sourced instruction skills (tagged "agent") and marks them healthy without requiring SKILL.md directory structure

### Improvements
- **Self-healing skill system**: `SkillManager.repairSkills()` auto-repairs broken built-in skills (restores SKILL.md from bundle) and degraded executables (generates conservative MANIFEST.json); scheduler and self-diagnostic attempt repair before reporting to user
- **ACP agent delegation expanded**: `delegate_agent` tool now supports 5 providers (codex, claude, pi, gemini, copilot); `ACPSessionManager` auto-installs acpx via bun/npm on first use
- **SKILL.md frontmatter normalised**: `acp-setup` and `huggingface-scout` skills aligned to agentskills.io standard (metadata nesting, removed non-standard top-level fields)
- **Sparkle background check silenced**: scheduler update checks now use `checkForUpdatesInBackground()` — no "you're up to date" dialog when already current

---

## v0.8.147 — Conversational Tool Responses + Orb Performance (2026-03-23)

### Improvements
- **Conversational tool responses**: Apple tool results (calendar, reminders, mail, contacts, notes) now route through the LLM for natural-language interpretation instead of being read back verbatim — Fae analyzes, summarizes, and flags what matters
- **Improved personality prompts**: system prompt updated to guide Fae toward interpreting and presenting information as a thoughtful friend, not a text-to-speech reader
- **Orb shader optimized**: NebulaOrb Metal shader rewritten with half-precision, reduced FBM octaves, and constant folding — significantly lower GPU cost at 120px render size
- **Rate limiter relaxed**: bash tool limit raised from 5 to 30 calls/min; high-risk minimum raised from 3 to 15 to support multi-tool scripting workflows
- **Speech verifier resilience**: speech verifier now logs and continues when model is not loaded rather than silently skipping verification

### Bug fixes
- **Approval manager timeout**: updated test expectations to match 45s timeout (was 20s)
- **Voice pipeline test**: synthetic speech signal strengthened to meet WeSpeaker 2s+ voiced duration threshold
- **Owner auto-approval test**: fixed test that was accidentally auto-approving via voice identity instead of testing the no-approval-manager path

### Tests
- Total: 1616 tests, 0 failures

---

## v0.8.145 — Self-Diagnostic + Correction Feedback (2026-03-20)

### New features
- **Self-diagnostic skill**: instruction skill (`self-diagnostic`) that guides Fae through a comprehensive health check — system resources, pipeline state, security events, tool health, memory status, and speaker profiles
- **Voice command trigger**: say "diagnose", "run diagnostics", "health check", "how are you doing" to activate self-diagnostic
- **Proactive anomaly watcher**: 6-hour scheduler task (`self_diagnostic`) silently checks memory health, skill health, and disk space; queues a spoken alert when anomalies are found
- **User correction detection**: `CorrectionDetector` recognises name errors ("my name is X not Y"), mishearings ("I said X"), interruptions ("you interrupted me"), and wrong actions ("that was wrong")
- **Correction memory capture**: corrections are stored as memory records (profile for names, episode for others) via `MemoryOrchestrator.storeCorrection()`
- **ASR vocabulary learning**: name corrections are fed into `DynamicVocabularyCorrector.addCorrectionPair()` for immediate post-ASR improvement

### Tests
- 27 CorrectionDetector tests (all pattern types, false positives, CorrectionRecord)
- 8 VocabularyLearning tests (addCorrectionPair, deduplication, integration flow)
- 16 SelfDiagnosticSkill tests (voice commands, skill discovery, activation)
- Total: 1395 tests, 0 failures

---

## Completed milestones

- **v0.6.2** — Production hardening: pipeline startup, runtime event routing, settings redesign
- **v0.7.0** — Dogfood readiness: backend cleanup, voice command routing, UX feedback, settings expansion
- **Milestone 7** — Memory Architecture v2: SQLite + semantic retrieval, hybrid scoring, backups
- **v0.8.0** — Pure Swift migration: MLX engines, unified pipeline, no Rust core
- **v0.8.1** — Tool security hardening: 7-layer safety model
- **v0.8.62** — Echo/barge-in fix: prevent garbled speech from self-interruption
- **v0.8.72** — Vision + Computer Use: Fae can see the screen and interact with apps
- **v0.8.74** — Voice Pipeline Overhaul: TTS consistency, timestamps, conversational voice identity
- **v0.8.75** — Native Tool Calling: MLX native tool calling integration for all tools
- **v0.8.82** — Proactive Visual Awareness: camera presence, screen monitoring, overnight research, enhanced briefings
- **v0.9.0** — Memory v2: neural embeddings, ANN search, knowledge graph
- **v1.0.0** — UX overhaul: orb enchantment, streaming, canvas feed, stop, hotkey, input flow
- **v1.1.0** — Data Vault, Skills v2, TrustedActionBroker, security hardening
- **v1.2.0** — Fae Forge, Toolbox & Mesh: tool creation, registry, and peer sharing
- **v1.3.0** — Worker subprocess architecture, CoWork web search, TTS switch to Kokoro
- **v1.4.0** — Thinking crawl, capability discovery, enrollment UX, code quality pass
- **v1.4.1** — CoWork approval flow fixes + camera tool fix
- **v1.4.2** — ACP integration, channel adapters, training pipeline, skill hardening
- **v0.8.125** — Memory inbox: multi-line pastes split into individual memory records; date prefixes and list markers from migration format are stripped automatically
- **v0.8.124** — Tool visibility: conversational follow-ups now correctly show available tools; Discord channel setup fixed
