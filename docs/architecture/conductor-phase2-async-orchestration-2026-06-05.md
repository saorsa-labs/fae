# Fae Conductor — Phase 2: Async Work Orchestration

> Status: **Design draft** (2026-06-05) · Owner: David Irvine · Layer: headless Rust core
> Phase 2 of the conductor. Phase 1 = [`conductor-tier1-own-fleet-2026-06-05.md`](./conductor-tier1-own-fleet-2026-06-05.md) (sync).
> Authorization = [`conductor-capability-grants-2026-06-05.md`](./conductor-capability-grants-2026-06-05.md).
> Discovery = [`conductor-capability-advertisement-2026-06-05.md`](./conductor-capability-advertisement-2026-06-05.md).

## 1. Purpose

Tier-1 delegation answers a *question* now. This spec handles a *body of work*: "research X overnight," "fix this bug," "migrate this module" — fire it, let an agent claim and execute it in an isolated workspace, get a signed result back. This is where **Hermes / Codex / Claude Code / local Fae become interchangeable `Runner`s** under one conductor — the commoditisation thesis as code.

The conductor's routing brain gets a third tool: *"is this an answer-now question (`delegate_to_mesh`) or a unit-of-work (`orchestrate_work`)?"* Same E4B judgment, fine-tuneable, benchmarkable.

## 2. The three things x0x-symphony does **not** ship (we build them)

**Source-verified (2026-06-05):** `x0x-symphony-core` is **traits + types only**. Confirmed: **no orchestrator, no dispatch loop, no bin/, no JSONL adapter, no x0x-CRDT adapter.** It depends only on `async-trait`/`futures-core`/`serde`/`thiserror` — **not on x0x** (transport-agnostic by design). So we build, in a new crate (`fae-conductor-orchestrator`) that depends on *both* x0x and x0x-symphony-core:

1. **`X0xWorkTracker`** — implements symphony's `Tracker` trait over x0x storage (§4). The load-bearing adapter.
2. **`ConductorOrchestrator`** — the poll→claim→run→handoff dispatch loop symphony omits (§5).
3. **`Runner` adapters** — Local / ACP / Subprocess / CrossOwner (§6).

## 3. Verified trait surface we implement

```rust
// x0x-symphony-core, all #[async_trait]
trait Tracker {
    async fn fetch_candidates(&self, ctx: &PollContext) -> Result<Vec<Issue>>;
    async fn fetch_by_ids(&self, ids: &[IssueId]) -> Result<Vec<Issue>>;
    async fn claim(&self, id: &IssueId, agent_id: &AgentId) -> Result<Claim>;
    async fn heartbeat(&self, claim: &Claim) -> Result<()>;
    async fn release(&self, claim: &Claim, reason: ReleaseReasonCode) -> Result<()>;
    async fn handoff(&self, claim: &Claim, handoff: Handoff) -> Result<()>;
}
trait Runner {                          // runner.rs:613
    fn name(&self) -> &'static str;
    fn capabilities(&self) -> &RunnerCapabilities;             // { runner_kind: String, labels, structured_events: bool }
    async fn start_session(&self, ctx: SessionContext) -> Result<SessionHandle>;
    async fn run_turn(&self, sess: &mut SessionHandle, prompt: Prompt) -> Result<TurnOutcome>;
    fn stream_events(&self, sess: &SessionHandle) -> EventStream; // Pin<Box<dyn Stream<Item=RunnerEvent>+Send>>
    async fn stop_session(&self, sess: SessionHandle) -> Result<UsageReport>;
}
trait Workspace { /* root, create(&Issue)->WorkspaceHandle, run_hook, destroy */ }
```

Verified types: `IssueId(String)`, `IssueState(String)` (both **newtype strings**, not enums — flexible states); `Claim { issue_id, by: AgentId, at, heartbeat_at, shard_role: ShardRole(Primary|Backup(usize)|ManualM1), signature }`; `ReleaseReasonCode { OperatorCancelled, RunnerFailed, ExpiredHeartbeat, Conflict, Other }`; `Handoff { summary, files_changed, validation: Vec<ValidationResult>, follow_up, proofs_dir }` — **no signature field on Handoff** (Claim *is* signed; we sign the Handoff at the envelope layer, §4.5).

