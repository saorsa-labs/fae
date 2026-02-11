# Phase 2.3: Integration & Polish

## Goal
Complete the Runtime Voice Switching feature with GUI integration, help/query commands, and comprehensive documentation. Make the model switching experience seamless and user-friendly.

## Approach
Build on the complete voice command detection (Phase 2.1) and live switching (Phase 2.2) to add visual feedback in the GUI, handle query commands (list/current), and provide full documentation and testing.

## Tasks

### Task 1: GUI active model indicator
**Files:** `src/bin/gui.rs`
- Add `active_model: Option<String>` to `AppState`
- Display active model name in status bar or header when known
- Update on startup after model selection completes
- Update when model switch events occur
- Style: subtle indicator, e.g., "🤖 Claude Opus 4" or "Model: gpt-4o"
- Tests: GUI state updates when model changes

### Task 2: Wire ListModels command to Pi query
**Files:** `src/pipeline/coordinator.rs`, `src/pi/engine.rs`
- When VoiceCommand::ListModels detected, call `pi.list_model_names()`
- Build spoken response using `list_models_response()`
- Send to TTS for voice output (bypass LLM generation)
- Update GUI to show brief "listing models" status
- Tests: ListModels command produces correct spoken output

### Task 3: Wire CurrentModel command to Pi query
**Files:** `src/pipeline/coordinator.rs`, `src/pi/engine.rs`
- When VoiceCommand::CurrentModel detected, call `pi.current_model_name()`
- Build spoken response using `current_model_response()`
- Send to TTS for voice output
- Tests: CurrentModel query returns active model name

### Task 4: Help command for model switching
**Files:** `src/voice_command.rs`, `src/pipeline/coordinator.rs`
- Add VoiceCommand::Help variant
- Recognize "help", "what can I say", "model commands"
- Return spoken help text listing all model switch patterns
- Example: "You can say: switch to Claude, use the local model, list models, or what model are you using."
- Tests: Help command returns correct text

### Task 5: Error handling and edge cases
**Files:** `src/pipeline/coordinator.rs`, `src/pi/engine.rs`
- Handle model switch during active generation gracefully
- Validate model switch didn't break Pi session continuity
- Handle unavailable model requests with fallback message
- Timeout handling for slow model switches
- Tests: Edge cases return appropriate error messages

### Task 6: Integration tests — end-to-end flow
**Files:** `tests/model_switching_integration.rs` (new)
- Full flow: startup → auto-select → voice command → switch → query
- Test: "switch to Claude" changes active model and GUI state
- Test: "list models" produces correct spoken output
- Test: "what model" returns current model
- Test: switch to unavailable model handles gracefully
- All tests use mock Pi/TTS to avoid real API calls

### Task 7: Documentation — user guide
**Files:** `docs/model-switching.md` (new), `README.md`
- Document all supported voice commands with examples
- Explain tier-based auto-selection behavior
- Document priority field override in models.json
- Document fallback to local model
- Add troubleshooting section (model not found, switch failed)
- Update main README with "Runtime Model Switching" section

### Task 8: Documentation — developer guide
**Files:** `docs/architecture/model-selection.md` (new)
- Document three-layer selection architecture (tier → priority → picker)
- Document voice command pipeline flow
- Document PiLlm model switching internals
- Document how to add new model tier mappings
- Document testing approach for voice commands
- Add architecture diagram if helpful
