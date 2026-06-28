# Spike S19 — Fluers harness substrate de-risk (Vision B gate)

- **Date:** 2026-06-28
- **Status:** Stage 1 + Stage 2 COMPLETE + reviewer-verified (2026-06-28).
  **Seam 2 CONFIRMED on a live llama.cpp turn → ADR-013 ACCEPTED (owner sign-off).**
  PROCEED WITH B, **5 tracked caveats** (the 5th = native `tool_call_id` in
  `fae-engine`, the first engine task). See "## Outcome" below.
- **Gates:** ADR-013 Vision B (daemon-on-fluers). A is committed regardless; this
  spike decides whether B proceeds.
- **Owner / reviewer:** main session is REVIEWER — verifies against **live output +
  `git diff`**, NOT the team's claims (static-only review has missed
  release-blocking bugs; agents have fabricated reports). Team implements AND
  tests, then HANDS BACK with verbatim self-captured evidence; does **not**
  commit/push.
- **Isolation:** run on a branch `spike/fluers-substrate` in a **git worktree**
  (not the shared main tree → avoids `.git/index.lock` races). The spike may live
  in a throwaway crate; nothing here ships.

## Why this spike exists

ADR-013's assumption test (2026-06-28) confirmed, from code, that:

- the daemon is **single-pass**; the multi-turn tool loop is **in Swift**
  (`PipelineCoordinator.generateWithTools`); and
- the conductor (`route_turn`) is **already `ModelProvider`-shaped**
  ("decide route → one inference → return response + tool_calls + telemetry"),
  and `fluers::ModelProvider::invoke(&self)` is async/`&self`/called once per turn.

So the conductor-as-provider claim is **not** the risk. The risks are the loop
relocation and the governance split. This spike exercises **every load-bearing
signature once**, end to end, so we learn whether B is a clean migration or an
impedance fight **before** committing the real work.

