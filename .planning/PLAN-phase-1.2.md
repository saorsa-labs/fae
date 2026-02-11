# Phase 1.2: Priority-Aware Candidate Resolution — Task Plan

## Goal
Rewrite `resolve_pi_model_candidates()` to sort candidates by tier + user priority. Add `priority` field to `PiModel` and tier/priority to `ProviderModelRef`.

## Dependencies
- Phase 1.1 (model_tier.rs) — COMPLETE

---

## Tasks (TDD Order)

### Task 1: Add `priority` field to `PiModel`
**Files:** `src/llm/pi_config.rs`
**Description:**
- Add `#[serde(default)] pub priority: Option<i32>` to `PiModel` struct (after `compat` field, before `extra`)
- Default is `None` (treated as 0 during sorting)
- Higher priority = preferred within same tier
- Write test: deserialize a models.json snippet with and without priority field
- Ensure backward compatibility: existing models.json files without priority still parse

### Task 2: Add tier and priority fields to `ProviderModelRef`
**Files:** `src/pi/engine.rs`
**Description:**
- Add `tier: ModelTier` and `priority: i32` to `ProviderModelRef` struct
- Import `crate::model_tier::{ModelTier, tier_for_provider_model}`
- Update `ProviderModelRef::display()` to optionally show tier
- Add `ProviderModelRef::new(provider, model, priority)` constructor that auto-computes tier
- Update all existing construction sites (the `push` closure in `resolve_pi_model_candidates`)
- Write test: constructing ProviderModelRef sets correct tier

### Task 3: Look up tier and priority during candidate resolution
**Files:** `src/pi/engine.rs`
**Description:**
- In `resolve_pi_model_candidates()`, when reading from pi_config:
  - Look up `PiModel.priority` for each model via `pi_config.find_model()`
  - Pass priority to `ProviderModelRef::new()`
- For models NOT in pi_config (e.g. from config.cloud_provider):
  - Use priority 0 (default)
- The tier is computed automatically by `ProviderModelRef::new()`
- Write test: candidates from pi_config carry correct priority values

### Task 4: Sort candidates by (tier, -priority)
**Files:** `src/pi/engine.rs`
**Description:**
- After building the candidate list, sort it:
  ```rust
  out.sort_by(|a, b| {
      a.tier.cmp(&b.tier)
          .then_with(|| b.priority.cmp(&a.priority))
  });
  ```
- This puts:
  1. Best tier first (Flagship < Strong < Mid < Small < Unknown)
  2. Within same tier, highest priority first
- Write test: verify sort order with mixed tiers and priorities
- Write test: verify fae-local fallback is still present but sorted to correct position

### Task 5: Update `pick_failover_candidate` to respect new ordering
**Files:** `src/pi/engine.rs`
**Description:**
- Read current `pick_failover_candidate()` implementation
- Ensure it respects the new pre-sorted order (it already picks next untried candidate)
- Verify that network errors still prefer fae-local (or verify it's sorted appropriately)
- Write test: failover walks candidates in tier order

### Task 6: Integration tests and documentation
**Files:** `src/pi/engine.rs`, `src/llm/pi_config.rs`
**Description:**
- Add integration test: full resolution with multiple providers and priorities
- Add doc comments to new/modified public items
- Run `just check` — full validation
- Verify: zero warnings, zero errors, all tests pass

---

## File Change Summary

| File | Action |
|------|--------|
| `src/llm/pi_config.rs` | **MODIFY** — Add `priority` to `PiModel` |
| `src/pi/engine.rs` | **MODIFY** — Add tier/priority to `ProviderModelRef`, sort candidates |

## Key Types After Changes

```rust
// pi_config.rs
pub struct PiModel {
    pub id: String,
    // ... existing fields ...
    #[serde(default)]
    pub priority: Option<i32>,  // NEW
    #[serde(default, flatten)]
    pub extra: HashMap<String, serde_json::Value>,
}

// engine.rs
struct ProviderModelRef {
    provider: String,
    model: String,
    tier: ModelTier,    // NEW — from model_tier::tier_for_provider_model()
    priority: i32,      // NEW — from PiModel.priority or 0
}
```

## Quality Gates
- `just check` passes
- Zero `.unwrap()` or `.expect()` in production code
- Backward-compatible with existing models.json files
- Existing tests still pass
- fae-local fallback still works correctly
