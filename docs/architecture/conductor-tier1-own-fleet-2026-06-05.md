# Fae Conductor — Tier 1: Own-Fleet Sync Delegation

> Status: **Design draft** (2026-06-05) · Owner: David Irvine · Layer: headless Rust core
> Scope: **Tier 1 only** — Fae coordinating *one human's own* agents across *their own* machines (single `UserId`).
> Companion: cross-owner delegation is **Tier 2**, designed separately in
> [`conductor-capability-grants-2026-06-05.md`](./conductor-capability-grants-2026-06-05.md).

## 1. Purpose

Turn Fae from an oracle (a local model that must know everything) into a **conductor** (a small, personal model that knows *where to find* capability and routes to it). Tier 1 is the minimum that proves the thesis and ships: **Fae reaches your other machines' agents over x0x, gets an answer or a result back, and speaks it.** No other human is involved, so the heavy cross-owner governance does not yet apply — but control-plane auth and audit still do.

The product claim Tier 1 delivers: *"Fae on my phone got smarter because she reached my Mac."*

## 2. Why this is the right first slice

- It rides the **already-greenlit** "1:1 Fae↔Fae over direct-QUIC" lane (`cross-platform-engine-plan-2026-05-30.md` §11A). No new gate.
- It is **same-owner**, so it sidesteps S12 (peer-memory disclosure), G5 production enforcement, TreeKEM, and the peer-tool-authorization design gate. Those are all Tier 2.
- The local conductor brain is **proven**: Gemma-4 E4B in mistral.rs — 65 tok/s, audio-in STT, tool calling (S13, done). Routing is a tool-calling judgment, which E4B does well.
- It is the smallest unit of genuinely novel product: a voice conductor for a personal, multi-machine agent fleet.

## 3. Non-goals (Tier 1)

- **No cross-owner delegation.** Another person's agent doing work for you, or you for them → Tier 2 (capability grants).
- **No group/mesh broadcast.** No x0x groups, no "the Fae". Tier 1 is point-to-point within one `UserId`.
- **No async work orchestration.** The x0x-symphony issue/claim/handoff loop (Runner/Tracker) is **Phase 2** (§11). Tier 1 is synchronous request→response only.
- **No peer-sourced memory writes.** Results from your own fleet are same-owner data, but they still enter memory only through the normal inbound gate with `provenance = inferred` or `tool` and appropriate `data_class` (see §9). No new memory path.

## 4. The two delegation modes (Tier 1 implements only the first)

| Mode | Transport | Shape | Tier 1? |
|------|-----------|-------|---------|
| **Sync delegation** (`delegate_to_mesh`) | x0x direct QUIC, app-layer req/resp | ask → await answer/result | **Yes** |
| **Async orchestration** (`orchestrate_work`) | x0x-symphony over CRDT TaskList | fire → claim → workspace → signed handoff | Phase 2 |

## 5. Where it sits

```
                 Thin client (SwiftUI+Metal orb / Dioxus-Tauri)
                              │  WS / Unix socket, ADR-002
                 ┌────────────▼─────────────────────────────────┐
                 │            Headless Rust core (daemon)        │
                 │                                               │
                 │  Pipeline → Conductor Router (E4B judgment)   │
                 │       │                │                      │
                 │   local tools      delegate_to_mesh           │
                 │   local LLM         │                         │
                 │                     ▼                         │
                 │              MeshDelegationClient             │
                 │              (correlation shim)               │
                 │                     │  send_direct/recv_direct│
                 └─────────────────────┼─────────────────────────┘
                                       │  x0x direct QUIC (ML-DSA-65, ML-KEM-768)
                 ┌─────────────────────▼─────────────────────────┐
                 │   Remote machine (same UserId)                 │
                 │   x0x Agent → MeshDelegationServer             │
                 │        → local Fae core (LLM / tool / runner)  │
                 └────────────────────────────────────────────────┘
```

The Conductor Router is a stage in the existing agent loop, not a new subsystem. `MeshDelegationClient`/`Server` are the only genuinely new code; everything beneath them (x0x `Agent`, identity, transport) exists.

## 6. Gap 1 — the correlation shim (the one piece of new substrate)

