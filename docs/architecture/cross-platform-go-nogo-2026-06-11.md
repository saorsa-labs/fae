# Cross-platform Fae: go/no-go — 2026-06-11

**Status:** Decision doc with same-day proof artifacts
**Question:** Can headless/light-UI Fae go cross-platform today, or must we stay Apple-only?
**Answer:** **Go — for the core and the face, now. The voice pipeline is the only
Apple-bound layer, and it is a porting roadmap, not a blocker.** Recommended
posture: **(ii+) cross-platform core proven continuously from today** (Linux build
+ live turn in CI), orb face already on a cross-platform toolkit, full
voice-first experience ships Apple-first.

**2026-06-11 owner clarification:** "mistral everywhere" means the **LLM lane**.
It does not delete MLX from Fae's moat: personal LoRA training, Kokoro/voice
continuity work, STT until Gemma-4-audio parity is product-proven, and VLM
short-term remain MLX/Apple-first where that is the best tool. The new required
bridge is adapter portability: MLX-trained personal adapters must be converted
or exported into a PEFT/safetensors shape mistral.rs can load. See
`docs/architecture/full-cross-platform-ml-pipeline-2026-06-11.md` for the full
pipeline view across TTS, STT, wake/VAD/AEC, VLM, embeddings, and training.

## 1. Today's proof artifacts (all reproducible)

1. **`fae-daemon` cross-compiles to Linux x86_64 with zero code changes.**
   `cargo zigbuild --target x86_64-unknown-linux-gnu -p fae-daemon` — full
   workspace including mistral.rs links clean (debug 926 MB ELF, release 56 MB).
2. **The daemon runs and answers on a 2-core / 3.7 GB Hetzner VPS (saorsa-1).**
   Mock engine: `session.authenticate` → `runtime.status` → `conversation.inject_text`
   round-trip over the Unix-socket NDJSON control plane, audit log written.
3. **A real model turn on Linux.** `FAE_MODEL_ID=Qwen/Qwen3-0.6B` →
   mistral.rs downloaded + ISQ-quantized (Q4K) on-box, daemon resident at
   ~1.9 GB RAM, real LLM response returned through the same control plane.
   *(Timing recorded in §1a.)*

### 1a. Live turn record (2026-06-11)

- Engine: `mistralrs (Qwen/Qwen3-0.6B)`, CPU, Q4K ISQ, ~1.9 GB resident
- Host: saorsa-1.saorsalabs.com (Hetzner Helsinki, 2 vCPU, 3.7 GB)
- Prompt: "Reply in one short sentence: confirm you are Fae's headless core
  running on a Linux server." (`/no_think`)
- Response (92.4 s wall, `finish_reason: stop`):
  **"I am the Fae's headless core running on a Linux server."**
- Path: Unix-socket NDJSON → `session.authenticate` →
  `conversation.inject_text` → mistral.rs stream collected → audit row written.
- 92.4 s is a *proof* number (2 shared vCPUs, debug-free release build, 512-token
  budget with prompt processing), not a latency target; consumer hardware with
  Vulkan llama.cpp runs the larger Gemma4 E4B at ~56 t/s (§3 bonus find).

## 2. The orb migration changed the calculus (2026-06-11)

Per `docs/reports/orb-ui-migration-2026-06-11.md`, the product UI is now the
**orb rendered by a Rust host** (`native/rust/fae-ui-shell`): `tao` window,
`wgpu` + WGSL rendering, `muda` menus, `wry` panels. CoWork is out of the default
product (legacy behind `showLegacyCoworkUI`).

Consequence: **the face is cross-platform by construction** — tao/wgpu/wry are
the cross-platform stack. The butler redesign's brain/face split (§7 of
`butler-ui-redesign-2026-06-05.md`) is no longer "port the face someday"; the
face is already written in portable technology. What remains Apple-bound is the
**Swift runtime brain**: voice pipeline, memory, tools, scheduler, skills. That
is exactly the component map the headless-core plan (Rev 4) already covers.

So the stack converges as:

| Layer | Today | Cross-platform path | State |
|---|---|---|---|
| Face (orb + panels) | Rust (tao/wgpu/wry) on macOS | Same code, Win/Linux targets | **Portable now** (untested targets) |
| Core (control plane, engine, security) | Rust daemon | Proven on Linux **today** | **Done — artifact exists** |
| LLM inference | mistral.rs (Metal/CPU) | mistral.rs CPU + llama.cpp Vulkan fallback (chunk 3d) | Gap: non-NVIDIA GPU accel (§3b) |
| Voice (STT/TTS/speaker/AEC) | Swift/MLX (Apple) | whisper.cpp + Kokoro ONNX + WeSpeaker ONNX + cpal | **The real gap** (§3c) |
| Memory/tools/scheduler | Swift | Rust port (Rev 4 map) | Roadmap, direction-confident |

## 3. Research findings

