# Unified Intercept — Code Review

**Reviewer**: Claude (claude-sonnet-4-6)
**Date**: 2026-03-19
**Diff base**: 2e4c1d0d..HEAD
**Files reviewed**: 13 changed (1,212 insertions, 189 deletions)

---

## Security Goal Assessment

**Goal:** Route all CoWork external LLM calls through ToolExecutor's unified security pipeline (DamageControlPolicy, OutboundExfiltrationGuard, TrustedActionBroker).

**Achieved: YES — with one meaningful caveat (see Bypass Paths).**

The implementation correctly:

- Creates `CoworkToolExecutor` as a Swift actor with the same `ToolExecutorProtocol` interface used by the voice pipeline
- Calls `toolExecutor.execute()` before every `provider.submit()`, `provider.stream()`, and `provider.submitWithWebSearch()` call
- Uses `modelLocality: .nonLocal` in `ToolExecutorContext.coworkExternal()`, which triggers DamageControlPolicy's `nonLocalOnly` zero-access rules
- Wires the executor through `PipelineCoordinator.makeCoworkToolExecutor()` and exposes it via `FaeCore.coworkToolExecutor`
- Replaces all three direct provider call sites in `CoworkWorkspaceController`

---

## Bypass Paths

### 1. The Graceful-Degradation Fallback is a Security Bypass (Medium Severity)

`CoworkWorkspaceController` wires the intercept with optional chaining:

```swift
let securityExecutor = await self.faeCore.coworkToolExecutor
if let securityExecutor {
    response = try await securityExecutor.submit(...)
} else {
    response = try await provider.submit(...)   // ← BYPASS
}
```

This pattern appears at all three call sites (streaming, blocking, web search) and also in the `WorkWithFae` consensus loop. If `coworkToolExecutor` is nil — meaning `PipelineCoordinator` has not yet been created, or has been deallocated — external LLM calls go through with no security checks at all.

The ROADMAP explicitly notes this as a design decision ("returns error result, not crash"), but the current implementation silently falls back to unguarded access rather than failing closed. A security-conscious fallback would be to throw `.pipelineNotReady` at the call site rather than bypassing the security stack. The current behavior means that during app startup, before `makeCoworkToolExecutor()` is called, CoWork calls are fully unguarded.

**Recommendation:** Change the fallback to a hard fail. If `coworkToolExecutor` is nil, throw `CoworkToolExecutorError.pipelineNotReady` at the `CoworkWorkspaceController` call site. Add a test covering the startup-race window.

### 2. `config.toml` Not in DamageControlPolicy Zero-Access Paths (Low Severity)

`DamageControlPolicy` now blocks `fae-vault/`, `speakers.json`, and `directive.md` for non-local models. The main config file (`~/Library/Application Support/fae/config.toml`) is not blocked. A compromised external model could read config (which may contain API keys or channel credentials stored there) or write config to change settings like `tool_mode`. This is not a new hole introduced by this diff, but the documentation in the `CoworkToolExecutor` header lists protected paths as if the list is exhaustive — it is not.

**Recommendation:** Either add `config.toml` to the zero-access paths, or note explicitly in the doc comment that the list is representative, not complete.

### 3. Injection Scan Fires Only Post-Streaming (Design Limitation, Documented)

For streaming calls, `guardNoInjection()` runs on the final assembled response after the stream completes. Partial tokens containing injection strings are forwarded to the UI via `onPartialText` before the scan fires. A sophisticated injector could front-load a malicious instruction in the first few tokens, which the user sees before the scan catches it.

This is a known limitation of streaming threat models and is hard to fully solve without buffering. The current implementation is reasonable for the stated scope. Worth noting in the architecture documentation so future contributors understand the window.

---

## Code Quality Assessment

### Strengths

**Actor isolation is correct.** `CoworkToolExecutor` is an actor; all mutable state (`isReady`, `metrics`, `inboundScanPatterns`) is actor-isolated. The `ProviderMetrics` struct is `Sendable`. `Task { await securityLogger?.log(...) }` detaches logging correctly to avoid blocking the actor.

**Protocol-based testing seam is well-designed.** Extracting `ToolExecutorProtocol` from the concrete `ToolExecutor` actor is the right approach. `MockToolExecutor` in tests conforms cleanly, and the injection via `init(toolExecutor: any ToolExecutorProtocol)` means test isolation is complete.

