# Sakana Fugu vs the Fae Conductor — what to steal, what to skip

> Status: **Research synthesis** (2026-06-22) · Owner: David Irvine
> Source question: *"Investigate https://sakana.ai/fugu — this is what we want Fae to be able to do (coordinate many models), and use x0x / x0x-symphony to share intelligence across groups."*
> Feeds: the accepted conductor doc set (`docs/architecture/conductor-*-2026-06-05.md`).

## TL;DR — the realization

**Fae is not trying to become Fugu. Fae already *is* most of Fugu by design.** David's accepted "head butler over the mesh" strategy (2026-06-05) already specifies: a small personal brain (Gemma-4 E4B) that routes to a pool of specialists (local models, daemon ACP agents, x0x peers, x0x-symphony runners), with capability grants for cross-owner work, and a nightly self-improvement loop (MetaOpt + TrainingBridge).

Sakana Fugu adds exactly one missing idea, and it is the whole point of their two ICLR 2026 papers:

> **The routing policy itself should be LEARNED — not a fixed hand-prompted judgment.**

That is the single thing to steal. The good news: Fae already owns the *exact* learning substrate the Fugu research endorses for it.

## What Fugu actually is (verified from the papers, not the marketing)

Sakana Fugu is one OpenAI-compatible API fronting a pool of heterogeneous models. Its two grounding papers (same Sakana author team: Xu, Sun, Schwendeman, Nielsen, Cetin, Tang):

### TRINITY — *arxiv 2512.04695* (the one that matters most for Fae)
- **Coordinator = a ~0.6B compact LM + a ~10K-parameter "lightweight head."** Tiny.
- Optimized with an **evolutionary strategy** (NOT gradient descent / NOT RL).
- Processes a query over **multiple turns**; each turn the coordinator assigns **one of three roles** to a selected LLM from the pool:
  - **Thinker** · **Worker** · **Verifier**
- "Effectively offloads complex skill acquisition from the coordinator itself."
- 86.2% on LiveCodeBench (SOTA). Generalizes out-of-distribution.
- The paper's own claim for *why evolution beats gradients*: **"under high dimensionality and strict budget constraints"** evolutionary optimization wins. (Read this twice — it is aimed at us.)

### Conductor — *arxiv 2512.04388* (the heavier cousin)
- A **7B** model trained with **reinforcement learning**.
- Learns to (a) design agent-to-agent **communication topologies** and (b) **prompt-engineer focused per-worker instructions** to exploit each worker's strengths.
- "Significant performance gains beyond any individual model."

### What Fugu-the-product adds on top
- One API façade; routing is **hidden by design** ("the specific models Fugu selects… are proprietary… not exposed").
- Provider/model **opt-out** for privacy/compliance.

## The mapping — Fae's existing pieces vs Fugu's

| Fugu concept | Fae today | Gap |
|---|---|---|
| Pool of heterogeneous models | Local models (MLX) + daemon ACP agents (Codex/Claude/Pi/Gemini/Copilot) + x0x peers (designed) + x0x-symphony runners (designed) | Pool is designed, not yet unified behind one `CapabilityIndex` |
| Coordinator that routes | Gemma-4 E4B "Conductor Router" as a stage in the agent loop (Tier-1 doc §5) | Exists in design; the **routing judgment is static/hand-prompted** |
| Thinker / Worker / Verifier roles | Fae has delegation (`delegate_agent`) but no role taxonomy | **Steal the 3 roles** — see §"What to steal" |
| Topologies (chain/star/debate) | Not present | Defer — start with direct + chain |
| **Learned** routing policy | **MetaOpt + AdapterEvaluator + GateReceipt** — evolutionary hill-climbing, fail-closed gate, keep/revert, audited, narrated | **The one real gap.** MetaOpt mutates prompts/config/skills/memory today — *not yet* the conductor's routing decisions |
| One API façade | Fae is one companion voice (SOUL) | ✓ already |
| Provider opt-out | `DamageControlPolicy.nonLocal` + `SensitiveContentPolicy` + (designed) capability grants | ✓ conceptually |
| Hidden routing | SOUL quiet presence + progressive disclosure | Fae should NOT fully hide routing (owner trust) — see §"Where Fae must diverge" |

## What to steal (ranked)

