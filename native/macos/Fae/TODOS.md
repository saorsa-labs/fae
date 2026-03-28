# TODOS

## Apprenticeship Trust — Prerequisites & Follow-ups

### TODO 1: Update SOUL.md and HEARTBEAT.md contracts (PREREQUISITE)
**What:** Update soul contract and runtime guidance to reflect narration-first behavior.
**Why:** Current docs say "approval popup is the default trust mechanism" and "no irreversible action without clear ask." With narration replacing confirmation, the LLM will read SOUL.md in the system prompt and fight the new behavior.
**Files:** `Sources/Fae/Resources/SOUL.md`, `Sources/Fae/Resources/HEARTBEAT.md`
**Depends on:** Must ship BEFORE or WITH the narration feature.
**Added:** 2026-03-28 (eng review)

### TODO 2: Multi-tool turn barge-in undo
**What:** Handle barge-in undo correctly when a turn has multiple tool calls.
**Why:** Current design tags one receipt ID at narration start. If the LLM chains 3 tool calls without pausing for narration between them, barge-in only undoes the last one. User might want to undo all 3.
**Approach:** Tag all receipt IDs created during the current turn. Barge-in offers "undo last action" or "undo all actions from this response."
**Depends on:** ActionReceipts implementation.
**Added:** 2026-03-28 (eng review, Codex finding)

### TODO 3: Tool mode clean sweep
**What:** Remove all mode-related code: toolMode field in ToolExecutorContext, isToolAllowed mode parameter, Settings mode picker, legacy mode migration, HostCommandBridge mode actions, InputBarView mode pill.
**Why:** Design calls for removing mode concept. Owner already auto-approved via ToolExecutor:448. Mode picker is vestigial UI.
**Blast radius:** 27+ test files, ToolRegistry, ToolPermissionSnapshot, HostCommandBridge, InputBarView, PipelineCoordinator.
**Approach:** Incremental — hide Settings UI first, then remove code in follow-up PRs.
**Depends on:** Lower priority than receipts/narration. Can be done after Phase 1.
**Added:** 2026-03-28 (eng review, Codex finding)
