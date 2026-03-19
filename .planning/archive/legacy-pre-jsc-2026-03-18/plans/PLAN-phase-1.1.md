# PLAN-phase-1.1: Linker Anchor & Anti-Dead-Strip

**Status:** Ready to implement
**Phase:** 1.1 — Linker Anchor
**Milestone:** 1 — Core Pipeline & Linker Fix

---

## Problem Statement

SPM links `libfae.a` with `-force_load` then `-dead_strip`. The 8 exported FFI functions route through stub handlers that never construct PipelineCoordinator, ParakeetStt, KokoroTts, LocalLlm, CpalCapture, CpalPlayback, SileroVad, or AecProcessor. Linker strips all ML/audio code → binary drops from ~100MB to 9MB.

**Fix:** Rust-side anchor function exported as `extern "C"` that holds `black_box` references to all subsystem constructors. Called from `fae_core_init` to ensure reachability.

---

## Tasks

### Task 1: Create `src/linker_anchor.rs` skeleton

**Description:** Create the module with `fae_keep_alive` exported as `extern "C"`. Initial implementation anchors only `SpeechConfig::default()` via `black_box`.

**Files:**
- `src/linker_anchor.rs` (new)
- `src/lib.rs` (add `pub mod linker_anchor;`)

**Acceptance:**
- `cargo build --release` passes
- `nm` shows `_fae_keep_alive` in libfae.a
- Zero clippy warnings

---

### Task 2: Anchor PipelineCoordinator and InitializedModels

**Description:** Extend `fae_keep_alive` to reference `PipelineCoordinator::new` and `PipelineCoordinator::with_models` via function pointer anchors in the `black_box(false)` guard block.

**Files:** `src/linker_anchor.rs`

**Acceptance:**
- `nm libfae.a | grep PipelineCoordinator` returns > 0
- Zero clippy warnings

---

### Task 3: Anchor ParakeetStt, LocalLlm, KokoroTts

**Description:** Add function pointer anchors for the three ML model constructors: `ParakeetStt::new`, `LocalLlm::new` (async fn), `KokoroTts::from_paths`/`KokoroTts::new`.

**Files:** `src/linker_anchor.rs`

**Acceptance:**
- `nm libfae.a | grep -c mistralrs` or `grep -c parakeet` returns > 0
- Archive size > 50MB
- Zero clippy warnings

---

### Task 4: Anchor audio subsystem (CpalCapture, CpalPlayback, SileroVad, AecProcessor)

**Description:** Add function pointer anchors for audio capture, playback, VAD, and AEC constructors.

**Files:** `src/linker_anchor.rs`

**Acceptance:**
- `nm libfae.a | grep cpal` returns > 0
- Zero clippy warnings

---

### Task 5: Wire anchor into fae_core_init

**Description:** Add `black_box(fae_keep_alive as usize)` near the top of `fae_core_init` in `src/ffi.rs`. Update `fae.h` to declare the anchor symbol.

**Files:**
- `src/ffi.rs`
- `native/macos/FaeNativeApp/Sources/CLibFae/include/fae.h`

**Acceptance:**
- `cargo build --release` passes
- Anchor symbol retained after full build
- Zero warnings

---

### Task 6: Add size-verification recipe to justfile

**Description:** Add `check-binary-size` recipe that asserts `libfae.a` > 50MB. Add `build-native-and-check` that chains build + size check + Swift build.

**Files:** `justfile`

**Acceptance:**
- `just check-binary-size` passes with valid binary
- `just check-binary-size` fails with undersized binary

---

### Task 7: Add Rust test for anchor compilation validity

**Description:** Add `#[cfg(test)]` block in `linker_anchor.rs` with `anchor_does_not_panic` test and compile-time type import guards.

**Files:** `src/linker_anchor.rs`

**Acceptance:**
- `cargo test` passes including anchor tests
- Zero warnings

---

### Task 8: End-to-end validation and documentation

**Description:** Run full `just build-native-and-check`. Create `docs/linker-anchor.md`. Update `CLAUDE.md` touchpoints. Verify Swift app launches with non-null handle.

**Files:**
- `docs/linker-anchor.md` (new)
- `CLAUDE.md`
- `Package.swift` (comments only)
- `justfile` (comments only)

**Acceptance:**
- `libfae.a` > 50MB
- Swift binary > 80MB
- App launches, `fae_core_init` returns non-null
- Documentation exists
