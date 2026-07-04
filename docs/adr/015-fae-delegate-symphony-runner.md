# ADR-015: Native Delegation Loop (`conversation.delegate`) + Quarantined Group-of-Fae Runner

- **Status:** Proposed
- **Date:** 2026-07-04
- **Decision owners:** David Irvine
- **Reviewers:** TBD
- **Supersedes:** none
- **Superseded by:** none
- **Related:** ADR-010 (llama.cpp sidecar), ADR-011 (headless Rust core runtime),
  ADR-012 (local-first coordinator of external AIs), ADR-013 (fluers agent-harness
  substrate), ADR-014 (cloud / multi-model lane),
  `docs/plans/cross-platform-completion-roadmap-2026-06-18.md` Phase F

## Context

Phase F asks a single question: can a symphony task be **claimed, worked by a
group of Fae, and returned with signed proofs**? Answering it needs two capabilities
Fae did not have:

1. **An autonomous agentic loop inside the daemon.** Until F1 the daemon only ran
   single-turn conversation + one-shot governed tool calls. A group-of-Fae worker must
   run its own generate → execute-tool → feed-back loop (many turns, real mutations)
   under hard budgets, jailed to a workspace, with no interactive owner behind it.

2. **A way to join an x0x-symphony task swarm without contaminating the daemon.**
   x0x-symphony (`Tracker` / `Runner` traits, x0xd CRDT task lists, ML-DSA signing) is a
   sibling project pulled as git-rev deps. The daemon core is deliberately kept free of
   any `x0x-symphony-*` dependency (the mesh boundary guard enforces it); a symphony
   integration must live somewhere that does not drag the daemon into that graph.

The pieces landed across F1–F4: F1 built the native jailed loop
(`conversation.delegate`); F2 added the orchestrator fan-out (parallel leaf batches);
F3 built `fae-symphony-runner` (a `Runner` over the daemon socket, proven against a
mock socket + in-memory tracker); F4 stood up the **live** two-daemon group-of-Fae
proof against a running x0xd. This ADR records the architecture those commits settled.

## Decision Drivers

- The daemon must stay symphony-clean: `cargo tree -i x0x-symphony-core` must show only
  one consumer, never `fae-daemon`.
- Autonomous tool execution must be confined by the **OS jail**, not by trusting the
  model — a delegated write outside the workspace root is denied without a prompt.
- Delegation must be **deadlock-free** and **honest about throughput** on a single local
  engine.
- Fae must hold **no signing keys**: every handoff/claim proof is signed by x0xd, the
  one component that owns identity.
- The live proof must be reproducible in CI-shaped conditions (no 8 GB model download,
  no interactive owner) while exercising the REAL daemon socket path — not a mock.

## Considered Options

1. **Accepted: native loop in `fae-daemon` (`conversation.delegate`, `ToolOrigin::Delegated`)
   + a separate quarantined `fae-symphony-runner` binary that is a pure socket client.**
   The daemon owns the jailed agentic loop; the runner owns the symphony wiring. Neither
   knows about the other's dependency graph. Described in full under Decision.

2. **Rejected: put the symphony `Runner` inside `fae-daemon`.** Simplest to wire, but it
   pulls every `x0x-symphony-*` crate (and their CRDT / signing transitive deps) into the
   daemon, breaking the mesh boundary guard and bloating the security-critical binary.
   Rejected: the quarantine is the whole point.

3. **Rejected: drive tools from the runner (client-side agentic loop), daemon stays
   single-turn.** The runner would run the generate→tool loop itself and call the daemon
   per tool. That moves the jail, the budget enforcement, and the mutation receipts OUT
   of the governed daemon and into an unprivileged client — exactly the surface the
   headless-core runtime (ADR-011) exists to contain. Rejected: the loop belongs where the
   jail and receipts already live.

## Decision