**Finding (source-verified 2026-06-05).** x0x has no *application-level* correlated request/response over direct QUIC, but it has the exact pattern to mirror:
- `ExecService::run_remote(target: AgentId, options: ExecRunOptions) -> Result<ExecRunResult, ExecServiceError>` (`src/exec/service.rs:198`) is **argv-exec only** — allowlisted commands, `(AgentId, MachineId)` ACL, lease-renewed streaming.
- `send_direct(to: &AgentId, payload: Vec<u8>) -> Result<DmReceipt, DmError>` (`src/lib.rs:2962`) is fire-and-forget; `recv_direct() -> Option<DirectMessage>` / `subscribe_direct() -> DirectMessageReceiver`. `DirectMessage { sender, machine_id, payload, received_at, verified, trust_decision }`.
- **But** the DM layer *already* carries a `request_id: [u8;16]` (`DmReceipt`/`DmPayload`, `src/dm.rs:131`) and runs a `DmAckWaiter` oneshot-registry (`register(request_id) -> oneshot::Receiver`, `resolve(request_id, outcome)`, `src/dm.rs:891`) — for **transport delivery acks**, not logical replies.

So Tier 1 builds a thin **application-level** request/response layer that **mirrors x0x's own proven `DmAckWaiter` design** (so the pattern is battle-tested, not invented). The logical reply is a *fresh* `send_direct` from the remote carrying our app `request_id` in its payload envelope — we do not overload the transport-ack `request_id` (the response is a new message with its own transport id). We deliberately do **not** model delegation as `ExecService` argv-exec — exec is for running allowlisted *binaries*, not "answer this with your LLM"; forcing LLM delegation through an argv allowlist is the wrong abstraction. `ExecService` is reserved for Tier 2 attested command execution (`Exec` scope).

### 6.1 Wire envelope (`fae.delegate/v1`)

Carried as the `payload: Vec<u8>` of a x0x direct message (CBOR or canonical JSON; CBOR preferred for size):

```rust
struct DelegationRequest {
    v: u8,                       // = 1
    request_id: [u8; 16],        // 128-bit, client-allocated, random
    kind: DelegationKind,        // Ask | RunTool | RunSkill  (closed enum)
    payload: DelegationPayload,  // typed per kind
    deadline_ms: u32,            // client's hard timeout (server must beat it)
    issued_at_ms: u64,
}

enum DelegationKind { Ask, RunTool, RunSkill }   // Tier 1: same-owner only

enum DelegationPayload {
    Ask   { prompt: String, max_tokens: u32, want_audio: bool },
    RunTool { tool: String, args: serde_json::Value },
    RunSkill { skill: String, input: serde_json::Value },
}

struct DelegationResponse {
    v: u8,                       // = 1
    request_id: [u8; 16],        // echoes the request
    status: DelegationStatus,    // Ok | Denied | Error | Timeout
    body: DelegationBody,        // text + optional structured + optional audio ref
    usage: Option<Usage>,        // tokens, ms — feeds routing telemetry
    served_at_ms: u64,
}
```

### 6.2 Correlation & lifecycle

- `MeshDelegationClient` keeps an in-memory `HashMap<[u8;16], oneshot::Sender<DelegationResponse>>`.
- `send()`:
  1. allocate `request_id`, register the oneshot,
  2. `agent.send_direct(&target, encode(req))`,
  3. `tokio::time::timeout(deadline, rx)` — on elapse, drop the entry and return `Timeout`.
- A single background task drains `agent.subscribe_direct()`; for each `DirectMessage` it decodes the envelope, looks up `request_id`, and fulfils the oneshot. Unknown/expired `request_id` → dropped + audit-logged (defends against late/replayed responses).
- **Chunking:** x0x direct payload cap is 16 MB; `Ask` answers and tool JSON fit comfortably. Audio results are *referenced*, not inlined (see §6.3).

### 6.3 Audio

`Ask{ want_audio }` does **not** stream TTS audio back over the delegation channel in Tier 1. The remote returns *text*; the **local** core synthesises with its own Kokoro so the voice stays consistent and latency stays local. (Remote TTS streaming is a Phase-2 nicety, not a Tier-1 need.)

### 6.4 Reliability

- `send_direct` falls back to gossip-DM when the peer isn't directly connected (x0x handles this), so delegation works phone↔home through NAT. But gossip-DM is best-effort — the client's `deadline_ms` is the authority; on timeout the conductor degrades gracefully (§8).
- Idempotency: `RunTool`/`RunSkill` may have side effects. Tier 1 marks each request with `request_id`; the server keeps a short-TTL seen-set to drop duplicate deliveries. Non-idempotent tools (writes) require local approval *before* delegation is even attempted (§9), so a lost-ack retry never silently double-executes.

