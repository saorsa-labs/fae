# Fae CoWork Security Intercept Roadmap

## Overview

Gate all CoWork external LLM calls with DamageControlPolicy (nonLocal locality enforcement) and inbound prompt injection scanning. CoWork calls are **provider-level** operations — not individual tool dispatches — so they use DamageControlPolicy directly rather than routing through the full ToolExecutor pipeline (which requires registered tool names in ToolRegistry).

**What IS enforced for CoWork calls:**
- DamageControlPolicy zero-access paths (vault, speakers, soul, directive, config) for nonLocal models
- Inbound prompt injection scan (10 patterns, post-response)
- Fail-closed startup gate (throws .pipelineNotReady if pipeline unavailable)
- SecurityEventLogger audit trail (block/flag/allow)
- Per-provider metrics counters

**What is NOT enforced (by design):**
- TrustedActionBroker — applies to individual tool calls, not provider-level LLM requests
- OutboundExfiltrationGuard — applies to tool output destinations, not LLM API endpoints
- ToolRegistry mode filtering — CoWork provider calls have no registered tool name
- Approval overlay — DamageControlPolicy blocks are immediate, not interactive

**Why:** ToolExecutor.execute() checks registry.isToolAllowed() at step 1, which rejects unregistered tool names. CoWork provider calls use synthetic names ("external_llm") that are not in the registry. Rather than registering fake tools, we call DamageControlPolicy directly — the layer that actually matters for provider-level security gating.

**Problem:** CoWork external LLM calls (Claude, GPT-5, MiniMax via HTTP) previously bypassed all security enforcement. They only had pre-send redaction (CoworkPromptEgressPolicy, SensitiveContentPolicy).

**Success:** Production ready — DamageControlPolicy-gated, inbound-scanned, fail-closed, tested, documented.

## Success Criteria
- All external CoWork calls gated by DamageControlPolicy with nonLocal locality
- DamageControlPolicy blocks credential/vault access for non-local models
- Inbound response scan catches prompt injection attempts
- Fail-closed: no fallback to unguarded provider access
- Full test coverage: unit + integration
- Public API docs for CoworkToolExecutor

## Technical Decisions
- Error Handling: Dedicated error types (CoworkToolExecutorError enum)
- Async Model: Actor pattern matching ToolExecutor
- Testing: Unit (mock ToolExecutor) + Integration (real CoworkWorkspaceController flow) + Property (fuzz injection patterns)
- Approach: TDD — tests first, then implementation
- Task Size: Smallest possible (~50 lines per task)

## Milestone 1: CoworkToolExecutor Core

### Phase 1.1: CoworkToolExecutor Actor
- **Focus**: Create CoworkToolExecutor actor that wraps provider.submit() calls
- **Deliverables**: CoworkToolExecutor.swift actor, inbound scan
- **Dependencies**: None (pure addition)
- **Estimated Tasks**: 4-6

### Phase 1.2: ToolExecutorContext Factory
- **Focus**: Extract context-building logic into ToolExecutor factory method (DRY)
- **Deliverables**: ToolExecutor.makeContext() helper, no behavior change
- **Dependencies**: Phase 1.1
- **Estimated Tasks**: 2-3

### Phase 1.3: CoworkToolExecutor Hardening & Contracts
- **Focus**: Pick up unresolved Phase 1.1 review findings before broader rollout
- **Deliverables**: logger test seam, redaction metadata contract, synthetic tool identity contract, streaming empty-response semantics, stable provider metrics key
- **Dependencies**: Phase 1.2
- **Estimated Tasks**: 4-6

---

## Milestone 2: FaeCore Integration

### Phase 2.1: Expose ToolExecutor through FaeCore
- **Focus**: Add coworkToolExecutor property to FaeCore after PipelineCoordinator starts
- **Deliverables**: FaeCore.coworkToolExecutor, PipelineCoordinator wires it
- **Dependencies**: Phase 1.1
- **Estimated Tasks**: 2-3

### Phase 2.2: Wire CoworkWorkspaceController
- **Focus**: Replace direct provider.submit() with CoworkToolExecutor.submit()
- **Deliverables**: 3 call sites updated (streaming, blocking, web search)
- **Dependencies**: Phase 2.1
- **Estimated Tasks**: 2-3

---

## Milestone 3: Testing & Hardening

### Phase 3.1: Unit + Integration Tests
- **Focus**: CoworkToolExecutor tests in CoworkRemoteProviderTests.swift
- **Deliverables**: 6 test cases covering security routing, error conversion, inbound scan
- **Dependencies**: Phase 2.2
- **Estimated Tasks**: 3-4

### Phase 3.2: DamageControlPolicy Enhancement
- **Focus**: Add Fae workspace secrets to zeroAccessPaths
- **Deliverables**: DamageControlPolicy.swift change, tests
- **Dependencies**: Phase 2.2
- **Estimated Tasks**: 1-2

### Phase 3.3: Documentation
- **Focus**: Public API docs for CoworkToolExecutor, ASCII diagram in code
- **Deliverables**: Doc comments, updated architecture diagram
- **Dependencies**: Phase 3.1
- **Estimated Tasks**: 1-2

---

## Risks & Mitigations
- PipelineCoordinator not started when CoWork call made: CoworkToolExecutor returns error result, not crash
- Actor isolation violations: Follow ToolExecutor actor pattern exactly
- Test flakiness with network mocks: Use in-process mock provider, not real HTTP

## Out of Scope
- Web search loop intercept (CoworkPromptEgressPolicy sufficient)
- Full inbound validation (basic scan only, upgrade path defined)
- Memory portability (design doc open question)
- CoWork model-switching UX (product decision)
- Audit trail UI for non-technical users (design doc open question)
- Configurable zeroAccessPaths (DamageControlPolicy redesign needed)