## 4. `X0xWorkTracker` — the adapter, built around two real gaps

The naive plan was "map symphony `Issue` onto x0x's CRDT TaskList." Source verification shows that **breaks on two confirmed gaps:**

- **Gap A — lossy `add_task`.** `TaskListHandle::add_task(title: String, description: String) -> TaskId` takes **only title + description**. Symphony `Issue` has `labels`, `priority`, `branch_name`, `url`, `blocked_by`, `extra` — **nowhere to put them** in the native task. `TaskSnapshot` exposes only `{id, title, description, state, assignee, owner, priority}`, and there is **no place to store a `Handoff`** at all.
- **Gap B — no un-claim.** `CheckboxState` is `Empty → Claimed{agent_id, timestamp} → Done{agent_id, timestamp}`, **immutable forward-only** (`checkbox.rs:53`). There is **no `Claimed → Empty` transition**. But `Tracker::release(claim, ExpiredHeartbeat)` *must* return a failed/abandoned issue to the pool. The native checkbox cannot express release.

### 4.1 Resolution: KvStore-authoritative, TaskList-as-mirror

The **authoritative** work state lives in an x0x **`KvStore`** (`create_kv_store(name, topic)`), keyed by `IssueId`, value = a serialized `WorkRecord`:

```rust
struct WorkRecord {           // serialized into KvStore value (CBOR), LWW-merged
    issue: Issue,             // full symphony Issue — solves Gap A (all fields preserved)
    state: WorkState,         // Open | Claimed | Running | Done | Failed | Cancelled  (LWW)
    lease: Option<Lease>,     // { holder: AgentId, claimed_at, heartbeat_at, ttl_ms }  (LWW) — solves Gap B
    handoff: Option<Handoff>, // signed envelope on completion — solves "no handoff storage"
}
```

The x0x **`TaskList` is an optional human-glanceable mirror**: one `TaskItem` per issue, `CheckboxState` reflecting coarse state (Empty/Claimed/Done) so the work shows up in x0x-native tooling. The mirror is **best-effort and non-authoritative** — its no-release limitation no longer matters because release is a `WorkRecord.state`/`lease` LWW update, not a checkbox transition.

Why KvStore: it carries **arbitrary values + `AccessPolicy`**, OR-Set membership + LWW values (so concurrent edits converge), and is **MLS-encryptable** for private group work (§8.3). It is the right primitive for rich, mutable, partition-tolerant work records.

### 4.2 `claim` — partition-safe arbitration without the checkbox's dead-end

Claim uses **lease + ShardRole (ADR-0002)**, not the forward-only checkbox:

