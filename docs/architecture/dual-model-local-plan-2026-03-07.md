# Dual-model local architecture plan for Pipeline Fae — 2026-03-07

## Scope boundary

This plan describes the **Pipeline Fae** runtime.

- the **concierge** model here is a worker role inside Pipeline Fae
- this is **not** a plan to merge or unify Pipeline Fae with Cowork Fae
- shared infrastructure may be reused, but pipeline assumptions stay separate

## Executive summary

Recommendation: ship a **dual-model local architecture** for the premium local experience.

### Default pair

- **Operator model:** `qwen3.5-2b`
  - handles fast turns, tool routing, strict instruction following, structured output, and memory write decisions
- **Concierge model:** `LiquidAI/LFM2-24B-A2B-MLX-4bit`
  - handles richer summarization, longer-form drafting, reflective background work, and higher-empathy responses

### Key implementation decision

Because MLX concurrency is currently a constraint, the safest architecture is:

- **main app process** = orchestration, audio pipeline, tool execution, memory, UI
- **LLM worker process A** = operator model (`qwen3.5-2b`)
- **LLM worker process B** = concierge model (`LFM2-24B-A2B`)

This avoids fighting single-process MLX contention and gives the best path to a stable premium experience.

## Product goals

The dual-model local system should produce:

1. fast first response
2. excellent tool choice and tool restraint
3. strong instruction following
4. careful memory behavior
5. richer background reasoning without slowing the foreground interaction

## Why this architecture

Benchmarks now suggest a split between two kinds of excellence:

- **best operator / control model:** `qwen3.5-2b`
- **best richer assistant / summary model:** `LFM2-24B-A2B`

A single-model strategy forces a compromise. A dual-model strategy does not.

## Current codebase touchpoints

### Existing useful integration points

- `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`
  - central orchestration point for STT → LLM → tools → TTS
  - already has deferred tool-job concepts and turn/generation IDs
- `native/macos/Fae/Sources/Fae/ML/MLXLLMEngine.swift`
  - current single-model MLX engine
  - already has session reuse, cache reuse, tool-call format handling, warmup
- `native/macos/Fae/Sources/Fae/ML/ModelManager.swift`
  - load orchestration and memory measurement
  - good place to move toward worker lifecycle management
- `native/macos/Fae/Sources/Fae/Core/FaeConfig.swift`
  - place for dual-model feature flags and RAM-tier policy
- `native/macos/Fae/Sources/Fae/PipelineAuxBridgeController.swift`
  - already tracks readiness/progress; extend for per-worker readiness
- `native/macos/Fae/Sources/Fae/HostCommandBridge.swift`
  - already anticipates transport abstraction (`stdin/stdout`, socket, `XPC`)
- `native/macos/Fae/Tests/HandoffTests/ThinkAndToolFlowSafetyTests.swift`
  - a natural home for new routing and handoff safety tests

### Existing precedent

`PipelineCoordinator` contains historical prior art from the older Kokoro Python TTS path, which used a separate process. Treat that as transport-related precedent only, not current runtime behavior. The current recommendation remains to keep Kokoro in the main process initially and use the precedent only to justify similar worker patterns for LLMs.

## Recommended runtime topology

### Process layout

#### Main app process
Responsibilities:
- audio capture / VAD / STT
- turn state
- conversation state
- tool registry and actual tool execution
- memory orchestrator
- UI updates
- worker supervision
- model routing decisions
- cancellation and interruption policy

#### Operator worker process
Model:
- `qwen3.5-2b`

Responsibilities:
- fast direct response generation
- tool selection / tool XML or JSON payload generation
- strict instruction-sensitive responses
- memory write proposals / memory suppression decisions
- structured output generation

Latency target:
- short-turn TTFT under ~150 ms after warm start

#### Concierge worker process
Model:
- `LFM2-24B-A2B`

Responsibilities:
- background long-form reasoning
- summarization
- reflective responses
- post-tool synthesis
- memory-aware enriched drafts
- proactive follow-up suggestions

