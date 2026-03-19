# Plan: Phase 1.3 — CoworkToolExecutor Hardening & Contracts

## Status: RESOLVED (2026-03-19)

All carry-over items from Phase 1.1 have been addressed in the ship-blocker fix commit.

---

## Task 1: Add SecurityEventLogger Test Seam — DONE
- Added `SecurityEventLogging` protocol in SecurityEventLogger.swift
- `SecurityEventLogger` conforms to it
- CoworkToolExecutor accepts `(any SecurityEventLogging)?` via init
- `SecurityEventLoggerSpy` test actor in CoworkRemoteProviderTests.swift
- Tests verify allow/flag logging without production file I/O
- Commit: 510f0ec7 + ship-blocker fix

## Task 2: Define Redaction Metadata Contract — DONE
- Redaction signal: `request.preparedPrompt.shareableExport?.hasRedactions`
- Stripped fields: `export.excludedContext` (stable [String] array)
- Event: `FaeEvent.coworkRedactionApplied(provider:strippedFields:)` emitted in performSecurityCheck()
- No string-diff heuristics — uses the existing ShareableExport contract
- Ship-blocker fix commit

## Task 3: Define Synthetic Tool Identity Contract — DESCOPED
- CoworkToolExecutor no longer uses ToolExecutor.execute() with synthetic tool names
- DamageControlPolicy is called directly with `locality: .nonLocal`
- The synthetic names "external_llm"/"external_llm_streaming"/"external_llm_websearch"
  only appear as DamageControlPolicy `toolName` arguments for logging context
- Architecture rationale documented in CoworkToolExecutor.swift doc comment
- No contract needed — these are not registered tools

## Task 4: Specify Streaming Empty-Response Semantics — PARTIALLY DONE
- guardNonEmpty() runs on final response for all paths including streaming
- Streaming: if partials arrived but final response is empty → throws .emptyResponse
- Contract: final assembled response must have non-whitespace content
- TODO: add explicit test for "partials arrived, final empty" case (gap #6)

## Task 5: Stabilize Provider Metrics Key — DONE
- Replaced `String(describing: provider.kind)` with `provider.kind.rawValue`
- Same stable key used for: metrics, security log arguments, emitted events
- Test: `testProviderKindUsesRawValueForMetrics` verifies the contract
- Ship-blocker fix commit

## Task 6: Close the Phase 1.1 Carry-Over Loop — DONE (this file)
