# Consensus Review — Unified Intercept
Date: 2026-03-19

## Grades
| Reviewer | Grade |
|----------|-------|
| Codex (Claude) | B+ |
| Kimi K2 | A- |
| GLM-4.7 | B+ |
| MiniMax | FAIL (critical bug) |
| Code Simplifier | N/A (suggestions only) |

## CRITICAL Findings (must fix)

### 1. CRITICAL: ToolRegistry blocks all CoWork calls (MiniMax, 1 vote)
`performSecurityCheck()` calls `toolExecutor.execute()` with `toolName = "external_llm"` which is NOT registered in ToolRegistry. The real ToolExecutor's `isToolAllowed()` returns false for unregistered tools, causing ALL CoWork calls to fail with `.securityBlocked`. DamageControlPolicy/OutboundGuard/Broker never run. Tests pass only because MockToolExecutor skips the registry.

**Fix:** Either register synthetic tool entries in ToolRegistry, or bypass the registry check for internal/synthetic calls, or call security layers directly instead of going through ToolExecutor.execute().

### 2. HIGH: Graceful-degradation fallback is a security bypass (Codex + Kimi, 2 votes)
When `coworkToolExecutor` is nil (during startup), CoworkWorkspaceController falls back to direct `provider.submit()` with no security checks. Should fail closed (throw .pipelineNotReady) instead of silently bypassing.

### 3. MEDIUM: `config.toml` and `soul.md` not in DamageControlPolicy zero-access (Codex + Kimi, 2 votes)
Both contain sensitive data that should be blocked for nonLocal models.

## MINOR Findings (should fix)

### 4. `chatProvider` localhost path bypasses security (GLM, 1 vote)
FaeLocalhostCoworkProvider calls bypass CoworkToolExecutor entirely. Document exemption or route through executor.

### 5. `buildContext(for:)` is a useless passthrough (Code Simplifier, 1 vote)
The method takes a request parameter it never reads and just calls `.coworkExternal()`. Inline it.

### 6. `toolMode: "full"` and `isOwner: true` in coworkExternal() may be misleading (Codex + GLM, 2 votes)
These values are correct for current use but may confuse future readers. Add doc comments explaining why.

### 7. Fire-and-forget Task {} for SecurityEventLogger may drop events (GLM, 1 vote)
Unstructured Tasks for logging could be lost during actor teardown.

### 8. Streaming submitStreaming() has dead code path (Code Simplifier, 1 vote)
The `guard let result = finalResponse else` can never trigger because finalError/finalResponse are mutually exclusive.

## Action Required
- Fix #1 (CRITICAL) — blocks production use
- Fix #2 (HIGH) — security bypass during startup
- Fix #3 (MEDIUM) — incomplete path protection
- Fix #5 (MINOR) — dead wrapper method