## 7. Control-plane commands (ADR-002)

Two new commands in the existing `{v, request_id, command, payload}` envelope (`daemon-control-plane.md`). They fill the `send_to_peer (TBD)` seam.

### `delegate_to_mesh` (Tier 1)
```jsonc
{ "v": 1, "request_id": "...", "command": "delegate_to_mesh",
  "payload": {
    "target": { "by": "agent_id" | "user_self_fleet" | "capability",
                "value": "<agent_id hex>" | null,
                "capability": "heavy_reasoning" | "vision" | "code" | "research" | null },
    "kind": "ask" | "run_tool" | "run_skill",
    "ask": { "prompt": "...", "max_tokens": 512 },
    "deadline_ms": 20000
  } }
```
Requires control-plane scope `mesh.delegate`. Emits `mesh.delegation.started` / `…​.completed` events on the WS stream so the thin client can show "asking your Mac…".

### `orchestrate_work` (Phase 2 stub — reserved, not implemented in Tier 1)
Reserved name so the protocol doesn't churn later. Documented in §11.

## 8. The routing decision (the conductor brain)

Routing is a **judgment call** the E4B model makes via tool-calling — exactly the surface CLAUDE.md Rule 5 says to use the model for. The router exposes `delegate_to_mesh` to the LLM as a tool alongside local tools. The model decides:

- **Answer locally** — greetings, personal/memory questions, anything the small model is confident on. Default.
- **Delegate (sync)** — "this needs more reasoning / a bigger model / a specialist / a capability I lack." E.g. hard reasoning → home dense 14B; screenshot analysis → a VLM agent; "search and verify X" → a research agent.

Routing policy is **not hand-coded heuristics** — it's a fine-tuneable behaviour:

- The improvement loop already collects feedback. Add a routing signal: *did the chosen route produce a better outcome than the alternative?* This becomes a DPO/eval target.
- New benchmark metric for `FaeBenchmark`: **routing accuracy** — given a query and a known-best route, did the conductor pick it? This replaces "did she answer well" with "did she route well," matching the new altitude.
- Guardrail: a deterministic **floor** — if the local confidence/answerability signal is high and no capability gap is detected, do not delegate (latency + battery). The model may delegate; code prevents *needless* delegation via a cheap pre-check, never forces it.

### Fallback ladder
1. Try delegate to best target.
2. Target offline / timeout → try next-best same-fleet target (presence-filtered).
3. No target reachable → **answer locally and say so** ("I couldn't reach your Mac, so here's my best local take"). Never silently pretend the mesh answered.

## 9. Governance within Tier 1 (lighter, not absent)

Same-owner removes cross-owner consent, but four controls remain:

1. **Control-plane auth.** `delegate_to_mesh` requires the `mesh.delegate` scope on the client's bearer token (`daemon-control-plane.md` per-message auth). A thin client without it cannot delegate.
2. **Target verification.** The conductor only delegates to agents where `agent.is_agent_machine_verified(agent_id, machine_id)` and the agent resolves under the owner's own `UserId` via `find_agents_by_user(self.user_id)`. **A delegation target that is not provably the same owner is refused and downgraded to Tier 2** (capability grant required). This is the hard boundary between the two docs.
3. **Write-tool approval stays local.** If `kind = run_tool` and the tool mutates (write/edit/bash/Apple-write), the **local** TrustedActionBroker / approval overlay runs *before* the request leaves the machine. We never export an unapproved mutation. Reads are ungated as today (Apple-read precedent).
4. **Audit.** Every delegation logs to `SecurityEventLogger`: `request_id`, target `(AgentId, MachineId)`, `kind`, tool/skill name, status, latency, and a payload **hash** (not raw content). Mirrors the existing CoWork external-call audit.

### Memory handling
Results enter memory **only** through the existing inbound write gate (`memory-migration-plan.md`). Same-owner fleet results carry `provenance = inferred` (for `Ask`) or `tool` (for `RunTool`/`RunSkill`), `ingestion_path = tool`, `data_class = local_operational` unless the user explicitly asks to remember a fact (then normal capture). **No `peer_claim` / `peer_envelope` path is used in Tier 1** — that path is Tier 2 and stays closed here.

## 10. Failure modes & limits

