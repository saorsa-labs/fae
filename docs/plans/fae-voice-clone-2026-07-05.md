# Fae voice clone — faithful local TTS of Lauren's voice (design, 2026-07-05)

Owner decision (2026-07-05): adopt a real local zero-shot voice cloner so Fae
speaks in a faithful clone of **Lauren** (the owner's gardener; reference at
`assets/voices/fae.wav`, 30s 24kHz). **Consent: Lauren has consented and is
delighted** — the imperceptible provenance watermark is acceptable/positive.
The current Kokoro "fae" voice is only an approximate style-match and stays as
the fast fallback.

## Model: Chatterbox (Resemble AI) — PRIMARY
- **MIT license on BOTH code and weights** (the decisive property for Fae's
  dual AGPL/commercial licensing). Verify against the LICENSE file at
  implementation time.
- Genuine zero-shot from a short reference; ~0.5B; actively maintained.
- Built-in imperceptible "Perth" neural watermark on every output — accepted
  (provenance: marks Fae's voice as an authorized clone).
- Runtime: PyTorch on Apple-Silicon MPS is the reliable path; an MLX-native
  route via `mlx-audio` may be viable — settle with a timing spike before
  committing (affects latency).
- **Second choice (Apache-2.0, if Chatterbox fidelity underwhelms on Lauren's
  clip):** CosyVoice2. One-adapter swap — the architecture is model-agnostic.
- **REJECTED for commercial use:** XTTS-v2 (Coqui CPML non-commercial), F5-TTS /
  `f5-tts-mlx` (weights CC-BY-NC), Fish-Speech/OpenAudio (non-commercial).
  Kokoro/Piper are not cloners (fallback only).

## Architecture (reuses existing seams — small churn)
- The `TTSEngine` protocol already declares `loadVoice(referenceAudioURL:
  referenceText:)` / `loadCustomVoice(...)` stubs; the daemon has a model-
  agnostic `TtsAdapter` trait; `fae.wav` + its transcript
  (`TtsConfig.bundledFaeReferenceText`) are already in config.
- Cloner runs as a **warm Python sidecar behind the daemon** (Fae's ADR-010
  sidecar pattern; `uv` script under `native/python/voice-clone/`). Daemon-side
  `CloneTtsAdapter: TtsAdapter` supervises it + IPC + caches the speaker cond.
- `FallbackTtsAdapter` decorator: **per-sentence** loud fallback to Kokoro on
  clone error/timeout — a slow/failed sentence degrades instantly, never
  silent, never stalls a reply.
- Speaker conditioning computed ONCE from `fae.wav` + ref-text → cached to
  `<data>/voices/fae_clone.cond` (analog to `fae.bin`), reused every synth.
- `models.lock` extended to SHA-256-verify the clone weights (fail-closed;
  `FAE_MODELS_LOCK=off` dev-only under `FAE_DEV`).
- Config `TtsConfig.engine: .kokoro | .clone` (default `.kokoro` until proven);
  FaeCore maps `.clone` → `FAE_TTS_ENGINE=clone` in daemon spawn; SelfConfigTool
  `tts.engine`; Settings control. Mute/text-first work untouched.
- Memory/thermal gating: opt-in; default Kokoro on <16GB (Gemma + clone + Kokoro
  resident is tight); reuse AwarenessThrottle to fall back to Kokoro under
  thermal/battery pressure; load-on-demand + unload under pressure.

## Latency (honest)
- Per-sentence render on M-series ≈ RTF 0.5–1.5 (a ~2s sentence ≈ 1–3s). First
  sentence audible ~1.5–3s after the LLM finishes it. Slower than Kokoro's
  near-instant — the fidelity trade. Mitigated by sentence-queued streaming
  (text appears immediately; audio follows) + Kokoro fallback under gating.

## Commit sequence (4, each gated)
1. Python clone sidecar (uv) + models.lock coverage + download/precompute-cond +
   standalone WAV smoke. Headless.
2. `CloneTtsAdapter` + `FallbackTtsAdapter` behind `FAE_TTS_ENGINE`; per-request
   loud Kokoro fallback. Gate: crates `just check` + mock + real-weights test
   behind a feature flag.
3. Config `tts.engine` end-to-end + FaeCore env propagation + SelfConfigTool +
   Settings. Gate: `swift build` + config/pipeline tests.
4. Reference-audio / set-voice flow (`loadCustomVoice`, cond swap) + thermal/
   battery gating + progress + docs/CHANGELOG/Obsidian.

## Owner-in-loop
- Fidelity judgment (A/B Kokoro vs clone on the same sentences) — only the owner
  can say if it sounds like Lauren.
- A cleaner **2–3 min** Lauren sample (quiet room) + its transcript → markedly
  better clone; design supports hot-swapping it in.
- Consent: recorded above (Lauren consented, delighted).
- Effort: ~2–3 focused days for the daemon-fronted warm clone lane + fallback +
  config; +1 for set-voice flow + gating polish.

Status: DESIGN ONLY — not started. Green-light when ready; separate focused
effort, not interleaved with the live-pass fixes.
