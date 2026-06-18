# Mega-prompt — prove (and if needed wire) the APP routes real turns to the llama.cpp daemon (gap B1.5)

Paste into a fresh session. Self-contained; **verify every claim against the repo and live output** —
static-only review has already missed a release-blocking bug on this work. The reviewer re-runs your evidence.

---

## Workflow — read first

**You (the team) implement AND test to completion, then HAND BACK for review. You do NOT commit or
push.** The reviewer commits + publishes.

1. **Diagnose first, then fix only what's needed** (see "The work").
2. **Test to completion** — every "Done criteria" item passes with **verbatim evidence you captured
   yourself**: `git diff --stat`; `swift build` clean; the live app-turn evidence below.
3. **Heed the BUNDLING TRAP**: `just build` alone does NOT update the running app/daemon — use the full
   `_bundle-app`/`_embed-daemon`/`_embed-ui-shell`/`_sign-bundle` chain. Confirm LIVE behaviour.
4. **Hand back** a report with evidence + deviations. Flag anything unverifiable; do not paper over it.

---

## Context — what's already done (B1 daemon-side, committed 70e5145c)

The **daemon** now runs llama.cpp by default and is proven IN ISOLATION: E4B QAT
(`unsloth/gemma-4-E4B-it-qat-GGUF:UD-Q4_K_XL`) + BF16 mmproj + E4B MTP drafter, fail-closed SHA-256
integrity gate (tamper→exit 78), `process_mtmd` audio, daemon-side thinking strip, tool-call streaming
fix, no-orphan. `FAE_ENGINE=mistralrs` hard-errors. Integration is the `llama-server` **sidecar**
(ADR-010 — do NOT switch to in-process bindings).

**The open gap (this task):** nobody has confirmed that a **real turn through the Swift app** is handled
by the llama.cpp **daemon** rather than the in-process **MLX Qwen** engine. Observed during B1 review:
- `llm.useDaemonEngine` and `tts.useDaemonEngine` both default **true** (`FaeConfig.swift`), so turns
  *should* route to the daemon.
- BUT the test-server `modelLabel` reports `conversation?.loadedModelLabel` — that's the **in-process
  MLX engine** (still loaded for vision + fallback), which showed `Qwen3.5 35B · A3B-4bit`. That label
  is **misleading**: it reflects the MLX engine, not whatever actually served the turn. So it neither
  proves Qwen nor proves llama.cpp.
- The B1 team saw "tool execution in the app" but could not attribute it to llama.cpp.

Until this is resolved, **the product the user runs is not confirmed to be on llama.cpp**, and B4
(deleting `vendor/candle` + `vendor/mistral.rs`) stays blocked.

---

## The work

### 1. Diagnose: does a real app turn hit the llama.cpp daemon or the MLX engine?
- Run the bundled, signed dev app (`just run-dev` style, full bundle chain) with `--test-server`.
- Drive a turn via `POST http://127.0.0.1:7433/inject` (Python urllib — a hook intercepts curl).
- **Attribute the turn to an engine with daemon-side evidence**, not the UI label: capture the
  **daemon's own log** (the embedded daemon's stdout/stderr) and show the request arriving + a
  `llama-server` generation for THAT turn. If instead the in-process MLX engine served it (no daemon
  request, MLX generation logs), that's the finding.
- Resolve the obvious failure modes if it fell back to MLX:
  - Did the embedded daemon **start** and select llama.cpp? (engine banner in its log)
  - Did the daemon need to **download the ~5GB E4B QAT GGUF** on first use and time out / not be
    triggered? (lazy spawn; `FAE_LLAMA_READY_TIMEOUT_SECS`)
  - Is `DaemonLLMEngine` actually used, or did it silently fall back to in-process MLX on a daemon
    connect/spawn error? Find the fallback branch and log why.

### 2. Fix the misleading model label
- The app must surface the **engine that actually serves turns**. When the daemon LLM lane is active,
  the label/readout (test-server `modelLabel`, About/Settings "Active model", self-diagnostic) must
  report the **daemon llama.cpp model** (e.g. `gemma-4-E4B-it-qat (llama.cpp)`), not the in-process MLX
  fallback's label. A user/inspector must be able to tell which brain is running.

### 3. Prove the full product path on llama.cpp
Once routing is confirmed/fixed, prove end-to-end through the app (not the standalone daemon):
- **Text turn** served by the daemon llama.cpp (daemon log attribution).
- **Tool call** runs on the llama.cpp path.
- **Audio turn**: a real PTT/WAV turn yields a correct `[heard]:` transcript via the daemon mmproj.
- **TTS + orb**: the turn speaks via daemon-owned playback (V3b default) and `ORB_MODE` reaches
  Speaking flicker-free (orb-host-owns-state). Capture the `ORB_MODE` trace from `/tmp/fae-dev.log`.

### 4. Check the thinking-strip interaction (regression guard)
B1 added **daemon-side** stripping of Gemma `<|channel>thought…<channel|>`. The Swift `ThinkTagStripper`
also strips `<channel|>` and drives the orb thinking exit-signal (`.thinkingText(isActive:false)`). With
the daemon now stripping first, confirm the Swift side still gets what it needs to fire the thinking
indicator correctly (no double-strip breakage, thinking still shown then cleared). Fix if the daemon
strip starves the Swift signal.

---

## Gotchas
- **ADR-010**: keep the sidecar; do not introduce in-process bindings.
- **Bundling trap**: full bundle/embed/sign chain, or you test a stale app.
- **First-run download**: the daemon lazily downloads the ~5GB E4B QAT GGUF on first turn — budget time
  or pre-warm the cache (`<data>/models/llamacpp`); it's already cached from B1 on this machine.
- **`env -u RUSTFLAGS`** for crate builds. **QUIT the dev app before any local `swift test`.**
- Don't regress the V3b daemon-playback default, the orb-host bridge auth (`BOOTSTRAP_CLIENT_ID`), or
  the `<channel|>` close marker.
- **autoresearch.jsonl** is unrelated churn — keep it out of your diff.

## Done criteria
1. **Attribution**: a real app turn is proven (via daemon-side logs) to be served by the **llama.cpp
   daemon**, not in-process MLX. If it wasn't, the wiring is fixed so it is — with the fallback-to-MLX
   reason found and addressed.
2. **Label**: the app reports the **actual serving engine** (daemon llama.cpp) wherever model identity
   is shown.
3. **Full path**: text + tool + audio(`[heard]`) + TTS + orb(`ORB_MODE`→Speaking) all proven through
   the app on the llama.cpp path.
4. **Thinking strip** interaction verified (orb thinking indicator still fires; no double-strip break).
5. `swift build` clean; any touched crate green under `env -u RUSTFLAGS` clippy `-D warnings` + nextest.
6. **Hand back** the evidence (do NOT commit/push). Reviewer validates, commits, and on publish updates
   open-gaps (B1.5 done → unblocks B4) + memory + Obsidian.

## Suggested order
1. Diagnose attribution (the one question that matters). 2. If MLX-fallback, find+fix why. 3. Fix the
   label. 4. Prove the full path. 5. Thinking-strip guard. 6. Hand back.

> Scope: B1.5 only — prove/wire the app onto the already-working daemon. B2 (full bundled-runtime
> packaging in release.yml CI), B3 (GGUF-LoRA personalization live), B4 (delete candle/mistral.rs) are
> separate follow-ons; B4 unblocks once B1.5 is proven.
