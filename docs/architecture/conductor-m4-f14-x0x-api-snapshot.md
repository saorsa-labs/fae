# M4-B — F-14 x0x API Snapshot

**Status:** F-14 confirmation artifact (M4-B slice)
**Date:** 2026-06-27
**Spec:** `docs/architecture/conductor-m4-ownerfleet-x0x-sync-spec-2026-06-27.md` §3
**Purpose:** Record the exact x0x / x0x-compute API surface that `delegate_to_mesh` targets, so the
M4-C port contract and the future M4-E REST adapter are grounded in verbatim source — not grep
summaries. Per F-14 ("confirm x0x crate API surface before implementation").

---

## Repos at read time

| Crate | Path | Commit | Tag | Working tree |
|---|---|---|---|---|
| `x0x` | `../x0x` | `a6fce96b341a` | `v0.26.0` | dirty: 1 untracked test script (`tests/pr109_local_soak.sh`) — non-source |
| `x0x-compute` | `../x0x-compute` | `c9f765b` | none | dirty: modified `.gitignore`, `AGENTS.md`; untracked `.pi/` — non-source |

**API structs/routes below are clean-tree** (the dirty files are config/docs/tooling, not `src/`).
If a future adapter cites this snapshot against a moved commit, re-read the source.

---

## Decisive conclusion (why M4 targets `x0x-compute`, not `x0x`)

- **`x0x` (v0.26.0)** is a **transport / identity / trust / mesh** layer. It has **no LLM/inference
  API.** Its request/response primitives are `ExecService` (remote *argv* execution → stdout/exit-code)
  and `send_direct` (DM, fire-and-forget + ACK). These are **not** the inference path Fae needs.
- **`x0x-compute`** is an **OpenAI-compatible chat-completion mesh.** `RuntimeAdapter::chat_completion`
  takes a chat request and returns a chat completion. HTTP route `POST /v1/openai/chat/completions`
  serves it. Peers advertise model namespaces (e.g. `qwen3.5:32b`). **This is the `delegate_to_mesh`
  contract.**
- **State:** Phase 2a — the contract is designed; `SkeletonRuntimeAdapter` is a **deterministic stub**
  (no real model wired). M4 targets this contract with a port + mock; real transport (M4-E) waits for
  a real backend.

The Fae↔x0x-compute integration (future M4-E) is **REST-over-localhost**: Fae's adapter talks to a
localhost `x0x-computed` daemon's HTTP surface. It does **not** link `x0x` or `x0x-compute` as a crate
dep, and does **not** touch `x0x`'s DM/ExecService layer directly (that's x0x-compute's internal
transport concern).

---

## `x0x-compute` — the inference contract (verbatim from `src/runtime.rs` + `src/daemon.rs`)

### The trait (`RuntimeAdapter`)

```rust
pub trait RuntimeAdapter: Send + Sync {
    fn local_models(&self) -> Vec<LocalModelInventory>;
    fn create_reservation(&self, request: CreateReservationRequest) -> Result<ModelReservation>;
    fn reservations(&self) -> Vec<ModelReservation>;
    fn release_reservation(&self, reservation_id: &str) -> Result<()>;
    fn openai_models(&self) -> OpenAiModelListResponse;
    fn chat_completion(
        &self,
        request: OpenAiChatCompletionRequest,
    ) -> Result<OpenAiChatCompletionResponse>;
}
```

> **Note for the future adapter:** `chat_completion` is synchronous in x0x-compute. The conductor's
> `ConductorMeshDelegationPort` is async-ready (returns a boxed Future) so the adapter can `.await`
> an HTTP client behind a synchronous-looking call or wrap appropriately. This is a deliberate
> impedance decision recorded here, not a mismatch.

