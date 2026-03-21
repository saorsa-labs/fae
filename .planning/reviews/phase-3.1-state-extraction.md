# Phase 3.1 Review: State Extraction + Type Promotion

**Date**: 2026-03-21
**Status**: PASS
**Scope**: Safe prep work for deeper decomposition — state grouping and type promotion only

---

## What shipped

5 new files (629 lines total) extracting state and types from PipelineCoordinator:

| File | Lines | What moved |
|------|-------|-----------|
| SpeechInputStage.swift | 150 | Segment queue, streaming STT epoch, wake detection state |
| SpeakerGateState.swift | 99 | Speaker identity, enrollment, streaming speaker gate |
| BargeInTypes.swift | 75 | 3 nested structs promoted to top-level |
| ToolCallParsing.swift | 221 | ToolCall, ScriptBlock types + ~190 lines parsing logic |
| PipelineTypes.swift | 84 | 6 nested enums promoted to top-level |

PipelineCoordinator: 10,080 → 9,724 lines (-356)

## What this is NOT

- NOT actor extraction — no new async boundaries, no timing changes
- NOT behavior isolation — coordinator still owns all logic, delegates through owned types
- NOT the substantial orchestration simplification — that comes in Phases 3.2-3.3

## Why the modest scope is correct

The coordinator has 72+ state vars with carefully sequenced mutations. Changing async
boundaries (e.g., making SpeechInputStage an actor) would change timing semantics and risk
subtle regressions. The safe path is: group state first, extract logic later, actorize last.

## Evidence

- 6 commits, each with 1560 tests passing
- Zero build warnings throughout
- Targeted regression: VoicePipelineRegressionTests, StreamingSTTTests,
  VoiceConversationPolicyTests, ParakeetStreamingEngineTests all pass

## Planning precision note

Roadmap originally said "SpeakerGateActor" — what shipped is `SpeakerGateState` (a struct).
Roadmap updated to reflect actual implementation. Actor extraction remains a future option
if behavior isolation is needed.
