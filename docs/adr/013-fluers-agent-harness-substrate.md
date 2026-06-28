# ADR-013: Fluers as Fae's Agent-Harness Substrate

- **Status:** Proposed (spike S19 **Stage 1 PASSED + reviewer-verified 2026-06-28**;
  recommendation PROCEED-WITH-B with 4 tracked caveats; Stage 2 live-engine turn +
  human sign-off owed before Accepted)
- **Date:** 2026-06-28
- **Decision owners:** David Irvine
- **Reviewers:** TBD
- **Supersedes:** none
- **Superseded by:** none
- **Related:** ADR-002 (embedded Rust core), ADR-010 (llama.cpp sidecar), ADR-011 (headless Rust core runtime), ADR-012 (local-first coordinator); `docs/plans/cross-platform-completion-roadmap-2026-06-18.md` (P7/D3); `docs/plans/fluers-harness-substrate-spike-2026-06-28.md` (the gating spike); `../fluers`

## Context

The cross-platform roadmap's North Star is explicit: *"No Swift product logic:
decision-making moves to Rust (daemon/orb-host); Swift stays the macOS adapter
(EventKit/MLX/AppKit shell). Portable skills replace Apple tools off-Mac."*
Two roadmap items are blocked on the same missing piece:

- **P7/D3** (portable tools off-Mac) needs a **daemon-side tool/skill execution
  host** — a filesystem/process abstraction plus a sandbox the tools target so the
  *same tool code* runs on macOS and Linux. `MEMORY.md` records this directly:
  *"no off-macOS tool/skill execution host — tools+skills run ONLY in Swift app;
  daemon is tool-AWARE but executes nothing; needs a daemon ToolHost/SkillHost
  foundation phase FIRST."*
- The egress flag (2026-06-23) anticipates that the moment such a ToolHost executes
  `web_search`/`fetch_url`, those become fresh cloud-egress surfaces that **must**
  route through the conductor's `assert_*_egress_gates` pipeline.

We own a sibling Saorsa Labs project, **fluers** (`../fluers`, Apache-2.0, same
panic-free lint discipline) — a Rust agent harness originally ported from Flue.
Ground-truth review (2026-06-28) found it ~70% mature and genuinely working:
12.5k LOC, 137 tests, a pure dependency-injected turn-loop (`fluers-core`), a
sandboxed `SessionEnv` with path containment, native `read/write/bash/grep/glob`
tools, a `Skill` SKILL.md loader, JSON+Postgres persistence, an OpenAI-compatible
provider, streaming, and MCP (`rmcp`). It is structurally the ToolHost P7 needs.

Because we own fluers and may deviate from a faithful Flue port (README updated),
the question is not "cherry-pick a subset" but **"what is the right relationship
between fluers and `fae-daemon`?"**

## Decision Drivers

- Deliver the roadmap North Star — decision-making and execution in Rust; Swift as
  a thin macOS adapter — with a **clean separation of responsibilities**.
- Unblock P7/D3 with a real, tested execution substrate rather than a bespoke one.
- Avoid two agent loops, two session models, two tool traits, two persistence layers.
- Preserve Fae's hard-won safety posture (ADR-005 DamageControlPolicy, ADR-012
  PII membrane + control-plane authz + audit) — nothing executes ungoverned.
- Keep `main` green and the live, mid-roadmap daemon (P5 merged, P9 in flight)
  unbroken — favour caution over speed (CLAUDE.md Rules 1, 2, 3, 12).
- Keep fluers independently shippable for other Saorsa projects (saorsa-core,
  ant-quic): Fae plugs in via **generic traits/hooks only**, no Fae-specific deps
  inside fluers.

## Considered Options

1. **No dependency; copy ideas.** Build a bespoke `fae-toolhost` from scratch.
   Rejected: wasteful given we own a working, tested harness.
2. **Vision A — toolhost bolt-on.** `fae-daemon` depends on `fluers-core` +
   `fluers-runtime`; adopt `SessionEnv`/`Sandbox`/`Tool`/`Skill` *wrapped under
   control-plane*, executing native + skill tools daemon-side. The Swift-driven
   multi-turn loop stays as-is for now.
3. **Vision B — daemon-on-fluers.** Relocate the multi-turn tool loop from Swift
   into the daemon (`fluers::run_agent`), with the conductor reshaped as a
   per-turn `ModelProvider`, `fae-engine` implementing `ModelProvider`, Swift
   macOS tools executed via a `RemoteSwiftTool` round-trip, and sessions owned by
   the daemon. The full "one loop / one session model" separation.

## Decision

