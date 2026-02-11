# Model Selection Architecture

This document describes the internal architecture of Fae's intelligent model selection and runtime switching system.

## Overview

The model selection system has three layers:

1. **Tier Registry** — Static capability ranking of known models
2. **Priority Resolution** — Combines tier + user priority to sort candidates
3. **Startup Selection** — Auto-select or interactive picker flow

Runtime switching adds a fourth layer:

4. **Voice Command Pipeline** — Parse → Resolve → Switch with TTS acknowledgment

## Three-Layer Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  LAYER 1: Tier Registry                                     │
│  Static tier list: claude-opus-4 → tier 0 (highest)        │
│                    gpt-4o → tier 1                          │
│                    fae-qwen3 → tier 3 (local)               │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  LAYER 2: Priority-Aware Resolution                         │
│  Combines tier + user priority field from models.json       │
│  Sorts candidates: (tier ASC, priority DESC)                │
│  Output: Vec<ProviderModelRef> sorted best-first            │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  LAYER 3: Startup Selection                                 │
│  - If 1 candidate: auto-select                              │
│  - If multiple with same (tier, priority): show picker      │
│  - Timeout (30s): auto-select first                         │
│  Output: Selected ProviderModelRef                          │
└─────────────────────────────────────────────────────────────┘
```

## Layer 1: Tier Registry

**File:** `src/model_tier.rs`

### Tier Enum

```rust
pub enum ModelTier {
    Tier0, // Frontier flagship models (Claude Opus 4, GPT-4.5, Gemini 2.0 Ultra)
    Tier1, // High-capability (GPT-4o, Claude Sonnet 3.7, Gemini 2.0 Flash)
    Tier2, // Mid-tier (GPT-4o Mini, Claude Haiku, Llama 3.3 70B)
    Tier3, // Local/on-device (Qwen 3 4B, Llama 3.2 3B)
}
```

### Tier Assignment

```rust
pub fn tier_for_model(model_id: &str) -> ModelTier {
    // Pattern-based matching for known model families
    if model_id.contains("claude-opus-4") { return ModelTier::Tier0; }
    if model_id.contains("gpt-4.5") { return ModelTier::Tier0; }
    if model_id.contains("gemini-2.0-ultra") { return ModelTier::Tier0; }
    // ... more patterns
}
```

**Design:** Pattern-based matching allows handling of new model versions (e.g., `claude-opus-4.1`) without code changes.

### Tier Ordering

Lower tier number = higher capability. When sorting candidates:
- Tier 0 < Tier 1 < Tier 2 < Tier 3
- Same tier → sort by user `priority` field (higher = better)

## Layer 2: Priority-Aware Resolution

**File:** `src/model_selection.rs`

### ProviderModelRef

```rust
pub struct ProviderModelRef {
    pub provider: String,      // e.g., "anthropic"
    pub model: String,         // e.g., "claude-opus-4"
    pub priority: i32,         // User-defined priority (default: 0)
}
```

### Candidate Sorting

```rust
fn resolve_pi_model_candidates(models_by_provider: HashMap<String, Vec<PiModel>>)
    -> Vec<ProviderModelRef>
{
    let mut candidates = Vec::new();

    for (provider, models) in models_by_provider {
        for model in models {
            let tier = tier_for_model(&model.model);
            let priority = model.priority.unwrap_or(0);
            candidates.push(ProviderModelRef {
                provider: provider.clone(),
                model: model.model.clone(),
                priority,
                tier, // (internal only, not in public struct)
            });
        }
    }

    // Sort: (tier ASC, priority DESC)
    candidates.sort_by(|a, b| {
        a.tier.cmp(&b.tier)
            .then_with(|| b.priority.cmp(&a.priority))
    });

    candidates
}
```

**Output:** Sorted vec where `candidates[0]` is the best available model.

## Layer 3: Startup Selection

**Files:** `src/model_picker.rs`, `src/model_selection.rs`, `src/pipeline/coordinator.rs`

### Selection Flow

```rust
enum ModelSelectionDecision {
    AutoSelect(ProviderModelRef),       // 1 candidate or clear winner
    Prompt(Vec<ProviderModelRef>),     // Multiple top-tier, need user choice
}

fn decide_startup_model(candidates: &[ProviderModelRef]) -> ModelSelectionDecision {
    if candidates.is_empty() {
        panic!("No models configured");
    }

    if candidates.len() == 1 {
        return AutoSelect(candidates[0].clone());
    }

    let best_tier = candidates[0].tier;
    let best_priority = candidates[0].priority;

    let top_tier_candidates: Vec<_> = candidates.iter()
        .take_while(|c| c.tier == best_tier && c.priority == best_priority)
        .cloned()
        .collect();

    if top_tier_candidates.len() == 1 {
        AutoSelect(top_tier_candidates[0].clone())
    } else {
        Prompt(top_tier_candidates)
    }
}
```

### Interactive Picker

When `Prompt` is returned:

1. Emit `RuntimeEvent::ModelSelectionPrompt { candidates, timeout_secs: 30 }`
2. GUI displays list with "provider/model" labels
3. User selects via GUI or voice
4. If no selection after 30s → auto-select `candidates[0]`
5. Emit `RuntimeEvent::ModelSelected { provider_model }`

**Channel:** `oneshot::Receiver<usize>` for GUI → coordinator selection response

## Runtime Voice Switching

### Voice Command Detection

**File:** `src/voice_command.rs`

```rust
pub enum VoiceCommand {
    SwitchModel { target: ModelTarget },
    ListModels,
    CurrentModel,
    Help,
}