1. **The agentic loop lives in the daemon as `conversation.delegate` (F1).** The daemon
   runs its own generate → execute-tool → feed-back loop rooted at an **ephemeral jailed
   ToolHost** at the caller-supplied `workspace_root`. Every tool runs under
   `ToolOrigin::Delegated`, which REQUIRES the OS jail (Landlock on Linux, seatbelt on
   macOS) — `execute_governed` fails closed if no jail backend is present. A write outside
   the root is denied without prompting; the model is never trusted to stay in bounds. The
   command authorizes on the `AgentDelegate` scope (a frontend token holds it; it is not
   the dangerous scope and never round-trips a confirm at the wire — per-tool confirmation
   is a separate, inner concern, see point 6).

2. **Budget model: two hard ceilings + two process-global semaphores.** Each delegation
   carries `max_iterations` and `max_output_tokens`, re-clamped daemon-side to
   `MAX_ITERATIONS_CEILING` / `TOKEN_CEILING` (a client request is never a guarantee).
   `budget_exhausted` is a terminal status, not an error. Beyond per-request budgets, two
   `tokio::sync::Semaphore`s bound the whole fan-out tree (point 3).

3. **Leaf-only permit ⇒ no starvation, no deadlock (F2).** A delegation is either a
   `Leaf` (does the work) or an `Orchestrator` (fans out a batch of leaf children in the
   SAME workspace, at depth + 1, with a subset toolset and clamped budgets). Only **leaves**
   consume the concurrency permit (`leaf_permit`), and they hold it for their whole run; an
   orchestrator holds **none** while it awaits its children. Because a permit holder can
   never itself fan out, the wait graph is acyclic — deadlock-free even at concurrency
   cap 1 (proven by `orchestrator_fan_out_no_deadlock_at_cap_one` + the headless
   `fanout.no_deadlock_at_cap_1` step). `MAX_DEPTH = 1`: an orchestrator at depth 0 spawns
   leaves at depth 1; depth ≥ 1 has no `delegate` tool in its schema AND a runtime
   rejection if it emits one (defense in depth).

4. **Single-engine throughput honesty.** A second semaphore (`engine_permit`, permit = 1)
   serialises the generation call across the whole tree — on ONE local engine token
   throughput cannot overlap. Parallel leaves overlap their **tool-exec / jail I/O**, not
   their generation. This is documented as-is; the fan-out is a latency win on I/O-bound
   tool work, not a token-throughput multiplier.

5. **The runner is a separate, quarantined binary (`fae-symphony-runner`).** It is the
   ONLY crate that depends on any `x0x-symphony-*` crate; it depends on `fae-control-plane`
   for the wire envelope and NEVER on `fae-daemon`. It implements x0x-symphony's `Runner`
   over the daemon control socket: `start_session` verifies socket + token; `run_turn`
   authenticates and issues `conversation.delegate` rooted at the issue workspace;
   `stop_session` is a no-op (each turn is self-contained). The stock
   `x0x-symphony-orchestrator` consumes it unmodified.

6. **x0xd signs everything; Fae holds no keys.** Claims and handoffs are ML-DSA-signed by
   x0xd via its `/agent/sign` surface (the `required_signing` tracker); Fae's trust in a
   peer's work is x0xd's `TrustedKeyResolver`, not any Fae-held key material. The daemon's
   inner per-tool `tool.confirm` round-trip (a dangerous write/edit/bash inside the jailed
   loop) is answered by the CLIENT. For an **autonomous** symphony worker there is no
   interactive owner, so the runner **pre-authorizes its own delegation**: it pinned a
   conservative leaf toolset in the request and the daemon jails every mutation to the
   workspace, so the runner replies `{approved: true}` — the OS jail, not an owner card, is
   the boundary. Any other server-initiated method fails closed (`{approved: false}`).

