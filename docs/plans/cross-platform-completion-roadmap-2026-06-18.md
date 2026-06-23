# Cross-platform completion roadmap — closing all open gaps (2026-06-18)

The sequenced plan to take Fae from "daemon brain runs llama.cpp in isolation" to "the product runs on
llama.cpp, is self-improving, and is portable off Apple." Each phase is a hand-back unit; the reviewer
spawns the phase's own mega-prompt when it starts.

## Reframe (owner decision 2026-06-18): keep the vendored libs

**B4 (delete `vendor/candle` + `vendor/mistral.rs` + the mistral.rs adapter) is DEFERRED, not a goal.**
We keep the vendored libs and the in-process MLX engine for now — they're the fallback substrate and a
deletion is pure churn with risk. So **nothing in this roadmap "gates B4," and no phase is blocked by
B4.** The goal is *Fae works on, and is portable via, llama.cpp + portable skills* — with MLX/mistral.rs
kept compiling as a safety net. Revisit B4 only if/when llama.cpp is the sole proven engine on every
target AND there's a concrete reason to shed the code.

## Workflow (every phase)

Same contract as the B1 phases: **the team implements AND tests a phase to completion, then HANDS BACK
with verbatim self-captured evidence; it does NOT commit/push. The reviewer verifies against live output
+ `git diff` (not the team's claims — static-only review has already missed a release-blocking bug, and
agents have fabricated reports), then commits + publishes.** One phase in flight at a time, except where
the diagram marks phases independent (they may run in parallel on separate branches).

Per-phase evidence floor: `git diff --stat`; `env -u RUSTFLAGS` fmt/clippy `-D warnings`/nextest for
touched crates; `swift build` clean; and the phase's **live** proof (daemon-log attribution, `ORB_MODE`
trace, `[heard]` transcript, etc.). Heed the **bundling trap** (full bundle/embed/sign chain — `just
build` alone does not update the running app/daemon).

## Baseline — what's already DONE (don't rebuild)

- **Brain**: llama.cpp is the daemon default (E4B QAT + BF16 mmproj + E4B MTP), integrity-gated, sidecar
  per **ADR-010** (commit 70e5145c). `FAE_ENGINE=mistralrs` hard-errors.
- **Orb**: Rust host owns its state from daemon events; flicker-free (908485a3). Daemon-owned TTS
  playback is the default (V3b, a26d3d38).
- **Personalization plumbing**: GGUF-LoRA per-request scale at the adapter + daemon level (B3/B3b
  landed); `engine.reload`.
- **Training producer**: cross-platform PEFT→GGUF (C2 landed). Training substrate settled: **MLX
  (Apple) / Unsloth (NVIDIA) / PEFT (portable)** — do NOT drop MLX (Unsloth is CUDA-only).
- **Tools (portable)**: `show_html` portable (D4); CalDAV/CardDAV/himalaya skills exist (need wiring, D3).

---

## Phases (sequenced)

```
P1 B1.5  app→daemon llama.cpp routing        ─┐ (foundational: product on the new brain)
P2 B5    audio-in hardening + STT decision    ├─ depend on P1
P3 C3    training→llama.cpp consumption loop  ─┘
P4 B2    cross-platform packaging + CI         (depends on P1; needed before shipping off-Mac)
P5 D2/V5 portable voice spine (capture+TTS/STT) (depends on P2's STT decision)
P6 D1    Linux orb-host render spike            (independent of P2/P3; needs P4 for a runnable Linux build)
P7 D3    Apple tools → portable skills wiring   (independent; can parallel P5/P6)
P8 A1–A4 native ACP delegation/conductor        (independent — branch acp-native-rust; can parallel throughout)
P9 C1/C4 training seam + mandatory bench gates   (formalizes P3; can follow P3)
XC  Release-validation real-audio phase          (cross-cutting gate before ANY user-facing release)
```

### P1 — B1.5: the app runs on the llama.cpp daemon  ⏳ NEXT — prompt ready
**Objective:** prove (via daemon-log attribution, not the UI label) that a real Swift-app turn is served
by the llama.cpp daemon, not the in-process MLX Qwen engine; if it falls back, find+fix why; fix the
misleading `modelLabel` to report the actual serving engine; prove text+tool+audio+TTS+orb through the
app; guard the daemon-vs-Swift thinking-strip interaction.
**Done:** a real app turn is daemon-log-attributed to llama.cpp; label correct; full path proven.
**Why first:** everything below assumes the product is actually on the new brain.