**Adopt fluers as Fae's agent-harness substrate, staged: commit Vision A now;
gate Vision B behind a de-risking spike.**

1. **Vision A is committed.** `fae-daemon` takes `fluers-core` + `fluers-runtime`
   as a path/workspace dependency and gains a daemon-side tool/skill execution
   host built on fluers' `SessionEnv` + `Sandbox` + `Tool` + `Skill`. Every tool
   execution runs **under** Fae governance: control-plane scope check + a fluers
   `Tool` **policy hook** carrying DamageControlPolicy/PathPolicy/egress-membrane
   evaluation. This unblocks P7/D3 and is the first brick of B (the
   `SessionEnv`/`Tool`/policy-hook seam is identical in both).

2. **Vision B is gated on the spike** (`fluers-harness-substrate-spike-2026-06-28.md`).
   The spike proves a thin end-to-end slice — one real daemon turn through
   `fluers::run_agent`, with the conductor wrapped as a `ModelProvider`,
   `fae-engine` behind that provider, one native tool executed in-daemon under
   control-plane, one `RemoteSwiftTool` round-trip to Swift, and a `TurnSink`
   recording a route receipt. If the slice meets parity, B is scheduled
   post-P9; if it fights, we stop at A (P7 still unblocked) and keep the
   Swift-driven loop.