| Failure | Behaviour |
|---------|-----------|
| Target offline | presence pre-check skips it; fallback ladder (§8). |
| Response lost (gossip-DM) | client `deadline_ms` fires → `Timeout` → local fallback. |
| Duplicate delivery | server seen-set drops dup; non-idempotent already locally approved. |
| Malformed/late response | unknown `request_id` dropped + audited. |
| Wrong owner target | refused at §9.2, surfaced as "that agent isn't yours — want to request access?" (Tier 2 hook). |
| Mesh entirely unreachable | answer locally, say so. Conductor degrades to oracle, never lies. |

## 11. Phase 2 preview — async orchestration (`orchestrate_work`)

Out of scope to build now; recorded so Tier 1 doesn't paint us into a corner.

- x0x-symphony is **traits only** (`Runner`/`Tracker`/`Workspace`) — no dispatch loop, no x0x-CRDT `Tracker` adapter. Phase 2 builds: (a) an x0x-TaskList-backed `Tracker`, (b) the dispatch loop, (c) `Runner` adapters where **Hermes / Codex / Claude Code become interchangeable runners**.
- `orchestrate_work` creates a CRDT TaskList `Issue`; for **own-fleet** Phase 2 the claiming agent is one of your machines (Primary by XOR-shard, `ShardRole::Primary`). Cross-owner claiming is Tier 2.
- The conductor routes "this is a *body of work*, not a question" → `orchestrate_work`; "I need an answer now" → `delegate_to_mesh`. Same routing brain, second tool.

## 12. Acceptance criteria (Tier 1 done when)

- [ ] `MeshDelegationClient`/`Server` round-trips `Ask` phone↔home (same `UserId`) over `send_direct`/`recv_direct` with `request_id` correlation, under a real deadline, with timeout→local-fallback proven.
- [ ] `delegate_to_mesh` exposed in ADR-002 control plane behind `mesh.delegate` scope; WS start/complete events fire.
- [ ] Conductor router exposes delegation as an LLM tool; deterministic no-needless-delegation floor in place.
- [ ] Same-owner target verification (`is_agent_machine_verified` + `find_agents_by_user(self)`); non-same-owner refused and routed to Tier 2 hook.
- [ ] Write-tool delegation gated by local approval before send; audit entries (hashed payload) for every delegation.
- [ ] Results enter memory only via inbound gate with `inferred`/`tool` provenance, never `peer_claim`.
- [ ] `FaeBenchmark` routing-accuracy metric exists and is recorded.
- [ ] Works on Apple + Linux (v1 scope). Windows deferred (S11, post-v1).

## 13. Open questions

1. **Self-fleet capability advertisement.** How does the home Mac tell the phone "I have a dense 14B / a VLM / a code runner"? **Designed in [`conductor-capability-advertisement-2026-06-05.md`](./conductor-capability-advertisement-2026-06-05.md)** — a `fae.capabilities/v1` descriptor, fleet-distributed by direct-message handshake (not gossip), consumed by the router's `CapabilityIndex`. Unified with the Tier-2 cross-owner advertisement need.
2. **Deadline policy by kind.** `Ask` ~15–20 s; `RunTool` varies wildly. Per-kind defaults + user override.
3. **CBOR vs JSON** on the wire — CBOR for size, but JSON is debuggable. Lean CBOR with a debug flag.
4. **Pre-check confidence signal** for the no-needless-delegation floor — reuse the implicit-feedback/answerability signals, or a cheap separate classifier?

## 14. References
- `cross-platform-engine-plan-2026-05-30.md` (Rev 13) — engine, x0x §11A, brain/face §12.
- `daemon-control-plane.md` — ADR-002 envelope, bearer-token scopes, per-message auth.
- `conductor-capability-grants-2026-06-05.md` — Tier 2 cross-owner grants (the boundary at §9.2).
- `memory-migration-plan.md` — inbound write gate, provenance/`data_class`.
- `fae-to-fae-governance.md` (G5), `directive-and-soul-migration.md` (W3).
- `docs/spikes/S13-mistralrs-eval.md` — E4B conductor brain proof.
- x0x: `src/direct.rs` (`send_direct`/`recv_direct`/`subscribe_direct`), `src/exec/service.rs` (`run_remote`), identity (`MachineId`/`AgentId`/`UserId`), `find_agents_by_user`, `is_agent_machine_verified`.
