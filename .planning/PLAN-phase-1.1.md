# Plan: Phase 1.1 — CoworkToolExecutor Actor (Updated)

## Context
CoworkToolExecutor routes CoWork external LLM calls through ToolExecutor's security pipeline.
Code for Tasks 1-4 already exists but needs fixes identified in CEO/Eng review.
Tasks 5-8 are NEW work from the CEO review cherry-picks.

Note: unresolved execution-safety findings from review are now tracked in `.planning/PLAN-phase-1.3.md` so the team can pick them up after Phase 1.2 without losing context.

---

## Task 1: Fix Force-Unwrap and pipelineNotReady Guard

**File:** `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift`

**What:** Fix 3 issues identified in review:
1. Remove force-unwrap at line 176 in `submitStreaming()` — replace `return finalResponse!` with proper guard/throw
2. Add `pipelineNotReady` guard — CoworkToolExecutor should check ToolExecutor readiness and throw `.pipelineNotReady` if not initialized
3. Add `CustomStringConvertible` conformance to `CoworkToolExecutorError` (minor spec compliance)

**Requirements:**
- Zero force-unwraps in production code
- `pipelineNotReady` must be reachable via a real code path
- `swift build` zero warnings

---

## Task 2: Extract DRY Security Check Helper

**File:** `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift`

**What:** Extract the repeated security-check boilerplate from all 3 submit methods into a single private helper:
- `private func performSecurityCheck(toolName: String, request: CoworkProviderRequest) async throws`
- Builds ToolExecutorContext, creates ToolCall, executes, checks outcomes
- All 3 submit methods call this instead of duplicating 15 lines each

**Requirements:**
- Zero behavior change — pure refactor
- All existing tests must still pass
- `swift build` zero warnings

---

## Task 3: Add Empty Response Guard

**File:** `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift`

**What:** After provider returns a response, guard against empty content:
- If `response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`, throw a descriptive error
- Add `emptyResponse` case to `CoworkToolExecutorError`
- Apply in all 3 submit methods (after provider call, before inbound scan)

**Requirements:**
- New error case with proper `errorDescription`
- Guard applies to blocking, streaming, and web search paths
- `swift build` zero warnings

---

## Task 4: Wire SecurityEventLogger for CoWork

**Files:**
- `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift` (add logger calls)
- `native/macos/Fae/Sources/Fae/Tools/SecurityEventLogger.swift` (check existing API)

**What:** Log every security-relevant event in CoworkToolExecutor:
- On security block: log with event type, provider, model, reason
- On injection flag: log with detected pattern, provider, model
- On allow: log success (for metrics baseline)
- Accept `SecurityEventLogger` reference via init parameter

**Requirements:**
- Use existing `SecurityEventLogger` API — do not modify it
- Structured JSONL entries matching existing patterns
- `swift build` zero warnings

---

## Task 5: Emit Redaction Visibility Event

**Files:**
- `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift` (emit event)
- `native/macos/Fae/Sources/Fae/Core/FaeEvent.swift` (add new case if needed)

**What:** When pre-send redaction strips content before forwarding to external provider, emit a FaeEvent so the UI layer can show what Fae protected:
- Check if CoworkPromptEgressPolicy or SensitiveContentPolicy modified the request
- If content was stripped, emit event via FaeEventBus with details of what was removed
- Event is informational only — does not block the request

**Requirements:**
- New FaeEvent case (e.g., `.coworkRedactionApplied`)
- Emitted via FaeEventBus (existing pub/sub)
- `swift build` zero warnings

---

## Task 6: Add Per-Provider Security Metrics

**File:** `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift`

**What:** Track lightweight per-provider counters:
- `private var metrics: [String: ProviderMetrics]` where ProviderMetrics has `allowed`, `blocked`, `flagged` counts
- Increment on each submit outcome
- Expose read-only `func getMetrics() -> [String: ProviderMetrics]` for diagnostics
- Define `ProviderMetrics` as a simple Sendable struct

**Requirements:**
- In-memory only — no persistence needed
- Thread-safe (actor provides this)
- `swift build` zero warnings

---

## Task 7: Update ASCII Diagram in CoworkToolExecutor

**File:** `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift`

**What:** Update the ASCII diagram in the doc comment (lines 15-29) to reflect:
- DRY helper (`performSecurityCheck`)
- SecurityEventLogger integration
- FaeEvent emission for redaction
- Metrics counter
- Empty response guard

**Requirements:**
- Diagram matches actual code flow
- Doc comments on all new public/internal methods

---

## Task 8: Complete Unit Tests

**File:** `native/macos/Fae/Tests/HandoffTests/CoworkRemoteProviderTests.swift`

**Tests to add:**
1. `testPipelineNotReady` — verify `.pipelineNotReady` thrown when ToolExecutor not initialized
2. `testEmptyResponseGuard` — verify empty response throws descriptive error
3. `testSecurityEventLoggerCalledOnBlock` — verify logger called when security blocks
4. `testSecurityEventLoggerCalledOnFlag` — verify logger called when injection detected
5. `testMetricsCounterIncrements` — verify allowed/blocked/flagged counts
6. `testStreamingHappyPath` — verify streaming submit routes through security
7. `testWebSearchHappyPath` — verify web search submit routes through security
8. `testDRYHelperReturnsSameOutcome` — verify refactored helper behaves identically

**Requirements:**
- All tests pass
- Mock SecurityEventLogger to verify calls
- `swift test` zero failures

---

## Verification

After all tasks:
- `swift build` — zero warnings, zero errors
- `swift test` — 100% pass
- No force-unwraps in production code (grep check)
