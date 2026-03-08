# Dual-model local execution plan for Pipeline Fae — 2026-03-07

> **Scope note:** This execution plan applies to **Pipeline Fae only**. It does not define Cowork Fae runtime pipeline behavior. Shared tools, memory, and model infrastructure may be reused, but do not assume a shared pipeline.

## Read this first

Start with `docs/architecture/pipeline-fae-dual-model-handoff-2026-03-07.md` for the agreed reading order and scope boundary.

Then read:

1. `docs/architecture/dual-model-local-execution-plan-2026-03-07.md`
   - execution-ready task breakdown
   - file touchpoints
   - rollout details
2. `docs/architecture/dual-model-local-plan-2026-03-07.md`
   - architecture proposal
   - runtime topology
   - milestone plan
3. `docs/benchmarks/fae-priority-eval-2026-03-07.md`
   - tool / instruction / memory weighted ranking

Supporting context:

- `docs/benchmarks/local-model-eval-2026-03-07.md`
- `docs/benchmarks/llm-benchmarks.md`

## Final product decision to implement

### Premium local mode

- **Operator model:** `qwen3.5-2b`
- **Concierge model:** `LFM2-24B-A2B-MLX-4bit`
- **Minimum recommended system RAM:** `32 GB`
- **Best architecture:** two separate LLM worker processes

### Standard local mode

- **16–24 GB:** single model `qwen3.5-2b`
- **8 GB:** single model `qwen3.5-0.8b`

---

## Important Kokoro TTS note

Recent TTS work matters here.

### Current reality

Fae now uses:
- `KokoroMLXTTSEngine` in `Sources/Fae/ML/KokoroMLXTTSEngine.swift`
- instantiated directly in `FaeCore.swift`
- pure Swift MLX, **not** the old Python subprocess path

That means the premium local architecture is not just:
- operator MLX model
- concierge MLX model

It is actually:
- operator MLX model
- concierge MLX model
- **Kokoro MLX TTS**

So the new premium path is effectively a **three-MLX-runtime system** unless we isolate or serialize some workloads.

### Collision risk

The dual-model plan does **not** fundamentally conflict with Kokoro, but it does create a real resource-risk area:

- MLX LLM worker A on GPU / unified memory
- MLX LLM worker B on GPU / unified memory
- Kokoro MLX TTS in app process also using MLX / GPU / unified memory

This raises 3 risks:

1. GPU contention during simultaneous LLM + TTS work
2. unified memory pressure / eviction / instability
3. degraded TTFT if Kokoro and concierge overlap badly

### Recommendation

For v1 of premium dual-model local mode:

- keep **Kokoro in the main app process**
- keep **operator and concierge as separate worker processes**
- add a **scheduler / arbitration layer** so Kokoro and concierge do not freely compete during latency-sensitive turns

### Scheduling rule for v1

Priority order:

1. operator generation
2. TTS synthesis / playback preparation
3. concierge background generation

In plain terms:
- the operator must win over everything
- Kokoro must win over concierge during active voice response windows
- concierge is opportunistic and should pause, defer, or run after speech begins/ends depending on load

### Optional v2 path if needed

If Kokoro contention becomes measurable in real usage:
- move Kokoro into its **own worker process** too
- or add a dedicated TTS subprocess mode for premium local devices

But do **not** start there unless measurement shows the need.

---

## Current code touchpoints that matter