**`performSecurityCheck()` DRY refactor is correct.** The three submit paths previously duplicated context-building and outcome-checking. Extracting `performSecurityCheck()` eliminated that duplication cleanly. The `isReady` guard is in the right place — it fires before any security stack call.

**`ToolExecutorContext` factory methods are good.** `.coworkExternal()` and `.restrictedFallback()` centralize context construction that was previously scattered across two files. The two `restrictedFallback()` call sites in `PipelineCoordinator` that were previously inline structs are now using the factory — cleaner and less error-prone.

**`ToolExecutorCallbacks.noop` is a clean quality-of-life addition.** Three prior callers built identical no-op closures by hand; this collapses them to `.noop`.

**DamageControlPolicy tests are specific and correct.** The six new tests in `DamageControlPolicyTests` use the actual `locality:` parameter to verify the nonLocal block vs local allow semantics. They will catch regressions in path matching.

**Test coverage is broad.** 17 new test cases in `CoworkToolExecutorTests` cover: security routing verification, context locality, provider error conversion, injection detection, streaming injection detection, custom patterns, clean-response pass-through, empty response guard, metrics (allow/block/flag), web search routing, context factory defaults, `noop` callbacks, `markReady` transition, and pipeline-not-ready fast-fail.

### Issues

**`toolMode: "full"` in `ToolExecutorContext.coworkExternal()` is semantically odd.**
The context used for external LLM interception has `toolMode: "full"`. This is not a tool-use context; it is a security-check context for a provider call. Setting `toolMode: "full"` suggests the external call has full tool access, which could interact unexpectedly with any future logic that inspects `toolMode` during `execute()`. `toolMode: "read_only"` or a dedicated mode would be safer. The current approach works because `ToolExecutor.execute()` uses tool mode to filter tool availability — external LLM calls don't dispatch tools — but the field is misleading to future readers.

**`isOwner: true` in `coworkExternal()` context may be overly permissive.**
The context passes `isOwner: true` for external model calls. If any branch of `TrustedActionBroker` or `DamageControlPolicy` grants additional permissions based on `isOwner`, external models receive those permissions. The original code (before this diff) also set `isOwner: true`, so this is not a regression. Still worth documenting the reason explicitly in the factory method comment.

**Metrics logging is fire-and-forget with no error surfacing.**
`recordAllow`, `recordBlock`, and `recordFlag` all spawn detached `Task` blocks for `SecurityEventLogger.shared.log(...)`. If the logger fails (e.g., disk full), the error is silently dropped. This is acceptable for metrics but worth noting.

**`emptyResponse` guard fires before injection scan, which is correct, but the streaming path has a subtle ordering issue.** In `submitStreaming`, `guardNonEmpty` and `guardNoInjection` only run if `finalResponse != nil`. If `finalError` is set, the guards are skipped. That's correct — there's no response to scan. However, if the stream yields content and then throws, `finalResponse` may be nil even though partial content was shown in the UI. This is an edge case but the current code handles it correctly by propagating `finalError`.

---

## Spec Compliance

| Requirement | Status | Notes |
|---|---|---|
| All CoWork calls route through ToolExecutor pipeline | Partial | Routing is correct when executor is available; fallback bypasses security |
| DamageControlPolicy blocks credential access for non-local models | Done | fae-vault, speakers.json, directive.md added to zero-access paths |
| Inbound response scan for prompt injection | Done | Keyword-based scan on all three call paths |
| Full test coverage: unit + integration | Done | 17 unit tests, DamageControlPolicy integration tests |
| Public API docs for CoworkToolExecutor | Done | All public methods have doc comments; architecture ASCII diagram updated |

---

## Summary

The implementation achieves the core security goal. All three provider submission paths now invoke `toolExecutor.execute()` with a `nonLocal` context before making external calls. DamageControlPolicy protection for Fae-specific secrets is correctly added and tested. The actor design, protocol extraction for testing, and DRY refactoring of `performSecurityCheck()` are all production-quality.

The primary concern is the graceful-degradation fallback in `CoworkWorkspaceController`: when `coworkToolExecutor` is nil, external calls proceed without security. This is a deliberate design choice per the ROADMAP, but the silent bypass (rather than a hard fail) means the security property does not hold during the startup window. This should be addressed before considering the milestone complete.

**Grade: B+**

Strong implementation with good test coverage and clean code. The graceful-degradation bypass prevents a clean A. Fixing the startup-race fallback to fail closed (throw `.pipelineNotReady` at the call site) would bring this to A.