Latency target:
- can be slower, but should not block operator path

## Responsibility split per turn

### Foreground turn types → operator first

Use operator worker first for:
- tool-eligible user requests
- exact formatting requests
- short Q&A
- memory-sensitive preference/fact capture decisions
- fast spoken responses

### Background turn types → concierge first or second

Use concierge worker for:
- summarization after tool results
- email drafting polish
- richer explanations
- planning / reflection
- background follow-up after the user already heard a short foreground answer

### Combined pattern

Recommended default flow for premium local mode:

1. user speaks
2. STT completes
3. main process classifies turn
4. operator worker is queried first
5. if tools needed:
   - operator returns tool call(s)
   - main process executes tools
   - operator may produce a short immediate answer
6. if richer synthesis is useful:
   - send compact turn package + tool results to concierge worker
   - concierge returns refined summary / fuller answer / follow-up suggestion
7. main process decides whether to speak the refined version now, later, or keep it as UI-only background output

## Routing policy

Build a small deterministic router in the main process.

### Initial routing rules

#### Route to operator only
- exact-output / schema-only replies
- direct tool tasks
- file reads / calendar / contacts / notes / reminders / web search
- short factual user asks
- memory-write candidate extraction

#### Route to operator then concierge
- tool result needs summarization
- user asks for summary / rewrite / email draft / explanation after data retrieval
- emotionally nuanced but actionable tasks
- meeting prep / briefings / synthesis

#### Route to concierge only
- long-form drafting where tools are not needed
- reflective journaling / brainstorming
- high-empathy responses after initial acknowledgment

### Important design rule

The **router must be deterministic and cheap**. Do not use a third LLM to decide which LLM to call in v1.

## IPC / worker transport

## Recommendation for v1

Use **two long-lived child processes** launched from the app bundle, with framed JSON over `stdin/stdout` or Unix sockets.

Why:
- easiest to ship quickly
- supports token streaming naturally
- matches existing bridge abstractions
- easier to debug than `NSXPC` in early development
- avoids blocking on a full helper/XPC architecture before validating the product win

### Message types

#### Main → worker
- `load_model`
- `warmup`
- `generate`
- `cancel`
- `reset_session`
- `memory_pressure`
- `health_check`
- `unload_model`

#### Worker → main
- `ready`
- `progress`
- `token`
- `tool_call`
- `done`
- `error`
- `health_status`
- `metrics`

### Generate request fields

- request id
- turn id
- model role (`operator` / `concierge`)
- system prompt fragment
- message history slice
- tool schemas if any
- thinking level
- suppression flags (`no_think`, strict output)
- max tokens
- context budget
- cancellation scope

### Generate response fields

- request id
- token chunks
- parsed tool calls if any
- prompt tokens
- generated tokens
- TTFT
- total wall time
- finish reason

## Worker internals

Each worker should contain:
- one `MLXLLMEngine`
- its own session/cache state
- its own load/warmup lifecycle
- a small command loop
- worker-local telemetry

### Important rule

**Never share MLX engine state between operator and concierge.**
Each worker owns its model container completely.

## Config changes

Extend `FaeConfig.LlmConfig` with something like:

```swift
var localMode: String = "single" // single | dual
var operatorModelPreset: String = "qwen3.5-2b"
var conciergeModelPreset: String = "LFM2-24B-A2B-MLX-4bit"
var dualModelEnabled: Bool = false
var dualModelMinSystemRAMGB: Int = 32
var keepConciergeHot: Bool = true
var allowConciergeDuringVoiceTurns: Bool = false
var operatorContextSizeTokens: Int = 8192
var conciergeContextSizeTokens: Int = 16384
```

Also add a runtime recommendation helper:
- 8 GB → tiny single model
- 16–24 GB → `qwen3.5-2b` single-model default
- 32 GB+ → dual-model eligible
- 64 GB+ → dual-model premium default

## Session design

Keep **two separate histories**:

### Shared conversation ledger
Canonical turn history in main process.