> **Provenance: VERIFIED 2026-06-11.** The workflow's adversarial-verification
> phase was cut off by a session limit, so every claim below was re-verified
> directly against its primary source the same day. Confirmed verbatim: Google's
> "operating system into an intelligence system" (blog.google, 2026-05-12,
> Android Show 2026) and "select Samsung and Google phones this summer";
> OpenAI Pulse (2025-09-25, nightly memory-driven proactive updates,
> Gmail/Calendar connectors) and Atlas (2025-10-21, "Download for macOS",
> "true super-assistant", browser memories); mistral.rs v0.8.3 latest (pre-1.0);
> whisper.cpp's stream tool self-described "naive example" needing SDL2;
> kokoro-onnx "near real-time on macOS M1" as its only perf claim; cpal backend
> table (Linux default ALSA, PipeWire optional ≥0.3.53); Microsoft's "EV
> certificates no longer bypass SmartScreen" + "several weeks and hundreds of
> clean installs"; Ollama #15601 measured 34 vs 52.3–56.2 t/s vendoring gap.
> Two qualifications: (1) "no Vulkan in mistral.rs" is negative evidence from
> the release history (no Vulkan mentions; Metal/CUDA/CPU throughout) — strong
> but not provable from one page; (2) Ollama's "18 of 36 patches failed" figure
> sits in issue comments not re-checked line-by-line; the headline benchmark is
> verified. **Bonus finds during verification:** mistral.rs v0.8.x shipped
> mid-stream grammar enforcement + strict mode for tool calls (#2060–#2062) —
> grammar-constrained tool calling exists in our chosen engine; and Ollama
> #15601 shows **Gemma4 E4B at ~56 t/s on consumer AMD via Vulkan llama.cpp** —
> a concrete cross-platform perf datapoint for Fae's target model class.

### 3a. Vendor convergence + lock-in landscape

Every major vendor is converging on the proactive personal assistant — and every
one is building lock-in Fae structurally refuses:

| Vendor | Assistant move | Lock-in mechanism | Cross-platform? |
|---|---|---|---|
| Google | "Gemini Intelligence": Android repositioned from OS to **"intelligence system"** with proactive Gemini at OS level | Device-exclusive staged rollout (select Samsung/Pixel first, summer 2026); OEM partnerships; OS integration | No — Android-first by design |
| OpenAI | **Pulse** (Sept 2025): proactive daily research/briefings; **Atlas** browser (Oct 2025): "super-assistant" with browser memories | **Account/data gravity** — server-side memory, chat history, connectors bound to OpenAI account | Notably: Atlas launched **macOS-only** — even OpenAI went Apple-first for desktop |
| Apple | Core AI + Foundation Models (WWDC26), LLM Siri rebuild | OS floor (macOS/iOS 27), App Store, device exclusivity | No — Apple silicon only |
| Microsoft | Copilot+ PCs, Recall | Windows integration, NPU hardware tie | (not covered by surviving sources) |
| Amazon / Meta | Alexa+ / wearables | device + account | (not covered) |

The thesis holds: **proactive assistant + lock-in is the industry direction; the
unoccupied position is cross-platform + user-owned mesh (x0x) + local weights.**
And OpenAI's own macOS-first Atlas launch validates Apple-first sequencing for a
voice/desktop assistant — even with their resources.

### 3b. LLM engine on non-Apple hardware

- **mistral.rs** (v0.8.3, 2026-06-01): actively maintained, strong Gemma 4
  support (tool-calling fixes, MTP speculative decoding) — but **pre-1.0**,
  **single-maintainer concentration around EricLBuehler**, and **no Vulkan backend**
  (CUDA/Metal/CPU are the documented acceleration paths). On Windows/Linux
  consumer **AMD/Intel** GPUs, mistral.rs is CPU-only.
- **Consequence:** chunk **3d (llama.cpp fallback)** is not just resilience —
  it is **the strategic enabler for non-NVIDIA Windows/Linux GPU acceleration**
  (llama.cpp Vulkan). Priority upgraded. Keep it behind `ProviderAdapter` as a
  thin upstream-tracking adapter; do not fork/vendor llama.cpp.
- **Ollama's cautionary tale** (issue #15601): vendored llama.cpp drifted to
  ~56% of upstream throughput on AMD Strix Halo, and 18 of 36 downstream patches
  failed on a rebase attempt. Lesson: track llama.cpp via thin adapter (the
  `ProviderAdapter` seam), never fork/vendor.
- Linux GPU fragmentation is real: ROCm on Strix Halo broken across Ubuntu
  kernels 6.17–6.19 until out-of-tree drivers. Vulkan, not ROCm, is the sane
  default path.

### 3c. Voice stack on Windows/Linux — the honest gap

| Component | Cross-platform state |
|---|---|
| STT batch | **Mature**: whisper.cpp on mac/Linux/Windows with Vulkan/CUDA/ROCm/OpenVINO |
| STT streaming | **Demo-grade**: whisper.cpp's mic streaming path self-describes as a naive SDL2 example — production streaming endpointing is ours to build |
| TTS | **Real but unbenchmarked off-Apple**: kokoro-onnx (ONNX Runtime, CPU+GPU); only published perf claim is "near real-time on macOS M1" |
| Speaker ID | WeSpeaker ONNX via `ort` (Rev 4 map; parity vs shipped voiceprints unproven) |
| Capture/playback | **Fine but low-level**: cpal covers WASAPI/ALSA/CoreAudio (+ PipeWire as opt-in feature, min 0.3.53); no AEC/resampling/duplex sync built in |

Conclusion: a **text-first** cross-platform Fae is feasible *now*; a
**voice-first** cross-platform Fae is an engineering program (streaming STT
endpointing, AEC strategy, TTS perf validation), not a research risk.

### 3d. Windows distribution friction (plan for it, don't discover it)

- SmartScreen: **EV certs no longer bypass reputation** — even signed releases
  from a low-volume publisher show "unrecognized app" warnings for weeks until
  hundreds of clean installs accumulate; no manual acceleration for consumer
  endpoints. Budget: sign early, seed installs early, consider Store
  distribution for the reputation path.

## 4. Decision

**Option (ii+), upgraded by today's evidence:**

1. **Core: cross-platform from today, enforced in CI.** Add
   `cargo zigbuild --target x86_64-unknown-linux-gnu -p fae-daemon` to CI and a
   smoke job that boots the daemon (mock engine) and round-trips
   `conversation.inject_text` on a Linux runner. The moat thesis's pillar 1
   stops being roadmap and becomes a regression gate.
2. **Face: keep the orb host on tao/wgpu/wry discipline** — no Apple-only
   dependencies in `fae-ui-shell` without a documented fallback. First
   Win/Linux orb render is a cheap follow-up spike, not v1 work.
3. **Experience: Apple-first.** The full voice-first butler ships on macOS
   (Swift runtime brain), exactly as OpenAI sequenced Atlas. Non-Apple v1 is
   **text-first**: orb + panels + daemon turn loop, voice arrives as the
   whisper.cpp/Kokoro-ONNX lane matures (Rev 4 components, S1/S5 spikes).
4. **Engine: accelerate chunk 3d (llama.cpp behind `ProviderAdapter`)** — it is
   the non-NVIDIA GPU path for Windows/Linux. Thin adapter, never vendor.
5. **Training/adapters: keep MLX and add an S14 conversion spike.** `mlx-lm`
   LoRA training emits adapter artifacts (`adapters/`, `adapters.safetensors`,
   adapter config); mistral.rs can load LoRA repos using `adapter_config.json`.
   That makes MLX→mistral.rs plausible, but not proven until tensor names,
   target modules, rank/scale conventions, and behavior deltas are verified.
   Unsloth is promising for non-Apple training (NVIDIA, AMD ROCm, Intel XPU,
   and macOS/MLX paths are documented), but it is not yet a single universal
   replacement for MLX.
6. **x0x stays the differentiator** no vendor touches: every assistant above is
   single-vendor lock-in by design; none connects *the user's own machines*.
   Today's saorsa-1 daemon is, in embryo, exactly the remote Fae node x0x will
   carry.

## 5. Linkage

- **Moat thesis** (`moat-thesis-deep-research-2026-06-11.md`): pillar 1
  (cross-platform) moves from "behind the market" to "proven core + portable
  face"; pillar 4 (conductor) gains a live remote node.
- **Butler UI** (`butler-ui-redesign-2026-06-05.md` + orb migration report
  2026-06-11): the face-not-panel decision is shipped; its §7 brain/face split
  is what made today's answer "go."
- **CoWork removal** (`cowork-removal-plan-2026-06-05.md`): executed in the orb
  migration (default UI), per "super simple UX, no cowork."

## 6. Follow-ups

- [ ] CI: Linux cross-build + daemon smoke turn (mock engine) — this week.
- [ ] Re-run the verification pass on §3 claims when session limits reset.
- [ ] Spike: orb host (`fae-ui-shell`) builds/renders on Linux + Windows.
- [ ] Chunk 3d: llama.cpp `ProviderAdapter` (Vulkan target).
- [ ] Full pipeline plan: `docs/architecture/full-cross-platform-ml-pipeline-2026-06-11.md`.
- [ ] S15: cross-platform TTS benchmark — Kokoro ONNX vs Piper vs sherpa-onnx.
- [ ] S16: cross-platform training lanes — MLX vs Unsloth CUDA/ROCm/XPU vs PEFT/Axolotl.
- [ ] S17: voice front-end portability — cpal + VAD + wake + AEC/noise + speaker verification.
- [ ] Voice lane spikes (Rev 4): whisper.cpp streaming endpointing; kokoro-onnx
      RTF benchmarks on Windows/Linux hardware; WeSpeaker ONNX parity.
- [ ] Windows signing + SmartScreen reputation plan before any Windows beta.