### P2 — B5: audio-in hardening + STT decision  (depends on P1)
**Objective:** make the voice lane reliable. Gemma-4 audio via the llama.cpp BF16 mmproj is merged but
finicky (bugs #21820/#21868, WER ~4.17% clean, worse noisy). Decide and wire: **(a)** keep the two-pass
Gemma mmproj `[heard]` path if it proves reliable through the app, or **(b)** fall back to **Qwen3-ASR /
whisper.cpp** for STT (both cross-platform under llama.cpp) when Gemma audio is shaky.
**Done:** a reliability bar on real (incl. noisy) mic input — a measured WER/accuracy gate, not a single
clean clip; the chosen path documented; degraded-audio behavior defined (never a silent wrong `[heard]`).
**Why P2:** a voice assistant that mis-hears is worse than useless; this is the top product risk.

### P3 — C3: close the training→brain consumption loop  ✅ DONE (commit c71d6ba1, 2026-06-19)
**Objective:** trained personal LoRA adapters must reach the **llama.cpp daemon brain**, not just the MLX
fallback. Wire the nightly loop: train (portable PEFT) → `convert_to_gguf.py` → hot-load into the
running llama-server via per-request scale (B3 adapter-level already landed) + `engine.reload`.
**Decision:** the daemon loop uses the cross-platform **PEFT producer** (`train_peft.py` →
`convert_to_gguf.py`); mlx-tune stays an out-of-loop Apple-fast experimental lane (its `.safetensors`
adapters have no proven GGUF path).
**Done ✅:** end-to-end loop closed and live-proven on the real daemon — a GGUF LoRA loads and serves at
scale=1 with instant scale=0 rollback (audit.jsonl: reload + set-scale, `model:management`, allow; probe
fact present at scale=1, absent at scale=0). Swift: `TrainingBridge.trainPeftAndConvert` (verify+fail-loud
GGUF), `DaemonLLMEngine.reloadAdapter/setAdapterScale`, the previously dead-end ICC `adapterPatchCallback`
wired → polymorphic `applyAdapterChange` (daemon vs MLX). Rust Stage 4: confinement + existence + SHA
*before* killing the sidecar, distinct `adapter_path_rejected`, `runtime.status` adapter report. Gate:
fmt/clippy -D warnings, nextest 85/85, swift build clean. **Reviewer-verified** against the real diff +
re-run gate + the daemon's own audit log. **Deferred:** bundled-app `run-dev` live proof (the
release-validation/human-in-loop gate); the mandatory FaeBenchmark hard-gate is formalized in P9/C4.

