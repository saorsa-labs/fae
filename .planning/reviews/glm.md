# GLM-4.7 External Review — Unified Intercept

**Reviewer**: GLM-4.7 (Z.AI/Zhipu) via z.ai wrapper
**Date**: 2026-03-19
**Scope**: git diff 2e4c1d0d..HEAD — Milestones 1–3 of the Unified Intercept roadmap
**Phase**: 1.3 (Hardening & Contracts)

---

## Summary

The Unified Intercept implementation routes all CoWork external LLM calls through ToolExecutor's security pipeline. The architecture is sound and the test coverage is good. Several findings below — one medium-severity correctness issue, several minor hardening gaps, and two coverage gaps.

---

## Findings

### 1. MEDIUM — `chatProvider` (localhost) bypasses the security stack at line 1404

**File**: `CoworkWorkspaceController.swift:1404`

```swift
if let chatProvider = self.chatProvider {
    let response = try await chatProvider.submit(request: providerRequest)
```

`chatProvider` is a `FaeLocalhostCoworkProvider`. Because it routes locally it may seem safe, but this code path bypasses `CoworkToolExecutor` entirely — no `performSecurityCheck`, no `guardNonEmpty`, no `guardNoInjection`, no metrics recording. The same exemption applies to the synthesis call at line 1791 for `WorkWithFae` consensus.

**Impact**: If a compromised localhost provider ever returned a prompt-injection response, the inbound scan would not fire. The metrics counter would also be incorrect — localhost calls would never appear.

**Recommendation**: Either route localhost through `CoworkToolExecutor` with a `modelLocality: .local` context (so nonLocal-only rules do not apply), or add an explicit comment documenting why localhost is intentionally exempt and what alternative protection applies. The current state is a silent gap that is easy to miss in future audits.

---

### 2. MINOR — `coworkExternal()` hardcodes `toolMode: "full"` and `isOwner: true`

**File**: `ToolExecutorContext.swift`, `coworkExternal()` factory

The context passed through the security stack for every CoWork call sets `toolMode = "full"` and `isOwner = true`. This is correct for the current use — security enforcement comes from DamageControlPolicy's `nonLocal` path rules, not from tool-mode filtering. However, both fields appear in audit logs and are visible to any code that inspects the context.

**Impact**: Low in isolation, but if a future caller reuses `coworkExternal()` for a less-privileged context (e.g. guest CoWork sessions), it would inherit owner-level claims without review. The factory method gives no parameter to override `isOwner`.

**Recommendation**: Add a brief doc comment on `coworkExternal()` noting that `isOwner: true` reflects that CoWork sessions require owner identity, and that the real enforcement boundary is `modelLocality: .nonLocal`. Consider adding an `isOwner` parameter with a default of `true` so callers can be explicit.

---

### 3. MINOR — Detached `Task` in metrics loggers may silently drop events under actor teardown

**File**: `CoworkToolExecutor.swift`, `recordAllow`, `recordBlock`, `recordFlag`

```swift
private func recordAllow(providerKind: String, model: String) {
    metrics[providerKind, default: ProviderMetrics()].allowed += 1
    Task {
        await securityLogger?.log(...)
    }
}
```

Each record method increments the in-actor counter synchronously but fires a detached `Task` to call `securityLogger.log`. If the actor is deallocated (e.g. in tests, or if `CoworkToolExecutor` is replaced during a pipeline restart), the detached task holds a reference to `securityLogger` and may log to a closed or deallocated resource. The task is also unstructured — it is invisible to Swift's structured concurrency and cannot be cancelled or awaited.

**Impact**: Low in production (singleton lifecycle). In tests it can cause spurious async calls after the test teardown. The `recordBlock` path is security-critical; a dropped log is observable.

**Recommendation**: Use `async let` or `await securityLogger?.log(...)` directly from the actor's synchronous context. Since `securityLogger.log` is `async`, this requires `recordAllow` etc. to be `async` as well — which in turn requires `guardNonEmpty` and `guardNoInjection` callers to `await` them. This is a minor refactor. At minimum, annotate the detached Task with a comment explaining the deliberate fire-and-forget choice.

---

### 4. MINOR — `coworkRedactionApplied` event is declared but never emitted

**File**: `FaeEvent.swift`, `FaeEventBus.swift`