### Operator projection
Compact recent context optimized for speed and tool execution.

### Concierge projection
Richer context optimized for summarization and synthesis.

The main app should derive worker-specific prompt views from a single canonical conversation state.

## Memory architecture

Memory writes should not come directly from the concierge model in v1.

### Recommended rule

- operator proposes memory actions
- main process validates and commits
- concierge may suggest, but does not directly own durable memory decisions

Why:
- operator is better at strict discipline in current benchmark data
- durable memory should favor precision and low hallucination risk

## Tool execution architecture

### Golden rule

**Only the main process executes tools.**
Workers may request tools, but never execute them directly.

### Tool flow

1. operator emits tool call request
2. main process validates against policy and permissions
3. main process executes tool
4. result is normalized
5. normalized result goes back to operator and optionally concierge

### Why operator first

Benchmarks show `qwen3.5-2b` is currently the best strict operator model.

## Voice UX policy

For spoken interaction, optimize for immediate perceived response.

### Recommended behavior

- operator gives the user the first response
- concierge runs opportunistically in background
- if concierge produces a meaningfully better answer before TTS starts, replace
- if it finishes later, surface it as:
  - a follow-up line
  - a canvas update
  - a silent UI enrichment

### Do not do in v1

- wait on concierge before speaking a normal answer
- speak two long answers back-to-back for the same user turn by default

## RAM policy

## Minimum system RAM for premium dual-model mode

**32 GB recommended minimum**

### Operating modes by installed RAM

| System RAM | Mode |
|---|---|
| 8 GB | single model: `qwen3.5-0.8b` |
| 16 GB | single model: `qwen3.5-2b` |
| 24 GB | single model default, optional experimental concierge loading |
| 32 GB | dual-model supported and recommended |
| 64 GB+ | dual-model premium default |

## Worker lifecycle policy

### 32 GB tier
- keep operator hot
- concierge can be hot if idle memory remains healthy
- unload concierge under pressure

### 64 GB+ tier
- keep both hot by default
- allow longer concierge contexts
- enable more aggressive background enrichment

## Failure handling

### If concierge fails
- continue with operator only
- no user-facing hard failure
- mark degraded premium mode in diagnostics

### If operator fails
- temporarily fall back to concierge for direct generation if available
- otherwise degrade to text-only / unavailable mode as appropriate

### If both fail
- preserve STT and UI where possible
- show clear recovery state

## Observability

Add per-worker diagnostics:
- worker ready state
- loaded model id
- RSS estimate
- TTFT
- average wall time
- token rate
- tool call count
- error count
- last health ping

Expose this through the diagnostics UI and `PipelineAuxBridgeController`.

## Milestone plan

## Milestone 1 — Process and protocol foundation

Goal: prove two worker processes can load, stream, cancel, and report health.

### Tasks
- create `FaeLLMWorker` executable target
- define JSON command protocol
- implement worker supervisor in app process
- support load / warmup / generate / cancel / reset / health
- surface worker readiness in diagnostics

### Likely files
- new: `native/macos/Fae/Sources/FaeLLMWorker/*`
- new: `native/macos/Fae/Sources/Fae/ML/WorkerProtocol.swift`
- new: `native/macos/Fae/Sources/Fae/ML/LLMWorkerClient.swift`
- update: `native/macos/Fae/Sources/Fae/ML/ModelManager.swift`
- update: `native/macos/Fae/Package.swift`
- update: `native/macos/Fae/Sources/Fae/PipelineAuxBridgeController.swift`

### Exit criteria
- both workers can load independently
- token streaming works from each
- cancellation works reliably
- app survives worker crash and reports degraded state

## Milestone 2 — Operator worker integration

Goal: move current foreground local LLM path onto operator worker without behavior regressions.

### Tasks
- route current foreground turns through operator worker
- keep tools in main process
- maintain existing approval and privacy logic
- maintain current TTS flow
- preserve tool-call parsing behavior

### Likely files
- update: `PipelineCoordinator.swift`
- update: `MLXLLMEngine.swift` or wrap behind worker adapter
- update: tool-call parsing tests