1. **TRINITY's three roles: Thinker / Worker / Verifier.** Map them onto the conductor's delegation. This is a near-free, high-value borrow. The conductor's turn output becomes: `{role, worker_selector, targeted_instruction, privacy_lane, continue_or_final}`. (Researcher's earlier "explorer/specialist/critic" guess was the right *shape*; the real names are Thinker/Worker/Verifier.)
2. **Evolutionary-optimized routing policy — via the loop Fae already has.** TRINITY's paper explicitly says evolution beats gradients "under high dimensionality and strict budget constraints." That is a description of a personal assistant on a laptop, not a datacenter. **Extend MetaOpt's mutation surfaces to include the conductor recipe** (which worker for which task class, which role, direct-vs-chain, escalation thresholds, per-role prompt templates). Same gate receipt, same fail-closed keep/revert, same narration. *This is the single most important recommendation in this doc.*
3. **Targeted per-worker instructions** (from Conductor). Condition each delegation prompt on the worker's capability, the assigned role, the privacy lane, and the output schema. Start as prompt *templates*; let MetaOpt mutate them.
4. **Topology templates as a closed set** (from Conductor). Ship `direct` and `chain` (Thinker→Worker→Verifier) first. Add `star` (parallel specialists → synthesizer) and `debate` only once eval discipline is strong. Do **not** allow free-form graph generation.
5. **The "compact coordinator" footprint proof.** TRINITY runs a 0.6B + 10K coordinator. Fae's butler brain (E4B 4B, or even saorsa1-tiny 0.8B) is *more* than enough to host a learned routing head. No new frontier model is required for v1.

## What to skip or defer

- **Full RL Conductor (the 7B paper).** RL needs a large consented eval corpus and heavy infra. Fae has sparse, no-ground-truth reward. Defer to a later ADR. MetaOpt-first is both safer and *paper-endorsed*.
- **Fugu's fully-hidden routing.** Fae is a companion accountable to one owner; routing that affects cost, privacy, latency, or trust must be progressive-disclosure, not opaque. Fae hides operational chatter, never privacy-relevant choices.
- **A new gossip stream type for intelligence.** Use existing x0x presence + direct messages + encrypted groups + TaskList CRDT + KvStore. Add a dedicated stream only if QoS demands it later.
- **Resurrecting CoWork.** Explicitly removed in the Great Cleanup (2026-06-11); the conductor + mesh + agentskills/MCP replaces it. Do not relitigate D6.

## Sharing intelligence across groups (the x0x half of the question)

Fae's existing conductor docs already design Tier-1 own-fleet sync (`delegate_to_mesh`) and Phase-2 async (`orchestrate_work` via x0x-symphony). What Fugu's framing adds is the *content* of what gets shared. Ranked by safety:

| Share this | x0x primitive | Privacy gate |
|---|---|---|
| **Learned routing heuristics** ("for Rust code review, Thinker→Worker→Verifier beats direct") | encrypted group KvStore / TaskList metadata | MLS-group only; signed by source |
| **Eval outcomes / gate receipts** (task class, runner, score delta, latency, cost, eval-suite version) | group KvStore; TaskList handoff metadata | signed; **no raw prompts**; group-scoped |
| **Capability descriptors** (model/runner classes, skills, tool modes) | A2A agent card + presence beacon | signed; no user data; trust-scoped |
| **Topology hints** (discovered collaboration patterns) | group KvStore `topology_hint` records | signed; sanitized before any cross-group export |
| Memory seeds (project facts) | group KvStore / TaskList knowledge item | import only via Fae's audited candidate path — **never** auto-overwrite `fae.db` |
| Raw conversations / personal memory | — | **Never** in v1. |

The principle, matching x0x's partition-tolerant data model: shared intelligence is **signed, scoped, mostly aggregate, and treated as a candidate prior** — each Fae node's conductor verifies and weights it locally, never blocks on a quorum, and degrades gracefully when the group is partitioned away.

**Where the conductor lives:** per-Fae-node. Each Fae is locally sovereign; x0x-symphony is the durable *work* substrate, not a distributed brain. This is consistent with x0x's no-central-orchestrator constitution and Fae's local-first companion identity.

## Where Fae must diverge from Fugu (non-negotiable, from AGENTS.md/SOUL)

- **SOUL drift is the #1 risk.** Visible model-team orchestration makes Fae feel like a control plane, not a companion. Orchestration stays invisible in normal speech; surfaces only for cost/privacy/timing/trust (progressive disclosure).
- **Memory is production-critical.** Conductor learning writes to `improvement.db` (existing isolation), never ad-hoc to `fae.db`. Any durable fact enters memory only through `MemoryOrchestrator` with supersession lineage + audit.
- **Mandatory release-validation gate.** This change touches models, routing, prompting, tools, scheduler, memory, remote providers. `docs/checklists/app-release-validation.md` + the live scenario script + comprehensive specs are required, not optional.
- **Cost/latency governance.** Remote/paid models need per-provider budgets, opt-out, deadlines, receipts, and approval for paid/cross-owner calls. No free-choice spend.
- **Egress membrane.** `PrivacyFilterBridge` (expected by older docs) was not found in current source — must be confirmed/rebuilt before any cross-owner path goes live. Reuse `SensitiveContentPolicy` + `DamageControlPolicy(nonLocal)` + `SecurityEventLogger`.

## Decisions for David

