# M4 — Tier-1 Same-Owner x0x Sync (`delegate_to_mesh`, `OwnerFleet`)

**Status:** DRAFT (pre-advisor)
**Date:** 2026-06-27
**Owner:** David Irvine
**Predecessors:** M2-live (`7e63d567`), M3 (`7df3552c`), M4 classifier (`acdd04af`), M5 hardening (`68c12caf`, all on `origin/main`)
**Plan ref:** `docs/plans/fae-learned-conductor-m0-m3-rust-execution-plan-2026-06-22.md` → "After M3 → M4"
**Vision ref:** ADR-012 (`docs/adr/012-local-first-coordinator-of-external-ais.md`)

---

## 1. Goal

ADR-012 positions Fae as a **local-first coordinator of external AIs** ("head butler"): the on-device
model owns the relationship; anything heavy or specialist gets **dispatched** to other executors on a
**trust gradient**, with the PII membrane as the constant egress floor. The gradient's rungs are
already coded as `PrivacyLane`:

| Rung | `PrivacyLane` | Status |
|---|---|---|
| On-device model | `LocalOnly` | **Live** (M1/M2) |
| Cloud-backed agent / API | `CloudBacked` | **Live** (M2; `pure-local` default, opt-in) |
| Own fleet (same-owner peers) | `OwnerFleet` | **This milestone** |
| Trusted peer / Remote provider | `TrustedPeer` / `RemoteAllowed` | **Deferred** (M6+, ADR-gated) |

M4 adds the **`OwnerFleet` rung**: routing a task-scoped prompt slice to a **same-owner peer** running
a heavier model, and returning the completion. The concrete primitive is `delegate_to_mesh`.

**M4 ships DORMANT.** This is the deliberate posture of every prior cross-boundary slice (M2 reward
was observation; M3 recipe-mutation was offline/CLI-only; M4 classifier was rule-based before LLM).
Real network transport waits until the external `x0x-compute` engine has a real model backend (its own
milestone). M4 lands the **safety contract + port + dispatch + membrane proof** — gate-first applied
to cross-node egress, so the day real transport comes, it inherits proven guards rather than building
them under pressure.

**Dormancy, precisely:** production default has **no configured mesh port** — the conductor constructs
an `UnavailableMeshDelegationPort` that fail-closes (`MeshOutcomeKind::TransportError`) on every call.
`MockMeshDelegationPort` is **`#[cfg(test)]` / test-helper only — never constructed by
`ConductorRuntime::production(...)`**. So under `local-symphony` with no port configured, an
`OwnerFleet` route degrades to direct-local exactly as if the peer were unreachable. No mock ever
answers a real user turn. `ConductorRuntime::production(...)` uses `UnavailableMeshDelegationPort`
(or no port) and `OwnerFleet` routes fail closed direct-local. This is the same posture as M3
(mutation unreachable from a running daemon) and the classifier hard gate.

## 2. Owner decisions (greenlit 2026-06-27)

1. **Posture: DORMANT.** Port + mock + executor dispatch split + membrane proof. Zero new network
   egress. Matches M2/M3/classifier discipline. Ships now.
2. **Integration shape (recorded, decide at wiring time): REST-over-localhost.** When real transport
   comes, Fae talks to a localhost `x0x-computed` daemon via REST HTTP (matches the existing
   skill-integration pattern and keeps x0x types out of the conductor). NOT a crate dep. Decided at
   the wiring milestone, not here.
3. **Scope: `OwnerFleet` same-owner only.** No `TrustedPeer`/`RemoteProvider`, no group/presence/
   memory-sharing, no G5 consent-receipt work (all M6+/ADR-gated). The x0x metadata threat model's
   heavy concerns (`docs/security/x0x-metadata-threat-model.md`) are explicitly out of scope.
4. **Governance caps bind:** D2 *governance* caps (turn-count, timeout, wall-clock — **not cost**,
   which stays deferred per owner directive 2026-06-26) bound mesh delegation exactly as they bound
   cloud. The fail-closed ceiling is unaffected by pricing absence.

## 3. The F-14 finding: x0x API confirmed

F-14 ("confirm x0x crate API surface before implementation") is **resolved by reading the actual
crates**, not grep summaries. Findings:

| Crate | Commit | What it is | Relevance |
|---|---|---|---|
| `x0x` | `a6fce96` (v0.26.0) | Transport/identity/trust/mesh. `send_direct` (DM, ACK'd), `ExecService` (remote *argv* exec) | The **pipe**. **No LLM/inference API.** Not what Fae links against directly for inference. |
| `x0x-compute` | `c9f765b` (no tag) | **OpenAI-compatible chat-completion mesh**: `RuntimeAdapter::chat_completion`, HTTP route `POST /v1/openai/chat/completions` (also `/v1/openai/models`, `/v1/models/local`), peers advertise model namespaces (`qwen3.5:32b`) | **The `delegate_to_mesh` contract.** Phase 2a: contract designed, `SkeletonRuntimeAdapter` is a deterministic stub (no real model). Exactly the dormant posture M4 matches. |

**Decisive conclusion:** the "send a prompt to a peer's LLM, get a completion back" request/response
primitive **exists as a contract** (`x0x-compute`'s OpenAI-compatible API) but is **not yet backed by
real inference**. M4 targets that contract with a port + mock; real transport (REST-to-localhost-daemon)
ships when x0x-compute has a real backend.

**Exact API (confirmed by reading source, `x0x-compute/src/runtime.rs` + `daemon.rs`):**

*Tree status at read time:* `x0x-compute@c9f765b` had a dirty working tree (modified `.gitignore`, `AGENTS.md`;
untracked `.pi/`) — these are non-source, so the **API structs/route below are clean-tree**. `x0x@a6fce96`
had one untracked test script (non-source). The F-14 snapshot doc (M4-B) will re-record clean-tree hashes
at snapshot time if needed.

```rust
// RuntimeAdapter::chat_completion — the inference primitive (synchronous in x0x-compute)
trait RuntimeAdapter: Send + Sync {
    fn chat_completion(&self, request: OpenAiChatCompletionRequest)
        -> Result<OpenAiChatCompletionResponse>;
}

struct OpenAiChatCompletionRequest {
    model: String,
    messages: Vec<OpenAiChatMessage>,  // { role: String, content: String }
    stream: bool,                     // skeleton REJECTS streaming (tested)
    max_tokens: Option<u32>,
    temperature: Option<f32>,
}

struct OpenAiChatCompletionResponse {
    id: String, object: String, created: u64, model: String,
    choices: Vec<OpenAiChatChoice>,   // { index, message, finish_reason }
    usage: OpenAiUsage,               // { prompt_tokens, completion_tokens, total_tokens }
}

// HTTP surface (axum): POST /v1/openai/chat/completions → openai_chat_completions
// handler delegates straight to state.runtime.chat_completion(request).
// Localhost daemon only; peers advertise model namespaces (e.g. "qwen3.5:32b").
```

`send_direct`/`ExecService` in `x0x` proper are transport/argv-exec primitives (no LLM) and are
NOT the inference path — Fae's REST adapter talks to `x0x-computed`'s HTTP surface, not x0x's DM/exec
layer directly. The DM/mesh transport is x0x-compute's internal concern.

**Mode-cap already supports `OwnerFleet` (verified in code):** `ModelMode::LocalSymphony` exists in
`crates/fae-daemon/src/conductor/policy.rs`, and `mode_permits_lane(LocalSymphony, OwnerFleet)` is
`true`. No enum work is needed for M4 — the lane is already permitted under the opt-in `local-symphony`
mode; default stays `PureLocal`. This removes a whole category of risk (the M2 prose mode is real).

## 4. The F-2 finding: membrane coverage of `OwnerFleet`

F-2 (the long-running egress-membrane work-package `ConductorEgressMembrane`) is **largely satisfied
by M2**, but M4 must *prove* it rather than assume it:

- `fae-pii-membrane::should_block_remote_egress` exists (530 lines, golden-parity with Swift
  `SensitiveContentPolicy`, tested).
- The §5.3 gate (`conductor-m2-reward-eval-shadow-routing-spec` §5) is wired and **already treats
  `OwnerFleet` as a remote-egress lane** alongside `CloudBacked` (`executor.rs:684`).
- The v1 safe profile permits `OwnerFleet` (`recipe.rs:370`); `PrivacyLane::permits` is monotone.

**What's missing:** an *explicit* proof and a *named* surface. The current code calls
`fae_pii_membrane::should_block_remote_egress` *incidentally*; F-2 wants it *named* as the egress
authority so the guarantee is structural, not incidental. **M4-A closes this with a REQUIRED thin
`ConductorEgressMembrane` wrapper** (not optional) around `should_block_remote_egress`, so every
remote-egress lane (`CloudBacked` + `OwnerFleet`) routes through one named authority and the F-2
proof is a structural guarantee, not a call-site convention.

## 5. The F-13 finding: `MeshDelegationServer` ↔ pipeline contract

F-13 (`MeshDelegationServer` → Rust pipeline integration contract defined before implementation) is
the **core M4 work**. Today the executor routes any non-`LocalOnly` decision to `run_cloud_chain`/
`run_cloud_direct`; there is no `OwnerFleet`-specific dispatch. F-13 defines the contract:

**Invariants (load-bearing):**
1. Mesh delegation receives **only the task-scoped prompt slice AFTER the normal §5 gate pipeline**
   (mode-cap → membrane → budget → provisioning/standing-grant). It never runs before egress gating.
2. It **never reads** the memory store (`fae.db`) or `MemoryOrchestrator`. The slice is all it gets.
3. It **never bypasses** mode cap, membrane, budget, or the provisioned standing grant. (The grant
   *is* the consent — ADR-012 principle 2 — for a same-owner, provisioned peer.)
4. It returns **answer / error / latency only**. Telemetry stores labels/ids, **never** prompt bodies.
5. Failure (peer unreachable, timeout, denial, transport error) **fails closed to direct-local** —
   exactly like a `CloudBacked` route that exceeds budget. No partial egress.

## 6. Design — the port (keeps x0x types out of the conductor core)

Mirroring the fae-metaopt boundary discipline: x0x types stay out of the conductor core. The conductor
talks to a **port trait**; a mock implements it for tests/dormant mode; a future REST adapter
implements it for real transport. A boundary guard (extend
`scripts/ci/guard-metaopt-boundary.sh` or a sibling) machine-enforces "no `x0x`/`x0x_compute` token
in conductor core."

```text
                         ConductorTurnContext
                                  │
                    policy.decide ──▶ OwnedRouteDecision { lane, worker_id, topology, approval }
                                  │
                    ┌───────────── §5 gate pipeline (mode cap → membrane → budget → approval) ─┐
                                  │
              ┌───────────────────┼─────────────────────┐
              ▼                   ▼                     ▼
         LocalOnly           CloudBacked            OwnerFleet
         (local model)       (cloud/ACP)        (delegate_to_mesh)
              │                   │                     │
              │            run_cloud_*           ┌──────┴────────┐
              │                                 ▼               ▼
              │                          ConductorMeshDelegationPort  ◀── mock (M4)
              │                          .delegate(slice) → answer/err   ◀── REST adapter (future)
              │
              ▼
          run()
```

The port (in conductor core; **async-ready** so the future REST adapter is not a trait redesign):

```rust
/// The result of delegating a task-scoped prompt slice to a same-owner peer.
///
/// Telemetry safety: the OUTCOME is the prompt-free projection (ids + outcome
/// kind + latency). The `answer` field is transient response data returned to
/// the user via the normal completion path; it is NEVER persisted in conductor
/// telemetry (mirrors RecipeMutationRecord's F-4 discipline).
pub struct MeshDelegationOutcome {
    /// Fresh per-delegation correlation id, NOT the conductor request_id (which
    /// would leak a stable cross-turn identifier to the peer). See §6 metadata.
    pub mesh_request_id: String,
    pub peer_worker_id: String,
    /// Transient answer; returned to the user, never persisted in telemetry.
    pub answer: Option<String>,
    pub latency_ms: u64,
    pub outcome_kind: MeshOutcomeKind,
}

pub enum MeshOutcomeKind {
    Completed,
    PeerUnreachable,
    Timeout,
    Denied,        // peer refused (ACL/capability)
    TransportError, // incl. "no port configured" (dormant production default)
}

/// The conductor's view of mesh delegation. x0x types NEVER cross this boundary.
///
/// Async-ready (returns a boxed Future) so the future REST-to-localhost-daemon
/// adapter does not require a trait redesign. The dormant production default is
/// `UnavailableMeshDelegationPort` (fail-closed); tests inject `MockMeshDelegationPort`.
pub trait ConductorMeshDelegationPort: Send + Sync {
    /// Delegate a task-scoped prompt slice to a provisioned same-owner peer.
    /// Contract: the caller (executor) has ALREADY run the §5 gate pipeline;
    /// this receives only the slice that cleared egress gating.
    fn delegate<'a>(
        &'a self,
        request: MeshDelegationRequest,
    ) -> std::pin::Pin<
        Box<dyn std::future::Future<Output = MeshDelegationOutcome> + Send + 'a>,
    >;
}

pub struct MeshDelegationRequest {
    /// Fresh per-delegation correlation id (not the conductor request_id).
    pub mesh_request_id: String,
    pub peer_worker_id: String,
    /// The task-scoped prompt slice. This is `prompt_from_command(cmd)` today
    /// (NOT durable recalled memory). Sending recalled context across the mesh
    /// boundary is BLOCKED until explicit per-call minimization rules exist
    /// (ADR-012 principle 3 enforcement note).
    pub prompt_slice: String,
    pub max_output_tokens: u32,
    pub timeout_ms: u64,
}
```

## 6.1 Metadata minimization (cross-boundary identifier hygiene)

The mesh boundary must not leak stable cross-turn identifiers to a peer:

- **No raw conductor `request_id` crosses the mesh.** The conductor's `request_id` is a stable
  per-turn id (HMAC'd for telemetry via `RequestFingerprint`, F-4). Sending it to a peer lets the
  peer correlate turns across time. Instead, `MeshDelegationRequest.mesh_request_id` is a **fresh,
  per-delegation** correlation id with no cross-turn meaning.
- **No raw session/user IDs.** Telemetry correlation stays local (HMAC/fingerprint pattern); the
  peer sees only the opaque `mesh_request_id` + `peer_worker_id`.
- **`prompt_slice` is the only user content.** Today that's `prompt_from_command(cmd)` only — NOT
  durable recalled memory (which never leaves the device, ADR-012 principle 3). Sending recalled
  context across the mesh is BLOCKED until explicit per-call minimization rules are coded.
- This is narrower than the full x0x metadata threat model (social graph / presence / group
  membership) — those are M6+/ADR-gated and out of scope. M4's metadata hygiene is scoped to the
  per-call delegation payload.

## 7. Slices

Each slice is independently shippable; per-stage gate is `-p fae-daemon` + the boundary guard.

| Slice | What | Gate |
|---|---|---|
| **M4-0** | This spec (advisor-reviewed) | doc |
| **M4-A** | F-2 closure: REQUIRED thin `ConductorEgressMembrane` wrapper around `should_block_remote_egress` (every remote-egress lane routes through it). Unit proof: `OwnerFleet` + credential-prompt ⇒ `PrivacyBlocked` **before any remote-egress dispatch**. (The "mesh port not invoked" proof lands in M4-D, once the port exists.) | `-p fae-daemon` |
| **M4-B** | F-14 confirmation artifact: `docs/architecture/conductor-m4-f14-x0x-api-snapshot.md` recording both commits + exact API signatures (see §3 + the snapshot). | doc |
| **M4-C** | F-13 port contract: async-ready `ConductorMeshDelegationPort` + DTOs in conductor core; `MockMeshDelegationPort` (`#[cfg(test)]`/test-only) + `UnavailableMeshDelegationPort` (production fail-closed default). Boundary guard: **scoped to deps/imports, NOT comment tokens** — forbids `x0x`/`x0x_compute` in `crates/fae-daemon/Cargo.toml` and any `use x0x`/`x0x::`/`x0x_compute::` import in `crates/fae-daemon/src/conductor/**` (existing prose comments mention x0x as architecture context and are intentionally ALLOWED). Mutation-tested. | `-p fae-daemon` + guard |
| **M4-D** | Executor dispatch split + integration proof: route by worker locality/lane. `LocalOnly` → local; `CloudBacked` → cloud path (unchanged); `OwnerFleet` → mesh port. Unsupported lanes (`TrustedPeer`/`RemoteAllowed`) **fail closed** (already do; make explicit). Integration proof: `OwnerFleet` + credential-prompt ⇒ `PrivacyBlocked`, fail-closed direct-local, **injected mock mesh port call-count = 0** (the port exists now). | `-p fae-daemon` |
| **M4-F** | Observability: prompt-free telemetry (`MeshDelegationOutcome` projects ids/labels only — `answer` is transient, never persisted), budget receipt (turn-count/timeout, no cost), timeout/fallback proven via acceptance test, assert no `fae.db`/memory egress. | `-p fae-daemon` |
| **M4-E (FUTURE)** | Real REST adapter to localhost `x0x-computed`. **Not an M4 slice — a future transport milestone**, blocked on x0x-compute gaining a real model backend (its `SkeletonRuntimeAdapter` is a deterministic stub today). Recorded for sequencing; not in M4 acceptance. | n/a |

## 8. Scope boundaries (the "not in M4" list)

- **No real network transport.** Mock only. No `x0x`/`x0x_compute` in `Cargo.toml`.
- **No `all-available` default flip.** Default stays `pure-local`. `local-symphony` (LocalOnly +
  OwnerFleet) is the opt-in mode M4 is reachable under.
- **No live mutation, no classifier upgrade.** Separate owner-gated decisions.
- **No peer/group/presence/memory-sharing.** All M6+/ADR-gated (threat model's heavy concerns stay
  out of scope: social graph, consent receipts, group membership, MASQUE relay policy).
- **No cost/pricing.** Economics deferred per owner directive. D2 governance caps (turns/timeout)
  still bind.

## 9. Test plan

- **M4-A (F-2):** `ownerfleet_credential_prompt_blocked_before_dispatch` — construct an
  `OwnerFleet` route decision + a credential-shaped prompt; assert `RouteFailure::PrivacyBlocked`
  at the membrane gate (before any remote-egress dispatch path). (The "mesh port call-count 0"
  assertion lands in M4-D once the port is injectable.)
- **M4-C/D (F-13):** `ownerfleet_route_delegates_through_port` — happy path: `OwnerFleet` decision
  after clearing §5 gates calls the injected mock port once with the post-membrane slice (carrying a
  FRESH `mesh_request_id`, not the conductor `request_id`); outcome is returned to the user.
  `ownerfleet_credential_prompt_mesh_port_not_invoked` — `OwnerFleet` + credential prompt ⇒
  `PrivacyBlocked` + injected mock mesh port **call-count = 0** (the port exists now, so this is
  the strong F-2 integration proof).
  `mesh_failure_fails_closed_to_direct_local` — port returns `PeerUnreachable`/`Timeout`/
  `Denied`/`TransportError` → executor degrades to direct-local (success path preserved).
  `no_port_configured_fails_closed` — with the production `UnavailableMeshDelegationPort`, an
  `OwnerFleet` route degrades to direct-local (no mock ever answers a real turn).
- **M4-F (observability):** `mesh_telemetry_is_prompt_free` — after an `OwnerFleet` turn, grep the
  isolated conductor store (`conductor_route_events`/`receipts`/shadow) for a sentinel prompt;
  absent. Assert the transient `answer` is NOT persisted in any telemetry file. Assert budget receipt
  recorded (turn-count/timeout). Assert `fae.db` untouched.

## 10. Acceptance

- [ ] F-2 closed: REQUIRED `ConductorEgressMembrane` wrapper routes all remote-egress lanes;
      M4-A unit proof `OwnerFleet` + credential prompt ⇒ `PrivacyBlocked` before dispatch; M4-D
      integration proof injected mock mesh port call-count 0 (once the port exists).
- [ ] F-14 recorded: snapshot doc with `x0x@a6fce96` / `x0x-compute@c9f765b` + exact API (§3).
- [ ] F-13 closed: async-ready `ConductorMeshDelegationPort` + DTOs in conductor core;
      `MockMeshDelegationPort` (`#[cfg(test)]` only) + `UnavailableMeshDelegationPort`
      (production default, fail-closed; `production(...)` never uses the mock); boundary guard
      forbids `x0x`/`x0x_compute` **deps/imports** (Cargo.toml + `use x0x`/`x0x::`/`x0x_compute::`)
      in conductor surfaces — prose comments mentioning x0x are allowed (mutation-tested).
- [ ] Executor splits dispatch by locality/lane; `OwnerFleet` → port, `CloudBacked` → cloud,
      `LocalOnly` → local, others fail closed.
- [ ] `mesh_request_id` is fresh per-delegation (not the conductor `request_id`); no raw
      session/user IDs cross the mesh boundary.
- [ ] Mesh failure (incl. no-port-configured) ⇒ fail-closed direct-local.
- [ ] Telemetry prompt-free; transient `answer` never persisted; budget receipt recorded; no
      `fae.db`/memory egress.
- [ ] No `x0x`/`x0x_compute` in any fae Cargo.toml (dormant).
- [ ] Default mode unchanged (`pure-local`); `local-symphony` opt-in is the only reachable path.
- [ ] Standard gates green: `cargo fmt` / `clippy -D warnings` / `check --workspace` / `test` /
      boundary guard / release-validation PR-attestation gate (M5).

## 11. Risks

- **Real transport never comes (x0x-compute stays skeleton).** Acceptable — M4's value is the proven
  safety contract, which holds regardless. The port + mock cost little to maintain.
- **Boundary leak (x0x type smuggled into conductor).** Mitigated by machine-enforced guard
  (mutation-tested), mirroring fae-metaopt's discipline.
- **Over-claiming "Fae can now coordinate external AIs."** M4 is dormant — the *contract* lands, not
  the capability. Acceptance and messaging state this explicitly (§1, §8).
- **Slice ordering.** M4-C (port) must land before M4-D (dispatch) — the dispatch needs something
  to call, and the M4-D "mesh port call-count 0" proof needs the port to exist. M4-A (membrane wrapper)
  is independent of M4-C and may land first; M4-F (observability) is last. M4-E (real transport) is a
  future milestone, not in this sequence. Recommended order: M4-A → M4-B → M4-C → M4-D → M4-F.