### Core wiring
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift`
  - currently constructs `MLXLLMEngine` and `KokoroMLXTTSEngine` directly
  - likely entry point for worker-supervisor wiring

### Pipeline orchestration
- `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`
  - where turn routing, tool execution, generation cancellation, and TTS coordination already live
  - should own operator vs concierge orchestration policy

### Model loading and memory
- `native/macos/Fae/Sources/Fae/ML/ModelManager.swift`
  - current place for load orchestration, memory measurement, and recommended model selection
  - should evolve into supervisor for local tier selection and worker readiness

### LLM engine abstraction
- `native/macos/Fae/Sources/Fae/ML/MLXLLMEngine.swift`
  - current single-process engine
  - logic should either be reused inside the worker executable or wrapped by a worker-side adapter

### TTS abstraction
- `native/macos/Fae/Sources/Fae/Core/MLProtocols.swift`
- `native/macos/Fae/Sources/Fae/ML/KokoroMLXTTSEngine.swift`
  - keep TTSEngine boundary stable while the LLM path changes underneath

### Diagnostics and progress
- `native/macos/Fae/Sources/Fae/PipelineAuxBridgeController.swift`
  - should gain per-worker ready / degraded / paused status

### Transport abstraction already anticipated
- `native/macos/Fae/Sources/Fae/HostCommandBridge.swift`
  - useful precedent that transport boundaries are already expected in architecture

### Safety tests
- `native/macos/Fae/Tests/HandoffTests/ThinkAndToolFlowSafetyTests.swift`
  - extend here for stale-turn dropping, dual-model turn ownership, and no-conflicting-final-answer rules

---

## Execution strategy

Use 3 workstreams in parallel where possible:

1. **worker infrastructure**
2. **pipeline routing integration**
3. **tests + diagnostics**

---

## Sprint 1 — Worker protocol and skeleton

### Goal
Prove that Fae can launch and talk to two long-lived LLM workers.

### Deliverables
- new worker executable target: `FaeLLMWorker`
- framed JSON protocol
- app-side worker client
- health check and restart behavior

### Tasks

#### Ticket 1.1 — Define protocol
Create:
- `Sources/Fae/ML/WorkerProtocol.swift`

Message schema:
- `load_model`
- `warmup`
- `generate`
- `cancel`
- `reset_session`
- `health_check`
- `unload_model`

Response schema:
- `ready`
- `progress`
- `token`
- `tool_call`
- `done`
- `error`
- `health_status`
- `metrics`

Acceptance:
- Codable request/response types
- request IDs and turn IDs mandatory
- version field included for future compatibility

#### Ticket 1.2 — Add worker executable
Update:
- `native/macos/Fae/Package.swift`

Create:
- `Sources/FaeLLMWorker/main.swift`
- `Sources/FaeLLMWorker/WorkerCommandLoop.swift`
- `Sources/FaeLLMWorker/WorkerRuntime.swift`

Acceptance:
- worker starts from CLI
- can load one model
- can emit ready + health events

#### Ticket 1.3 — App-side worker client
Create:
- `Sources/Fae/ML/LLMWorkerClient.swift`
- `Sources/Fae/ML/LLMWorkerSupervisor.swift`

Acceptance:
- app can spawn worker process
- app can send command and receive streaming replies
- app can kill and restart worker

#### Ticket 1.4 — Diagnostics plumbing
Update:
- `PipelineAuxBridgeController.swift`
- maybe `SettingsModelsPerformanceTab.swift` / diagnostics UI

Expose:
- operator ready state
- concierge ready state
- last health ping
- loaded model ids
- degraded status

Acceptance:
- settings UI shows both workers independently

---

## Sprint 2 — Operator worker integration

### Goal
Replace current foreground local LLM path with the operator worker, without changing product behavior.

### Deliverables
- operator worker used for live foreground turns
- current tool and approval semantics preserved

### Tasks

#### Ticket 2.1 — Add operator role config
Update:
- `FaeConfig.swift`

Add fields:
- `dualModelEnabled`
- `localMode`
- `operatorModelPreset`
- `conciergeModelPreset`
- `dualModelMinSystemRAMGB`
- `keepConciergeHot`
- `allowConciergeDuringVoiceTurns`
- `operatorContextSizeTokens`
- `conciergeContextSizeTokens`

Acceptance:
- config loads/saves with defaults
- migration path for old config is clean

#### Ticket 2.2 — Route foreground turns to operator worker
Update:
- `PipelineCoordinator.swift`
- `FaeCore.swift`
- `ModelManager.swift`

Acceptance:
- normal local replies come from operator worker
- tool call parsing still works
- cancellations / barge-in still work

#### Ticket 2.3 — Preserve tool policy in main process
Golden rule:
- operator may propose tools
- main process executes tools
- approvals remain in app process

Acceptance:
- no regression in tool approval behavior
- no worker-side tool execution path exists

#### Ticket 2.4 — TTFT parity benchmark
Acceptance:
- operator worker path is not materially worse than existing single-process path
- TTFT regression budget should be explicit, e.g. <= 15% after warmup

---

## Sprint 3 — Concierge worker and background synthesis

### Goal
Add optional richer second-pass synthesis without slowing foreground response.

### Deliverables
- concierge worker launches independently
- receives compact turn packages
- enriches responses after operator or tools

### Tasks

#### Ticket 3.1 — Add turn router
Create:
- `Sources/Fae/Pipeline/TurnRoutingPolicy.swift`

Use deterministic rules only.

Initial routing classes:
- operator-only
- operator-then-concierge
- concierge-only

Acceptance:
- route decision is deterministic and testable

#### Ticket 3.2 — Add turn package builder
Create:
- `Sources/Fae/Pipeline/WorkerPromptProjection.swift`

Responsibilities:
- canonical conversation ledger in main process
- compact operator projection
- richer concierge projection

Acceptance:
- per-worker prompt views derived from one conversation state

#### Ticket 3.3 — Concierge background summaries
Update:
- `PipelineCoordinator.swift`
- canvas/subtitle update paths as needed

Acceptance:
- after tool result, concierge can produce refined summary
- refined result can be surfaced in UI or as optional follow-up
- no blocking of first spoken answer

---

## Sprint 4 — Kokoro-aware scheduling and MLX arbitration

### Goal
Prevent premium local mode from degrading due to Kokoro + two MLX LLMs contending badly.

### Deliverables
- a simple scheduler for operator / concierge / Kokoro priority
- load-shedding policy under pressure

### Tasks

#### Ticket 4.1 — Add generation priority scheduler
Create:
- `Sources/Fae/ML/InferenceScheduler.swift`

Priority order:
1. operator
2. Kokoro TTS
3. concierge

Acceptance:
- background concierge can be delayed or paused during active speech generation windows
- operator never waits on concierge

#### Ticket 4.2 — Add Kokoro-aware coordinator hooks
Update:
- `PipelineCoordinator.swift`
- `KokoroMLXTTSEngine.swift`
- maybe `AudioPlaybackManager.swift`

Add hooks/events for:
- `tts_synthesis_started`
- `tts_synthesis_finished`
- `tts_backpressure`

Acceptance:
- concierge is deprioritized when TTS needs to synthesize an immediate answer

#### Ticket 4.3 — Memory pressure policy
Update:
- `ModelManager.swift`
- worker supervisor

Policy:
- operator always hot
- concierge unloadable under pressure
- Kokoro remains available for current reply path

Acceptance:
- app can unload concierge automatically under pressure and recover later

#### Ticket 4.4 — Measure real contention
Benchmark on target devices:
- 24 GB
- 32 GB
- 64 GB

Measure:
- operator TTFT while Kokoro is active
- concierge throughput while operator idle
- operator TTFT with concierge hot
- memory pressure behavior

Acceptance:
- data-driven decision whether Kokoro must move to its own worker later

---

## Sprint 5 — Memory discipline and tool-result ownership

### Goal
Make sure the right model owns durable decisions.

### Deliverables
- operator owns memory proposals
- concierge never directly mutates durable memory in v1

### Tasks

#### Ticket 5.1 — Memory proposal boundary
Update:
- `PipelineCoordinator.swift`
- `MemoryOrchestrator.swift`
- any turn post-processing path using model text for memory capture

Policy:
- operator proposes memory actions
- main process validates and commits
- concierge suggestions are advisory only

Acceptance:
- durable writes come only from validated operator-originated proposals

#### Ticket 5.2 — Tool-result synthesis boundary
Policy:
- operator may speak immediate factual answer
- concierge may rewrite, enrich, or summarize
- main process decides what reaches speech

Acceptance:
- one canonical spoken final answer owner at a time
- stale concierge updates are dropped if turn changed

---

## Sprint 6 — Productization and settings

### Goal
Expose the feature safely and understandably.

### Deliverables
- RAM-tier-aware defaults
- settings toggles
- premium local mode diagnostics

### Tasks

#### Ticket 6.1 — Settings surface
Update:
- `SettingsModelsTab.swift`
- `SettingsModelsPerformanceTab.swift`
- overview/help copy as needed

Show:
- current local mode: single / dual
- operator model
- concierge model
- recommended mode for this machine

#### Ticket 6.2 — Auto-tier selection
Update:
- `FaeConfig.recommendedModel(...)` logic or parallel helper in config/model policy

Behavior:
- 8 GB → `qwen3.5-0.8b`
- 16–24 GB → `qwen3.5-2b`
- 32 GB+ → dual-model eligible
- 64 GB+ → dual-model premium default

#### Ticket 6.3 — Feature flag rollout
Flags:
- hidden developer flag first
- beta flag for 64 GB+ testers
- then 32 GB+ supported rollout

---

## Testing checklist

### Must-add unit tests
- worker protocol round-trip
- routing decisions
- stale generation dropping by turn ID
- operator/concierge answer precedence
- scheduler priority logic

### Must-add integration tests
- operator tool call → main-process tool execution → spoken answer
- operator + concierge same turn
- concierge result arrives after user interrupts → stale result dropped
- worker crash → restart → degraded state surfaced cleanly
- concierge unload/reload under memory pressure
- Kokoro synthesis while concierge is active

### Must-add safety tests
Add to or near:
- `Tests/HandoffTests/ThinkAndToolFlowSafetyTests.swift`

Cases:
- no conflicting dual answers for one turn
- tool results cannot be applied to the wrong turn
- memory writes only come from operator proposal flow
- concierge cannot bypass approval or tool policy
- TTS scheduling does not starve operator generation

---

## Risks and mitigations

### Risk: Kokoro and LLM workers contend on MLX/GPU
Mitigation:
- add scheduler first
- measure before moving Kokoro to a worker
- operator wins over concierge always

### Risk: IPC adds latency
Mitigation:
- long-lived workers only
- preload and warmup on startup
- compact JSON framing

### Risk: dual answers confuse users
Mitigation:
- operator owns immediate spoken reply
- concierge default output is UI/background unless explicitly promoted

### Risk: memory behavior becomes inconsistent
Mitigation:
- operator-only memory proposal authority in v1

---

## Suggested team assignment

### Engineer A — worker/runtime
- worker executable
- protocol
- client/supervisor
- restart logic

### Engineer B — pipeline/router
- turn router
- operator integration
- concierge integration
- stale-turn protection

### Engineer C — settings/diagnostics/tests
- config and settings UI
- diagnostics surfaces
- regression and safety tests
- benchmark harness updates

### Engineer D — performance/QA
- 24 / 32 / 64 GB test matrix
- Kokoro contention measurements
- TTFT and memory pressure analysis

---

## Recommended implementation order

1. worker protocol
2. operator worker integration
3. diagnostics and restart handling
4. concierge worker background path
5. Kokoro-aware scheduling
6. RAM-tier defaults and settings
7. beta rollout

---

## Direct answer for the team

### Does recent Kokoro work collide with this plan?

**Not architecturally, but yes operationally it matters.**

The recent move to `KokoroMLXTTSEngine` means premium local mode now involves multiple MLX consumers. That does not block the dual-model strategy, but it means the team must explicitly implement:

- worker separation for LLMs
- scheduling priority between LLMs and Kokoro
- measurement of Kokoro/LLM contention on 32 GB and 64 GB systems

That should be treated as a first-class engineering concern, not an afterthought.

### Bottom-line recommendation

Proceed with:
- two LLM worker processes
- Kokoro kept in main process initially
- explicit operator > Kokoro > concierge priority policy
- 32 GB minimum for premium dual-model mode