These are the questions only the owner can settle. My recommendation in italics.

- **D1 — Conductor brain shape.** Keep E4B as the butler + add a *learned routing policy* evolved by MetaOpt? *Yes — this is the Fugu insight, grafted onto Fae's existing safety substrate. Defer any trained-coordinator-model ADR until route telemetry + a consented eval corpus exist.*
- **D2 — Cross-group boundary in v1.** *Same-owner fleet only for v1. Pairwise cross-owner grants (Tier 2) next. MLS group sharing only after TreeKEM/G5. Never raw memory.*
- **D3 — Visibility.** *Progressive disclosure. Hide operational routing detail; expose anything that affects cost/privacy/trust. Never fully opaque like Fugu.*
- **D4 — Where learning writes.** *Routing telemetry + policy candidates in `improvement.db`. Only user-visible durable facts enter `fae.db` via MemoryOrchestrator.*
- **D5 — Reward signal (the hard one).** *No ground truth for a companion. Combine: route-labeled `routing_accuracy` benchmark + implicit signals (re-asks, corrections, abandonment, follow-through, praise) + limited shadow routing. Reject pure model self-judgment. Fail-closed keep/revert always.*
- **D6 — First topology set.** *`direct` + `chain` (Thinker→Worker→Verifier). Add star/debate later.*
- **D7 — Sync vs async first.** *`delegate_to_mesh` same-owner sync first (Tier 1, already designed). Then async own-fleet. Cross-owner/group only after grants + egress + TreeKEM + red-team.*

## Minimal first step (safe under current guardrails)

1. Add **route telemetry** + a `routing_accuracy` eval surface (instrumentation only, no behavior change).
2. Define the **`FaeConductorRecipe`** value type: `{taskClass, allowedWorkers, privacyLane, topology, roleSlots[Thinker|Worker|Verifier], promptTemplates, budget, stopPolicy}`.
3. Implement a **`ConductorRoutingPolicy`** that chooses among: local answer, existing ACP agent/session, same-owner mesh delegate. Inject through the existing `AgentRunner` seam (the file literally names itself "gap A4 conductor seam").
4. Persist route outcomes in `ImprovementStore` (cost/latency/success/fallback).
5. Let **`MetaOptimizer` propose recipe mutations** under the existing budget + gate-receipt + rollback pattern. This is TRINITY's evolutionary lesson, implemented in Fae's own loop.
6. Audit every route (chosen target, cost est/actual, latency, payload hash, fallback) via `SecurityEventLogger`.
7. Keep the UX quiet: *"I'm asking your Mac."* / *"I couldn't reach it, so here's my local take."*

**Verdict:** Conditional GO on the minimal Tier-1 learned-routing prototype above. An **ADR is required before** any of: a new production Rust conductor core, a trained coordinator model, cross-owner capability grants, MLS group intelligence sharing, new memory schema, auto-selected paid remote providers, or x0x-symphony async work beyond a same-owner spike.

## ADR required? (trigger list)

- ~~New Rust conductor core in production runtime~~ → **covered by [ADR-011](../adr/011-headless-rust-core-runtime.md)** (headless Rust core is now canonical, 2026-06-22). Building the conductor in `crates/` is authorized.
- Trained coordinator model / RL pipeline → **ADR** (still required; ADR-011 covers the runtime, not new training governance)
- Cross-owner capability grants → **ADR**
- MLS group-scoped intelligence sharing → **ADR** (gated on TreeKEM/G5)
- New memory schema or peer-memory ingestion path → **ADR**
- Autonomous `conductorRecipe` mutation as a MetaOpt surface → **ADR-008 amendment** (ADR-008 covers the existing Swift MetaOpt surfaces; the new Rust-side conductor surface needs explicit authorization with enforceable constraints)
- Paid remote providers selected automatically → **ADR**

## Sources
- Sakana Fugu landing: <https://sakana.ai/fugu>
- TRINITY: <https://arxiv.org/abs/2512.04695> (verified abstract: 0.6B + 10K head, evolutionary, Thinker/Worker/Verifier, 86.2% LiveCodeBench)
- Conductor: <https://arxiv.org/abs/2512.04388> (verified abstract: 7B, RL, topology + targeted instructions)
- Fugu technical report: <https://github.com/SakanaAI/fugu/blob/main/Fugu_technical_report.pdf>
- Fae accepted strategy: `docs/architecture/conductor-positioning-and-scope-2026-06-05.md` + the 4-doc conductor set + `great-cleanup-2026-06-11.md`
- Fae seams inspected: `Tools/AgentRunner.swift` (gap A4), `Tools/AgentDelegateTool.swift`, `Scheduler/{MetaOptimizer,AdapterEvaluator,MetaOptNarrator}.swift`, `Memory/{ImprovementStore,SQLiteMemoryStore}.swift`
