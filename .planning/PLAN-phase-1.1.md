# Plan: Phase 1.1 — CoworkToolExecutor Actor

## Context
CoworkToolExecutor is a new actor that wraps CoWork external LLM calls and routes them through ToolExecutor's security pipeline. This is the core of the unified intercept architecture.

**Reference:** ~/.gstack/projects/saorsa-labs-fae/davidirvine-main-test-plan-20260319-124815.md

---

## Task 1: Define CoworkToolExecutor Error Types

**File:** `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutorError.swift` (NEW)

**What:** Define `CoworkToolExecutorError` enum for all failure modes:
- `pipelineNotReady` — ToolExecutor not yet initialized
- `providerError(underlying: Error)` — CoworkProviderError wrapped
- `securityBlocked(reason: String)` — TrustedActionBroker or DamageControl blocked
- `inboundScanFlagged(reason: String)` — response flagged by inbound scan
- `timeout`

**Requirements:**
- Typed errors, not stringly-typed
- Conform to Error and CustomStringConvertible
- No implementation — types only

---

## Task 2: Implement CoworkToolExecutor Actor (Blocking)

**File:** `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift` (NEW, ~200 lines)

**What:** Create the actor with:
- `private let toolExecutor: ToolExecutor` reference
- `private let inboundScanPatterns: [String]` — injection patterns to detect
- `func submit(request: CoworkProviderRequest, provider: some CoworkLLMProvider) async throws -> CoworkProviderResponse`
  - Builds `ToolExecutorContext` with `modelLocality: .nonLocal`
  - Calls `toolExecutor.execute()` for security stack
  - On allow: calls `provider.submit(request:)`
  - Converts errors to CoworkToolExecutorError
  - Runs inbound scan on response

**Requirements:**
- Actor isolation throughout
- No `.unwrap()` in production code
- Graceful degradation if pipeline not ready

---

## Task 3: Add Streaming and Web Search Support

**File:** `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift` (append)

**What:** Add to CoworkToolExecutor:
- `func submitStreaming(request: CoworkProviderRequest, provider: some CoworkStreamingProvider) async throws -> CoworkProviderResponse`
- `func submitWithWebSearch(request: CoworkProviderRequest, provider: some CoworkWebSearchProvider) async throws -> CoworkProviderResponse`

**Requirements:**
- Same security stack, different provider protocol
- Inbound scan runs on final accumulated response

---

## Task 4: Inbound Response Scan

**File:** `native/macos/Fae/Sources/Fae/Cowork/CoworkToolExecutor.swift` (append)

**What:** Add `scanForInjection(response: String) -> CoworkToolExecutorError?`
- Detects prompt injection patterns in responses
- Patterns: "ignore previous instructions", "disregard all prior", "you are now", etc.
- Returns error if flagged, nil if clean

**Requirements:**
- Pattern matching only — no ML
- Extensible pattern list (not hardcoded forever)
- Minimal false positives

---

## Task 5: Unit Tests for CoworkToolExecutor

**File:** `native/macos/Fae/Tests/HandoffTests/CoworkRemoteProviderTests.swift` (append)

**Tests:**
1. `testCoworkToolExecutorRoutesThroughToolExecutorSecurityStack` — mock ToolExecutor, verify execute() called with modelLocality=.nonLocal
2. `testCoworkToolExecutorConvertsProviderErrorsToToolExecutorResultError` — inject network error
3. `testCoworkToolExecutorContextHasNonLocalModelLocality` — verify context
4. `testCoworkToolExecutorInboundScanDetectsInjection` — send response with injection pattern
5. `testCoworkToolExecutorReturnsErrorWhenPipelineNotReady` — ToolExecutor not initialized

**Requirements:**
- Mock ToolExecutor using existing test double patterns
- 100% pass rate
- Tests run in < 5s

---

## Verification

After all tasks:
- `swift build` — zero warnings, zero errors
- `swift test` — 100% pass, CoworkRemoteProviderTests included
- `swiftlint` if .swiftlint.yml exists
