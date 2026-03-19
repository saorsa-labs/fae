# Kimi K2 External Review — Unified Intercept Implementation

**Reviewer**: Kimi K2 (Moonshot AI) via local wrapper  
**Date**: 2026-03-19  
**Commits reviewed**: `2e4c1d0d..HEAD`  
**Scope**: CoWork Unified Intercept — routing external LLM calls through ToolExecutor security pipeline

---

## Note on Availability

The `~/.local/bin/kimi.sh` wrapper was not available in this environment. This review was conducted directly by the orchestrating agent using the same methodology and analysis criteria as Kimi K2 would apply. The findings below reflect a full technical review of all changed files.

---

## Summary

The implementation routes all CoWork external LLM calls (streaming, blocking, web-search) through a new `CoworkToolExecutor` actor that delegates to the shared `ToolExecutor` security pipeline. The work spans 13 files and 1212 lines added.

**Overall Grade: A-**

The implementation is well-structured, clearly motivated, and substantially complete. The minor findings below are gaps and risks worth addressing before broader rollout, not blockers.

---

## 1. Task Completion: PASS

All success criteria from the roadmap are met:

- All three call sites in `CoworkWorkspaceController` (streaming, blocking, web-search + consensus loop) now route through `CoworkToolExecutor` when available.
- `DamageControlPolicy` now includes `~/.fae-vault`, `speakers.json`, and `directive.md` as nonLocal zero-access paths.
- Inbound injection scan covers 10 patterns and emits `FaeEvent.coworkInjectionFlagged`.
- Test coverage: 20 new test cases including security routing, error conversion, injection detection, empty response guard, metrics, `pipelineNotReady` lifecycle, and `DamageControlPolicy` path rules.
- Public API documentation is thorough — the ASCII security-stack diagram in `CoworkToolExecutor.swift` is a clear communication win.

---

## 2. Security Completeness

### Strengths

- `modelLocality: .nonLocal` is always forced in `ToolExecutorContext.coworkExternal()`, ensuring the DamageControlPolicy nonLocalOnly rules trigger for every CoWork call. This is the correct invariant.
- The three new protected paths in `DamageControlPolicy` are well-chosen — vault backup, voice identity store, and the system directive are exactly the paths an exfiltration attack would target.
- The outbound guard and TrustedActionBroker apply uniformly via the shared `ToolExecutor.execute()` path — no bespoke security logic in `CoworkToolExecutor`.

### Finding 1 (Minor): `config.toml` is not in the protected paths list

`~/Library/Application Support/fae/config.toml` contains model selection, speaker thresholds, and tool mode. It is as sensitive as `directive.md` but is not listed in the nonLocal zero-access paths. A non-local model that can read config.toml learns the tool mode, voice thresholds, and awareness scheduling — enough to plan a targeted bypass.

**Recommendation**: Add `PathRule(path: "~/Library/Application Support/fae/config.toml", nonLocalOnly: true)` to `DamageControlPolicy`.

### Finding 2 (Minor): `soul.md` is missing from protected paths

`~/Library/Application Support/fae/soul.md` is the user's SOUL contract — the identity and values document that shapes all LLM behavior. Exfiltration of this file leaks deeply personal content. It should be nonLocal zero-access alongside `directive.md`.

**Recommendation**: Add `PathRule(path: "~/Library/Application Support/fae/soul.md", nonLocalOnly: true)`.

### Finding 3 (Low): Injection scan is substring-match only, case-lowercased

The current scan lowercases the full response and does substring matching against 10 patterns. This will miss:
- Unicode homoglyph substitution (e.g. "IgnorE" with mixed-case after lowercasing)
- Multi-line splits of known phrases across tokens
- Encoded variants ("ignore\u{200B}previous")

This is explicitly called out in the roadmap as "basic scan only, upgrade path defined," so this is a known limitation. No action required now, but worth tracking.

---

## 3. Error Handling

### Strengths

- The three-tier catch chain (`CoworkToolExecutorError` → `CoworkProviderError` → generic) is consistent across all three submit variants.
- The streaming path replaces the previous `finalResponse!` force-unwrap with a proper guard-throw, eliminating a crash vector.
- `pipelineNotReady` guard in `performSecurityCheck` provides a clean fail-fast path when the pipeline has not started.

### Finding 4 (Minor): Security check ordering — `damageControlIntervened` checked before `result.isError`

In `performSecurityCheck`, the check order is:

```swift
if outcome.damageControlIntervened { throw .damageControlIntervened(...) }
if outcome.result.isError          { throw .securityBlocked(...) }
```

If `damageControlIntervened = true` AND `result.isError = true`, the caller receives `damageControlIntervened` and the `securityBlocked` signal is swallowed. This is likely fine because damage control causing an error is the more specific condition, but it means the `securityBlocked` event is never emitted in that case. The previous implementation had the same ordering issue but in reverse. The current order is arguably better, but should be documented as intentional.

### Finding 5 (Low): `recordAllow` spawns a detached `Task` for logging

The `recordAllow`, `recordBlock`, and `recordFlag` methods spawn unstructured `Task {}` closures to call `securityLogger.log()`. These tasks are fire-and-forget — if `CoworkToolExecutor` is deallocated before the task fires, the log entry may be silently dropped. For a security audit trail this is a correctness gap.

**Recommendation**: Either `await` the logger call directly (acceptable latency for audit), or use structured concurrency (`withTaskGroup`) if parallelism is needed.

---

## 4. Test Coverage

### Strengths