1. Read `WorkRecord`. Eligible to claim iff `state ∈ {Open, Failed}` **or** (`state == Claimed` **and** `lease` expired, i.e. `now - heartbeat_at > ttl_ms`).
2. Apply ADR-0002 ownership: `ShardRole::Primary` (XOR-closest `AgentId`) may claim immediately; `Backup(n)` may claim only after the lease TTL lapses; reject otherwise (`ReleaseReasonCode::Conflict` semantics).
3. LWW-write `state = Claimed`, `lease = { holder: self, claimed_at, heartbeat_at: now, ttl_ms }`. **Concurrent-claim tie-break:** mirror x0x `CheckboxState`'s rule — **earliest `claimed_at` wins, then `AgentId` bytes** (`checkbox.rs` Ord) — applied to the LWW lease so the adapter and the native checkbox agree.
4. Return a symphony `Claim` (signed — `Claim` has a built-in `signature` field; sign with the agent's ML-DSA-65 key) with `shard_role` set.

This keeps the partition-tolerant, deterministic claim arbitration the checkbox gave us, while regaining release.

### 4.3 `heartbeat`
LWW-write `lease.heartbeat_at = now`. Cheap, frequent. Missing heartbeats past `ttl_ms` make the record reclaimable (§4.2.1).

### 4.4 `release`
LWW-write `state = Failed` (for `RunnerFailed`/`ExpiredHeartbeat`/`Conflict`) or `Cancelled` (for `OperatorCancelled`), clear `lease`. The issue re-enters `fetch_candidates` (state `Failed` is claimable; `Cancelled` is terminal). This is the Gap-B fix.

### 4.5 `handoff`
LWW-write `state = Done`, `handoff = <signed envelope>`. **Because `Handoff` has no native signature field**, we wrap it: `SignedHandoff { handoff, by: AgentId, at, sig }` (ML-DSA-65 over canonical bytes) so the conductor can verify *who* produced the result before trusting it (critical cross-owner, §8). Mirror: set TaskList checkbox `Done`. Proofs (`proofs_dir`) referenced, not inlined (16 MB DM cap).

### 4.6 `fetch_candidates`
No subscription API exists in x0x task lists (confirmed) — **poll**. Enumerate `WorkRecord`s via `KvStore::keys()`/`get()`, filter by `PollContext { active_states, terminal_states, agent_id }`, return reconstructed `Issue`s. Poll cadence is the orchestrator's (§5), aligned with the scheduler tick.

## 5. `ConductorOrchestrator` — the dispatch loop

```
loop (poll interval):
  candidates = tracker.fetch_candidates(poll_ctx)
  for issue in eligibility_gate(candidates):          // §5.1
     claim = tracker.claim(issue.id, self.agent_id)?  // ADR-0002 + lease
     spawn heartbeat task (tracker.heartbeat every ttl/3)
     ws = workspace.create(&issue)?                    // isolated dir; run AfterCreate hook
     runner = select_runner(issue)                     // by labels/runner_kind + grants (§6)
     sess = runner.start_session(SessionContext{ issue, workspace_path: ws, env_allowlist })?
     outcome = drive(runner, sess, issue)              // run_turn loop, stream_events → progress
     handoff = build_handoff(outcome, validations)     // run BeforeRun/AfterRun hooks
     tracker.handoff(&claim, handoff)?                 // signed, §4.5
     workspace.destroy(ws)                             // BeforeRemove hook
  honour concurrency cap; on any failure → tracker.release(claim, reason)
```

### 5.1 Eligibility gate
- Concurrency cap (don't claim more than N concurrent issues per agent).
- **ShardRole** check (ADR-0002): Primary now, Backup after TTL.
- **Cross-owner gate**: if the issue originates from another owner (or targets a cross-owner runner), require a matching `CapabilityGrant` via `GrantEnforcer` (§8). No grant → skip.
- TillDone/quiet-hours/thermal throttles reused from the scheduler stack.

### 5.2 Where it runs
The orchestrator is a **scheduler task** in the headless core (the existing `FaeScheduler` already runs ~23 background tasks). `orchestrate_work` enqueues an issue; the loop is always-on at a low poll cadence. Same-owner overnight work (research, etc.) is the first user.

## 6. Runner adapters — the commoditisation payoff

`RunnerCapabilities.runner_kind` is a **`String`** (verified — not an enum), so new harnesses are config, not code changes. Four adapters cover the field:

| Adapter | `runner_kind` | Wraps | Use |
|---------|---------------|-------|-----|
| **LocalFaeRunner** | `"fae-local"` | in-process mistral.rs (E4B/14B) + ToolExecutor | the conductor does the work itself |
| **AcpRunner** | `"acp"` | Fae's existing `acpx` / `agent_session` / `ACPSessionManager` | **any ACP harness — Codex, Claude Code, Hermes-if-ACP** |
| **SubprocessRunner** | `"shell"`/`"codex"`/`"claude_code"` | a CLI via `SafeBashExecutor` | harnesses with a CLI but no ACP |
| **CrossOwnerRunner** | mirrors remote | x0x `send_direct` → remote agent's orchestrator | run on *someone else's* compute under a grant (§8) |

`AcpRunner` is the high-leverage one: Fae **already has** ACP delegation (`AgentSessionTool`, `ACPSessionManager`, max 5 concurrent). Wrapping it in symphony's `Runner` trait makes every ACP-speaking harness a drop-in conductor backend. This is the literal mechanism by which "the harnesses become indistinguishable" — they're all just `runner_kind` strings behind one trait.

`select_runner(issue)` matches `issue.labels` against each runner's `RunnerCapabilities.labels` + `runner_kind`, intersected with available grants/adverts (`CapabilityIndex`, advert spec §5). (`RunnerKind` referenced in the grants/advert docs resolves to this `String`.)

## 7. `orchestrate_work` control-plane command (ADR-002)

Fleshing out the Tier-1 reserved stub:

```jsonc
{ "v": 1, "request_id": "...", "command": "orchestrate_work",
  "payload": {
    "title": "Investigate testnet NAT regression",
    "description": "...", "labels": ["research","code"], "priority": 3,
    "runner_hint": "claude_code" | null,
    "target": { "by": "self_fleet" | "agent" | "group" | "capability", "value": null },
    "deadline": "overnight" | { "by_ms": 1717600000000 } | null
  } }
```
Requires control-plane scope `mesh.orchestrate`. Creates a `WorkRecord` (state `Open`); the orchestrator picks it up. Progress streams as `work.progress` events (from `Runner::stream_events`); completion fires `work.handoff` with the signed result so the thin client / voice can surface "your Mac finished the NAT investigation — want the summary?"

## 8. Governance integration

### 8.1 Same-owner fleet
Issue created and claimed within one `UserId` → Tier-1-grade bar: control-plane auth (`mesh.orchestrate`), target verification (`is_agent_machine_verified` + `find_agents_by_user(self)`), local write-approval *before* a mutating runner acts, full audit. No cross-owner consent.

### 8.2 Cross-owner
A `CrossOwnerRunner`, or claiming another owner's issue, is gated by a **`RunRunner` `CapabilityGrant`** (grants doc §4): `GrantEnforcer.verify` runs at claim time (eligibility gate §5.1) *and* before each `run_turn`. Symphony's `security-sensitive` label maps onto requiring a grant whose scope covers the runner. The **signed Handoff** (§4.5) is verified (`is_agent_machine_verified` + sig) before the result is trusted; the result passes the **outbound egress membrane** (PII/exfil/`data_class`, grants doc §7) when it crosses the owner boundary.

### 8.3 Group work ("the Fae") — gated
A shared work list for a team uses an **MLS-encrypted KvStore/TaskList** (`EncryptedTaskListDelta { group_id, epoch, ciphertext, aad }`). This stays **hard-gated on TreeKEM wiring + G5 production enforcement**, consistent with every other doc. Pairwise cross-owner orchestration (8.2) over direct QUIC ships earlier; group orchestration waits.

### 8.4 Handoff → memory
A completed handoff may carry facts. Ingestion goes through the inbound write gate: same-owner → `provenance = tool`, `data_class = local_operational`; cross-owner → `provenance = peer:<agent>`, `data_class = peer_claim`, `review_status = unreviewed` (W3 quarantine — never reaches system/developer prompts without review). No new memory path.

## 9. Conductor routing — the third tool

The E4B router now chooses among **answer-locally / `delegate_to_mesh` (sync) / `orchestrate_work` (async)**. Heuristic the model learns (not hand-coded): *bounded question needing one response* → sync; *multi-step work product, tolerant of latency, benefits from an isolated workspace and validation* → async. Routing accuracy across all three is the `FaeBenchmark` metric and an improvement-loop target.

## 10. Partition & CRDT semantics

- **Claim arbitration** is deterministic under partition (earliest `claimed_at`, then `AgentId`) — two agents claiming the same issue across a split converge to one winner; the loser's work is wasted but **state is never corrupted** (the x0x duplicate-work-tolerant model).
- **No silent caps:** if the orchestrator bounds concurrency or skips issues (no grant, no capable runner), it `log()`s the skip + reason — a skipped issue must never look completed.
- **Lease TTL** is the only liveness mechanism (no native un-claim); pick `ttl_ms` ≫ heartbeat interval (e.g. ttl 90 s, heartbeat 30 s) to tolerate jitter without premature reclaim.

## 11. Build surface (net-new)

1. `fae-conductor-orchestrator` crate (deps: x0x + x0x-symphony-core).
2. `X0xWorkTracker` (`Tracker` impl) + `WorkRecord`/`WorkState`/`Lease` + KvStore-authoritative storage + optional TaskList mirror.
3. `ConductorOrchestrator` dispatch loop (scheduler task) + eligibility gate + heartbeat tasks.
4. `Workspace` impl (isolated dirs + the 4 `HookName` stages).
5. Four `Runner` adapters (LocalFae / Acp / Subprocess / CrossOwner); `AcpRunner` wraps existing `ACPSessionManager`.
6. `SignedHandoff` envelope + verification.
7. `orchestrate_work` command + `work.progress`/`work.handoff` events.
8. Router third-tool + routing-accuracy benchmark extension.

Reuses: scheduler, ToolExecutor, ACP stack, GrantEnforcer, CapabilityIndex, egress membrane, memory inbound gate — all existing or already specced.

## 12. Phasing within Phase 2

1. **2a — own-fleet local/ACP**: `orchestrate_work` → LocalFae/Acp/Subprocess runners on *your own* machines. Ships after Tier-1 + `X0xWorkTracker`. The overnight-research user.
2. **2b — pairwise cross-owner**: `CrossOwnerRunner` + `RunRunner` grants over direct QUIC. After GrantEnforcer.
3. **2c — group work**: MLS-encrypted shared work lists. Gated on TreeKEM + G5.

## 13. Acceptance criteria

- [ ] `X0xWorkTracker` round-trips an issue through Open→Claimed→Running→Done with lease heartbeat + release-on-failure, KvStore-authoritative, TaskList mirror coherent.
- [ ] Concurrent claim across two agents converges to one winner deterministically; loser releases cleanly; no corruption.
- [ ] `ConductorOrchestrator` drives a real Runner end-to-end (AcpRunner via existing `ACPSessionManager`) producing a `SignedHandoff`.
- [ ] `select_runner` dispatches by labels/`runner_kind`; adding a harness is config (new `runner_kind` string), not code.
- [ ] `orchestrate_work` behind `mesh.orchestrate`; progress + handoff events fire; voice surfaces completion.
- [ ] Cross-owner claim/dispatch blocked without a `RunRunner` grant; signed handoff verified before trust; egress membrane on cross-owner results.
- [ ] Handoff facts enter memory only via inbound gate with correct provenance/`data_class`.
- [ ] Skips/caps are logged with reason (no silent truncation).
- [ ] Group work disabled until TreeKEM + G5. Apple+Linux v1; Windows post-v1 (S11).

## 14. Open questions / upstream proposals

1. **Propose to x0x:** (a) a `Claimed → Empty` release transition on `CheckboxState`, and (b) a richer `add_task` (labels/priority/metadata). Both would let the native TaskList be authoritative and shrink `X0xWorkTracker` to a thin mirror. Until then, KvStore-authoritative is the pragmatic path. Worth raising — Communitas may want the same.
2. **KvStore vs TaskList as the canonical mirror** — is the human-glanceable checkbox worth maintaining two stores, or skip the TaskList mirror entirely until x0x-native tooling needs it? Lean: skip in 2a, add when there's a consumer.
3. **Workspace isolation depth** — plain dirs (reuse `SafeBashExecutor` cwd) for 2a; do cross-owner runners need worktree/container isolation (symphony M4 "sandbox profiles")? Defer to 2b.
4. **Heartbeat cost on gossip** — frequent LWW lease writes generate CRDT deltas; tune `ttl_ms`/cadence to keep gossip chatter low (presence-budget aware, W4).
5. **Handoff proof transfer** — `proofs_dir` over the 16 MB DM cap → reference + pull via x0x file transfer (`files/`) rather than inline.

## 15. References
- `conductor-tier1-own-fleet-2026-06-05.md` (sync path, ADR-002 stub), `…-capability-grants-…` (RunRunner, GrantEnforcer, egress), `…-capability-advertisement-…` (CapabilityIndex, runner_kind).
- `cross-platform-engine-plan-2026-05-30.md` §11A (TreeKEM/group gating), `fae-to-fae-governance.md` (G5), `memory-migration-plan.md` (inbound gate).
- x0x-symphony-core: `tracker.rs:178`, `runner.rs:613`, `issue.rs:294`, `claim.rs` (`ShardRole`/`ReleaseReasonCode`), `handoff.rs:116`, `workflow.rs` (`HookName`). Deps: async-trait/serde only (not x0x).
- x0x: `create_kv_store`/`KvStore`/`AccessPolicy`, `create_task_list`/`TaskListHandle` (`add_task`/`claim_task`/`complete_task`/`list_tasks`), `crdt::CheckboxState` (`checkbox.rs:53`, no un-claim), `crdt::TaskId` (`task.rs:26`), `crdt::encrypted::EncryptedTaskListDelta` (`encrypted.rs:17`), `send_direct`, `files/`.
