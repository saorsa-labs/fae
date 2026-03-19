# Fae JSC Tool-as-Code Runtime — Roadmap

## Overview
Two-lane runtime model:
- **JavaScriptCore** for in-process tool programs that orchestrate host-approved tools.
- **uv Python** for package-heavy or ecosystem-heavy skills.

The goal is to replace repeated LLM tool-call round-trips for multi-step workflows
without bypassing Fae's existing governance stack.

## Success Criteria
- LLM can emit a JavaScript tool program for multi-step orchestration.
- All approvals, broker checks, damage control, rate limits, and audit stay in Swift.
- Script path consumes machine-friendly structured results; LLM path keeps prose.
- Batch approval UX prevents N popups for N loop iterations.
- Script budgets exist: max invocations, runtime, concurrency, cancellation.
- `swift build` and `swift test` pass for touched code.

## Technical Decisions
- **Runtime**: JavaScriptCore.
- **Bridge model**: Promise-based `fae.*` API; do not block JS with semaphores on the main actor.
- **Governance**: Extract and reuse the existing tool execution/security path.
- **Structured data**: Introduce script-safe structured results incrementally.
- **Non-goals**: No Lua/Luau, no Wasm, no policy bypass.

## Plan Location
The active project uses dedicated phase plans under:
`.planning/plans/jsc-tool-as-code/`

Always use `STATE.json.phase.plan` instead of inferring filenames.

---

## Milestone 1: Runtime Foundation

### Phase 1.1: Extract ToolExecutor Actor
- Extract reusable tool execution/governance logic from `PipelineCoordinator`.
- Preserve mode checks, damage control, broker decisions, approvals, rate limits, and audit.

### Phase 1.2: Build JSCRuntime + Promise Bridge
- Add `JSCRuntime` actor and `JSCToolBridge`.
- Expose a narrow Promise-based `fae.*` API to scripts.
- Keep the runtime fresh per execution; no persistent cross-turn JS state.

### Phase 1.3: Script Budgets & Cooperative Cancellation
- Add script budgets for tool count, wall-clock runtime, and concurrency.
- Add turn-end cancellation and host-enforced timeouts.
- Treat instruction-level interruption as optional/follow-up work, not a prerequisite.

### Phase 1.4: Developer Harness & Runtime Validation
- Add a developer/test harness for executing JS tool programs outside the live LLM path.
- Validate runtime, logging, and cancellation before pipeline integration.

---

## Milestone 2: Structured Script APIs

### Phase 2.1: Structured Tool Result Primitives
- Extend `ToolResult` or add a parallel script-result envelope for structured data.
- Keep existing prose outputs intact for the LLM path.

### Phase 2.2: Core Tool Structured Results
- Add structured results for the highest-value orchestration tools first:
  `calendar`, `reminders`, `contacts`, `mail`, `notes`, `web_search`, `fetch_url`.

### Phase 2.3: Script-Facing Typed Adapters
- Add typed bridge helpers so JS scripts consume stable objects instead of prose parsing.
- Prefer script-safe adapters over directly exposing every legacy tool shape.

---

## Milestone 3: Governance UX & Pipeline Integration

### Phase 3.1: Batch Approval UX
- Group looped or repeated actions into a single user decision where appropriate.

### Phase 3.2: Script-Scoped Capability Tickets
- Bind capability grants to the script lifetime and allowed tool set.

### Phase 3.3: Pipeline Integration
- Route JS tool programs through the new runtime alongside the existing tool-call path.
- Remove the `prefix(5)` cap only for the script path after budgets and governance are in place.

### Phase 3.4: Dry-Run Mode
- Add a plan/preview mode so users can inspect what a script intends to do before real execution.

---

## Milestone 4: Prompting, Testing, Documentation

### Phase 4.1: Prompting & Model Routing
- Teach the model when to emit a JS tool program versus normal tool calls.

### Phase 4.2: End-to-End Testing
- Cover runtime execution, approvals, cancellation, error recovery, and structured results.

### Phase 4.3: Documentation & Release Validation
- Update developer docs, changelog, and release validation for the new execution path.

---

## Risks & Mitigations
- **Approval loops**: batch approval in Phase 3.1.
- **Structured API effort**: phased tool rollout in Milestone 2.
- **Model quality**: prefer stronger local models for tool-program generation.
- **Runtime safety**: keep host-side enforcement authoritative; JS never gets direct file/network access.
- **Bridge complexity**: Promise-based bridge only; no main-thread semaphore hacks.

## Out of Scope
- Lua/Luau runtime
- Wasm runtime
- Direct JS access to filesystem/network outside host-injected tools
- Persistent JS contexts across turns
