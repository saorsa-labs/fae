# S13 independent replication (W6 / G1) — 2026-06-02

> Phase 0 W6 artifact: independent replication of the S13 engine claims on **another machine + another OS** (Linux x86_64), to harden the `measured-locally` (single-Mac) evidence behind the mistral.rs engine decision.

## TL;DR
**Cross-OS BUILD + CORRECTNESS confirmed on Linux x86_64.** mistral.rs (`mistralrs 0.8.1` + candle 0.10.2) builds cleanly on Ubuntu 24.04 and **generates + tool-calls identically to the macOS/Metal runs.** **CUDA throughput was NOT validated** — DigitalOcean had no NVIDIA GPU capacity at run time, so this is a **CPU-only** node. W6 status: **Linux correctness ✓ / CUDA performance deferred.**

## Environment (independent of the original S13 Mac)
| | |
|---|---|
| Provider / instance | DigitalOcean `c-32` (CPU-optimized) |
| CPU | Intel Xeon Platinum 8280 @ 2.70 GHz, **32 vCPU** |
| RAM / disk | 62 GiB / 385 GiB free |
| OS / kernel | **Ubuntu 24.04.3 LTS, Linux 6.8.0 x86_64** |
| GPU | **none** (DO GPU droplets — RTX 4000/6000 Ada, L40S, H100 — all returned "not available in region" across nyc2/tor1/atl1/nyc3) |
| Engine build | `mistralrs 0.8.1`, candle-core/nn `0.10.2`, **`features = []` (CPU)**, rustc 1.96.0 |

## Results

| Test | Build | Generates | Tool calling | Decode (CPU) | Verdict |
|---|---|---|---|---|---|
| **Build** (mistralrs+candle, Linux x86_64 CPU) | ✅ clean, **3m24s** | — | — | — | **Cross-platform build confirmed** — no Mac/Metal-specific assumptions block a Linux build. |
| **Qwen3-0.6B** (text/ISQ-Q4K) | ✅ | ✅ coherent reasoning | ✅ **`get_weather({"city":"Tokyo"})`** | ~7.7 tok/s | **Engine behaves identically to macOS** — same structured tool call, coherent output. Load 13.9s, TTFT 9.1s (CPU). |
| **Qwen3-14B dense** (driver, text/ISQ-Q4K) | ✅ | ✅ coherent reasoning | (n/a — see note) | ~2.1 tok/s | **Dense heavy-driver loads + generates correctly on Linux** (load 229s incl. 28 GB dl; TTFT 52s). Tool call not reached because `--max 40` was too small for a thinking model at CPU speed (still mid-reasoning) — *not* an engine failure; tool calling already proven on the 0.6B run. |

> Decode speeds are **CPU** numbers and are **not** representative — they exist only to prove correctness. Meaningful tok/s requires the CUDA path (deferred).

## What this does and does NOT establish
- ✅ **Does:** the engine + adapter are genuinely cross-platform — clean Linux build, correct generation, correct tool calling. Removes the "single-machine, maybe Mac-specific" doubt over the S13 engine decision.
- ⚠️ **Does NOT:** validate **CUDA performance** on Linux (no GPU capacity), nor **Gemma-4 E4B audio-in on Linux** (Gemma-4 is a gated HF repo; not downloaded to a throwaway node without the owner's HF token — the unified-audio path was already proven on the Mac in S13).

## Follow-ups (to fully close G1/W6 on the GPU path)
1. Re-run on an **NVIDIA GPU Linux box** (DO when capacity returns, or another provider / local GPU) with `features = ["cuda"]` → record real E4B / Qwen3-14B tok/s + the **same-weights GGUF parity** case (G2 strengthening).
2. Optional: validate **Gemma-4 E4B audio-in on Linux** (needs HF token on the node).

## Provenance
- Run by the headless-core team on 2026-06-02. Droplet `fae-w6` (`45.55.86.77`), created and destroyed within the session.
- Harness: `bench/mistralrs-eval/` (copied to the droplet, patched `metal`→CPU). Evidence grade for these results: **independently-replicated (build + correctness, CPU/Linux)**; CUDA performance remains **single-machine/Apple-only** until the GPU follow-up.
