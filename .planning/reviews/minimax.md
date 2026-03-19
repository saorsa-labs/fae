# MiniMax External Review — Unified Intercept

**Date**: 2026-03-19
**Reviewer**: MiniMax M2.7 (via Claude Code wrapper)
**Scope**: git diff 2e4c1d0d..HEAD — CoworkToolExecutor unified intercept implementation

---

## Summary

The implementation routes all CoWork external LLM calls through a `CoworkToolExecutor` actor that delegates to `ToolExecutorProtocol.execute()`. The structural intent is correct and the tests are thorough. However there is one critical architectural bug that silently prevents DamageControlPolicy from running for CoWork calls. Several smaller gaps also exist.

---

## Task Completion

The deliverables from the ROADMAP are present:

- CoworkToolExecutor actor: present
- ToolExecutorProtocol for test isolation: present
- ToolExecutorContext factory methods (coworkExternal, restrictedFallback): present
- FaeCore.coworkToolExecutor exposed after pipeline start: present
- CoworkWorkspaceController 3 call sites wired: present
- DamageControlPolicy 3 new nonLocalOnly paths: present
- 17 test cases in CoworkRemoteProviderTests + 6 in DamageControlPolicyTests: present
- FaeEvent 3 new cowork events: present
- CLAUDE.md documentation updated: present

---

## Critical Bug: Security Stack Never Runs for CoWork Calls

### The bug

`performSecurityCheck()` calls `toolExecutor.execute()` with `toolName = "external_llm"` (or `"external_llm_streaming"` / `"external_llm_websearch"`). These names are not registered in `ToolRegistry.buildDefault()`.

`ToolExecutor.executeInner()` runs `registry.isToolAllowed(call.name, mode: "full", ...)` at step 1. For mode `"full"`, this returns `tools[name] != nil`. Since `external_llm` is not in the registry, it returns `false`. The guard fires and executeInner returns:

```
ToolExecutorResult(
    result: .error("Tool 'external_llm' is not available in read-only mode..."),
    damageControlIntervened: false
)
```

`performSecurityCheck()` sees `outcome.result.isError == true` and throws `.securityBlocked(reason: ...)`. Every single CoWork call through the executor will throw `.securityBlocked` with the message about read-only mode. The executor never reaches DamageControlPolicy, OutboundExfiltrationGuard, or TrustedActionBroker. The security layers it is supposed to invoke are completely bypassed.

The fallback path in `CoworkWorkspaceController` (direct provider access when `coworkToolExecutor` is nil) will NOT trigger here because `coworkToolExecutor` is non-nil — it just throws an error. The CoWork call will fail entirely for users.

### Why the tests pass despite the bug

The tests use `MockToolExecutor`, which ignores the tool name and returns whatever `nextResult` was configured to return. The mock bypasses the real `ToolExecutor.executeInner` path entirely. No test exercises the full integration path through the real `ToolExecutor` with `ToolRegistry`.

### Fix

Register synthetic tool descriptors for `external_llm`, `external_llm_streaming`, and `external_llm_websearch` in `ToolRegistry`, OR bypass step 1 by adding a separate code path in `ToolExecutor` for synthetic/internal calls that skips the registry check but still runs DamageControl + OutboundGuard + Broker.

The simpler and cleaner fix is to not route through `ToolExecutor.execute()` at all for the security check, and instead call `DamageControlPolicy.evaluate()`, `OutboundExfiltrationGuard`, and `TrustedActionBroker` directly in `performSecurityCheck()`. This avoids the unregistered tool problem and makes the security stack invocation explicit and auditable.

---

## Medium Issues

### 1. coworkExternal() sets isOwner=true and toolMode="full"

`ToolExecutorContext.coworkExternal()` creates a context with `isOwner = true` and `toolMode = "full"`. This is passed to `ToolExecutor.execute()` alongside `actionSource = .relay`.

`isOwner = true` and `toolMode = "full"` are the highest-privilege settings in the system. They are designed for the verified human owner's voice commands. Setting them for a relay call from an external LLM provider conflicts with the stated threat model. If any part of the security stack uses `isOwner` or `toolMode` to grant additional capabilities (e.g., TrustedActionBroker, ApprovalManager), CoWork relay calls would be treated as equivalent to the owner's direct voice commands.

The correct context for a relay from an external model would be `isOwner = false`, `toolMode = "read_only"` or at most `"assistant"`, unless there is an explicit design decision to trust all CoWork sessions as owner-equivalent. This decision is not documented in the roadmap or code comments.