### P4 — B2: cross-platform packaging + CI  ✅ LINUX DONE (2026-06-19)
**Objective:** ship/resolve the `llama-server` binary per platform (bundled+signed macOS done; Linux/
Windows discovered or installed) + the pinned runtime under `models.lock` (fail-closed). Extend the B1
SHA-pinning gate into CI.
**Scope (owner):** Linux x86_64 + linux-aarch64, **full native installers** (`.deb` + AppImage,
GPG-signed). Windows + macOS-x86_64 deferred.
**Done ✅:** multi-platform `llamacpp-runtime.lock.json` (schema v2, per-platform SHA-pinned, reviewer-
verified vs real ggml-org b9692 assets); platform-aware install + `bundled_llama_server_path()`
resolution; `models.lock` Linux binary artifacts (fail-closed); `build-linux-package.py` → `.deb` +
AppImage + GPG sign/verify (existing `GPG_PRIVATE_KEY`/`GPG_PASSPHRASE` secrets); `ci-linux.yml` /
`release-linux.yml` build + integrity-gate both arches on **native runners** (ubuntu-latest +
ubuntu-24.04-arm, **no Docker/QEMU**). **CI proven green both arches** (run 27851337705). Reviewer-
verified locally: Stage-1 SHAs (both arches), a real signed `.deb` + GPG roundtrip + structure, native
daemon gate. **Reviewer fix:** Linux runtime-path resolution (`.deb` `/usr/bin` symlink → doubled
nonexistent dir → daemon wouldn't start) now probes both layouts; arm64 needed `target-feature=+fp16`
for the dead-on-Linux vendored gemm asm. **CI-only by necessity (proven in CI, not on the Mac):** native
daemon + orb-host build (ALSA/WebKitGTK), single-file AppImage, daemon run-smoke. **Deferred:** Windows,
macOS-x86_64; the daemon run-smoke as a dedicated CI step.

### P5 — D2 / V5: portable voice spine  (depends on P2's STT decision)
**Objective:** move voice off Apple-only. **V5**: PTT capture → daemon cpal (capture is the last
Swift→host orb signal). **TTS/STT/speaker**: portable path (candle Kokoro port, or llama.cpp audio-in for
STT per P2; ECAPA speaker portable or dropped — voice identity is retired). Accept an Apple-fast /
portable-fallback split if needed.
**Done:** a Linux build can capture, transcribe, and speak a turn (even if lower quality than Apple).

### P6 — D1: Linux orb-host render spike  (independent; needs P4 for a runnable Linux build)
**Objective:** the Rust orb host (tao/wgpu/wry) renders on Linux; the pill/panels tolerate the WebKitGTK
transparency/render defects (tauri#12800/#13157/#9220) via the designed **opaque frosted fallback**.
**Done:** orb + pill + a data panel render acceptably on a Linux desktop; fallback path proven.

### P7 — D3: Apple tools → portable skills wiring  (independent; can parallel P5/P6)
**Objective:** wire `calendar-caldav` / `contacts-carddav` / `mail-himalaya` as the **non-Apple** tool
path (skills = hands), so calendar/contacts/mail work off macOS. EventKit stays the macOS adapter.
**Done:** on a non-Apple platform, calendar/contacts/mail operations route through the portable skills.

> **⚠ Egress-surface flag (added 2026-06-23):** when this (or any later phase) lands a **daemon-side ToolHost** that executes `web_search` / `fetch_url` / networked tools, those become **fresh cloud-egress surfaces** and MUST route through the conductor's `assert_*_egress_gates` pipeline (mode cap → secret/credential membrane → provisioning) — the same gate that now covers `conversation.inject_text` and the `agent.*` commands. Today the daemon "is tool-aware but executes nothing," so there is no egress; the moment that changes, the gate must cover it. Flagged here (not in a review) so it is not rediscovered the way `agent.session_start` was — an ungated surface everyone assumed was fine. See `docs/architecture/egress-scope-and-stage3-hold-2026-06-23.md` §3.

### P8 — A1–A4: native ACP delegation/conductor  (independent — branch `acp-native-rust`)
**Objective:** finish the native ACP client in the daemon. **A1** Swift thin client (repoint
`AgentDelegateTool` at the daemon). **A2** streaming + persistent sessions. **A3** server-initiated
permission round-trip + fs mediation (the payoff). **A4** conductor seam + polish.
**Done:** Fae delegates to an ACP agent end-to-end through the daemon with permission mediation.
**Note:** lives on its own branch; can run in parallel with the B/C/D phases throughout.

### P9 — C1 / C4: training seam + mandatory benchmark gates  (follows P3)
**Objective:** formalize the `TrainingBackend` seam (`prepareDataset/trainAdapter/convertAdapter/...`)
across MLX/Unsloth/PEFT, and enforce **FaeBenchmark regression gates** on every adapter before deploy
("LoRA prevents forgetting" was REFUTED — gates are mandatory).
**Done:** the training loop is backend-agnostic behind the seam; no adapter deploys without passing gates.

### XC — Release-validation real-audio phase  (cross-cutting gate)
Before ANY user-facing release of the orb-host / V3b-playback / llama.cpp series, the
`docs/checklists/app-release-validation.md` **real-audio phase** (physical mic + loopback, not text
injection) + full live-UI pass must be green. This is the human-in-the-loop gate the B1/V3b hand-backs
could not satisfy headlessly. Not a phase to "build" — a gate to clear before shipping.

---

## Cross-cutting rules (apply to every phase)
- **ADR-010**: llama.cpp stays a `llama-server` sidecar; no in-process FFI bindings (iOS would revisit).
- **Integrity gates**: any downloaded/bundled model or binary is SHA-pinned + fail-closed;
  `FAE_MODELS_LOCK=off` only under `FAE_DEV`.
- **No Swift product logic**: decision-making moves to Rust (daemon/orb-host); Swift stays the macOS
  adapter (EventKit/MLX/AppKit shell). Portable skills replace Apple tools off-Mac.
- **Training**: MLX (Apple) / Unsloth (NVIDIA) / PEFT (portable) — keep MLX; Unsloth is CUDA-only.
- **B4 deferred**: keep `vendor/candle` + `vendor/mistral.rs` compiling; no deletion churn now.
- **Verify against live, not claims**; flag anything unverifiable; heed the bundling trap.
