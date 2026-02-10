# Code Simplifier Review

## Findings

### TtsEngine Enum Dispatch

- [MINOR] The `TtsEngine` enum wrapper with manual dispatch could be replaced with a trait object | FILE: src/pipeline/coordinator.rs:1593-1610
  - Current pattern: `enum TtsEngine { Kokoro(Box<KokoroTts>), FishSpeech(FishSpeechTts) }` with manual match dispatch in `synthesize()`
  - Alternative: Define `trait TtsBackend { async fn synthesize(&mut self, text: &str) -> Result<Vec<f32>> }` and use `Box<dyn TtsBackend>`
  - Trade-off: Trait object would be slightly cleaner but current enum is more explicit and has minimal match boilerplate (single method)
  - Verdict: Current approach is acceptable for 2 variants and 1 method. Trait would be better if more methods or variants are added

- [INFO] Kokoro backend is boxed but FishSpeech is not | FILE: src/pipeline/coordinator.rs:1595,1598
  - Asymmetry suggests FishSpeech is smaller than Kokoro
  - If true, this is correct. If sizes are similar, both should be boxed for consistency
  - Recommendation: Document size rationale or box both for consistency

### Startup Backend Selection

- [INFO] Backend selection logic is clean and explicit | FILE: src/startup.rs:63,82-102
  - `use_local_llm` flag is clear: `matches!(config.llm.backend, LlmBackend::Local | LlmBackend::Agent)`
  - Conditional TTS loading: `if matches!(config.tts.backend, TtsBackend::Kokoro)`
  - No issues here — straightforward and readable

- [MINOR] Redundant println statements could be consolidated | FILE: src/startup.rs:93-100
  - Both branches of TTS selection print similar messages
  - Could extract common formatting logic
  - Impact: Low (only 2 branches, messages are clear)

### Feature-Gated Code Clarity

- [IMPORTANT] Fish Speech feature gating creates nested complexity | FILE: src/pipeline/coordinator.rs:1634-1650
  - Nested `#[cfg(feature = "fish-speech")]` blocks with duplicated error handling
  - Current structure:
    ```rust
    TtsBackend::FishSpeech => {
        #[cfg(feature = "fish-speech")]
        { /* init code */ }
        #[cfg(not(feature = "fish-speech"))]
        { /* error */ }
    }
    ```
  - Improvement: Extract to helper function or use conditional compilation at call site
  - Impact: Moderate — this pattern will repeat if more backends are added

### TTS Module Structure

- [INFO] Clean module separation | FILE: src/tts/mod.rs:1-16
  - Conditional `pub mod fish_speech` and `pub use` based on feature
  - No issues — standard Rust practice

### Config Enums

- [INFO] TtsBackend and LlmBackend enums are well-structured | FILE: src/config.rs:146-174,358-367
  - Clear defaults, explicit serde aliases
  - No simplification needed

### General Patterns

- [INFO] No redundant error handling patterns detected
  - Error propagation is consistent
  - No unnecessary `.map_err()` chains

- [INFO] No overly complex nested ternaries
  - Code uses explicit `if`/`match` statements appropriately

- [INFO] Variable naming is clear and consistent
  - `preloaded_*`, `use_local_llm`, `engine` — all self-documenting

## Recommendations

1. **Extract feature-gated TTS initialization** (lines 1634-1650 in coordinator.rs)
   - Move to helper function: `fn init_tts_engine(config: &TtsConfig, preloaded: Option<KokoroTts>) -> Result<TtsEngine>`
   - Reduces nesting and makes match arm cleaner

2. **Consider trait-based dispatch for TTS if more backends are planned**
   - Current enum is fine for 2 backends + 1 method
   - Trait object (`Box<dyn TtsBackend>`) would scale better beyond 3+ backends

3. **Document or fix Kokoro boxing asymmetry**
   - Either document why Kokoro is boxed and FishSpeech is not
   - Or box both for consistency

## Verdict: PASS

The code is clean, explicit, and maintainable. The identified issues are minor and do not represent blockers. The current structure balances clarity with performance.

**Key strengths:**
- Clear separation of backend selection logic
- Explicit enum dispatch (not overly clever)
- Consistent error handling
- No nested ternaries or cryptic one-liners

**Potential improvements are optional optimizations, not correctness issues.**