### 2. Graceful degradation is a documented security bypass

When `coworkToolExecutor` is nil, `CoworkWorkspaceController` falls back to calling the provider directly. The CLAUDE.md documents this as "graceful degradation." During the window between app launch and pipeline startup completion (including model load), all CoWork calls bypass the security pipeline entirely.

Given that pipeline startup includes MLX model loading (potentially minutes on first run), this is not a brief race window — it is a predictable and exploitable gap. A user could receive a security-critical external LLM response before the pipeline is ready.

The fallback should be to fail with a user-visible error, not to silently allow the call through without security enforcement.

### 3. Fire-and-forget security audit logging

All three `record*` methods (`recordAllow`, `recordBlock`, `recordFlag`) spawn detached `Task { await securityLogger?.log(...) }` without error handling and without any backpressure. Under cancellation or high call volume, audit log entries will be silently dropped. For a security-sensitive path, the audit log should be structured as a durable in-order queue or the log calls should be awaited directly since `CoworkToolExecutor` is already an actor.

### 4. fae.db not in DamageControlPolicy protected paths

`~/Library/Application Support/fae/fae.db` is the primary memory database. It contains every conversation the user has ever had with Fae. It is not in the new `nonLocalOnly` zeroAccessPaths. An external model that gains write tool access could corrupt or read the memory store. `soul.md` (`~/Library/Application Support/fae/soul.md`) and `config.toml` are also unprotected.

---

## Minor Issues

### 5. Inbound injection scan is case-normalized substring matching only

The 10-pattern scan in `scanForInjection()` lowercases the entire response and checks for substring presence. This will produce false positives on legitimate content containing phrases like "ignore previous instructions" in quoted text, analysis, or educational contexts. It will also miss obfuscated injection (unicode lookalikes, newline injection, multi-token splitting). The scan is documented as non-ML and basic, which is acceptable given the roadmap's scope, but the false positive risk for real-world CoWork use (e.g., a model summarizing an article about prompt injection) is not acknowledged.

### 6. No test for web search injection detection path

`testCoworkToolExecutorWebSearchRoutesThroughSecurityStack` verifies routing but not injection detection. There is no test that delivers a web-search response containing an injection pattern and asserts `inboundScanFlagged` is thrown. This gap mirrors the streaming injection test but for the third submit path.

### 7. performSecurityCheck condition ordering

`performSecurityCheck` checks `outcome.damageControlIntervened` first, then `outcome.result.isError`. In `ToolExecutor`, a DC block sets `damageControlIntervened = true` AND `result = .error(...)`. So the damageControlIntervened check would fire first, which is correct. However in the unknown-tool path (the critical bug above), `damageControlIntervened = false` and `result = .error(...)`. So the wrong error case fires. Once the critical bug is fixed, verify the condition ordering remains correct.

### 8. Metrics key is provider.kind description

The metrics dictionary key is `String(describing: provider.kind)`. This relies on the stable string representation of the `kind` enum. If `CoworkProviderKind` gains new cases or renames, the metrics key changes silently. The roadmap flagged a "stable provider metrics key" as a hardening concern. The current implementation delegates stability to Swift's `String(describing:)` which is implementation-defined. This should use a dedicated stable string property on `CoworkProviderKind`.

---

## What is Done Well

- `ToolExecutorProtocol` extraction enables clean test isolation without mocking the entire pipeline
- `ToolExecutorCallbacks.noop` is a useful named constant rather than inline closures at call sites
- `ToolExecutorContext` factory methods eliminate copy-paste across `PipelineCoordinator.swift` (two `.restrictedFallback()` callsites were cleaned up)
- DamageControlPolicy tests for the three new paths are thorough: read, write, edit, and the local-model allow cases
- 17 CoworkToolExecutor tests cover the major success and failure paths
- The `markReady()` / `isReady` pattern correctly prevents use before pipeline initialization
- FaeEvent additions are appropriately typed and documented
- `submitStreaming` no longer uses `!` force-unwrap on `finalResponse` (fixed from earlier version)

---

## Grade

**D**

The implementation is structurally correct and well-tested against the mock. However the critical bug means the real security pipeline (DamageControlPolicy, OutboundGuard, TrustedActionBroker) does not run for any CoWork call in production. The implementation ships the appearance of security enforcement without the actual enforcement. This must be fixed before merge.

---

*External review by MiniMax M2.7*
*Note: MiniMax wrapper invokes Claude Code as the inference backend. This review was produced by the wrapper's underlying model performing independent analysis of the full git diff and source files.*
