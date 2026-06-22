# Daemon-A/B live de-risk (P9 / C4, gguf eval lane)

> **Status: DEFERRED — owner/real-hardware runbook.** The `DaemonABEvaluator`
> (`native/macos/Fae/Sources/Fae/Scheduler/DaemonABEvaluator.swift`) is **unit-proven
> via a mock `DaemonABClient`** — the A/B orchestration, the per-dimension delta
> math, and the restore-on-every-exit safety property all have tests. What no test
> can exercise is the **live** path: a real `fae-daemon` reloading real GGUF LoRA
> adapters and a real held-out suite that actually *discriminates* a good adapter
> from a bad one. That is an owner action on a Mac running the daemon LLM lane.
> **The P9/C4 gate is structurally complete and merged (PR #21) without this — the
> unsafe auto-deploy hole is closed; this page confirms the live legs.**

## Why this is a smoke, not a gate

The structural safety property is already enforced in code and tests: no path writes
the live `currentAdapterPath` without a verifying, unconsumed, tamper-evident
`GateReceipt` minted by an allowlisted real evaluator. For the `.gguf` lane that
evaluator is `DaemonABEvaluator`, which:

- A/Bs the **live llama.cpp daemon** by reloading the **deployed** adapter, scoring
  the held-out suite, then reloading the **candidate** and scoring again
  (`reload(deployed) → score → reload(candidate) → score`), producing a measured
  per-dimension `EvalDelta`.
- **Restores the deployed adapter on EVERY exit** (success, throw, timeout,
  cancellation) and *confirms* it via `runtime.status` — so the live daemon is
  never left serving the un-gated candidate. This is the deploy-without-receipt
  hole the series closes, and it is a **hard safety property**, not best-effort.

Unit tests cover all of that with a fake client. The two things only real hardware
proves are (a) the A/B runs end-to-end against an actual daemon + actual GGUF
adapters and yields a *measured* (not blocked) delta, and (b) the bundled held-out
set is **discriminating** — a bad adapter scores measurably worse, not the same.

## Prerequisites

1. **Daemon LLM lane active** — `llm.useDaemonEngine` true, the bundled
   `llama-server` runtime installed, and a real `fae-daemon` serving Gemma 4 E4B.
   This is the same setup the bundled app uses (`source ~/.secrets && just run-dev`).
2. **Two real GGUF LoRA adapters** produced by the P3/C3 producer
   (`train_peft.py` → `convert_to_gguf.py`, in the `training-orchestrator` skill):
   - a **deployed baseline** adapter (or none → the daemon base model is the
     baseline), and
   - a **candidate** adapter to gate. The `~/llama-spike` workspace already holds
     such artifacts (`personal-metric*.gguf` etc., per P3/C3).
3. **Runtime-adapter dev escape** — `FAE_DEV=1` and `FAE_MODELS_LOCK=off`, exactly
   as P3/C3 used. A runtime LoRA cannot be pinned in `models.lock` (that is *why*
   the daemon's reload path canonicalizes + SHA-checks the adapter instead); the
   dev escape lets the daemon load a non-locked GGUF. Production releases must keep
   the lock ON — this is a dev-only de-risk.

## Real symbols this exercises

| Layer | Symbol |
|-------|--------|
| Evaluator | `DaemonABEvaluator.evaluate(candidatePath:baselinePath:)` |
| Live client | `LiveDaemonABClient` (wraps `DaemonLLMEngine`) |
| Daemon reload | `DaemonLLMEngine.reloadAdapter(path:)` → daemon `engine.reload` |
| Daemon scale | `DaemonLLMEngine.setAdapterScale(_:)` → daemon `engine.set_adapter_scale` |
| Daemon status | `DaemonLLMEngine.runtimeStatus()` → daemon `runtime.status` (`{path, sha256, scale}`) |
| Per-prompt infer | `DaemonLLMEngine.inferForEval(messages:systemPrompt:options:)` |
| Registration | `FaeScheduler` → `coordinator.setAdapterEvaluator(daemonEvaluator)` (only when the daemon lane is live AND `DaemonEvalSuite.loadBundled()` SHA-verifies) |
| Held-out suite | `daemon-ab-eval-v1.json` (SHA-locked via `DaemonEvalSuite.lockedSHA256`) |
| Gate receipt | `GateReceipt` minted by `ImprovementCycleCoordinator.mintAndStoreGateReceipt`, required by `requireGateReceipt` before deploy |

## Procedure

The eval phase runs inside the nightly improvement cycle. There are two ways to
drive it; **B is preferred for a focused de-risk** because it isolates the A/B from
the rest of the cycle.

### A. Trigger the nightly improvement cycle's eval phase

With the daemon lane live, `FaeScheduler` registers the `DaemonABEvaluator` at
cycle start (see the registration symbol above). Drive a cycle that reaches the
EVALUATING state — either let `improvement_cycle` fire at 03:00, or force it with
the `scheduler_trigger` tool / debug console against the `improvement_cycle` task,
having seeded enough feedback (20+ events, 5+ corrections) and a trained candidate
GGUF. When the cycle reaches EVALUATING, `DaemonABEvaluator.evaluate` runs the
`reload(deployed) → score → reload(candidate) → score → restore(deployed)` sequence.

### B. Focused A/B (recommended)

Construct a `DaemonABEvaluator` directly against the live engine and call
`evaluate` with explicit paths — mirror `FaeScheduler`'s construction:

```swift
let suite = try DaemonEvalSuite.loadBundled()           // SHA-verifies the bundled set
let client = LiveDaemonABClient(engine: daemonLLMEngine) // the LIVE daemon
let evaluator = DaemonABEvaluator(client: client, suite: suite)
let outcome = try await evaluator.evaluate(
    candidatePath: "/abs/path/candidate.gguf",
    baselinePath:  "/abs/path/deployed.gguf")            // nil ⇒ baseline = base model
print(outcome.delta)                                     // per-dimension EvalDelta
```

Read the per-dimension delta off `outcome.delta` (toolCalling / faeCapability /
assistantFit / serialization, in percentage points; `nil` for any dimension the
A/B could not measure on both sides). Watch the daemon audit log / NSLog for the
reload + set-scale + restore sequence.

## Pass criteria

1. **Measured, not blocked.** The A/B returns a `GateOutcome` with a *measured*
   per-dimension `EvalDelta` (deltas present, not `nil`/unavailable). An
   unavailable/failed eval is `candidate_blocked` → `.idle` by design — that is the
   fail-closed path, not a pass.
2. **Restore-on-exit verified (the safety property).** After eval, `runtime.status`
   shows the daemon back on the **DEPLOYED** adapter (or the base model when none
   was deployed) — **never the candidate**. Confirm via the daemon audit log /
   NSLog line `DaemonABEvaluator: restored deployed adapter after eval (…)`. A
   `restoreUnconfirmed` throw (NSLog `FAILED to restore deployed adapter …
   (fail-closed)`) is a hard failure: the daemon may be on the un-gated candidate.
3. **Discrimination — bad candidate is BLOCKED.** Run a deliberately-BAD candidate
   (e.g. an adapter overfit to garbage, or the base model presented as the
   "candidate" against a strong deployed adapter). It must produce a **negative**
   delta and be **blocked** — no receipt, no deploy. This proves the held-out set
   actually separates good from bad.
4. **Good candidate passes the full gate.** A genuinely-better candidate produces a
   non-negative delta, **mints a `GateReceipt`** (sha matching the candidate
   artifact), and deploys *through* the gate (`requireGateReceipt` consumes the
   receipt before `currentAdapterPath` is written).

## Eval-set discrimination — known weaknesses (feeds a future `daemon-ab-eval-v2`)

A static read of `daemon-ab-eval-v1.json` (32 examples, 8 per dimension) against
the `DaemonEvalScorer` rules shows the suite is **structurally sound but skews
lenient** — every dimension has at least some genuinely discriminating items, but
several examples any coherent model passes, which compresses the measurable delta:

- **toolCalling (8) — strongest dimension.** 6 `expectToolCall` items check both the
  tool name AND required arg keys (a real routing+serialization test), plus two
  `expectNoToolCall` restraint items (`tool-005` "thanks, that's all", `tool-006`
  "favourite colour?"). This dimension *will* separate a model that mis-routes or
  drops required args. Keep as-is; it is the load-bearing gate.
- **serialization (8) — mostly discriminating.** `expectJSONKeys`/`expectJSONArray`
  (`ser-004/005/007`) and the `SUPERSEDE`-vs-`STORE` item (`ser-003`) are real format
  tests a sloppy model fails. The four bare `expectLinesPrefixed STORE:` items
  (`ser-001/002/006/008`) are easier — any model that emits one `STORE:` line passes,
  regardless of content quality. Weak-ish but not free.
- **faeCapability (8) — easy trivia, weakly discriminating.** All eight are
  single-keyword `expectKeywords` factoids (Tokyo, 42, Mars, 366, Shakespeare, CO₂,
  H₂O, France). Any competent base model and any non-catastrophic candidate both
  score ~100%, so this dimension contributes **near-zero delta** in practice — it
  catches only gross capability *regression*, not improvement. This is the weakest
  dimension for *discrimination* (though useful as a forgetting tripwire).
- **assistantFit (8) — partly trivial.** The keyword/forbidden items (`fit-001/002/
  003/005/006/007`) are reasonable persona checks (greeting words present, "as an
  ai"/"language model" forbidden). But **`fit-004` and `fit-008` are
  `expectNonEmpty`** — they pass on *any* non-empty answer lacking the forbidden
  phrases, i.e. essentially free. These two are the clearest "any coherent model
  passes" examples.

**Net:** the gate is meaningful — toolCalling + the JSON/SUPERSEDE serialization
items will move the delta for a real change, and the forbidden-phrase checks catch
persona drift — but `faeCapability` (all trivia) and the two `expectNonEmpty`
`assistantFit` items add little discrimination and risk a base-vs-candidate tie on
those dimensions. A future **`daemon-ab-eval-v2`** should: replace the two
`expectNonEmpty` fit items with keyword/forbidden checks; harden the bare `STORE:`
serialization items to assert at least key *content* (e.g. `expectKeywords` on the
extracted value); and add some harder/adversarial capability items (multi-step or
distractor-laden) so `faeCapability` measures more than rote recall. Any such change
needs a **new SHA lock** (regenerate `lockedSHA256`) and updated tests — the suite
is intentionally SHA-pinned so a drifted set is rejected rather than silently
changing what a pass means.

## What "fail" must look like (safety)

A **failed or interrupted eval must leave the daemon on the DEPLOYED adapter** — the
restore runs on every exit path (success, throw, timeout, cancellation) precisely so
an aborted run cannot strand the live daemon on the un-gated candidate. If you kill
the app mid-eval, confirm `runtime.status` afterwards: it must report the deployed
adapter, never the candidate. If it reports the candidate, that is a safety
regression and the `restore-on-every-exit` design did not hold — stop and surface it.

## Live de-risk run — 2026-06-22 (results)

First live run on real hardware (Apple M5 Max), driven headlessly by
`crates/fae-engine/examples/daemon_ab_derisk.rs` (a manual, non-CI harness that
spawns the real `llama-server` sidecar and exercises the *actual* `fae-engine`
`set_adapter_scale` / `reload_adapter` / `loaded_adapter` primitives — the same
mechanism `DaemonABEvaluator` drives — bypassing only the Swift/NDJSON layer, which
is already unit-proven). Base model `gemma-4-E4B-it-Q4_K_M.gguf`; adapters
`~/llama-spike/personal-metric.gguf` and `personal-c2.gguf` (P3/C3 bench probes).
Run it with `env -u RUSTFLAGS cargo run --release --manifest-path crates/Cargo.toml -p fae-engine --example daemon_ab_derisk`.

Per-dimension accuracy:

| dimension      | base (s0) | personal-metric (s1) | personal-c2 (s1) |
|----------------|-----------|----------------------|------------------|
| assistantFit   | 100%      | 88%                  | 88%              |
| faeCapability  | 88%       | 88%                  | 88%              |
| serialization  | 100%      | 100%                 | 100%             |
| toolCalling    | 100%      | 100%                 | 100%             |

**Legs proven (mechanism + safety):**
- ✅ Real sidecar spawn, scale-0/scale-1 A/B, `reload_adapter` to a *different* adapter
  (SHA-confined), and `loaded_adapter` status all work end-to-end on real GGUF adapters.
- ✅ **Restore-on-exit holds live** — after the A/B the harness logged
  `loaded_adapter after restore: None (base only)`; the daemon was left on the base
  model, never the candidate.

**Leg NOT proven — discrimination (`daemon-ab-eval-v1` is too weak):**
- 3 of 4 dimensions (`faeCapability`, `serialization`, `toolCalling`) are **identical**
  across base and both adapters → zero delta; the suite cannot tell these adapters apart.
- `assistantFit` moved −12pp, but **identically for both adapters** — a single-example
  artifact (1 of 8 fit items), not signal that separates good from bad.
- This is on probe adapters (not necessarily "good" personal adapters), but it confirms
  the static review on real hardware: **v1 does not meaningfully discriminate.** The
  gguf lane's *safety* is intact (a zero/negative delta fails closed — the gate blocks,
  never deploys), but its *usefulness as an improvement filter is low until a
  `daemon-ab-eval-v2`* hardens the weak dimensions (see the weaknesses section above).
- Follow-up: investigate which `assistantFit` example drives the uniform −12pp (likely a
  keyword/forbidden phrasing difference), and build v2 before relying on the gguf lane
  to *promote* (as opposed to merely *block*) adapters.

## Scope notes

- This is **dev-only** (`FAE_DEV=1` / `FAE_MODELS_LOCK=off`) because runtime LoRA
  adapters cannot be `models.lock`-pinned; production keeps the lock ON and the
  daemon's reload path enforces canonicalize + SHA confinement instead.
- The **MLX `.mlxDir` lane** uses `FaeBenchmarkEvaluator`, not this A/B; it has its
  own availability gate (the FaeBenchmark binary must be configured, else the lane
  stays blocked). This runbook covers only the `.gguf` daemon lane.
- This smoke is owner-run on real hardware and is intentionally **not** wired into
  CI (no live daemon + GGUF adapters in the runners). The unit tests + the SHA lock
  are the automated proofs; this page is the manual confirmation of the live legs.
