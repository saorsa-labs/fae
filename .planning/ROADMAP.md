# Fae Unified Intercept Roadmap

## Overview

Route all CoWork external LLM calls through ToolExecutor's unified security pipeline. One security logic everywhere — DamageControl, OutboundGuard, TrustedActionBroker, ApprovalMgr all apply to CoWork calls the same way they apply to native tool calls.

**Problem:** CoWork external LLM calls (Claude, GPT-5, MiniMax via HTTP) bypass the ToolExecutor security stack. They only have pre-send redaction (CoworkPromptEgressPolicy, SensitiveContentPolicy) but no security enforcement.

**Success:** Production ready — complete, tested, documented.

## Success Criteria
- All external CoWork calls route through ToolExecutor security pipeline
- DamageControlPolicy blocks credential access for non-local models
- Inbound response scan catches prompt injection attempts
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
