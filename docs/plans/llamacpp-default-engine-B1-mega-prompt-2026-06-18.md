# Mega-prompt — make `LlamaServerAdapter` the DEFAULT daemon engine + prove a real Gemma-4 turn (gap B1)

Paste into a fresh session. Self-contained; **verify every claim against the repo and live output** —
dev-agents have fabricated reports, and static-only review has already missed a release-blocking bug
on this branch. The reviewer will re-run your evidence.

---

## ⛔ REVISION — reviewer send-back (2026-06-18, round 1)

Round-1 (uncommitted working tree) built the **Fae-owned llama.cpp runtime** — bundled+signed
`llama-server`, SHA-pinned `runtime.lock.json`, app-support install, `exit_fatal` no-silent-fallback,
orphan-kill, lazy spawn + async lock, MTP default-on. **That is accepted — KEEP it.** The mistral.rs
runtime removal is also accepted (owner confirmed "no more mistral.rs" — do NOT restore the kill
switch). But round-1 did **not** meet the core B1 objective and has a security regression. Fix all of
the following **in one pass** and re-hand-back with evidence; nothing commits until then.

**Owner decisions (2026-06-18):** (1) **mistral.rs stays removed** — `FAE_ENGINE=mistralrs`-as-hard-
error is fine. (2) **Default model = Gemma-4 E4B everywhere** — REVERT the `12b` default.

### Required changes (blocking)
1. **Integrity-gate the downloaded GGUF (security regression — top priority).** The new `-hf`
   (`LlamaModelSource::HuggingFace`) path does ZERO model verification — Fae will run whatever HF
   serves. The binary is SHA-pinned but the *model* is not. Wire a **fail-closed digest check** on the
   downloaded GGUF (+ mmproj, + the MTP drafter if used): extend `models.lock` (the `ModelsLock`
   loader still exists in `fae-engine`) or an equivalent pinned-SHA gate, verified after download /
   before the sidecar serves. Tamper/mismatch → `exit_fatal`. Honor `FAE_MODELS_LOCK=off` only under
   `FAE_DEV`. **Prove it:** a tampered cached GGUF makes the daemon exit fatally.
