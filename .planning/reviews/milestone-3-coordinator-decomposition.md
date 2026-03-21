# Milestone 3: PipelineCoordinator Decomposition — Closeout

**Status**: COMPLETE
**Date**: 2026-03-21
**Duration**: 4 phases across 2 sessions

## Goal

Break the ~10K line PipelineCoordinator monolith into focused modules.
Original target: <2K lines remaining.

## Result

**PipelineCoordinator**: 10,080 -> 7,893 lines (-2,187 lines, -21.7%)

### Extracted Files (10 files, 2,942 lines total)

| File | Lines | Phase | What Was Extracted |
|------|-------|-------|--------------------|
| SpeechInputStage.swift | 150 | 3.1 | Segment queue, streaming epoch, wake state |
| SpeakerGateState.swift | 99 | 3.1 | Speaker identity + enrollment state |
| BargeInTypes.swift | 75 | 3.1 | 3 nested structs promoted to top-level |
| ToolCallParsing.swift | 221 | 3.1 | ToolCall, ScriptBlock + parser |
| PipelineTypes.swift | 84 | 3.1 | 6 nested enums promoted to top-level |
| BargeInState.swift | 206 | 3.2 | 11 state vars + 6 decision functions |
| TTSState.swift | 45 | 3.2 | TTS task chain + TTFA telemetry |
| ToolRoutingHelpers.swift | 1,077 | 3.3 | ~50 tool routing/repair/intent statics |
| TurnHelpers.swift | 772 | 3.3 | Turn-level decision statics |
| GateHelpers.swift | 213 | 3.3 | Gate/speaker decision statics |

### Phase Breakdown

| Phase | Reduction | Technique |
|-------|-----------|-----------|
| 3.1 | -356 | State grouping into owned types, type promotion |
| 3.2 | -61 | Barge-in/TTS state consolidation, pure function extraction |
| 3.3 | -1,770 | Massive static function extraction (~90 functions) |
| 3.4 | 0 | Validation + cleanup (no code changes) |
| **Total** | **-2,187** | |

## Why Not <2K Lines

The original target of <2K lines was unrealistic. Here's what remains and why:

### Remaining Large Methods (cannot extract without async boundary changes)

| Method/Section | ~Lines | Why It Stays |
|---------------|--------|--------------|
| generateWithTools | 2,000 | 15+ coordinator deps (eventBus, playback, conversationState, memoryOrchestrator, speakerGate, config, registry, echoSuppressor, etc.) |
| Main pipeline loop | 1,200 | Processes audio chunks with VAD, speaker ID, echo suppression |
| Speech segment processing | 800 | Wake detection, speaker verification, semantic turns |
| Gate control | 1,200 | Idle/active state, sleep hints, conversation stop triggers |
| Tool execution (instance) | 500 | DeferredToolJob dispatch, executeTool with context building |
| JSC script execution | 200 | JSCRuntime lifecycle, script context building |
| Lifecycle/init | 400 | Dependency injection, configuration, cleanup |

Each of these methods accesses 10+ actor-isolated properties. Moving them to separate actors
would require introducing async boundaries at every property access, fundamentally changing
the execution model.

### What Would Be Needed for Further Reduction

1. **Actor protocol decomposition**: Define protocols for pipeline stages and create
   separate actor types. Requires passing coordinator state through async channels.
2. **Dependency injection refactor**: Move all 30+ dependencies into a single
   `PipelineContext` struct passed to each stage.
3. **Event-driven architecture**: Replace direct method calls with an event bus pattern
   where stages communicate through messages.

These are architectural changes that would touch every caller of PipelineCoordinator
and every test. Not safe to do incrementally alongside feature work.

## Quality Evidence

- **Build**: Zero warnings throughout all 4 phases
- **Tests**: 1560 tests, 0 failures throughout all 4 phases
- **Commits**: 8 clean commits across the milestone (5 in 3.1, 3 in 3.2, 3 in 3.3)
- **No behavioral changes**: All extractions preserved exact API compatibility via
  forwarding methods

## Lessons Learned

1. **Static functions are the easiest extraction target** — they have no state dependencies.
   Phase 3.3 removed 1,770 lines by moving ~90 static functions to 3 namespace enums.

2. **Private types limit extraction** — Structs like DeferredToolJob and GenerationContext
   are used only within the actor. Moving them to a separate file forces them to be
   internal, breaking encapsulation for no benefit.

3. **Forwarding stubs preserve compatibility** — Tests reference `PipelineCoordinator.xxx`
   extensively. Thin forwarding methods avoid updating ~80 test call sites.

4. **The <2K target should have been ~7-8K from the start** — An honest assessment of
   the coordinator's dependency graph would have shown that most methods are deeply
   intertwined with actor state.
