# Fae v0.5.0: Always-On Companion + Tool Feedback + Speed

## Problem Statement
Fae operates in a "summoned servant" model requiring a wake word. Tool execution gives zero feedback until completion. VAD silence detection adds unnecessary latency. Canvas sometimes shows blank messages.

## Success Criteria
- Wake word system completely removed — Fae always listens
- Conversation gate starts Active (always-on)
- Stop/start listening button preserved
- Sleep phrases preserved
- Real-time tool execution feedback in canvas
- No blank canvas messages
- Response latency reduced (VAD tuning, wakeword overhead removed)
- Zero compilation errors and warnings
- All tests pass

---

## Milestone 1: Always-On Companion + Speed + Feedback

### Phase 1.1: Remove Wake Word System ✅
Deleted wakeword.rs, record_wakeword binary, removed all wakeword code from coordinator, gate starts Active, removed WakewordDetected event.

### Phase 1.2: Speed Improvements ✅
VAD silence 2200ms→1000ms, barge-in silence 1200ms→800ms, audio path simplified.

### Phase 1.3: Real-Time Tool Feedback ✅
Added ToolExecuting event, threaded runtime_tx into AgentLoop, live tool event emission, auto-open canvas for all tools.

### Phase 1.4: Fix Canvas Blank Messages ✅
Whitespace guards in flush_assistant, AssistantSentence, push(), push_tool().

### Phase 1.5: Integration Testing & Polish ✅
End-to-end validation, backward compat testing, update CHANGELOG.md, update docs.

**Key files:** `src/pipeline/coordinator.rs` (tests), `src/config.rs`, `CHANGELOG.md`