7. **`FAE_ENGINE=mock` is the live-proof substrate (F4).** A dev-gated scripted
   `MockAdapter` (a `write tracked.txt` tool call → final answer, several pairs queued)
   lets a REAL daemon serve its socket with NO model download. It is gated exactly like
   `FAE_MODELS_LOCK=off`: valid only under `FAE_DEV=1`, and `engine_selection` fails closed
   (exit 78) if requested without it, so a production build can never run a mock brain.

## Consequences

### Positive

- A group of Fae can genuinely claim, work, and return signed symphony tasks — proven
  live: two real daemons, two isolated workspaces, one shared x0xd list, no double-claim,
  signed handoffs (`live_group_of_fae.rs`).
- The daemon stays symphony-clean and security-focused; the whole symphony surface is
  quarantined in one deletable crate.
- Autonomous tool execution is confined by the OS jail, not by model trust; the same jail
  the interactive owner path uses.
- Deadlock-free fan-out with an honest throughput story — no false "parallel = faster
  tokens" claim.
- No Fae-held signing keys: identity and proof live entirely in x0xd.

### Negative / Trade-offs

- **Single local engine ⇒ generation serialises.** Fan-out helps only I/O-bound tool work;
  a true throughput multiplier needs multiple engines / machines (the cross-machine
  conductor is future work).
- **The runner auto-approves its own delegation's tool confirms.** This is safe only
  because the toolset is pre-restricted AND the OS jail confines mutations; if either
  weakens, the pre-authorization must be revisited. It is a deliberate autonomous-worker
  decision, not a blanket "approve everything."
- **The live proof shares ONE x0xd identity across both workers.** A single x0xd node
  exposes one ML-DSA identity, so no-double-claim is proven at the **task-lease** level
  (a claimed task leaves the pool and is never offered to the second worker), not across
  two distinct signing identities. True two-identity claiming across two replicated x0x
  nodes is a documented multi-node follow-up.

### Neutral / Operational

- `FAE_ENGINE=mock` is committed but dev-gated; no production turn can reach it.
- The live test is `#[ignore]` and SKIPs (not fails) when x0xd or a built daemon is
  absent, so CI without the live infra stays green; the owner runs it against the local
  x0xd + a `cargo build -p fae-daemon`.
- Structured streaming events from the delegation (`stream_events`) are `stream::empty`
  for v1; per-token/tool event fidelity to the orchestrator is a documented fast-follow.

## Validation

- **Gate:** `env -u RUSTFLAGS just check` (crates workspace) — fmt / clippy `-D warnings` /
  nextest — green.
- **Headless (CI-safe):** `--headless-delegate-test` (F1/F2 jailed-loop assertions) +
  `runner_headless.rs` (runner over a mock socket + in-memory tracker + git workspace).
- **Live group-of-Fae (owner-run):** `live_group_of_fae.rs` (`#[ignore]`) against a running
  x0xd — two real daemons (mock engine), no double-claim, workspaces mutated, signed
  handoffs, tasks left the pool, proofs written.
- **Review trigger:** revisit the runner's confirm auto-approval if the delegated toolset
  is ever widened beyond the conservative leaf default, or if the OS jail's confinement
  guarantee changes; revisit the shared-identity limitation when two replicated x0x nodes
  are available for a two-identity live proof.

## Notes for AI-assisted work

This ADR is **Proposed** — owner sign-off is required. Until Accepted:

- Do NOT widen the delegated leaf toolset beyond `[read, write, edit, bash, glob, grep]`
  without re-evaluating the runner's `tool.confirm` auto-approval (point 6).
- Do NOT let any `x0x-symphony-*` dependency reach `fae-daemon` — the quarantine
  invariant is load-bearing (`cargo tree -i x0x-symphony-core` must show only
  `fae-symphony-runner`).
- Do NOT remove the `FAE_DEV` gate on `FAE_ENGINE=mock`; a production build must fail
  closed rather than serve a mock brain.
- The two-identity multi-node no-double-claim proof is the sanctioned next step; the
  single-node shared-identity harness is a deliberate, documented interim.

To supersede: write a new ADR; do not edit this one after it is Accepted.