3. **Fae-driven changes to fluers stay generic** (README updated per ownership
   rule): a `Tool` execution **policy hook** (`ToolPolicy`/`PolicyVerdict` — landed
   generic in spike S19, default allow-all), an integrity'd `Skill` schema
   (`schemaVersion`/`capabilities`/`allowedTools`/SHA-256), an `edit` tool, the
   OS-level sandbox isolation already on fluers' own SECURITY.md roadmap (seatbelt
   on macOS, landlock on Linux), and (for B's L7 governance) likely an **around-tool
   hook** so Reversibility/receipts can wrap execution. `AgentContent::Audio` is
   **not** needed (R4 resolved). None introduces a Fae-specific dependency into
   fluers.

### Target architecture (end-state, Vision B)

```
Swift app    macOS adapters ONLY (EventKit, MLX fallback, AppKit shell, mic/audio)
             + UX + approval cards + RemoteSwiftTool responder
   │ NDJSON socket (product contract) + NEW server-initiated tool-exec channel
fae-daemon   transport + ConductorProvider (routing / RLHF / budget / intel
   │           as a per-turn ModelProvider; telemetry stays inside it)
   │         + control-plane authz/egress as a fluers Tool policy hook
   │         + RemoteSwiftTool + native tools + Fae skills (integrity'd) + fae-acp
   ▼ depends on (path/workspace dep)
fluers       ONE turn loop (run_agent) + SessionEnv + Sandbox + Tool + Skill
   │           + sessions/persistence + MCP + OS isolation
   │         ← stays independently shippable (CLI / server) for other consumers
fae-engine   mistral.rs / llama.cpp / ModelsLock  →  implements fluers::ModelProvider
```

### Why the conductor-as-provider fit is sound (assumption test, 2026-06-28)

Evidence-based review of both codebases confirmed the load-bearing claim:

- **The daemon is single-pass per request; the multi-turn loop lives in Swift**
  (`PipelineCoordinator.generateWithTools` recursion, `session.rs:run_turn` does
  one streaming inference and returns `tool_calls` without feeding them back). So
  the conductor was never a competing loop — `route_turn` is *already*
  provider-shaped ("decide route → one inference → return response + tool_calls +
  telemetry").
- **`fluers::ModelProvider::invoke(&self, …)`** is async + `&self` → a stateful
  router impl is fine; the provider is invoked **exactly once per turn**
  (`runner.rs:268`), matching the conductor's per-turn (not mid-turn) routing.
- The **Thinker→Worker→Verifier chain** stays encapsulated *inside* `invoke`
  (one provider call internally does N backend calls, returns one `ModelResponse`).
  Conductor **telemetry/receipts stay where they are**, inside the provider.
- **Budget/reward/intel are per-turn / per-run, not token-level** (budget dormant;
  "token counts never a blocking dimension in v1"; reward = rolling post-turn
  receipts; intel = export-only at turn-end) → they map onto fluers' `TurnSink` /
  `RunEvent` hooks; fluers' lack of token-level budget is not needed.

The real scope/risk of B is therefore **not** the conductor. It is: (R1) loop
relocation with behaviour parity, (R2) splitting the 8-layer per-tool governance,
(R3) the new server-initiated tool channel, (R4) two-pass audio, (R5) the
Swift-only `<tool_program>` JSC path. These are what the spike must surface.

## Consequences

### Positive

- One agent loop, one session/persistence model, one `Tool` trait spanning
  daemon-native tools, `RemoteSwiftTool` (macOS), and MCP tools.
- P7/D3 unblocked: tools/skills target `SessionEnv` → portable across macOS/Linux.
- Session/conversation state moves into the daemon (a North-Star item delivered
  as a side effect of B).
- MCP arrives "for free" via `fluers-mcp` — a capability Fae lacks today.
- fluers gains a security policy hook + OS isolation it needed anyway; Fae's
  safety requirement becomes fluers' generic feature.
- Egress flag satisfied by construction: the policy hook is where
  `assert_*_egress_gates` runs, so any networked daemon-side tool is gated from
  day one.

### Negative / Trade-offs

- **R1 — loop relocation.** Behaviour parity with the Swift loop (maxToolTurns
  10/25, termination conditions, duplicate-loop guard, `isToolFollowUp` thinking
  suppression) must be reproduced in `run_agent`'s config + hooks.
- **R2 — governance split.** Platform-specific gates (DamageControlPolicy,
  ReversibilityEngine, ReceiptStore) stay in Swift behind `RemoteSwiftTool`;
  policy gates (mode/privacy, proactive allowlist, TillDone, computer-use cap)
  plus native-tool damage/path control need daemon-side homes on the policy hook.
  This is the substantial migration.
- **R3 — new channel.** B needs a server-initiated daemon→Swift tool-exec
  round-trip (today the round-trip is Swift-initiated). ACP A3's server-initiated
  permission round-trip is the precedent, not a greenfield.
- **R4 — audio. Resolved (spike S19, 2026-06-28): NO `AgentContent::Audio` variant
  needed.** Two-pass STT means `ConductorProvider::invoke` transcribes in pass 1 and
  the loop runs on text only (S18 deleted single-pass audio-native). This *removes*
  a planned fluers change.
- **R5 — `<tool_program>`. Resolved (recommendation, 2026-06-28; see
  `docs/spikes/S19-R5-toolprogram-portability-findings.md`).** Make the JS path
  cross-platform with **zero macOS functionality loss** via a **hybrid behind a
  `ToolProgramRuntime` trait**: keep Swift JSCRuntime as the macOS adapter
  (untouched), add an `rquickjs` (QuickJS, ~2–3 MB) portable impl for off-Mac.
  rquickjs preserves memory/stack limits, async/await, and the `fae.tool` bridge;
  the acceptable gaps are CPU limit → wall-clock polling (same on both) and a
  ~200-LOC Proxy wrapper to reproduce `DryRunPlan`. `boa` (no memory cap / no
  graceful cancel) and `deno_core` (V8: 10–12 MB, slow cross-platform builds) were
  rejected. Same trait-seam + macOS-adapter pattern as the rest of this ADR.
- Coupling: `fae`'s crate workspace pins fluers (path/git dep); fluers changes
  must stay generic to avoid Fae-specific coupling.

### Neutral / Operational

- fluers' `MemoryAdapter` is the eventual seam for Fae memory moving to Rust;
  near-term memory stays in Swift.
- fluers' `LocalSandbox` is path-containment-only today; acceptable **only**
  because it runs behind the policy hook (DamageControl/PathPolicy) — OS isolation
  is scheduled, not optional.
- One phase in flight at a time per the roadmap workflow; B lands after P9.

## Validation

- **Spike gate:** B proceeds only if the spike's success criteria are met (see
  the spike doc) — a real daemon turn through `run_agent` with a native tool and a
  `RemoteSwiftTool`, behaviour-parity termination, and a control-plane-audited tool
  execution.
- **Parity tests:** loop-termination and tool-turn-cap tests mirror the Swift
  loop's behaviour before any cutover.
- **Governance proof:** every daemon-executed tool produces a control-plane audit
  entry; a path-escape and a damage-control case are both denied daemon-side.
- **Green gate:** `env -u RUSTFLAGS` fmt / clippy `-D warnings` / nextest across
  touched crates; `swift build` clean; fluers `just check-all` green.
- **Review trigger:** revisit if the conductor ever needs mid-turn re-routing
  (would break the once-per-turn provider model) or if fluers' upstream diverges
  in a way that fights Fae's hooks.

## Notes for AI-assisted work

This ADR is **Proposed**. AI tools may draft and refine it but **must not mark it
Accepted without human review**. Accepted ADRs are immutable — supersede, don't
edit. The Vision B commitment specifically must not be treated as approved until
the spike reports and a human accepts.
