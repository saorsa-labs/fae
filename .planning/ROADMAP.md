# Intelligent Model Selection & Runtime Switching — Roadmap

## Overview
Fae currently has no intelligence about which LLM is "best" — she just uses whatever's hardcoded or configured in TOML. This feature adds three-layer model selection (embedded tier list, user priority override, interactive startup picker) and runtime voice switching so users can say "use the local model" or "switch to Claude" mid-conversation.

## Success Criteria
- Fae auto-selects the most capable available model at startup
- User can override via `priority` field in Pi's models.json
- When multiple top-tier models exist, Fae presents a canvas list and asks
- Voice commands switch models at runtime with spoken acknowledgment
- Graceful fallback to local `fae-qwen3` when no cloud models are reachable
- Production ready: complete, tested, documented

## Technical Decisions
- Error Handling: Dedicated error types via `thiserror` (`SpeechError`)
- Async Model: Tokio (match existing codebase)
- Testing: Unit + Integration (TDD, tests first)
- Task Size: Smallest possible (~50 lines each)

---

## Milestone 1: Intelligent Model Selection Core

### Phase 1.1: Model Tier Registry
- **Focus**: Embedded static tier list mapping known model IDs to capability tiers
- **Deliverables**: `src/model_tier.rs` with `ModelTier` enum, `tier_for_model()` lookup, pattern-based matching for model ID families
- **Dependencies**: None (pure data + logic)
- **Estimated Tasks**: 6-8

### Phase 1.2: Priority-Aware Candidate Resolution
- **Focus**: Rewrite `resolve_pi_model_candidates()` to sort by tier + user priority; add `priority` field to `PiModel`
- **Deliverables**: Updated `pi_config.rs` (priority field), updated `engine.rs` (sorted candidates), `ProviderModelRef` gains tier + priority
- **Dependencies**: Phase 1.1 (tier registry)
- **Estimated Tasks**: 6-8

### Phase 1.3: Startup Model Selection
- **Focus**: Auto-select best model at startup; interactive canvas list when multiple top-tier models are available
- **Deliverables**: Startup selection flow in `startup.rs`/`coordinator.rs`, canvas-based picker UI, timeout with auto-select fallback
- **Dependencies**: Phase 1.2 (sorted candidates)
- **Estimated Tasks**: 6-8

---

## Milestone 2: Runtime Voice Switching

### Phase 2.1: Voice Command Detection
- **Focus**: Pattern matching for model-switch phrases in transcriptions before LLM generation
- **Deliverables**: `src/voice_command.rs` with command parser, integration point in LLM stage
- **Dependencies**: Milestone 1 complete (model selection infra)
- **Estimated Tasks**: 6-8

### Phase 2.2: Live Model Switching
- **Focus**: Runtime model switch via PiLlm, spoken acknowledgment via TTS, session management
- **Deliverables**: `switch_model_by_command()` in `PiLlm`, acknowledgment flow, edge case handling (switch during generation, unavailable model)
- **Dependencies**: Phase 2.1 (command detection)
- **Estimated Tasks**: 6-8

### Phase 2.3: Integration & Polish
- **Focus**: GUI display of active model, canvas status, help/list commands, documentation
- **Deliverables**: GUI model indicator, "what model are you using?" voice query, "list models" command, full test suite, docs
- **Dependencies**: Phase 2.2 (live switching)
- **Estimated Tasks**: 6-8

---

## Risks & Mitigations
- **Stale tier list**: Model landscape changes fast → mitigate with pattern-based matching (e.g., `claude-opus-*` → tier 0) and user priority override
- **Voice command false positives**: "switch to Claude" in normal conversation → mitigate with prefix pattern ("Fae, switch to Claude") and confidence threshold
- **Pi session restart on model switch**: Switching provider/model may require Pi subprocess restart → mitigate by testing session continuity vs. restart semantics

## Out of Scope
- Dynamic benchmark fetching (no web search)
- Automatic cost optimization (cheapest model for task)
- Multi-model routing (different models for different tasks)
- Model fine-tuning or custom model registration UI