pub enum ModelTarget {
    ByName(String),        // "gpt-4o"
    ByProvider(String),    // "anthropic"
    Local,                 // "local", "offline"
    Best,                  // "best", "flagship"
}
```

### Parsing Flow

```
User speech: "Fae, switch to Claude"
      ↓
STT: "fae switch to claude"
      ↓
parse_voice_command():
  1. Strip wake prefix: "switch to claude"
  2. Match pattern: "switch to {X}"
  3. parse_model_target("claude"):
     - Known provider → ModelTarget::ByProvider("anthropic")
      ↓
VoiceCommand::SwitchModel { target: ByProvider("anthropic") }
```

### Target Resolution

```rust
pub fn resolve_model_target(
    target: &ModelTarget,
    candidates: &[ProviderModelRef]
) -> Option<usize> {
    match target {
        ModelTarget::Best => Some(0), // candidates[0] is best (pre-sorted)
        ModelTarget::Local => candidates.iter()
            .position(|c| c.provider == "fae-local"),
        ModelTarget::ByProvider(provider) => candidates.iter()
            .position(|c| c.provider.eq_ignore_ascii_case(provider)),
        ModelTarget::ByName(name) => candidates.iter()
            .position(|c| c.model.to_lowercase().contains(&name.to_lowercase())),
    }
}
```

**Returns:** Index into `candidates` vec, or `None` if not found.

### Pipeline Integration

**File:** `src/pipeline/coordinator.rs`

```
LLM Stage Event Loop:
  ┌─────────────────────────────────────────────────┐
  │  select! {                                       │
  │    transcription = stt_rx.recv()                 │
  │    voice_cmd = voice_cmd_rx.recv()  ← NEW      │
  │    text_injection = text_rx.recv()               │
  │  }                                               │
  └─────────────────────────────────────────────────┘
              ↓ (voice_cmd received)
  ┌─────────────────────────────────────────────────┐
  │  handle_voice_command(&cmd, &mut llm_engine)    │
  │    match cmd {                                   │
  │      SwitchModel { target } =>                   │
  │        pi.switch_model_by_voice(target)          │
  │      ListModels =>                               │
  │        list_models_response(&pi.list_models())   │
  │      CurrentModel =>                             │
  │        current_model_response(&pi.current_model)│
  │      Help =>                                     │
  │        help_response()                           │
  │    }                                             │
  └─────────────────────────────────────────────────┘
              ↓ (response string)
  ┌─────────────────────────────────────────────────┐
  │  Send to TTS (bypasses LLM generation)          │
  └─────────────────────────────────────────────────┘
```

**Key:** Voice commands short-circuit the LLM — the response is spoken directly without consulting the model.

### Switch Internals

**File:** `src/pi/engine.rs`

```rust
pub fn switch_model_by_voice(&mut self, target: &ModelTarget) -> Result<String, String> {
    let idx = resolve_model_target(target, &self.candidates)
        .ok_or_else(|| format!("Model not found: {target:?}"))?;

    if idx == self.active_index {
        return Ok(already_using_acknowledgment(&self.current_model_name()));
    }

    // Interrupt ongoing generation (if any)
    self.interrupt_flag.store(true, Ordering::Relaxed);

    // Switch active index
    self.active_index = idx;

    // Emit runtime event
    let _ = self.event_tx.send(RuntimeEvent::ModelSelected {
        provider_model: self.current_model_name(),
    });

    Ok(switch_acknowledgment(&self.current_model_name()))
}
```

**Edge Cases:**
- Switch during generation → interrupt flag set, generation stops cleanly
- Switch to same model → no-op, returns "already using" message
- Switch to unavailable model → returns error, automatic fallback to previous model

### TTS Acknowledgment

**File:** `src/voice_command.rs`

```rust
pub fn switch_acknowledgment(model_name: &str) -> String {
    format!("Switching to {model_name}.")
}

pub fn already_using_acknowledgment(model_name: &str) -> String {
    format!("I'm already using {model_name}.")
}

