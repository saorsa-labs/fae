# Companion Presence Mode — Roadmap

## Problem Statement
Fae currently operates as a "summoned servant" — she wakes on command, responds, then auto-dismisses herself after 20 seconds of silence. This feels cold and dismissive. She can't decide for herself whether to speak — she's either fully on or fully off.

We want Fae to be an **always-present companion** who listens, thinks, and chooses when to speak. She should stay present unless explicitly told to go to sleep. She should intelligently decide whether speech is directed at her, whether she can helpfully contribute to a nearby conversation, or whether she should stay quiet.

## Success Criteria
- Auto-idle timeout removed (Fae never auto-dismisses herself)
- Multiple natural "go to sleep" phrases: "shut up", "stop Fae", "go to sleep", "that'll do Fae", "quiet Fae", etc.
- Wake word ("fae" / "hi fae") still brings her back from sleep
- System prompt + SOUL.md updated for companion presence behavior
- Fae intelligently decides whether to respond based on context:
  - Direct address → respond normally
  - Overheard question she can help with → politely interject with variety
  - Background noise / TV / others chatting → stay quiet
- Errs on the side of silence when uncertain
- Interjection language varies naturally (not the same phrase each time)
- All barge-in and interruption mechanisms preserved
- Backward-compatible config migration (existing configs still work)
- Zero compilation errors and warnings
- All tests pass

---

## Milestone 1: Companion Presence Mode

### Phase 1.1: Config & Sleep Phrases
Update `ConversationConfig` to support multiple sleep phrases. Add `sleep_phrases: Vec<String>` with sensible defaults. Change `idle_timeout_s` default from 20 to 0 (disabled). Keep backward compatibility with existing single `stop_phrase` field via serde migration.

**Key files:** `src/config.rs`

### Phase 1.2: Conversation Gate
Modify `run_conversation_gate()` in the pipeline coordinator. Remove/disable auto-idle timer when `idle_timeout_s == 0`. Replace single stop-phrase check with multi-phrase sleep detection from `sleep_phrases`. Preserve all wake mechanisms (wake word, wakeword spotter, GUI button) and barge-in behavior unchanged.

**Key files:** `src/pipeline/coordinator.rs`

### Phase 1.3: Personality & Prompts
Update `Prompts/system_prompt.md` and `SOUL.md` for companion presence mode. Add guidance for contextual awareness: when to respond, when to interject, when to stay quiet. Add interjection variety ("Excuse me, I couldn't help but overhear...", "Just thought I'd mention...", etc.). Ensure Fae errs on the side of silence when uncertain.

**Key files:** `Prompts/system_prompt.md`, `SOUL.md`

### Phase 1.4: Integration Testing
Add/update tests for multi-phrase sleep detection, disabled auto-idle, gate state transitions with new config. Verify backward compatibility with existing configs. Full validation (fmt, clippy, test).

**Key files:** `src/pipeline/coordinator.rs` (tests), `src/config.rs` (tests)

---

## Architecture Notes
- Conversation gate is in `src/pipeline/coordinator.rs` lines ~2836-3091
- State machine: `GateState { Idle, Active }`
- Auto-idle timer: `tokio::time::interval(5s)` checks `last_activity.elapsed()`
- Stop phrase: `strip_punctuation()` → `expand_contractions()` → substring match
- Wake word: `find_wake_word()` with variant detection ("fae", "faye", "fee", etc.)
- Prompts assembled in `src/personality.rs`: core_prompt + SOUL + skills + user_addon
- Barge-in: name-gated (conversation gate) + energy-based (control handler) + wakeword spotter
- ConversationConfig: `wake_word`, `stop_phrase`, `enabled`, `idle_timeout_s`