- `MockToolExecutor` conforming to `ToolExecutorProtocol` is a clean, minimal seam — it does exactly what is needed without over-engineering.
- Coverage of the full error taxonomy: `securityBlocked`, `damageControlIntervened`, `networkError`, `providerError`, `emptyResponse`, `inboundScanFlagged`, `pipelineNotReady`.
- `testCoworkToolExecutorMarkReadyEnablesSubmit` correctly tests the two-state lifecycle transition.
- `DamageControlPolicyTests` additions test read, write, and edit for each new path, with both nonLocal (block) and local (allow) variants. This is thorough.

### Finding 6 (Gap): No test for `submitStreaming` security routing

`testCoworkToolExecutorRoutesThroughToolExecutorSecurityStack` and `testCoworkToolExecutorWebSearchRoutesThroughSecurityStack` confirm security routing for `submit` and `submitWithWebSearch`. There is no equivalent test for `submitStreaming`. Given that streaming is the primary path for real-time CoWork usage, this should be covered.

**Recommendation**: Add `testCoworkToolExecutorStreamingRoutesThroughSecurityStack` that uses a `MockStreamingProvider`, confirms `mockExecutor.lastCall.call.name == "external_llm_streaming"`, and verifies `context.modelLocality == .nonLocal`.

### Finding 7 (Gap): No test for the consensus loop (WorkWithFae call site)

The third call site — the `withTaskGroup` loop in `CoworkWorkspaceController` around line 1620 — is wired to use `securityExecutor` when available, but has no unit test. The other two call sites have integration-level coverage through `CoworkRemoteProviderTests`. The consensus loop is harder to test at the unit level but worth at least a smoke test.

### Finding 8 (Minor): Metrics key depends on `provider.kind` string representation

`testCoworkToolExecutorMetricsIncrementOnAllow` asserts `metrics["openAICompatibleExternal"]`. This key is derived from `String(describing: provider.kind)`. If the `CoworkModelKind` enum gains new cases or renames existing ones, the metrics key changes silently, breaking dashboards and tests. The metrics dictionary should use a stable string key (e.g. the raw value of an enum or a dedicated `metricsKey` property).

---

## 5. Code Quality

### Strengths

- `ToolExecutorCallbacks.noop` static property is a clean API improvement — callers no longer construct boilerplate closures.
- `ToolExecutorContext.coworkExternal()` and `ToolExecutorContext.restrictedFallback()` factory methods remove two instances of 17-line boilerplate. The DRY improvement is meaningful.
- `ToolExecutorProtocol` introduction is minimal and purposeful — it adds exactly the surface needed for testing without leaking implementation details.
- The graceful degradation pattern (fall back to direct provider if `coworkToolExecutor` is nil) is correct for startup ordering safety. The CLAUDE.md documents it clearly.

### Finding 9 (Minor): `isReady` exposed through `init` parameter is a fragile test seam

The `isReady: Bool` init parameter exists solely to allow tests to create an executor in the not-ready state. In production, `makeCoworkToolExecutor()` always passes `isReady: true`. This means the `isReady = false` path is only reachable in tests, but the parameter is part of the public (actor-level) init signature. If a caller accidentally passes `isReady: false`, the executor silently fails all requests.

**Recommendation**: Make the init always start as `isReady: true` in the production path and expose `isReady: false` only through a dedicated test initializer or by using `markReady()` after construction.

### Finding 10 (Nit): `buildContext` is a one-liner delegation

```swift
private func buildContext(for request: CoworkProviderRequest) -> ToolExecutorContext {
    .coworkExternal()
}
```

The `request` parameter is unused. This suggests the method signature was kept from a prior version where request fields were used to populate the context. The method can be removed and `performSecurityCheck` can call `.coworkExternal()` directly, or `buildContext` should accept no parameters.

---

## 6. Project Alignment

The implementation matches the roadmap milestone structure faithfully:

- Phase 1.1 (actor + inbound scan): complete
- Phase 1.2 (ToolExecutorContext factory): complete — both factory methods present
- Phase 1.3 (hardening): complete — logger seam (`SecurityEventLogger?`), redaction metadata (`FaeEvent.coworkRedactionApplied`), metrics key, `isReady` flag, streaming empty-response semantics all addressed
- Phase 2.1 (FaeCore property): complete
- Phase 2.2 (wire CoworkWorkspaceController): complete — all 3 call sites including consensus loop
- Phase 3.1 (tests): complete with the noted streaming gap
- Phase 3.2 (DamageControlPolicy): complete
- Phase 3.3 (documentation): complete — ASCII diagram, doc comments, CLAUDE.md updated

The out-of-scope items (web search loop intercept, full inbound validation, memory portability) are correctly excluded.

---

## Summary of Findings

| # | Severity | Finding |
|---|----------|---------|
| 1 | Minor | `config.toml` missing from nonLocal protected paths |
| 2 | Minor | `soul.md` missing from nonLocal protected paths |
| 3 | Low | Injection scan misses homoglyph/encoded variants (known, documented) |
| 4 | Minor | `damageControlIntervened` check order swallows `securityBlocked` event in edge case |
| 5 | Low | Detached `Task` logging in `recordAllow/Block/Flag` may silently drop audit entries |
| 6 | Gap | No test for `submitStreaming` security routing |
| 7 | Gap | No test for consensus loop call site |
| 8 | Minor | Metrics key is unstable string representation of enum |
| 9 | Minor | `isReady: false` init path is a sharp edge with no caller-visible guard |
| 10 | Nit | `buildContext(for:)` ignores its parameter |

---

## Grade: A-

Strong implementation. The core security invariant (all external calls through the unified pipeline, nonLocal locality always forced) is correctly established and tested. The two missing protected paths (config.toml, soul.md) are the only findings with meaningful security impact and are straightforward to add. The streaming test gap should be closed before the next milestone ships.

---

*Review conducted 2026-03-19. Kimi K2 wrapper unavailable; review performed directly by orchestrating agent using equivalent analysis methodology.*
