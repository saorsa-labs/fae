# Phase 2.1: Voice Command Detection

## Overview
Add pattern matching for model-switch phrases in transcriptions before LLM generation.
Users can say "Fae, switch to Claude" or "use the local model" and Fae will detect
these as voice commands rather than passing them to the LLM.

## Integration Point
Pipeline flow: `Transcription → IdentityGate → VoiceCommandFilter → LLM`

The new `VoiceCommandFilter` stage sits between `run_identity_gate()` and `run_llm_stage()`.
It inspects each `Transcription`, and if it matches a voice command pattern, it sends a
`VoiceCommand` through a new channel instead of forwarding the transcription to the LLM.

## Key Files
- `src/voice_command.rs` (NEW) — types, parser, model name resolution
- `src/runtime.rs` — new RuntimeEvent variants for voice commands
- `src/pipeline/coordinator.rs` — wire in VoiceCommandFilter stage
- `src/pi/engine.rs` — receive and handle voice commands (Phase 2.2)
- `src/model_selection.rs` — ProviderModelRef (existing, referenced)
- `src/model_tier.rs` — tier_for_model (existing, referenced)

---

## Task 1: Define VoiceCommand types
**~40 lines | src/voice_command.rs**

Create `src/voice_command.rs` with:
- `VoiceCommand` enum: `SwitchModel { target: ModelTarget }`, `ListModels`, `CurrentModel`
- `ModelTarget` enum: `ByName(String)`, `ByProvider(String)`, `Local`, `Best`
- Module-level doc comments explaining purpose
- Add `pub mod voice_command;` to `src/lib.rs`

No parsing logic yet — just the types.

## Task 2: Unit tests for command parsing (TDD)
**~80 lines | src/voice_command.rs**

Add `#[cfg(test)] mod tests` with test cases for the parser (to be implemented in Task 3):
- "fae switch to claude" → SwitchModel(ByProvider("anthropic"))
- "use the local model" → SwitchModel(Local)
- "switch to gpt-4o" → SwitchModel(ByName("gpt-4o"))
- "use the best model" → SwitchModel(Best)
- "what model are you using" → CurrentModel
- "list models" → ListModels
- "hello how are you" → None (not a command)
- "switch to the flagship model" → SwitchModel(Best)
- Case insensitivity: "FAE SWITCH TO CLAUDE" → same result
- Partial match: "could you switch to claude please" → SwitchModel

Tests call `parse_voice_command(&str) -> Option<VoiceCommand>` which doesn't exist yet.
Mark tests with `#[ignore]` so they compile but skip until Task 3.

## Task 3: Implement parse_voice_command()
**~80 lines | src/voice_command.rs**

Implement `pub fn parse_voice_command(text: &str) -> Option<VoiceCommand>`:
- Lowercase and trim input
- Match patterns:
  - "switch to {target}" / "use {target}" / "change to {target}"
  - "what model" / "which model" / "current model" → CurrentModel
  - "list models" / "show models" / "available models" → ListModels
- Parse target:
  - "local" / "local model" / "offline" → ModelTarget::Local
  - "best" / "best model" / "flagship" → ModelTarget::Best
  - "claude" / "anthropic" → ModelTarget::ByProvider("anthropic")
  - "gpt" / "openai" → ModelTarget::ByProvider("openai")
  - "gemini" / "google" → ModelTarget::ByProvider("google")
  - Anything else → ModelTarget::ByName(target_string)
- No regex — use simple string contains/starts_with patterns
- Remove `#[ignore]` from Task 2 tests; all must pass

## Task 4: Model name resolution
**~60 lines | src/voice_command.rs**

Implement `pub fn resolve_model_target(target: &ModelTarget, candidates: &[ProviderModelRef]) -> Option<usize>`:
- `ModelTarget::Local` → find candidate where `provider == FAE_PROVIDER_KEY`
- `ModelTarget::Best` → return index 0 (candidates are pre-sorted by tier)
- `ModelTarget::ByProvider(p)` → find first candidate matching provider (case-insensitive)
- `ModelTarget::ByName(n)` → find first candidate where model contains name (case-insensitive)
- Returns `Option<usize>` — index into candidates array
- Add tests for each target type with mock candidates

## Task 5: RuntimeEvent variants for voice commands
**~20 lines | src/runtime.rs**

Add new variants to `RuntimeEvent`:
- `VoiceCommandDetected { command: String }` — human-readable description of detected command
- `ModelSwitchRequested { target: String }` — model switch was requested (before execution)

Keep payloads as simple Strings (lightweight, no heavy types crossing channel).

## Task 6: VoiceCommandFilter stage in pipeline
**~70 lines | src/pipeline/coordinator.rs**

Add `run_voice_command_filter()` async function:
- Receives `mpsc::Receiver<Transcription>` from identity gate
- Sends non-command transcriptions to `mpsc::Sender<Transcription>` (to LLM)
- Sends detected commands to `mpsc::UnboundedSender<VoiceCommand>` (new channel)
- Emits `RuntimeEvent::VoiceCommandDetected` via broadcast
- Only inspects `is_final` transcriptions (ignore partials)

Wire it into `PipelineCoordinator::run()`:
- Create new channel pair for voice commands
- Insert filter between identity gate output and LLM input
- Pass voice_command_tx through to where PiLlm will consume it (Phase 2.2)

## Task 7: Integration tests
**~80 lines | src/voice_command.rs**

Add integration-style tests that verify the full flow:
- parse_voice_command() → resolve_model_target() with real candidates
- Test that non-commands return None and don't affect candidate resolution
- Test edge cases: empty string, very long string, unicode, numbers
- Test that "fae" prefix is optional
- Test multiple command synonyms resolve to same VoiceCommand variant
- Verify ModelTarget::ByName partial matching works across the tier table

## Task 8: Documentation and verification
**~30 lines | src/voice_command.rs, src/lib.rs**

- Add module-level doc comment with examples and supported command list
- Add doc comments on all public items
- Verify `just check` passes (zero warnings, zero errors)
- Verify all tests pass
- Update progress.md

---

## Acceptance Criteria
- [ ] `parse_voice_command()` correctly detects switch/list/current commands
- [ ] `resolve_model_target()` maps voice targets to candidate indices
- [ ] VoiceCommandFilter stage wired into pipeline (receives transcriptions, emits commands)
- [ ] RuntimeEvent variants emitted for detected commands
- [ ] Non-command transcriptions pass through unchanged
- [ ] Partial transcriptions are never treated as commands
- [ ] `just check` passes with zero warnings
- [ ] All new code has doc comments
