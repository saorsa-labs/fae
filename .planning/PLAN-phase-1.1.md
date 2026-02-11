# Phase 1.1: Model Tier Registry — Task Plan

## Goal
Create an embedded static tier list mapping known model IDs to capability tiers. Pure data + logic module with zero external dependencies.

## Deliverable
`src/model_tier.rs` — `ModelTier` enum, `tier_for_model()` lookup, pattern-based matching for model families.

---

## Tasks (TDD Order)

### Task 1: Define `ModelTier` enum, core types, and wire module
**Files:** `src/model_tier.rs` (new), `src/lib.rs` (add module)
**Description:**
- Create `src/model_tier.rs` with module-level docs
- Define `ModelTier` enum: `Flagship`, `Strong`, `Mid`, `Small`, `Unknown`
  - Derive: `Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash`
  - `Flagship` < `Strong` < `Mid` < `Small` < `Unknown` (lower = better)
- Implement `Display` for `ModelTier` (human-readable names)
- Add `ModelTier::rank(&self) -> u8` method (0 = Flagship, 4 = Unknown)
- Wire into `lib.rs` as `pub mod model_tier;`
- Write unit tests for ordering, display, and rank

### Task 2: Implement pattern matching engine with tests
**Files:** `src/model_tier.rs`
**Description:**
- Implement `fn matches_pattern(model_id: &str, pattern: &str) -> bool`
  - Case-insensitive comparison
  - Support `*` wildcard at end (prefix match) and start (suffix match)
  - Support `*` in middle (contains match)
  - Exact match when no wildcard
- Implement `fn normalize_model_id(id: &str) -> String` — lowercase, trim whitespace
- Write comprehensive tests for pattern matching:
  - Exact: "gpt-4o" matches "gpt-4o"
  - Prefix: "claude-opus-*" matches "claude-opus-4-20250514"
  - Suffix: "*-instruct" matches "qwen3-4b-instruct"
  - Case: "GPT-4o" matches "gpt-4o"
  - No match: "gpt-3.5" does NOT match "gpt-4o"

### Task 3: Build static tier table with known models
**Files:** `src/model_tier.rs`
**Description:**
- Define `struct TierEntry { pattern: &'static str, tier: ModelTier }`
- Create `TIER_TABLE: &[TierEntry]` ordered from most-specific to least-specific:
  - **Flagship:** claude-opus-*, o1-*, o3-*, gpt-4o (exact), gpt-4-turbo*, gemini-*-pro, deepseek-r1
  - **Strong:** claude-sonnet-*, gpt-4 (exact), gemini-*-flash*, llama-3*-405b*, qwen3-235b*, command-r-plus*, mistral-large*
  - **Mid:** claude-haiku-*, gpt-4o-mini*, gpt-3.5*, llama-3*-70b*, qwen3-32b*, qwen3-14b*, mixtral*, command-r, phi-4*
  - **Small:** llama-3*-8b*, qwen3-4b*, qwen3-1.7b*, phi-3-mini*, gemma-*, mistral-7b*, fae-qwen3
- IMPORTANT: Order matters — `gpt-4o-mini` must match Mid BEFORE `gpt-4o` matches Flagship
- Write tests for at least 2 models per tier

### Task 4: Implement `tier_for_model()` public API
**Files:** `src/model_tier.rs`
**Description:**
- Implement `pub fn tier_for_model(model_id: &str) -> ModelTier`
  - Normalize the model_id
  - Walk TIER_TABLE looking for first match
  - Return `ModelTier::Unknown` if no match
- Implement `pub fn tier_for_provider_model(provider: &str, model_id: &str) -> ModelTier`
  - Check `PROVIDER_OVERRIDES` first (provider+model specific entries)
  - Fall back to `tier_for_model()` for pure ID-based lookup
- Define `PROVIDER_OVERRIDES: &[(provider, model_pattern, tier)]` for:
  - ("fae-local", "fae-qwen3", Small) — local fallback always Small
- Write tests for known models, unknown models, and provider overrides

### Task 5: Handle tricky edge cases and provider-specific patterns
**Files:** `src/model_tier.rs`
**Description:**
- Ensure these edge cases are handled correctly (add to TIER_TABLE or PROVIDER_OVERRIDES):
  - `gpt-4o-mini` → Mid (not Flagship — must come before `gpt-4o` pattern)
  - `claude-3-5-sonnet-*` → Strong (sonnet family)
  - `claude-3-5-haiku-*` → Mid (haiku family)
  - `gemini-2.0-flash-thinking-exp` → Strong (flash family)
  - `deepseek-v3` → Strong (not r1)
  - Version suffixes: `claude-sonnet-4-20250514` → Strong
- Write targeted tests for each edge case
- Run `just check` to verify zero warnings

### Task 6: Documentation and final validation
**Files:** `src/model_tier.rs`, `src/lib.rs`
**Description:**
- Add module-level documentation with overview and usage examples
- Add doc comments with `/// # Examples` blocks on all public items:
  - `ModelTier` enum
  - `tier_for_model()`
  - `tier_for_provider_model()`
  - `ModelTier::rank()`
- Ensure doc examples compile (`cargo test --doc`)
- Run full validation: `just check`
- Verify: zero warnings, zero errors, all tests pass, all docs present

---

## File Change Summary

| File | Action |
|------|--------|
| `src/model_tier.rs` | **NEW** — Core deliverable |
| `src/lib.rs` | **MODIFY** — Add `pub mod model_tier;` |

## Quality Gates
- `just check` passes (fmt, lint, build, test, doc, panic-scan)
- Zero `.unwrap()` or `.expect()` in production code
- 100% public API documentation with examples
- All tests pass
