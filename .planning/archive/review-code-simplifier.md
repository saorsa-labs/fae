# Code Simplifier Review — Unified Intercept (2e4c1d0d..HEAD)

Reviewed files: `CoworkToolExecutor.swift`, `CoworkWorkspaceController.swift`,
`PipelineCoordinator.swift`, `ToolExecutorContext.swift`, `FaeCore.swift`.

---

## 1. `buildContext(for:)` is a passthrough wrapper — inline it

`CoworkToolExecutor.buildContext(for:)` takes a `CoworkProviderRequest` parameter
it never reads, and its entire body is a single call to the static factory:

**Before**
```swift
private func buildContext(for request: CoworkProviderRequest) -> ToolExecutorContext {
    .coworkExternal()
}
```

**After** — call `ToolExecutorContext.coworkExternal()` directly in `performSecurityCheck`:
```swift
let context = ToolExecutorContext.coworkExternal()
```

The parameter `request` is unused, and the wrapper adds a layer of indirection for
no gain. Removing it makes it obvious at the call site exactly what context is being
created.

---

## 2. `submitStreaming` uses a two-variable error/response pattern when `throws` is available

The streaming method uses `var finalResponse: CoworkProviderResponse?` and
`var finalError: Error?` as mutable state that is then checked in sequence. This
pattern exists because the stream closure can't propagate throws directly, but the
post-stream validation and result assembly are overcomplicated as a result.

The guards run in an order that can hide a logic gap: `guardNonEmpty` and
`guardNoInjection` are checked before `finalError`, so a provider error that also
somehow produced a finalResponse would have the guard checks run unnecessarily. More
importantly, there is a dead code path: `finalResponse` is always non-nil when
`finalError` is nil (stream sets one or the other), so the trailing `guard let result`
can never be reached via the `finalError == nil && finalResponse == nil` path — yet
the code and its error message imply it can.

**Before**
```swift
var finalResponse: CoworkProviderResponse?
var finalError: Error?

do {
    let response = try await provider.stream(request: request) { ... }
    finalResponse = response
} catch let error as CoworkProviderError {
    finalError = CoworkToolExecutorError.providerError(underlying: error)
} catch let error as CoworkToolExecutorError {
    finalError = error
} catch {
    finalError = CoworkToolExecutorError.networkError(underlying: error)
}

if let response = finalResponse {
    try guardNonEmpty(response)
    try guardNoInjection(response, providerKind: providerKind)
}

if let error = finalError {
    throw error
}

guard let result = finalResponse else {
    throw CoworkToolExecutorError.networkError(
        underlying: NSError(domain: "CoworkToolExecutor", code: -1, ...)
    )
}
recordAllow(providerKind: providerKind, model: request.model)
return result
```

**After** — restructure so the happy path is a single flow and errors throw immediately:
```swift
do {
    let response = try await provider.stream(request: request) { partialText in
        await onPartialText(partialText)
    }
    try guardNonEmpty(response)
    try guardNoInjection(response, providerKind: providerKind)
    recordAllow(providerKind: providerKind, model: request.model)
    return response
} catch let error as CoworkToolExecutorError {
    throw error
} catch let error as CoworkProviderError {
    throw CoworkToolExecutorError.providerError(underlying: error)
} catch {
    throw CoworkToolExecutorError.networkError(underlying: error)
}
```

This matches the structure of `submit` and `submitWithWebSearch` exactly and
eliminates the optional-variable accumulation pattern entirely.

---

## 3. `performSecurityCheck` duplicates the block/event pattern for two cases

When `damageControlIntervened` is true, and when `outcome.result.isError` is true,
the code in `performSecurityCheck` does the same three things in the same order:
extract the reason, call `recordBlock`, send the event bus notification, then throw a
different error type. The only difference is which error is thrown.

**Before**
```swift
if outcome.damageControlIntervened {
    let reason = outcome.result.output
    recordBlock(providerKind: providerKind, model: request.model, reason: reason)
    eventBus?.send(.coworkSecurityBlocked(provider: providerKind, reason: reason))
    throw CoworkToolExecutorError.damageControlIntervened(reason: reason)
}

if outcome.result.isError {
    let reason = outcome.result.output
    recordBlock(providerKind: providerKind, model: request.model, reason: reason)
    eventBus?.send(.coworkSecurityBlocked(provider: providerKind, reason: reason))
    throw CoworkToolExecutorError.securityBlocked(reason: reason)
}
```

**After** — extract the shared side-effect sequence into a local helper or use a
single conditional that selects only the error type:
```swift
func blockAndThrow(reason: String, error: CoworkToolExecutorError) throws {
    recordBlock(providerKind: providerKind, model: request.model, reason: reason)
    eventBus?.send(.coworkSecurityBlocked(provider: providerKind, reason: reason))
    throw error
}

if outcome.damageControlIntervened {
    try blockAndThrow(reason: outcome.result.output,
                      error: .damageControlIntervened(reason: outcome.result.output))
}
if outcome.result.isError {
    try blockAndThrow(reason: outcome.result.output,
                      error: .securityBlocked(reason: outcome.result.output))
}
```

Alternatively (and more idiomatically for a private method), simply factor out the
shared lines into a `recordAndBroadcastBlock` helper called from both branches:

```swift
private func recordAndBroadcastBlock(providerKind: String, model: String, reason: String) {
    recordBlock(providerKind: providerKind, model: request.model, reason: reason)
    eventBus?.send(.coworkSecurityBlocked(provider: providerKind, reason: reason))
}
```

---

## 4. `CoworkWorkspaceController` security executor fallback duplicates call-site logic

The three dispatch branches in `CoworkWorkspaceController` each independently check
`if let securityExecutor` and duplicate the fallback call. The streaming branch
additionally duplicates the `onPartialText` closure body verbatim between the secured
and unsecured paths.

**Before** (streaming branch, condensed):
```swift
if let securityExecutor {
    response = try await securityExecutor.submitStreaming(...) { partialText in
        await MainActor.run {
            if !self.conversation.isStreaming { self.conversation.startStreamingReply() }
            self.conversation.updateStreaming(text: partialText)
        }
    }
} else {
    response = try await streamingProvider.stream(...) { partialText in
        await MainActor.run {
            if !self.conversation.isStreaming { self.conversation.startStreamingReply() }
            self.conversation.updateStreaming(text: partialText)
        }
    }
}
```

The `onPartialText` closure body is byte-for-byte identical in both branches. The
simplest fix is to extract it:

```swift
let onPartialText: @Sendable (String) async -> Void = { partialText in
    await MainActor.run {
        if !self.conversation.isStreaming { self.conversation.startStreamingReply() }
        self.conversation.updateStreaming(text: partialText)
    }
}

if let securityExecutor {
    response = try await securityExecutor.submitStreaming(
        request: providerRequest, provider: streamingProvider, onPartialText: onPartialText)
} else {
    response = try await streamingProvider.stream(
        request: providerRequest, onPartialText: onPartialText)
}
```

The same principle applies to the web-search and blocking branches: extract a local
helper that picks the secured or direct path based on `securityExecutor`:

```swift
func callProvider(_ executor: CoworkToolExecutor?) async throws -> CoworkProviderResponse {
    if let executor {
        return try await executor.submit(request: providerRequest, provider: provider)
    }
    return try await provider.submit(request: providerRequest)
}
```

---

## 5. `getMetrics()` should use Swift naming conventions — rename to `metrics`

`getMetrics()` is a getter-style function with no side effects, returning a value type.
Swift naming conventions prefer properties or bare noun names for pure accessors:

**Before**
```swift
func getMetrics() -> [String: ProviderMetrics] {
    metrics
}
```

**After**
```swift
var snapshotMetrics: [String: ProviderMetrics] {
    metrics
}
```

Or simply expose the field directly as `nonisolated(unsafe)` is not possible here, but
a computed property named `metricsSnapshot` matches the Swift API design guidelines
better than a `get`-prefixed function. The existing tests use
`await executor.getMetrics()` so this is a rename-only change.

---

## 6. `isReady` is set in `init` and `markReady()` — the `init` parameter is redundant with default `true`

The init signature has `isReady: Bool = true`, meaning callers that don't pass it get
`isReady = true` immediately. The only production call site
(`PipelineCoordinator.makeCoworkToolExecutor()`) passes `isReady: true` explicitly.
The only test usage passes `isReady: false` to verify `pipelineNotReady` behavior,
then calls `markReady()`.

The `isReady = false` test path could instead be served by a dedicated
`CoworkToolExecutor.notReady(toolExecutor:)` factory or by simply not using the
default. However, the deeper issue is that `markReady()` is public API only needed
by tests — the production init always passes `true`. Consider whether `markReady()`
and the `isReady` guard are needed at all in production, or whether they should be
test-only via `#if DEBUG`.

This is a design suggestion rather than a mechanical simplification. No before/after
shown because the right answer depends on whether `isReady: false` will ever be used
in production (e.g. for deferred startup).

---

## 7. MARK comment label is task-tracking noise, not a code boundary

Two MARK comments in `CoworkToolExecutor.swift` retain task-tracking labels:

```swift
// MARK: - DRY Security Check (Task 2)
// MARK: - Response Guards (Task 3)
// MARK: - Metrics (Task 6)
```

The parenthetical `(Task N)` suffixes are implementation tracking artifacts, not
meaningful section names for a reader of the finished code. Strip them to:

```swift
// MARK: - Security Check
// MARK: - Response Guards
// MARK: - Metrics
```

---

## Summary

| # | File | Category | Effort |
|---|------|----------|--------|
| 1 | `CoworkToolExecutor.swift` | Remove passthrough wrapper | Trivial |
| 2 | `CoworkToolExecutor.swift` | Flatten streaming two-variable pattern | Small |
| 3 | `CoworkToolExecutor.swift` | Extract repeated block/broadcast sequence | Small |
| 4 | `CoworkWorkspaceController.swift` | Extract duplicated closure and dispatch logic | Small |
| 5 | `CoworkToolExecutor.swift` | Rename `getMetrics()` to match Swift conventions | Trivial |
| 6 | `CoworkToolExecutor.swift` | Evaluate `isReady`/`markReady` necessity | Design |
| 7 | `CoworkToolExecutor.swift` | Remove task-tracking labels from MARK comments | Trivial |

Items 1, 2, 3, and 4 are the highest-value changes: they reduce duplicated logic and
align `submitStreaming` with the structure of its sibling methods. None of the
suggestions change behavior.