```swift
case coworkRedactionApplied(provider: String, strippedFields: [String])
```

The event handler in `FaeEventBus.swift` is wired and correct, but no call site in `CoworkToolExecutor` emits this event. The ROADMAP Phase 1.3 lists "redaction metadata contract" as a deliverable.

**Impact**: Not a correctness issue — no observer depends on this event yet. But the dead code will generate a linting warning (unused enum case in a `switch`) if `FaeEventBus.sendToNotificationCenter` gains a future exhaustive switch, and it misleads readers about what events actually fire.

**Recommendation**: Either emit the event from `CoworkToolExecutor` when outbound redaction is applied (hooking into `CoworkPromptEgressPolicy`), or remove the case and re-add it when the redaction metadata contract is implemented.

---

### 5. MINOR — `performSecurityCheck` does not include the prompt content in the `ToolCall` arguments

**File**: `CoworkToolExecutor.swift`, `performSecurityCheck`

The `ToolCall` passed to `ToolExecutor.execute` has only `model`, `provider`, and `thinkingLevel` as arguments. `DamageControlPolicy` and `OutboundExfiltrationGuard` evaluate tool arguments to decide whether to block. Without the prompt content in the arguments, these policies have no visibility into what is actually being sent to the external model.

**Impact**: `DamageControlPolicy`'s path-rule matching operates on `arguments["path"]`. For native tools this is the file path. For CoWork calls there is no path argument — the payload that actually contains sensitive paths is in the prompt, which is not inspected by the security stack at this layer. The protection against credential exfiltration therefore relies entirely on `CoworkPromptEgressPolicy` (pre-send redaction), not on the broker.

This is within the stated scope ("Out of scope: full inbound validation") but should be explicitly documented as a known limitation in the code, not just in the roadmap.

**Recommendation**: Add a doc comment to `performSecurityCheck` noting that argument-level inspection is limited to metadata (model/provider/thinkingLevel) and that content-level protection is provided by `CoworkPromptEgressPolicy` upstream.

---

### 6. COVERAGE GAP — No test for `submitWithWebSearch` blocking path

**File**: `CoworkRemoteProviderTests.swift`

`testCoworkToolExecutorWebSearchRoutesThroughSecurityStack` tests the happy path. There is no test that verifies `submitWithWebSearch` throws `damageControlIntervened` or `securityBlocked` when the mock executor returns an error result. The blocking tests (`testCoworkToolExecutorBlocksWhenDamageControlIntervenes`) only cover `submit`, not `submitWithWebSearch`.

**Recommendation**: Add a parallel test for the web search path. Low effort — the mock infrastructure is already in place.

---

### 7. COVERAGE GAP — `markReady()` race condition is untested

**File**: `CoworkToolExecutor.swift`, `markReady()`

`isReady` is a mutable actor-isolated `var`. The `markReady()` method is public. There is no test verifying that a concurrent `submit` call made while `markReady()` is in flight behaves correctly. Since actor isolation serializes these, it is safe by construction, but a test documenting the expected behavior (first call fails, second succeeds) would prevent future regression if the `isReady` mechanism changes.

**Recommendation**: Low priority, but worthwhile given the safety-critical nature of the pipeline-not-ready guard.

---

## Architecture Assessment

The core architecture is correct. Routing through a single `performSecurityCheck` DRY helper, then calling the provider, then validating the response is the right structure. The `ToolExecutorProtocol` abstraction enables clean test doubles. The `ToolExecutorContext.coworkExternal()` factory appropriately sets `modelLocality: .nonLocal` so the DamageControlPolicy nonLocal rules fire. The three new `DamageControlPolicy` paths (`~/.fae-vault`, `speakers.json`, `directive.md`) are correct and well-tested.

The fallback pattern (direct provider call when `coworkToolExecutor` is nil) is acceptable for graceful degradation during pipeline startup, but the localhost bypass (finding #1) is a silent exception that should be made explicit.

---

## Grade: B+

The implementation delivers the stated goals: all external CoWork calls route through the security stack, DamageControlPolicy blocks credential access for non-local models, inbound scan fires on streaming and blocking responses, and test coverage is solid. The localhost bypass (finding #1) is the only genuine correctness gap — everything else is hardening or documentation. Fix #1 and annotate #5 before broader rollout.

---

*External review — architecture analysis based on diff 2e4c1d0d..HEAD*
