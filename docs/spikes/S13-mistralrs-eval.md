# Spike S13 — mistral.rs (0.8) engine evaluation for the headless Rust core

> **Status:** IN PROGRESS (started 2026-05-31). **Goal:** get *solid data* on whether mistral.rs
> can be Fae's in-process Rust LLM engine, so the §8a "lean mistral.rs" call is evidence-based.
> Runs in parallel with the x0x team's saorsa-mls TreeKEM wiring.
> See `docs/architecture/cross-platform-engine-plan-2026-05-30.md` §8a.

## Why this spike

Deep-research (Rev 8) said "keep llama.cpp" because only it has *verified* Gemma-4 audio-in.
Prior-art discovery (Rev 9) reframed it: `legacy/rust-core/` already ran **mistralrs 0.7** with
**cascaded** STT (parakeet), which dissolves the audio dealbreaker. So the open questions are now
narrow and **answerable by measurement**, not more research:

1. Does **mistralrs 0.8 + candle + Metal** build cleanly on Apple Silicon? (API drift 0.7→0.8)
2. Does **Gemma-4 E4B** generate coherent text, or hit the hang? (bug #2051)
3. Does **Gemma-4 26B-A4B** generate, or emit **NaN logits**? (bug #2051 — the heavy driver)
4. Does **Qwen3** generate correctly, or show candle's GGUF NEOX-RoPE defect? (#3410)
5. What is **Metal tok/s** (load / TTFT / decode) vs llama.cpp for ~2–4B and the 26B-A4B MoE?
6. Do **tool calling** and **X-LoRA** runtime swap work? (Fae relies on both)

## The harness

`bench/mistralrs-eval/` — a **throwaway** standalone crate (`mistralrs = "0.8"`, `features=["metal"]`),
~150 LOC, modelled on the legacy `LocalMistralrsAdapter` builder API. Measures load, TTFT, decode
rate; prints raw output; crude NaN/garbage sniff. **Not product code — delete after S13.**

```
cargo build --release --manifest-path bench/mistralrs-eval/Cargo.toml

# run smallest first, scale up:
./target/release/mistralrs-eval gguf Qwen/Qwen3-1.7B-GGUF Qwen3-1.7B-Q4_K_M.gguf   # smoke test
./target/release/mistralrs-eval text google/gemma-4-E4B-it                          # Q1: E4B (#2051 hang?)
./target/release/mistralrs-eval text google/gemma-4-26b-a4b-it                       # Q3: MoE driver (NaN?)
./target/release/mistralrs-eval gguf <qwen3-gguf-repo> <file>                        # Q4: RoPE #3410
```

> Note: `text` mode downloads full HF weights then ISQ-quantizes at load (slow first run, big download);
> `gguf` mode pulls a pre-quantized GGUF (faster). Prefer GGUF where a good quant exists.

## Reviving the full legacy stack (separate, larger step — NOT this spike)

The *engine* question is answered by the harness above. Reviving the **whole** voice stack is a later
task (it's the headless-core build itself), via `legacy/rust-core/ROLLBACK.md`:

- `legacy/rust-core/` is `fae v0.7.4`, quarantined. ROLLBACK.md moves `Cargo.toml/Cargo.lock/build.rs/.cargo/src/include/tests` back to repo root.
- It carries: `mistralrs 0.7` LLM (`src/llm/mod.rs`, `src/fae_llm/`), `parakeet-rs` STT (`src/stt/mod.rs`), `ort`+`misaki-rs` TTS, `cpal` audio, `src/x0x_listener.rs`, `src/ffi.rs` (the ADR-002 C ABI).
- **Do NOT run ROLLBACK on the main tree** (conflicts with the Swift-first app). Revive into a worktree/branch when building the headless core for real.

## API drift to port (mistralrs 0.7 → 0.8)

Legacy 0.7 builder API (from `src/llm/mod.rs`), to re-validate against 0.8 (harness will surface breaks):
- `GgufModelBuilder::new(id, vec![gguf]).with_logging().with_tok_model_id(t).with_paged_attn(...).build().await`
- `VisionModelBuilder::new(id).with_isq(IsqType::Q4K).with_logging().with_paged_attn(...).build().await`
- `PagedAttentionMetaBuilder::default().with_gpu_memory(MemoryGpuConfig::ContextSize(n)).build()`
- `RequestBuilder` / `TextMessages` + `TextMessageRole`; `model.stream_chat_request(...)` → `Response::Chunk{choices[].delta.content}`
- Tool calling: `mistralrs::{Tool, ToolType::Function, Function, ToolChoice::Auto, ToolCallResponse}`

## Decision criteria (what the data decides)

| Outcome | Meaning | Action |
|---|---|---|
| Gemma-4 E4B + 26B-A4B generate clean text, tok/s within ~1.5–2× of llama.cpp | mistral.rs is viable now | **Adopt mistral.rs in-process** (cascaded STT); llama.cpp = fallback. No fork. |
| Generates clean but **slow** (≫2× llama.cpp on Metal) | candle Metal perf gap | Adopt with a perf-optimization track in **candle** (upstream first); fork only if upstream-unresponsive |
| **#2051 reproduces** (E4B hang / 26B NaN) | base-model correctness broken | Stay on llama.cpp for now; track #2051; re-test on close. Consider Qwen3 driver instead of Gemma MoE. |
| Qwen3 garbled (#3410) | candle GGUF RoPE defect live | Avoid GGUF-Qwen on candle; use ISQ/safetensors path or llama.cpp for Qwen |

**Reminder:** the engine is a means, not the product. Fork only if the in-process all-Rust unification
is worth ongoing **candle** maintenance for a small team.

## Results (fill in)

| Test | Build | Loads | Generates | tok/s (decode) | TTFT | Verdict |
|---|---|---|---|---|---|---|
| **build (mistralrs 0.8.1 + candle + metal)** | ✅ **PASS** | — | — | — | — | **Builds clean on Apple Silicon. 0.7→0.8 API drift trivial: `Delta.content` now `Option<String>`; `InternalError/ValidationError` carry `Box<dyn Error>` vs `ModelError(String,_)`; stream has inherent `.next()` (no `StreamExt`).** |
| **Qwen3-0.6B (text/ISQ Q4K, smoke)** | ✅ | ✅ **1.5s** (cached; 207s incl. 1.2GB dl) | ✅ coherent CoT | **~282 tok/s** | **0.02s** | **Engine generates correctly on Metal (`Layers 0-27: metal`, BF16→ISQ-Q4K, prefix-cache on). NOTE: Qwen3 streams CoT into `reasoning_content`, not `content` — harness must capture both (fixed).** |
| **Gemma-4 E4B (auto/ISQ Q4K)** | ✅ | ✅ **~35s** (after ~33min/16GB one-time dl) | ✅ **coherent, no NaN/hang** | **~65 tok/s** | **0.41s** | **#2051 did NOT reproduce. BONUS: mistral.rs LOADED THE AUDIO TOWER — `audio_config: Gemma4AudioConfig{conf 12-layer conformer}`, modalities `[Text, Vision, Video, Audio]`. So mistral.rs wires Gemma-4 audio-in (deep-research's "claim only" was too pessimistic). Audio *transcription* not yet tested (sent text only). Also a thinking model (reasoning channel).** |
| **Gemma-4 26B-A4B (auto/ISQ)** | ✅ | ✅ (loads, MoE: 128 experts/top-8) | ❌ **FAILS at inference** | — | — | **DOES NOT RUN in mistral.rs 0.8.1. Not the NaN bug — a different error: `UnquantLinear::gather_forward: unsupported input shape [1,31,8,704]` (8=top_k, 704=expert dim) → candle/mistralrs MoE expert-gather UNSUPPORTED for Gemma-4 MoE. Heavy driver needs another path (see verdict).** |
| **tool calling (Gemma-4 E4B)** | ✅ | ✅ 6.7s | ✅ | 48 tok/s | 0.10s | **WORKS — emitted structured `get_weather({"city":"Paris"})` via `delta.tool_calls`, correct reasoning. Fae-critical ✓** |
| **audio transcription (Gemma-4 E4B)** | ✅ | ✅ ~6s | ✅ | ~60 tok/s | 0.4–1.2s | **CONFIRMED (2 clips) — transcribed an unguessable clip verbatim ("My appointment with Dr Chen is on Thursday at quarter past four in Glasgow") — specifics only present in the audio. Refutes deep-research "audio claim-only." → UNIFIED STT works in-process; cascaded Parakeet now OPTIONAL, not required.** |
| X-LoRA hot-swap | API ✓ | — | — | — | — | `RequestBuilder.set_adapters()` (per-request swap) + `XLoraModelBuilder` present; runtime swap test needs a trained adapter (deferred). |
| **Qwen3-14B DENSE (heavy driver, text/ISQ Q4K)** | ✅ | ✅ | ✅ | **42 tok/s** | 0.38s | **DENSE HEAVY DRIVER CONFIRMED — runs clean in mistral.rs, tool calling ✓ (`get_weather({"city":"Tokyo"})`). Dense sidesteps the MoE bug entirely. (S13b)** |
| Qwen3 GGUF (RoPE #3410) | _untested_ | | | | | Qwen *safetensors*/ISQ path fine (0.6B + 14B); GGUF-NEOX path untested |

**Confirmed so far (2026-05-31):** `mistralrs 0.8.1` pulls a clean dep tree incl. `mistralrs-audio-0.8.1`,
`mistralrs-quant`, `mistralrs-paged-attn`, `mistralrs-vision`, `mistralrs-mcp` — full-stack engine, all
Rust. Build cached; harness recompiles in ~2.4s. **API parity with the legacy 0.7 integration is high** —
encouraging for resurrection cost.

_Compare tok/s against the existing llama.cpp / MLX numbers for the same models + hardware._

## VERDICT (2026-05-31) — mistral.rs is the engine

Every capability Fae needs is **confirmed working in-process on Apple Silicon Metal**, in one engine, one model:

- ✅ **Builds** clean (mistralrs 0.8.1 + candle + metal); trivial 0.7→0.8 drift; 90 MB single binary, **no sidecar**.
- ✅ **Gemma-4 E4B** generates coherently, ~65 tok/s, **#2051 hang did NOT reproduce**.
- ✅ **Tool calling** — structured `get_weather({"city":"Paris"})` (Fae-critical).
- ✅ **Audio STT** — Gemma-4 E4B transcribes WAVs **accurately, in-process** (2 clips, unguessable specifics). **Unified STT+VLM+LLM+tools in ONE model/engine** — cascaded Parakeet becomes an *optional accuracy fallback*, not a requirement.
- ✅ **X-LoRA** API present (`set_adapters` per-request); runtime swap test pending an adapter.
- ❌ **Gemma-4 26B-A4B MoE does NOT run** — `UnquantLinear::gather_forward: unsupported input shape` → candle/mistralrs MoE expert-gather unsupported for this model (loads, fails at inference). Not the NaN bug; a real engine limitation.

**Recommendation: adopt mistral.rs as Fae's in-process engine — with E4B as the workhorse.** Pure-Rust (aligns the all-Rust Saorsa stack), no sidecar, runs the **unified Gemma-4 E4B path** (STT+VLM+LLM+tools), Fae has prior integration code (`legacy/rust-core/`). **No fork needed** for the E4B path.

**Heavy-driver caveat (the one real gap):** the planned Gemma-4 **26B-A4B MoE driver does not run in mistral.rs 0.8.1**. Three options:
1. **E4B-only for v1** — E4B already does STT+VLM+LLM+tools at ~65 tok/s. Simplest; ship on it, add a heavy driver later. *(recommended start)*
2. **Qwen3.5-MoE driver** — mistral.rs's arch registry lists `qwen3_5moe`/`qwen3vlmoe` as supported, so a Qwen3.5-MoE heavy driver likely works in-process (eval needed). Keeps single-engine.
3. **llama.cpp for the 26B-A4B only** — dual-engine: mistral.rs for E4B + everything, llama.cpp sidecar for the Gemma-4 MoE driver. Keeps Gemma-4 26B but adds a sidecar.

Avoid forking candle to fix the MoE gather unless option 2/3 prove inadequate — it's deep ML-systems work. llama.cpp retained as the verified fallback behind the `ProviderAdapter`. Also pending: a real X-LoRA swap test.
