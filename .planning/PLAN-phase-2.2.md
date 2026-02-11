# Phase 2.2: Live Model Switching

## Goal
Wire voice commands from Phase 2.1 into PiLlm so users can switch LLM models
at runtime via voice ("Fae, switch to Claude"). Includes spoken acknowledgment
via TTS, list/current model queries, and edge case handling.

## Current State
- `voice_command.rs`: `VoiceCommand` enum (SwitchModel, ListModels, CurrentModel),
  `parse_voice_command()`, `resolve_model_target()` — all tested
- `coordinator.rs`: `run_voice_command_filter()` intercepts transcriptions, sends
  parsed commands to `voice_cmd_tx` channel — BUT `_voice_cmd_rx` is dropped (unused)
- `engine.rs`: `PiLlm` has `switch_to_candidate(idx)`, `active_model()`,
  `model_candidates` vec — switching restarts Pi subprocess via `session.set_provider_model()`
- `runtime.rs`: `VoiceCommandDetected`, `ModelSwitchRequested`, `ModelSelected` events exist

## Architecture
Voice command flow:
```
User speech → STT → VoiceCommandFilter → voice_cmd_tx → LLM stage loop
                                                              ↓
                                                      resolve target
                                                              ↓
                                                   PiLlm::switch_to_candidate()
                                                              ↓
                                                   RuntimeEvent::ModelSelected
                                                              ↓
                                                   TTS spoken acknowledgment
```

## Tasks

### Task 1: Add public model query methods to PiLlm
**Files:** `src/pi/engine.rs`
- Add `pub fn list_model_names(&self) -> Vec<String>` — returns `model_candidates.iter().map(|c| c.display()).collect()`
- Add `pub fn current_model_name(&self) -> String` — returns `active_model().display()`
- Add `pub fn candidate_count(&self) -> usize`
- Tests: list_model_names returns expected strings, current_model_name matches active index

**Acceptance criteria:**
- Methods are pure getters, no side effects
- Documented with doc comments
- 3+ unit tests

### Task 2: Add switch_model_by_voice() to PiLlm
**Files:** `src/pi/engine.rs`
- Add `pub fn switch_model_by_voice(&mut self, target: &ModelTarget) -> Result<String, String>`
  - Calls `resolve_model_target(target, &self.model_candidates)`
  - If resolved: calls `switch_to_candidate(idx)`, returns Ok(display name)
  - If already active model: returns Ok with "already using" message
  - If not found: returns Err with "model not found" message
- Emits `RuntimeEvent::ModelSwitchRequested` before switch
- Emits `RuntimeEvent::ModelSelected` after successful switch
- Tests: successful switch, already-active no-op, not-found error

**Acceptance criteria:**
- Uses existing `switch_to_candidate()` internally
- Emits both runtime events
- Returns human-readable strings for TTS
- 4+ unit tests

### Task 3: Wire voice_cmd_rx into PiLlm constructor
**Files:** `src/pi/engine.rs`, `src/pipeline/coordinator.rs`
- In `engine.rs`: Add field `voice_command_rx: Option<mpsc::UnboundedReceiver<VoiceCommand>>`
- Update `PiLlm::new()` signature to accept the receiver
- In `coordinator.rs`: Change `_voice_cmd_rx` to `voice_cmd_rx` (line ~438)
- Store `voice_cmd_rx` and pass it through to `PiLlm::new()` when constructing
- Tests: verify PiLlm accepts the channel (construction test)

**Acceptance criteria:**
- Channel receiver flows from coordinator → PiLlm
- No dropped channels (no underscore prefix)
- Compiles clean with `just lint`

### Task 4: Handle voice commands in LLM stage loop
**Files:** `src/pipeline/coordinator.rs`
- In `run_llm_stage()`: extract `voice_command_rx` from PiLlm (or pass as separate param)
- Add third branch to `tokio::select!` in the LLM loop:
  ```
  cmd = voice_cmd_rx.recv() => { handle voice command }
  ```
- For `SwitchModel { target }`: call `engine.switch_model_by_voice(&target)`
  - On Ok(msg): inject TTS sentence ("Switching to {model}")
  - On Err(msg): inject TTS sentence ("Sorry, {error}")
- For `ListModels`: get list, inject TTS sentence listing models
- For `CurrentModel`: get current, inject TTS sentence
- Tests: mock channel, send command, verify TTS output injected

**Acceptance criteria:**
- Commands handled without blocking LLM generation
- TTS acknowledgment injected into pipeline
- All three command types handled
- 3+ integration-style tests

### Task 5: TTS acknowledgment helpers
**Files:** `src/pi/engine.rs` or new `src/voice_command_response.rs`
- `pub fn switch_acknowledgment(model_name: &str) -> String` — "Switching to {name}"
- `pub fn already_using_acknowledgment(model_name: &str) -> String` — "I'm already using {name}"
- `pub fn model_not_found_response(target: &str) -> String` — "I couldn't find a model matching {target}"
- `pub fn list_models_response(models: &[String], current_idx: usize) -> String` — "I have access to {models}. Currently using {current}."
- `pub fn current_model_response(model_name: &str) -> String` — "I'm currently using {name}"
- Tests: all response strings format correctly

**Acceptance criteria:**
- Pure functions, no side effects
- Natural-sounding sentences for TTS
- Documented with doc comments
- 5+ unit tests covering each function

### Task 6: Edge case — switch during active generation
**Files:** `src/pipeline/coordinator.rs`
- When a voice command arrives during active LLM generation:
  - Set a cancellation flag / token to interrupt current generation
  - Complete the switch
  - Resume with new model (user can ask again)
- If switch fails mid-generation: continue with current model, report error via TTS
- Tests: simulate concurrent generation + voice command

**Acceptance criteria:**
- No panic or deadlock on concurrent command
- Generation interrupted cleanly
- Error case handled gracefully
- 2+ tests

### Task 7: Edge case — unavailable model and fallback
**Files:** `src/pi/engine.rs`
- When switching to a model that's configured but unreachable:
  - Attempt switch → Pi fails to start → detect error
  - Auto-fallback to previous model using `pick_failover_candidate()`
  - Emit `RuntimeEvent::ModelSwitchRequested` with fallback info
  - TTS: "Couldn't reach {target}, staying with {current}"
- Tests: simulate failed switch, verify fallback

**Acceptance criteria:**
- Graceful fallback, no crash
- User informed via TTS
- Previous model restored
- 2+ tests

### Task 8: Integration tests and verification
**Files:** `src/voice_command.rs`, `src/pi/engine.rs`, `src/pipeline/coordinator.rs`
- End-to-end test: parse "switch to Claude" → resolve → switch → verify active model changed
- End-to-end test: parse "what model are you using" → verify response string
- End-to-end test: parse "list models" → verify all candidates listed
- Run `just check` — zero errors, zero warnings
- Update `.planning/progress.md` with Phase 2.2 completion
- Verify all doc comments present on public items

**Acceptance criteria:**
- All existing tests still pass (567+)
- 3+ new end-to-end tests
- `just check` passes clean
- Progress log updated
