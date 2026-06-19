# P5 / D2-V5 — Portable voice spine: Linux TTS + offline turn proof (mega-prompt, 2026-06-20)

> **Role split.** You are the IMPLEMENTING TEAM. The main session is the REVIEWER and verifies your
> hand-back against the **real git diff + a re-run gate + live/CI output**, not your report. Implement
> AND test to completion, then HAND BACK with verbatim self-captured evidence. **Do NOT commit or push.**
>
> **Liveness:** two prior-phase agents went silent mid-work without handing back. Hand back at EACH stage
> checkpoint (don't disappear into a long silent run); if you're blocked, say so immediately. The reviewer
> watches disk activity, not heartbeats.
>
> **Your worktree — branch off `main`** (the consolidated trunk; everything is on `main` now):
> `git worktree add /Users/davidirvine/Desktop/Devel/projects/fae-p5 -b p5-voice main`
> Work only there. Read this prompt by absolute path.

## Objective & scope (owner decisions — do not relitigate)

Make a **Linux** build of the Fae daemon **speak**, and prove a full **offline voice turn** end to end on
Linux: an audio clip → STT → LLM → TTS → a synthesized WAV. Today Linux returns `MockTtsAdapter` silence.

**Decisions:**
- **Linux TTS = Piper** (pragmatic portable neural TTS), as a **SHA-pinned sidecar binary + voice model**
  (same ADR-010 pattern as `llama-server`; reuse P4's runtime-lock + install + integrity machinery).
- **macOS keeps Kokoro/MLX** (`voice-tts`) — Apple-fast lane, UNCHANGED. Accept the quality split.
- **Speaker-ID stays dropped** (voice identity retired, S18) — no portable speaker work.
- **STT is inherited** (llama.cpp Gemma-4 mmproj two-pass + Qwen3-ASR fallback — already cross-platform).
- **DEFER the macOS V5 capture flip** (Swift AVAudioEngine → daemon cpal). Out of scope here.
- Targets: **linux-x86_64 + linux-aarch64** (match P4).

**DONE:** on a Linux build, the daemon transcribes a provided audio clip (STT), runs an LLM turn, and
**Piper synthesizes intelligible speech to a WAV** — proven in CI/container (CPU-only, no audio device).
The Piper sidecar is integrity-gated (SHA-pinned, fail-closed). macOS TTS path unchanged. Live mic+speaker
on Linux is deferred (headless CI has no audio device; cpal is portable by construction — see Stage 5).

## Verified current state (anchors — confirm before relying on them)

### TTS — macOS-only; Linux = silence (THE gap)
- `crates/fae-daemon/src/main.rs:163-189` `build_tts_engine()`: `#[cfg(target_os = "macos")]` spawns
  `fae_engine::VoiceTtsAdapter` (Kokoro via `voice-tts`/mlx-rs); **every non-macOS path returns
  `MockTtsAdapter::new("mock-tts")`** (line 188).
- `crates/fae-engine/src/voice_tts_adapter.rs:1-11`: "compiled on macOS only (mlx-rs)… Other targets get
  `MockTtsAdapter` until the candle port lands." `crates/fae-engine/Cargo.toml:42-48`: `voice-tts` is under
  `[target.'cfg(target_os = "macos")'.dependencies]`; non-macOS deps have **no TTS**.
- `crates/fae-engine/src/tts.rs:64-102` `MockTtsAdapter`: returns 240 samples of **silence** at 24 kHz.
- **`TtsAdapter` trait** is the seam: implement a `PiperTtsAdapter` (non-macOS) that `synthesize(text,
  voice, speed) -> TtsAudio { wav, sample_rate }` and slot it into `build_tts_engine`'s non-macOS branch.

### STT — already portable (inherit, don't rebuild)
- `crates/fae-daemon/src/main.rs:202-221`: Gemma-4-E4B GGUF + mmproj (all targets, llama.cpp) and the
  lazy Qwen3-ASR sidecar (`ggml-org/Qwen3-ASR-1.7B-GGUF`). `session.rs:1317-1365`: `transcribe_fallback()`
  + `normalize_asr_transcript()` (portable Rust). No Apple specifics.

### Audio I/O — already portable (cpal), capture/playback handlers exist
- `crates/fae-audio/src/lib.rs`: **zero `#[cfg(target_os)]`** — `AudioManager::capture_start/capture_stop`
  (16 kHz mono WAV), `play_wav`, `play_start/play_stop` (V3a non-blocking + RMS level). cpal 0.15 →
  ALSA/PulseAudio/PipeWire on Linux. Device override via `FAE_AUDIO_INPUT_DEVICE`/`_OUTPUT_DEVICE`.
- `crates/fae-daemon/src/session.rs`: dispatch for `audio.capture_start`/`audio.capture_stop` (~869-914),
  `speak_tts` (~1007-1070, calls `tts.synthesize` then `play_start` + publishes `audio.level`),
  `audio.play`, `audio.stop`. So the daemon already has the turn primitives; P5 makes `tts.synthesize`
  actually produce speech on Linux + adds an offline driver.

### Packaging machinery to reuse (from P4, now on `main`)
- `scripts/llamacpp-runtime.lock.json` (schema v2, per-platform SHA-pinned) + `install-llamacpp-runtime.py`
  (platform-aware download + SHA-verify) + `models.lock` fail-closed + `build-linux-package.py` (.deb +
  AppImage). Mirror this for the Piper sidecar + voice model.

## Work items (dependency order — hand back at EACH checkpoint)

### Stage 1 — Piper sidecar + voice model, integrity-pinned
- Pick a Piper distribution: the `piper` (rhasspy/OHF) prebuilt binary (it bundles ONNX Runtime +
  espeak-ng phonemization) + one voice model (`.onnx` + `.onnx.json`). VERIFY real download URLs + sizes +
  SHA-256 from the actual releases (don't guess — the P4 lesson). Cover linux-x86_64 + linux-aarch64 (if no
  arm64 prebuilt exists, say so and propose build-from-source or an alternative — resolve with evidence).
- Add a `piper-runtime.lock.json` (or extend the existing lock) + teach the install script to fetch +
  SHA-verify it into a per-platform dir. Add the binary + model to `models.lock` (fail-closed).
- Done: running the installer fetches + SHA-verifies the Piper binary + voice on each Linux target (paste
  the verbatim SHA match). macOS unaffected.

### Stage 2 — PiperTtsAdapter (fae-engine), wired into the daemon
- Implement `PiperTtsAdapter` under `#[cfg(not(target_os = "macos"))]` in fae-engine implementing
  `TtsAdapter`: `synthesize(text, voice, speed)` invokes the Piper sidecar (text in → WAV out), returns
  `TtsAudio` (resample to the project's 24 kHz contract if Piper emits 22.05 kHz). Integrity-gate the
  binary/model path (confinement + existence + SHA, mirroring P4 Stage 4). `speed` maps to Piper's
  length-scale. Fail loud, never silent-wrong; if the sidecar is missing/unverified, error (do NOT silently
  fall back to silence in production).
- Wire it into `build_tts_engine`'s non-macOS branch (replace the `MockTtsAdapter` default; keep
  `FAE_TTS=mock` as the explicit test override). macOS `voice-tts` path UNTOUCHED.
- Done: `env -u RUSTFLAGS` unit tests for the adapter (incl. integrity rejection); cross-compile fae-daemon
  for both Linux targets clean (note: the daemon links ALSA → native build on the arm runners in CI, and
  `crates/.cargo/config.toml` already sets `+fp16` for aarch64).

### Stage 3 — Linux offline turn driver
- Add a daemon example/CLI (e.g. `crates/fae-daemon/examples/linux_voice_turn.rs`) or a `--offline-turn`
  harness that, with NO audio device: reads a provided WAV clip → daemon transcribe (STT) → LLM turn →
  `tts.synthesize` (Piper) → writes the spoken-answer WAV to a path. This is the headless-verifiable proof
  of the full spine on Linux.
- Done: on a Linux target, the harness turns a sample clip into a non-empty, correct-duration spoken WAV;
  ideally round-trip the synthesized WAV back through STT and show the words survive (intelligibility).

### Stage 4 — CI proof
- Extend the Linux CI (ci-linux.yml or a sibling job): install + SHA-verify the Piper sidecar, build, and
  run the Stage-3 offline turn (CPU-only — works on headless runners), asserting a non-empty WAV + the
  integrity gate. Each CI step must be a command you also ran locally (in a container if needed).
- Done: the workflow is written and each step locally reproduced; the reviewer pushes to run it.

### Stage 5 — Live mic+speaker on Linux (DEFERRED — document only)
- cpal capture+playback are portable by construction; a headless CI runner has no audio device, so the
  live mic→speaker turn is an owner/real-Linux-box smoke. DOCUMENT the exact device path
  (`FAE_AUDIO_INPUT_DEVICE`/`_OUTPUT_DEVICE`, ALSA/Pulse/PipeWire) and how to run the live turn on a Linux
  desktop. Do NOT block the phase on hardware you don't have.

## DONE criteria
1. Linux build: clip → STT → LLM → **Piper synthesizes intelligible speech to a WAV**, proven in
   CI/container (CPU-only). 2. Piper sidecar SHA-pinned + fail-closed (no silent silence in production).
3. macOS TTS path unchanged (voice-tts) and still builds/speaks. 4. Speaker-ID stays dropped; STT inherited.

## Evidence floor (verbatim, labeled to a DONE criterion; mark CI-only vs local)
- `git diff --stat`; Rust `env -u RUSTFLAGS` fmt/clippy `-D warnings`/nextest for touched crates (paste
  tails) + cross-compile both Linux targets; installer SHA-verify output for the Piper artifacts; the
  Stage-3 offline-turn transcript (input words → synthesized WAV → optional STT round-trip); macOS
  still-builds proof; the exact CI workflow + any secret the reviewer must have.

## Traps & rules
- **Reviewer verifies live/CI, not the report.** Capture real output; mark CI-only honestly.
- **ADR-010:** Piper is a `llama-server`-style sidecar — no in-process Apple/MLX deps on Linux.
- **Don't break macOS:** `voice-tts`/Kokoro path and the macOS bundle stay green; Linux is additive.
- **Integrity fail-closed** for the Piper binary+model (confinement + SHA), `FAE_MODELS_LOCK=off` only
  under `FAE_DEV`. **Never silent-wrong audio** (a mis-synth or missing sidecar must error, not emit
  silence in production).
- **`env -u RUSTFLAGS`**; aarch64 already needs `+fp16` (in `crates/.cargo/config.toml`).
- **Resolve real Piper asset URLs/SHAs with evidence**, not assumptions (the P4 arm64-prebuilt lesson).
- **Surgical:** add the `PiperTtsAdapter` + sidecar; don't refactor the TTS trait or the macOS lane.
- Per-stage hand-back; never commit/push.