2. **Resolve the audio mmproj on the DEFAULT path + prove a `[heard]` turn.** Today `--mmproj` is only
   wired for the dev `Local` source; the production `-hf` path passes none, so push-to-talk pass-1 ASR
   has no Gemma-4 audio projector → voice hears nothing. Resolve/download/verify the E4B audio mmproj
   and pass `--mmproj`, then **prove a real WAV turn produces a correct `[heard]:` transcript.** This is
   the highest-risk item; if E4B-GGUF audio genuinely can't work on llama.cpp, STOP and hand back the
   finding (do not ship a voice assistant that can't hear).
   **Audio reality (owner research 2026-06-18):** Gemma-4 audio-in IS merged in llama.cpp (PR #21421)
   but **finicky — the mmproj is BF16 (large, can't be low-bit-quantized) and has known bugs (#21820
   bad transcripts, #21868 server routing); WER ~4.17% clean, worse on noisy mic.** Budget for the
   large BF16 mmproj download+verify; if the Gemma mmproj path proves shaky, the sanctioned fallback is
   **Qwen3-ASR or whisper.cpp for STT** (both cross-platform under llama.cpp) — flag it and hand back
   rather than shipping an unreliable `[heard]`.
3. **Prove a real Gemma-4 turn end-to-end** (the actual objective — round-1 only did a partial
   download). Paste evidence for ALL: text tokens stream; native `<tool_call>` runs; served-thinking
   `<|channel>thought…<channel|>` stripped (don't regress the `<channel|>` close marker); the audio
   `[heard]` turn from #2; TTS speaks (daemon-owned) and `ORB_MODE` reaches Speaking flicker-free.
4. **Revert the default model to Gemma-4 E4B — specifically the QAT build (owner research 2026-06-18).**
   Change `DEFAULT_LLAMA_MODEL_SPEC` from `unsloth/gemma-4-12b-it-GGUF:UD-Q4_K_XL` to
   **`unsloth/gemma-4-E4B-it-qat-GGUF:UD-Q4_K_XL`** (QAT = quantization-aware training: ~5GB RAM, same
   footprint as plain dynamic but higher accuracy +15.6% on Q4, native audio, 128K ctx — fits 8–16GB
   Macs alongside Fae's other resident models: Kokoro TTS + SmolVLM ×2 + embeddings + speaker encoder).
   Do NOT use 12B as the universal default — its Q4 file is already ~8GB, so with Fae's full stack it
   OOMs/thrashes on ≤16GB; 12B QAT (7GB) is an **opt-in ≥16GB tier for later**, not now.
   **Fix the MTP drafter:** round-1 hardcoded `mtp-gemma-4-12b-it.gguf`. Use the **E4B** assistant-MTP
   drafter for `-hf` auto-discovery; if the E4B drafter isn't available, default `FAE_LLAMA_MTP` off for
   E4B and say so. (MTP = 1.4–2.2× faster, no accuracy loss — keep it on when the right drafter exists.)

Re-run the full static gate (`env -u RUSTFLAGS` fmt/clippy `-D warnings`/nextest, fae-daemon +
fae-engine) AND the live evidence. Then hand back — the reviewer commits + publishes.

---

---

## Workflow — read first

**You (the team) implement AND test this to completion, then HAND BACK for review. You do NOT commit
or push.** The owner's reviewer commits + publishes after review.

1. **Build it** per "The work", smallest-increment-first ("Suggested order").
2. **Test to completion** — every "Done criteria" item passes with **verbatim evidence you captured
   yourself**, not asserted:
   - `git diff --stat` of everything you changed.
   - `cd crates && env -u RUSTFLAGS cargo fmt -p <c> -- --check && cargo clippy -p <c> --all-targets --
     -D warnings && cargo nextest run -p <c>` tails for each touched crate.
   - **A real Gemma-4 turn through `llama-server`, end-to-end through the daemon** (test-server
     `POST /inject`, Python urllib — a hook intercepts curl), with the daemon log showing the
     llama.cpp engine selected and tokens flowing. Paste the daemon stdout/stderr proving it.
   - **Heed the BUNDLING TRAP** (gotchas): `just build` alone does NOT update the running app/daemon.
     Use the full bundle/embed/sign chain. Confirm LIVE behavior, not the source diff.
3. **Hand back a report** with all the above + a short summary + deviations/risks. Then STOP — the
   reviewer validates, commits, publishes. **Flag anything you could not verify; do not paper over it.**

---

## Objective (owner decision 2026-06-18)

Make `LlamaServerAdapter` (llama.cpp `llama-server` sidecar) the **default daemon LLM engine**, and
**prove a real Gemma-4 turn end-to-end through it** — tokens, native tool calling, the served-thinking
format, push-to-talk audio (pass-1 ASR), TTS, and the orb all working. This is **gap B1** of the
cross-platform brain pivot (`docs/architecture/cross-platform-brain-llamacpp-2026-06-16.md`) and the
**single biggest lever toward total cross-platform**: it is the step that lets us later delete
`vendor/candle` + `vendor/mistral.rs` (B4). Until llama.cpp is the default, the Mac still runs the
candle/Metal path and non-NVIDIA GPUs have no fast lane.

**Owner intent:** retire candle + mistral.rs. B1 does NOT delete them — it makes llama.cpp the default
and proves parity, leaving mistral.rs reachable as a kill switch until B4.

> **Integration is the `llama-server` SIDECAR, not in-process FFI bindings (ADR-010, 2026-06-18).**
> Do NOT swap the `LlamaServerAdapter` (HTTP/SSE to a spawned, SHA-pinned, signed `llama-server`) for
> an in-process crate (`llama_cpp`/`llama-cpp-2`/`llama-cpp-rs`). In-process would force the daemon to
> compile llama.cpp + a GPU backend per target (re-introducing the candle build coupling we're
> deleting), and loses crash isolation + binary-SHA pinning. The `ProviderAdapter` seam keeps an
> in-process adapter as a cheap future option (iOS, where subprocesses are banned). See
> `docs/adr/010-llamacpp-sidecar-vs-inprocess.md`. Correctness over speed.

---

## What already exists (build on it — DO NOT rebuild)

Branch `llamacpp-serving-adapter` (pushed through `7606fbad`).

- **`crates/fae-engine/src/llamacpp_adapter.rs` (~655 lines, REAL).** `LlamaServerAdapter` behind the
  `ProviderAdapter` contract: `LlamaServerConfig::args()` (assembles the `llama-server` command line,
  incl. `--lora <gguf> --lora-init-without-apply` for the personal adapter); `LlamaServerHandle::spawn`
  (+ `await_ready` poll, killed on `Drop`); OpenAI-compatible HTTP/SSE chat; per-request LoRA scale
  (`with_lora`, `set_adapter_scale`, atomic); `engine.reload` restart with a different `--lora`.
  **Audio is wired:** `encode()` attaches push-to-talk audio as an `input_audio` content part and the
  config has an **audio mmproj projector field** for Gemma 4's pass-1 ASR (S18 two-pass). Unit-tested
  without a live server.
- **`build_llamacpp_engine()` (`crates/fae-daemon/src/main.rs:231`).** Two modes: **attach** to an
  existing server (`FAE_LLAMA_SERVER_URL`, optional `FAE_LLAMA_HAS_LORA`) or **spawn** a sidecar from
  `FAE_LLAMA_MODEL_GGUF` (+ `FAE_LLAMA_BIN`, default `llama-server` on PATH). Default `FAE_MODEL_ID` =
  `gemma-4`.
- **Engine selection (`build_engine()`, main.rs:188).** llama.cpp is **opt-in** today:
  `FAE_ENGINE=llamacpp` → `build_llamacpp_engine()`; otherwise the **mistral.rs** path
  (`LocalMistralrsAdapter`, with `verify_models_lock` fail-closed) is the default.
- **`models.lock` fail-closed** is wired for the mistral.rs path (`verify_models_lock` →
  `exit_models_lock_fatal` on mismatch; `FAE_MODELS_LOCK=off` is the loud `FAE_DEV` escape hatch).
  The **llama.cpp path does NOT yet go through it** — that's the main gap B1 must close.
- **Design doc** `docs/architecture/cross-platform-brain-llamacpp-2026-06-16.md` — source of truth
  (per-request scale semantics, the B1–B4 sequence). The end-to-end path (Gemma-4 PEFT→GGUF→llama-server
  per-request scale) was validated in a spike at ~83–103 tok/s decode — that's your perf sanity band.

---

## The work

### 1. Deterministic, fail-closed model resolution (the real B1 gap)
- Resolve, by default (no env gymnastics), the three artifacts a Gemma-4 llama.cpp turn needs:
  1. the **GGUF base** (Gemma-4 E4B, quantized),
  2. the **audio mmproj** projector (Gemma-4) — WITHOUT it, push-to-talk **pass-1 ASR breaks** and
     voice turns hear nothing,
  3. the **`llama-server` binary**.
- Run the GGUF (+ mmproj) through **`models.lock` fail-closed**, mirroring the mistral.rs path
  (`verify_models_lock` → `exit_models_lock_fatal` on tamper/mismatch; honor `FAE_MODELS_LOCK=off`
  only under `FAE_DEV`). Production must fail closed on a missing/altered GGUF, mmproj, or binary.
  (This is the B2 overlap B1 cannot skip — a default engine with no integrity gate is a regression.)
- Decide + document the binary source (bundled vs PATH vs download) and the GGUF source (HF download
  pinned by revision vs bundled). Whatever you choose, it must be deterministic and `models.lock`-gated.

### 2. Flip the default (the cutover) — mirror the V3b pattern
- Make llama.cpp the default engine; keep mistral.rs reachable as a **kill switch**
  (`FAE_ENGINE=mistralrs` → old path). Match the just-landed V3b style: default-on, one loud env var
  back to the old behavior, documented. Do NOT delete mistral.rs/candle (that's B4).

### 3. Prove a real Gemma-4 turn end-to-end (parity)
Drive a turn through the daemon (test-server `/inject` and, for audio, a WAV-bearing turn) and prove
**all** of these work on the llama.cpp default — paste evidence for each:
- **Text turn:** tokens stream; the answer is coherent.
- **Native tool calling:** the model emits the `<tool_call>` contract and a tool runs (e.g. a trivial
  read). Parity with the mistral.rs path.
- **Served-thinking format:** Gemma-4 emits `<|channel>thought … <channel|>{answer}` and the pipeline
  strips it correctly (the `ThinkTagStripper` close marker is `<channel|>` — see commit 5cc2ad1c; do
  NOT regress it).
- **Push-to-talk audio (pass-1 ASR):** a real WAV turn produces a correct `[heard]:` transcript via the
  audio mmproj, then reasons on it (two-pass, S18). **This is the highest-risk item** — if the mmproj
  isn't loaded/resolved, the turn hears nothing.
- **TTS + orb:** the turn speaks (daemon-owned playback, now default) and the orb rides it
  (`ORB_MODE Thinking→Speaking→Quiescent`).

### 4. Child-process hygiene
- The daemon spawns `llama-server` as a child. Confirm it joins the **`DaemonProcessRegistry` /
  parent-watch orphan-kill** (app → daemon → llama-server chain): kill the daemon / quit the app and
  prove no orphaned `llama-server` survives. `LlamaServerHandle` kills on `Drop`, but verify the
  whole-chain teardown, not just the happy path.

### 5. Tests
- Unit/integration for the new resolution + `models.lock` gating (tamper → fatal exit). Keep the
  existing adapter unit tests green. `env -u RUSTFLAGS` clippy `-D warnings` + nextest for fae-engine +
  fae-daemon.

---

## Live-run recipe (capture the evidence)

```bash
env -u RUSTFLAGS just build-ui-shell build-daemon build _bundle-app _embed-ui-shell _embed-daemon _sign-bundle _kill-fae
BUNDLE="$PWD/native/macos/Fae/.build/xcode/Build/Products/Debug/Fae.app"
SHELL_BIN="$BUNDLE/Contents/MacOS/fae-ui-shell"
# Default run — do NOT set FAE_ENGINE; prove llama.cpp is now the default.
FAE_DEV=1 RUST_LOG=info FAE_UI_SHELL_BIN="$SHELL_BIN" open "$BUNDLE" \
  --stdout /tmp/fae-dev.log --stderr /tmp/fae-dev.log \
  --env FAE_DEV=1 --env RUST_LOG=info --env FAE_UI_SHELL_BIN="$SHELL_BIN" --args --test-server
# Wait for the daemon "engine : llama.cpp …" line + "all models loaded", then:
python3 -c "import urllib.request,json; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:7433/inject', data=json.dumps({'text':'What time is it? Use a tool if you need one.'}).encode(), headers={'Content-Type':'application/json'}), timeout=10)"
grep -iE "engine .*llama|llama-server|tool_call|ORB_MODE|playback_ended|heard" /tmp/fae-dev.log
# Audio turn: drive a WAV-bearing /inject (or the test PTT path) and grep the [heard]: transcript.
# Kill switch: relaunch with --env FAE_ENGINE=mistralrs and confirm the old path still works.
```

---

## Gotchas
- **`env -u RUSTFLAGS`** for all crate builds (vendored candle's unused-import breaks `-D warnings` —
  ironic, and it goes away at B4).
- **Bundling trap.** The daemon is embedded in the app bundle (`_embed-daemon`). `just build` alone
  won't update the running daemon — run the full chain. `FAE_DAEMON_BIN` can override for quick spins.
- **`models.lock` is non-negotiable.** A default engine that loads an unverified GGUF/mmproj/binary is
  a security regression. Fail closed; loud `FAE_DEV`-only escape hatch.
- **Audio mmproj is the trap.** Text parity is easy; the pass-1 ASR (`input_audio` + Gemma-4 mmproj) is
  where a default flip silently breaks voice. Prove a real WAV turn, not just text.
- **Don't touch** the orb-host bridge auth (`BOOTSTRAP_CLIENT_ID`), the `ThinkTagStripper` close marker
  (`<channel|>`), or the V3b daemon-playback default — all just landed and verified.
- **QUIT the dev app before any local `swift test`** (live daemons + MLX loads abort the suite).
- **autoresearch.jsonl** is unrelated churn — keep it out of your diff.

---

## Done criteria
1. **llama.cpp is the default** (no `FAE_ENGINE`): daemon log shows it selected; a real Gemma-4 **text**
   turn streams a coherent answer.
2. **Tool calling** works on the llama.cpp default (a `<tool_call>` runs) — parity evidence pasted.
3. **Served-thinking** stripped correctly (no leaked `<|channel>thought`/`<channel|>` in the spoken
   answer; thinking exit signal fires).
4. **Push-to-talk audio** turn produces a correct `[heard]:` transcript (mmproj loaded) then answers.
5. **TTS + orb**: turn speaks (daemon-owned) and `ORB_MODE` reaches Speaking flicker-free.
6. **`models.lock` fail-closed**: a tampered/missing GGUF (or mmproj/binary) makes the daemon exit
   fatally (proven); `FAE_MODELS_LOCK=off` only works under `FAE_DEV`.
7. **Kill switch**: `FAE_ENGINE=mistralrs` restores the mistral.rs path (proven live).
8. **No orphans**: quitting the app leaves no surviving `llama-server` (proven).
9. **Green**: `env -u RUSTFLAGS` clippy `-D warnings` + nextest for fae-engine + fae-daemon; perf in the
   ~83–103 tok/s decode sanity band (note the actual number).
10. **Hand back** the evidence report (do NOT commit/push). The reviewer validates, commits, and updates
    open-gaps B1 + memory + Obsidian on publish.

---

## Suggested order
1. Model resolution + `models.lock` gating for GGUF + mmproj + binary (the real gap); prove fail-closed.
2. Flip the default + kill switch. 3. Real text turn + tool calling + thinking parity. 4. Audio (mmproj)
   turn — the high-risk one. 5. Orphan-kill check. 6. Tests + perf number. 7. Hand back.

> Scope note: this is **B1 only** (default + parity proof). B2 (full bundled-GGUF/binary packaging in
> `release.yml`), B3 (GGUF-LoRA personalization live), and B4 (delete candle/mistral.rs) are separate
> follow-on prompts. If audio-via-llama.cpp proves harder than text (real risk), flag it and hand back
> text-parity + the audio findings rather than forcing it — the reviewer will sequence.