### Exit criteria
- same or better latency than current single-process foreground path
- no regression in tool approval behavior
- all current handoff safety tests pass

## Milestone 3 — Concierge background worker

Goal: add optional second-pass synthesis without blocking the operator response.

### Tasks
- implement routing policy
- send post-tool summaries to concierge
- support background enrichment updates to UI
- gate whether concierge can interrupt spoken output
- add feature flag for premium mode

### Exit criteria
- operator path remains fast
- concierge enrichments are visible and useful
- no duplicate or contradictory user-facing answers by default

## Milestone 4 — Memory and synthesis discipline

Goal: use the right model for the right durable decisions.

### Tasks
- operator owns memory write proposals
- concierge can propose enriched summaries only
- add validation path for supersession / contradiction handling
- add tests for memory-store correctness under dual-model flow

### Exit criteria
- no silent memory overwrites
- no degradation in existing memory semantics
- audit trail remains clear

## Milestone 5 — Productization and RAM-tier behavior

Goal: make dual-model mode safe and automatic.

### Tasks
- auto-select mode by system RAM
- add UI messaging for local tier selected
- implement memory-pressure unload policy
- benchmark hot/hot vs hot/cold concierge
- finalize defaults for 8 / 16 / 24 / 32 / 64 GB devices

### Exit criteria
- stable automatic tier selection
- graceful downgrade under pressure
- strong UX on supported RAM tiers

## Testing plan

### Unit tests
- worker protocol encoding/decoding
- routing logic
- per-turn worker selection
- cancellation propagation
- degraded-mode fallback selection

### Integration tests
- operator tool call → tool execution → spoken answer
- operator + concierge combined turn
- worker crash and restart recovery
- memory pressure unload/reload
- same-turn interruption during concierge generation

### Benchmark tests
- TTFT by worker role
- time to correct tool call
- time to final enriched response
- RAM impact of hot/hot vs hot/cold modes

### Safety tests to add
- operator and concierge cannot both speak conflicting final answers
- stale background answers are dropped if turn changed
- tool results are not applied to the wrong turn
- memory writes only come from validated operator proposals

## Rollout plan

### Phase A — hidden developer flag
- `dualModelEnabled=false` by default
- developer-only settings toggle

### Phase B — 64 GB+ opt-in beta
- enable for high-RAM testers first
- collect stability and latency telemetry

### Phase C — 32 GB+ supported mode
- expose as recommended premium local mode

### Phase D — dynamic defaults
- use system RAM and device health to choose mode automatically

## Key engineering risks

### 1. IPC streaming complexity
Mitigation:
- keep the command protocol tiny
- start with line-delimited JSON and request IDs

### 2. Turn desynchronization
Mitigation:
- every request carries a turn ID and generation ID
- stale outputs are dropped in main process

### 3. Memory pressure from two hot models
Mitigation:
- operator always hot
- concierge unloadable
- memory-pressure watcher and health policy

### 4. Duplicate or contradictory answers
Mitigation:
- operator owns immediate spoken response
- concierge only enriches under explicit policy

### 5. Tool-policy bypass risk
Mitigation:
- workers never execute tools directly
- all tool calls remain validated in main process

## Recommended immediate next actions for the dev team

1. Build the worker protocol and worker executable.
2. Move current foreground LLM generation to the operator worker first.
3. Keep the concierge worker dark-launched behind a feature flag.
4. After operator-worker stability is proven, add background concierge summarization.
5. Benchmark 24 GB, 32 GB, and 64 GB systems separately before broad rollout.

## Final recommendation

If Fae wants the **absolute best local product experience**, the architecture should be:

- **single-model mode** for 8–24 GB systems
- **dual-model mode** for 32 GB+
- **operator = qwen3.5-2b**
- **concierge = LFM2-24B-A2B**
- **two separate worker processes** rather than one process with concurrent MLX models

That is the cleanest path to achieving both:
- best operational assistant behavior
- best richer premium local experience
