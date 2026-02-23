# Linker Anchor: Anti-Dead-Strip for libfae.a

## Problem

Swift Package Manager links `libfae.a` with `-force_load` (pulls all `.o` files
from the archive) followed by `-dead_strip` (macOS linker removes code not
reachable from exported symbols).

The only exported symbols are the 8 `extern "C"` FFI functions in `src/ffi.rs`.
Those functions route through stub command handlers that never construct
`PipelineCoordinator`, `ParakeetStt`, `KokoroTts`, `LocalLlm`, or audio
subsystem types. The linker therefore strips all ML and audio code, shrinking
the binary from ~100 MB to ~9 MB.

## Solution

`src/linker_anchor.rs` exports `fae_keep_alive` as a `no_mangle` C-ABI function.
Inside, an `if black_box(false) { ... }` block holds `black_box` references to
every major subsystem constructor. Because `black_box(false)` is opaque to the
optimiser, the compiler cannot prove the block is dead and the linker retains
every referenced symbol.

`fae_core_init` (in `src/ffi.rs`) calls
`black_box(fae_keep_alive as *const () as usize)` to ensure the anchor itself
survives dead-stripping.

## Anchored Subsystems

| Subsystem | Constructor(s) |
|-----------|---------------|
| Config | `SpeechConfig::default()` |
| Pipeline | `PipelineCoordinator::new`, `::with_models` |
| STT | `ParakeetStt::new` |
| LLM | `LocalLlm::new` |
| TTS | `KokoroTts::new` |
| Audio Capture | `CpalCapture::new` |
| Audio Playback | `CpalPlayback::new` |
| VAD | `SileroVad::new` |
| AEC | `ReferenceBuffer::new`, `AecProcessor::new` |

## Verification

```bash
# Build the static library
just build-staticlib

# Check binary size (must be > 50 MB)
just check-binary-size

# Full pipeline: build lib + size check + Swift build
just build-native-and-check
```

## Maintenance

When adding a new subsystem to the pipeline, add a reference to one of its
concrete types or constructors inside the `if black_box(false)` block in
`src/linker_anchor.rs`. The compile-time tests in the `#[cfg(test)]` block
will catch any removed or renamed types.

## Files

- `src/linker_anchor.rs` — anchor function + tests
- `src/ffi.rs` — `fae_core_init` references the anchor
- `include/fae.h` — C header declares `fae_keep_alive`
- `native/macos/.../include/fae.h` — Swift module map copy
- `justfile` — `check-binary-size`, `build-native-and-check` recipes