> Walking-skeleton discipline (mirrors fluers' own MVP 0.5): one thin slice
> through every layer, before locking any signature.

## The slice to build

A standalone test/binary in a throwaway crate (e.g. `crates/fae-substrate-spike`)
that runs **one real multi-turn agent run through `fluers::run_agent`**, driven
inside the daemon process boundary, proving the four seams:

```
fluers::run_agent(
    provider:  &ConductorProvider,     // SEAM 1: conductor-as-ModelProvider
    tools:     &[ Arc<ReadTool>,       // SEAM 3a: native tool, executes in-daemon
                 Arc<RemoteSwiftTool> ], // SEAM 3b: round-trips to a stub Swift responder
    messages,  model, config,
    cancel,
    hooks:     RunHooks { turn_sink: Some(&RouteReceiptSink), .. }, // SEAM 4: per-turn telemetry
)
```

### Seam 1 — `ConductorProvider: fluers_core::ModelProvider`

- Wrap the **existing** conductor entry (`route_turn` / `runtime.run`) as
  `impl ModelProvider for ConductorProvider { async fn invoke(&self, req) -> Result<ModelResponse> }`.
- `invoke` must: build a `ConductorTurnContext` from the `ModelRequest`
  (messages + tools), call the existing routing+inference path, and return the
  assistant message(s) as `ModelResponse { messages }` including any `ToolUse`
  blocks parsed from `run_turn`'s `tool_calls`.
- **Do not** re-implement routing. Reuse `route_turn`'s body. Telemetry/receipts
  stay inside `invoke` exactly as today.
- **Local-only route is sufficient** for the spike (`StaticDirectPolicy` →
  `fae-engine`). Cloud routing is out of scope here.
- `fae-engine` is reached **through** the conductor; if cleaner, also provide a
  thin `EngineProvider: ModelProvider` directly over `fae-engine` and have the
  conductor delegate to it — document whichever you choose.

### Seam 2 — `fae-engine` produces `fluers` message/tool shapes

- Map `fae-engine`'s `ChatRequest`/`ChatEvent`/`ToolSpec` ↔ fluers'
  `ModelRequest`/`AgentMessage`/`ContentBlock::ToolUse`/`ToolDefinition`.
- Confirm `ChatEvent::ToolCall { name, arguments }` round-trips to
  `ContentBlock::ToolUse { id, call }` and that a `Role::Tool` tool-result message
  (fluers appends one per call) maps back to a `ChatMessage` the engine accepts on
  the next turn. **This is the inversion** that today happens in Swift.

### Seam 3 — two tools behind one `Tool` trait

- **3a Native:** use fluers' `ReadTool` over a `LocalSessionEnv` rooted at a temp
  dir. Wrap its `execute` so it **first** calls control-plane
  `authorize(client, cmd)` and a **policy hook** (see below). Prove a read inside
  root succeeds and a `../escape` path is **denied daemon-side**.
- **3b RemoteSwiftTool:** `struct RemoteSwiftTool { name, sink }` whose `execute`
  does a round-trip to a **stub Swift responder** — for the spike this can be an
  in-process async channel or a local socket that echoes a canned result. The
  point is to prove a `Tool::execute` can block on a server-initiated round-trip
  and feed the result back into the loop. (Real Swift wiring is B's work, not the
  spike's.)

### Seam 4 — governance policy hook + telemetry sink

- Introduce the **generic policy hook** in fluers — **APPROVED by owner
  (2026-06-28); this fluers change is sanctioned, build it.** A trait the `Tool`
  executor consults *before* `execute`, generic (no Fae types), e.g.
  ```rust
  // fluers-core (generic; no Fae types)
  #[async_trait] pub trait ToolPolicy: Send + Sync {
      async fn check(&self, tool: &str, input: &Value, ctx: &InvokeContext) -> PolicyVerdict;
  }
  // PolicyVerdict::{ Allow, Deny(reason), Confirm(reason) }
  ```
  Wire it as an optional field on the run (via `RunHooks` or a `RunConfig`
  addition — pick the cleanest of those two and document why). **Update the fluers
  README** to record the deviation from the upstream Flue port. Default = no policy
  (Allow-all) so existing fluers consumers are unaffected. Fae's impl composes
  control-plane scopes + DamageControlPolicy/PathPolicy + the PII/egress membrane
  behind it.
- `RouteReceiptSink: fluers_core::TurnSink` — `after_turn` writes a `RouteReceipt`
  to the daemon's existing `audit.jsonl` path, proving budget/reward/intel can
  observe at per-turn granularity through the hook.

## Execution staging (de-risk order)

Mirror fluers' own MVP 0.5 discipline — prove every load-bearing signature with a
mock provider first, then swap in the real engine:

- **Stage 1 — walking skeleton (CI-safe, no model, do this first).** All four
  seams against a **mock `ModelProvider`** that emits a scripted turn
  (text → tool call → text), exactly like fluers' existing mock. This exercises
  `ConductorProvider` wiring shape, the `ToolPolicy` hook, native-tool governance +
  path-escape denial, the `RemoteSwiftTool` stub round-trip, the `TurnSink`
  receipts, and `max_turns` parity — **with zero network/model dependency.** This
  stage alone answers R1–R3 and most of the gate.
- **Stage 2 — live engine turn (needs daemon + model).** Replace the mock with
  `fae-engine` (llama.cpp lane; `FAE_DEV` / `FAE_MODELS_LOCK=off` permitted) and run
  one real multi-turn turn. This confirms the `fae-engine ↔ ModelProvider` mapping
  (Seam 2) for real. If the runner cannot reach a live daemon/model in its
  environment, **hand back Stage 1 complete + Stage 2 blocked with the exact
  blocker** — do NOT fabricate a live result. The reviewer (or owner) runs Stage 2
  on a machine with the daemon.

## Success criteria (the gate)

All must hold, with **verbatim captured evidence**:

1. **End-to-end run:** a single `run_agent` call completes a multi-turn run
   (≥2 turns: turn 1 emits a tool call, tool executes, turn 2 produces final text)
   against the **real `fae-engine`** (llama.cpp daemon lane; `FAE_DEV` /
   `FAE_MODELS_LOCK=off` permitted for the spike). Capture the daemon log showing
   llama.cpp served the turns.
2. **Conductor-as-provider:** the run goes through `route_turn`/`runtime.run`
   inside `ConductorProvider::invoke`, and a route telemetry entry / fingerprint is
   produced per turn (show the audit/telemetry line).
3. **Native tool, governed in-daemon:** `ReadTool` reads a file inside the session
   root **and** a path-escape attempt is **denied by the policy hook** with a
   control-plane audit entry. Show both the success and the denial audit lines.
4. **RemoteSwiftTool round-trip:** a tool call routes to the stub Swift responder
   and its result is fed back into the next turn (show the result text appearing in
   turn 2's context).
5. **Per-turn telemetry:** `RouteReceiptSink.after_turn` fired once per turn; show
   the receipts.
6. **Behaviour-parity probe:** `RunConfig { max_turns }` enforces a cap analogous
   to the Swift loop's maxToolTurns; show a run that hits the cap and terminates
   cleanly (no panic, a defined outcome).
7. **Green gate:** `env -u RUSTFLAGS` fmt + clippy `-D warnings` + nextest for the
   spike crate and any touched fluers/fae crate; fluers `just check-all` green if
   fluers was modified.

## Questions the spike MUST answer (report explicitly, with evidence)

- **R1 (loop parity):** Does `run_agent`'s config + hooks reproduce the Swift
  loop's termination set (turn cap, all-denials exit, duplicate-loop guard)? Which
  Swift behaviours have **no** fluers equivalent and would need adding?
- **R2 (governance split):** Is the `ToolPolicy` hook a sufficient seam for
  control-plane + DamageControl + membrane? What governance is genuinely
  platform-bound (must stay in Swift behind `RemoteSwiftTool`) vs. movable
  daemon-side? Enumerate, mapped to the 8 layers in ADR-013.
- **R3 (channel):** What does the server-initiated daemon→Swift tool-exec channel
  need beyond ACP A3's round-trip? Sketch the message types.
- **R4 (audio):** With two-pass STT, does the loop ever need an
  `AgentContent::Audio` content block, or does the conductor-provider handle audio
  in pass 1 and emit text to the loop? Decide from the actual flow.
- **R5 (`<tool_program>`) — owner priority: maximize cross-platform reach WITHOUT
  losing any functionality.** The JS `<tool_program>` path runs today in the Swift
  JSCRuntime (`Runtime/JSCRuntime.swift`) with `ScriptBudget`, per-block
  `allowedTools`, the tool bridge, and `DryRunPlan`. Investigate options and
  recommend with evidence:
  1. **Portable Rust JS engine in the daemon** — evaluate `rquickjs` (QuickJS
     bindings), `boa`, or `deno_core` as a daemon-side script runtime so
     `<tool_program>` executes cross-platform with the tools exposed via the same
     fluers `Tool` set (native + `RemoteSwiftTool`). Assess: feature/JS-spec
     coverage vs JSC, sandbox/budget enforceability, binary-size/build cost, and
     whether `ScriptBudget`/`allowedTools`/`DryRunPlan` can be reproduced 1:1.
  2. **Round-trip to Swift JSCRuntime** — daemon loop detects a `tool_program`
     block and hands it to Swift over the (new) server-initiated channel; portable
     platforms lose the feature.
  3. **Hybrid** — portable engine where available, Swift JSCRuntime as the macOS
     fast-path.
  Hard constraint: **no loss of functionality on macOS.** State which option gets
  closest to "cross-platform AND full-functionality," the gaps, and the effort.
  A throwaway "hello + one tool call" script under the chosen portable engine is a
  bonus de-risk if cheap; otherwise a written recommendation is acceptable for the
  spike.
- **Coupling:** path-dep vs git-dep for `../fluers`; does any fluers change risk
  Fae-specific coupling? Confirm all fluers edits stayed generic + README updated.

## Out of scope (do NOT build)

- Real Swift-side `RemoteSwiftTool` wiring (a stub responder is enough).
- Cloud routing, budget enforcement, reward scoring (observe-only telemetry only).
- Moving session/conversation state out of Swift.
- Any production cutover. **Nothing in this spike ships.** The deliverable is the
  evidence + the R1–R5 findings that let the reviewer accept or reject ADR-013
  Vision B.

## Deliverable

A hand-back containing: `git diff --stat`; the captured evidence for criteria 1–7;
the explicit R1–R5 findings; and a one-paragraph recommendation —
**proceed with B / proceed with caveats / stop at A** — with the reasoning. The
reviewer verifies against live output and the diff, then updates ADR-013's status.

---

## Outcome (2026-06-28, reviewer-verified)

**Stage 1 walking skeleton COMPLETE.** Driver: agent `S19build` (general-purpose).
Branches (uncommitted, not for merge): fluers `spike/fae-toolpolicy`, fae
`spike/fluers-substrate`.

**Reviewer verification (NOT the report — re-run + real diff):**
- fluers diff matches claim: NEW `crates/fluers-core/src/policy.rs`,
  `runner.rs +178` (wiring + 2 tests), `event.rs +6` (`RunHooks.policy`), README
  +18 (Flue-deviation note), small re-exports.
- fae diff: NEW `crates/fae-substrate-spike/`, `crates/Cargo.toml +2` (member).
- **Gates re-run by reviewer:** `fae-substrate-spike` clippy clean + **5/5
  nextest pass**; fluers `clippy -D warnings` clean (all crates) + **139/139
  nextest** (was 137; +2 policy tests; no consumer regressions).
- **Tests are substantive** (negative controls present): denial test writes a real
  secret OUTSIDE root and asserts it is NEVER read; remote-tool test uses a
  `MISSING_SWIFT_RESULT` sentinel to prove the feedback path; cap test asserts
  exactly `max_turns` invocations.
- **Security check verified in the diff:** `policy_check` is consulted in BOTH the
  sequential (`runner.rs:754`) and parallel (`:776`, awaited before spawn) tool
  paths — no governance bypass under `tool_concurrency > 1`. `None ⇒ allow-all`;
  `Deny ⇒` model-visible error + loop continues. Trait names zero Fae types.

**Findings (R1–R5):**
- **R1 (loop parity) — achievable, ZERO further fluers-core changes.** `run_agent`
  already reproduces the turn cap, cancellation, no-tool-finish, and
  tool-error/unknown/panic/deny recovery, and ADDS `turn_timeout_ms` +
  `max_tool_calls_per_turn`. The three Swift behaviours it lacks are all
  satisfiable without core changes: duplicate-loop guard and all-denials early-exit
  land as a `TurnSink` (returning `Err` from `after_turn` aborts the run);
  `isToolFollowUp` thinking-suppression moves into `ConductorProvider::invoke`
  (inspect last msg = tool result → lower thinking).
- **R2 (governance split) — ToolPolicy covers the PRE-execution layers.** Of
  ADR-013's 8 layers: L2 tool-mode, L3 proactive-allowlist, L4 TillDone, L5
  computer-use-cap, L6 DamageControl/Path → all movable onto `ToolPolicy`
  daemon-side. **GAP: L7 Reversibility + ReceiptStore is around/post-execution, not
  a pre-gate** → needs a NEW around-tool hook in fluers OR stays in Swift behind
  `RemoteSwiftTool` (decide in B). L1 voice-identity (retired, S18) + L8 Apple-TCC
  are platform-bound (stay Swift). **Caveat:** `InvokeContext` carries only
  `{tool_call_id, cancel}` — run-scoped state (caller identity, proactive mode,
  till-done counters) must live in the Fae policy impl's own per-run `Arc` state.
- **R3 (channel) — A3-shaped, INVERTED (daemon=client, Swift=executor).** Reuse the
  NDJSON socket + `ConnSink`/`EventBus` + `BOOTSTRAP_CLIENT_ID`; new payloads:
  `ExecuteTool{call_id,session_id,turn,name,input,deadline_ms}` /
  `ConfirmRequest{call_id,tool,summary}` / `Cancel{call_id}` (daemon→swift) and
  `ToolResult`/`ToolError`/`ConfirmReply`/`Progress` (swift→daemon). New work, but
  bounded and precedented.
- **R4 (audio) — RESOLVED: NO `AgentContent::Audio` block needed.** Two-pass STT
  means `ConductorProvider::invoke` transcribes in pass 1 and the loop runs on text
  only (S18 deleted single-pass audio-native). **This removes one planned fluers
  change.**
- **R5 (`<tool_program>`) — HYBRID** (`rquickjs` portable + JSC macOS fast-path
  behind a `ToolProgramRuntime` trait). Independently confirmed by the dedicated R5
  investigation (`S19-R5-toolprogram-portability-findings.md`) — two agents
  converged. Zero macOS functionality loss.
- **Coupling:** spike used a path-dep; for real B, use a **git-dep pinned to a rev**
  so CI needs no sibling checkout.

**The 4 caveats to track when B is scheduled (post-P9):**
1. Duplicate-loop + all-denials guards → implement as a `TurnSink` (no core change).
2. L7 Reversibility/ReceiptStore → add an around-tool hook in fluers, or keep it in
   Swift behind `RemoteSwiftTool` (decision needed).
3. Server-initiated daemon→Swift tool-exec channel (R3) → real new work, A3-shaped.
4. `Confirm` UX rides that channel (the `ToolPolicy::Confirm` verdict is plumbed but
   has no confirmation channel in-loop yet).

### Stage 2 — live `fae-engine` turn (DONE + reviewer-re-run, 2026-06-28)

Driver: agent `S19stage2` (general-purpose) on an M5 Max. Added `EngineProvider:
fluers_core::ModelProvider` (lib.rs +226) over a real `LlamaServerAdapter`, plus
`examples/live_engine_turn.rs`. **Seam 2 CONFIRMED.**

**Reviewer re-ran the live example independently** (`cd crates && env -u RUSTFLAGS
FAE_DEV=1 FAE_MODELS_LOCK=off SPIKE_TRACE=1 cargo run -p fae-substrate-spike --example
live_engine_turn`, exit 0):
- Live `llama-server` on :18100, `Chat format: peg-gemma4`, real eval timings.
- Turn 1: the real Gemma-4 E4B QAT model emitted `ToolCall name=read args={"path":"note.txt"}`.
- The governed `ReadTool` read the temp file; turn 2's answer quoted the sentinel
  `GLASGOW-HERON-1742` — only knowable by actually reading the file.
- Stage 1 mock nextest still 5/5.
- (Op note: cargo runs from `crates/`, not the repo root — root is the Swift project.)

**Finding → caveat #5 (first engine task for B):** the tool-result *return* path is
text-flattened (carried as a `User` turn) because `fae-engine`'s `ChatMessage` is
text-only — no `tool_call_id` / native `assistant.tool_calls`. The forward path is fully
native. Extend `fae-engine`'s `ChatMessage`/`build_chat_body` to emit native OpenAI
`assistant.tool_calls` + `tool` messages with `tool_call_id` before B ships the lane.

**ADR-013 → Accepted (owner sign-off 2026-06-28).** Spike branches stay reference-only
(not for merge).