### Request / response (OpenAI-compatible)

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenAiChatCompletionRequest {
    pub model: String,
    pub messages: Vec<OpenAiChatMessage>,
    #[serde(default)]
    pub stream: bool,                 // SkeletonRuntimeAdapter REJECTS streaming (tested)
    #[serde(default)]
    pub max_tokens: Option<u32>,
    #[serde(default)]
    pub temperature: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenAiChatMessage {
    pub role: String,                 // e.g. "user", "assistant", "system"
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenAiChatCompletionResponse {
    pub id: String,
    pub object: String,
    pub created: u64,
    pub model: String,
    pub choices: Vec<OpenAiChatChoice>,
    pub usage: OpenAiUsage,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenAiChatChoice {
    pub index: u32,
    pub message: OpenAiChatMessage,
    pub finish_reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenAiUsage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
}
```

### HTTP surface (axum, `src/daemon.rs`)

Daemon binary: **`x0x-computed`** (`name = "x0x-computed"`). Routes:

| Method | Path | Handler | Relevance |
|---|---|---|---|
| GET | `/health` | `health` | liveness |
| GET | `/v1/identity` | `identity_handler` | peer identity |
| GET | `/v1/capabilities/local` | `local_capability` | this daemon's models |
| GET | `/v1/capabilities/peers` | `peer_capabilities` | **peers advertise model namespaces here** |
| GET | `/v1/config` | `config_view` | config view |
| GET | `/v1/models/local` | `local_models` | local model inventory |
| GET | `/v1/openai/models` | `openai_models` | OpenAI-style model list |
| POST | **`/v1/openai/chat/completions`** | `openai_chat_completions` | **the inference call** |
| DELETE | `/v1/reservations/:id` | `delete_reservation` | reservation teardown |

The chat handler is a thin pass-through:

```rust
async fn openai_chat_completions(
    State(state): State<AppState>,
    Json(request): Json<OpenAiChatCompletionRequest>,
) -> Result<Json<OpenAiChatCompletionResponse>> {
    let response = state.runtime.chat_completion(request)?;
    Ok(Json(response))
}
```

---

## `x0x` (v0.26.0) — transport primitives (NOT the inference path; recorded for completeness)

These are x0x-compute's internal transport, not Fae's integration surface. Fae does not call them.

### `send_direct` (DM — fire-and-forget + ACK)

```rust
// Agent::send_direct — sends a payload to a peer agent, returns an ACK receipt (NOT a response).
pub async fn send_direct(
    &self,
    to: &identity::AgentId,
    payload: Vec<u8>,
) -> Result<dm::DmReceipt, dm::DmError>;

pub async fn send_direct_with_config(
    &self,
    to: &identity::AgentId,
    payload: Vec<u8>,
    config: dm::DmSendConfig,
) -> Result<dm::DmReceipt, dm::DmError>;
```

> `DmReceipt` confirms the peer *received* the message, not an application-layer response. A
> request/response pattern would be built *on top of* DMs (peer receives, runs, replies via a second
> DM) — but `delegate_to_mesh` uses x0x-compute's HTTP completion endpoint instead, which already
> encapsulates that.

### `ExecService` (remote argv execution — also not the inference path)

```rust
pub struct ExecService { /* ... */ }

impl ExecService {
    pub fn spawn(/* agent, exec_policy, exec_dm_rx */) -> Arc<Self>;
    pub async fn run_remote(
        self: &Arc<Self>,
        target: AgentId,
        options: ExecRunOptions,            // { argv: Vec<String>, stdin, timeout_ms, ... }
    ) -> Result<ExecRunResult, ExecServiceError>;
    pub async fn cancel_remote(/* ... */) -> Result<(), ExecServiceError>;
    pub async fn shutdown(&self);
    pub fn enabled(&self) -> bool;
}

pub struct ExecRunResult {
    pub request_id: ExecRequestId,         // ExecRequestId(pub [u8; 16])
    pub code: Option<i32>,                 // exit code
    pub signal: Option<i32>,
    pub duration_ms: u64,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub stdout_bytes_total: u64,
    pub stderr_bytes_total: u64,
    pub truncated: bool,
    pub denial_reason: Option<DenialReason>,
    pub warnings: Vec<WarningKind>,
}

pub enum ExecServiceError {
    Protocol(String),
    Transport(String),
    Timeout,
    Denied(&'static str),
    ResponseChannelClosed,
}
```

> `ExecService` runs *arbitrary argv* on a peer (subject to ACL). Fae delegates *inference*, not
> process execution, so this is the wrong primitive. Recorded only because the original Tier-1 doc
> cited it; the snapshot confirms it is **not** the M4 path.

---

## Implications for M4-C (port contract) and M4-E (future adapter)

- **M4-C port:** the conductor's `ConductorMeshDelegationPort` carries its own prompt-free DTOs
  (`MeshDelegationRequest`/`Outcome`/`MeshOutcomeKind`). It does **not** reference
  `OpenAiChatCompletionRequest` or any x0x type. The DTO translation happens in the (future) adapter,
  behind the port — exactly as fae-metaopt's DTOs stay out of fae-daemon.
- **M4-E adapter (future):** maps `MeshDelegationRequest.prompt_slice` →
  `OpenAiChatCompletionRequest { model, messages: [{role:"user", content: slice}], max_tokens, .. }`,
  POSTs to `http://127.0.0.1:<port>/v1/openai/chat/completions`, maps the response's
  `choices[0].message.content` back to `MeshDelegationOutcome.answer`. Errors (non-2xx, timeout,
  connection refused) map to `MeshOutcomeKind::{TransportError, Timeout, PeerUnreachable}`. The
  `model` field comes from the worker's `model` registration (e.g. `qwen3.5-32b`).
- **`usage` tokens** (`OpenAiUsage`) flow into the conductor's budget governor as observed token
  counts (not cost — economics deferred). This is a budget-governance signal, not a billing signal.

---

## F-14 acceptance

- [x] Exact `RuntimeAdapter::chat_completion` signature recorded (verbatim).
- [x] Exact `OpenAiChatCompletionRequest`/`Response`/`Choice`/`Usage`/`Message` fields recorded.
- [x] HTTP route `POST /v1/openai/chat/completions` + handler recorded.
- [x] Commits recorded (`x0x@a6fce96`, `x0x-compute@c9f765b`) with working-tree status.
- [x] Decisive conclusion: `x0x-compute` is the inference contract; `x0x` is transport-only.
- [x] Skeleton-runtime caveat recorded (no real model; M4-E blocked on real backend).