pub fn model_not_found_response(target: &str) -> String {
    format!("I couldn't find a model matching {target}.")
}
```

These are sent directly to TTS, bypassing LLM generation.

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  STARTUP: Model Selection                                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Load models.json                                        │
│     ↓                                                       │
│  2. Assign tiers (model_tier::tier_for_model)               │
│     ↓                                                       │
│  3. Sort by (tier, priority)                                │
│     ↓                                                       │
│  4. Decide: AutoSelect or Prompt                            │
│     ↓                                                       │
│  5. If Prompt:                                              │
│     - Emit ModelSelectionPrompt event                       │
│     - Wait for user selection (max 30s)                     │
│     - Emit ModelSelected event                              │
│     ↓                                                       │
│  6. Start LLM with selected model                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  RUNTIME: Voice Command Switch                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. User speech → STT → "switch to claude"                  │
│     ↓                                                       │
│  2. VoiceCommandFilter (pipeline stage):                    │
│     - parse_voice_command() → VoiceCommand::SwitchModel     │
│     - Emit VoiceCommandDetected event                       │
│     - Send to voice_cmd_tx channel                          │
│     ↓                                                       │
│  3. LLM Stage receives voice_cmd:                           │
│     - handle_voice_command(&cmd, &mut llm_engine)           │
│     - PiLlm::switch_model_by_voice()                        │
│     ↓                                                       │
│  4. Switch logic:                                           │
│     - resolve_model_target() → candidate index              │
│     - Set active_index                                      │
│     - Emit ModelSelected event (GUI updates)                │
│     - Return acknowledgment string                          │
│     ↓                                                       │
│  5. Acknowledgment → TTS → "Switching to Claude Opus 4."    │
│     ↓                                                       │
│  6. Continue conversation with new model                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Testing Strategy

### Unit Tests

**voice_command.rs:**
- Parse all command patterns
- Resolve targets against candidate list
- TTS acknowledgment formatting
- Edge cases (unicode, long input, whitespace)

**model_selection.rs:**
- Tier assignment for known models
- Candidate sorting by (tier, priority)
- Decision logic (AutoSelect vs Prompt)

**coordinator.rs:**
- handle_voice_command() for each command type
- Integration with mock PiLlm engine

### Integration Tests

**End-to-end flows:**
- Parse → Resolve → Switch
- ListModels produces correct spoken output
- CurrentModel returns active model
- Help returns command list

**Edge cases:**
- Model not found → fallback
- Switch during generation → interrupt
- Switch to same model → no-op

### Manual Testing

**Visual verification:**
- GUI topbar shows active model
- Model indicator updates on switch
- Picker UI displays candidates correctly

**Voice verification:**
- Speak commands and verify TTS responses
- Test wake word prefix variations
- Test synonym coverage ("change to" = "switch to")

## Adding New Model Tiers

**To add a new model to the tier registry:**

1. Edit `src/model_tier.rs`:
   ```rust
   pub fn tier_for_model(model_id: &str) -> ModelTier {
       // Add pattern match for new model
       if model_id.contains("new-model-name") {
           return ModelTier::Tier0; // or appropriate tier
       }
       // ... existing patterns
   }
   ```

2. Add test case:
   ```rust
   #[test]
   fn tier_new_model() {
       assert_eq!(tier_for_model("new-model-name"), ModelTier::Tier0);
   }
   ```

3. Run tests:
   ```bash
   cargo test tier_new_model
   ```

**No changes needed in:**
- Voice command parsing (works with any provider/model name)
- Resolution logic (uses runtime candidate list)
- GUI (displays any "provider/model" string)

## Configuration

### models.json Format

```json
{
  "providers": {
    "anthropic": {
      "api_key": "sk-ant-...",
      "models": [
        {
          "model": "claude-opus-4",
          "priority": 50
        },
        {
          "model": "claude-sonnet-3.7"
        }
      ]
    },
    "openai": {
      "api_key": "sk-proj-...",
      "models": [
        {
          "model": "gpt-4o",
          "priority": 100
        }
      ]
    },
    "fae-local": {
      "models": [
        {
          "model": "fae-qwen3"
        }
      ]
    }
  }
}
```

**Fields:**
- `priority` (optional): Higher values preferred. Default: 0.
- `model`: Exact model ID string (case-sensitive for API calls).

### Priority Override Example

To prefer GPT-4o over Claude Opus 4 (despite lower tier):

```json
{
  "providers": {
    "openai": {
      "models": [
        {
          "model": "gpt-4o",
          "priority": 100
        }
      ]
    },
    "anthropic": {
      "models": [
        {
          "model": "claude-opus-4",
          "priority": 50
        }
      ]
    }
  }
}
```

**Result:** GPT-4o selected (both Tier 0, but priority 100 > 50).

## Future Work

### Considered but Deferred

- **Dynamic benchmarking**: Fetch live benchmark scores from web sources
- **Cost optimization**: Switch to cheaper models for simple tasks
- **Multi-model routing**: Use different models for different task types
- **Custom tier definitions**: User-defined tier lists in config

### Potential Enhancements

- **Model health checking**: Ping providers at startup, hide unavailable models
- **Usage tracking**: Log which models are used most
- **Model recommendations**: Suggest model switches based on query type
- **Batch switching**: "Use Claude for coding, GPT for creative writing"

## See Also

- [User Guide](../model-switching.md) — End-user documentation
- [ROADMAP.md](../../.planning/ROADMAP.md) — Project plan and milestones
- [Phase 2.1-2.3 Plans](../../.planning/) — Detailed task breakdowns
