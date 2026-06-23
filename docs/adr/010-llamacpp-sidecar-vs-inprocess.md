# ADR-010: llama.cpp via `llama-server` Sidecar, not In-Process FFI Bindings

Status: Accepted
Date: 2026-06-18

## Context

Fae is standardising inference on llama.cpp (the cross-platform serving pivot, gaps B1–B4 in
`docs/architecture/cross-platform-brain-llamacpp-2026-06-16.md`), behind the `ProviderAdapter` seam in
`crates/fae-engine`. There are two ways to embed llama.cpp in the Rust daemon:

- **A — Sidecar (current B1):** the daemon spawns the prebuilt `llama-server` binary as a supervised
  child and talks to it over its OpenAI-compatible HTTP/SSE API on loopback. Implemented in
  `LlamaServerAdapter` (~655 lines: spawn/await-ready/kill-on-drop, SSE streaming, per-request LoRA
  scale, `engine.reload`); the binary is SHA-pinned (`scripts/llamacpp-runtime.lock.json`), bundled,
  and signed.
- **B — In-process FFI bindings:** link llama.cpp into the daemon binary via a Rust crate
  (`llama_cpp` / `utilityai` `llama-cpp-2` / `eugenehp` `llama-cpp-rs`) and load the GGUF + stream
  tokens in-process, compiling the backend (`cuda`/`vulkan`/`metal`/`hipblas`) via crate feature flags.

By June 2026 the binding ecosystem closed the capability gaps that previously ruled B out: multimodal
(`--features mtmd`, mmproj), MTP/speculative decoding, and per-request LoRA scale (via the C API
`llama_set_adapter_lora(ctx, adapter, scale)`) are all reachable in-process. So the decision rests on
build/operational factors, not capability.

Note: the often-cited `llama_cpp` (binedge/edgenai) crate is the friendliest but least-maintained,
text-leaning binding. The feature-complete maintained options are `utilityai/llama-cpp-rs`
(`llama-cpp-2`) and `eugenehp/llama-cpp-rs` (tracks llama.cpp ~`94a220cd6`, June 2026, TurboQuant +
MTP + mtmd).

## Decision

**Use the `llama-server` sidecar (option A) for B1–B4.** Keep the `ProviderAdapter` seam so an
in-process `LlamaCppCrateAdapter` can be added behind the same trait later, without disturbing callers.

### Why the sidecar, on the axes Fae actually cares about

1. **Build / CI burden (decisive).** In-process forces the daemon build to **compile llama.cpp with a
   GPU backend per target** — dragging the CUDA toolkit, Vulkan SDK, Xcode/Metal, and ROCm into Fae's
   CI matrix. The sidecar consumes llama.cpp's **official prebuilt release binaries** (the project's CI
   already produces metal/cuda/vulkan/hip/cpu variants), so Fae builds **no C++ at all** and the daemon
   stays a clean, fast, pure-Rust binary. For a small team doing cross-platform, this is a large,
   ongoing cost difference — and the "cross-platform" framing actually favours the sidecar: you get
   per-platform GPU support by *downloading*, not by *building*.
2. **Consistency with retiring candle (ADR-aligned).** The pain being removed by deleting
   `vendor/candle` + `vendor/mistral.rs` (B4) is precisely *a heavy vendored-C++ build coupled into the
   daemon* (the `env -u RUSTFLAGS` breakage). In-process llama.cpp re-introduces that exact coupling.
   The sidecar keeps the daemon decoupled from any C++ compile.
3. **Crash isolation.** An FFI segfault (llama.cpp edge cases, OOM, malformed GGUF) crashes the whole
   daemon; a sidecar segfault is recoverable — the daemon restarts it and reports a clean error. Suits
   reliability-first Fae (the supervise/restart/orphan-kill machinery already exists).
4. **Upstream churn.** Pinning a **binary by SHA** is far more stable than coupling the daemon to a
   binding crate's vendored llama.cpp commit and its ABI breaks.
5. **Performance is a non-factor.** At Fae's single-user, seconds-per-turn conversational QPS, loopback
   SSE overhead is in the microseconds — the in-process "Rust iterator streaming" elegance buys no
   measurable latency.
6. **Audio is equally experimental either way** — both paths sit on the same `libmtmd`/`clip.cpp`, so
   in-process offers no reliability advantage for Gemma-4 audio. (STT-fallback planning — Qwen3-ASR /
   whisper.cpp — applies regardless; see the B1 prompt.)

## Consequences

- Fae ships, per platform: one pure-Rust daemon + one prebuilt, SHA-pinned, signed `llama-server`.
- The daemon never builds llama.cpp; cross-platform GPU support comes from upstream release binaries.
- Sidecar lifecycle (spawn, ready-poll, kill-on-drop, orphan-kill via `DaemonProcessRegistry` +
  parent-watch) is part of the contract and already implemented.
- A failed/segfaulting sidecar is a recoverable, reported condition — not a daemon crash.

## Revisit criteria (when to add an in-process adapter behind the same seam)

- **iOS / iPadOS target.** Subprocesses are not permitted in the iOS sandbox, so an in-process binding
  (or static lib) becomes *mandatory* there. This is the one scenario that forces option B, and it is a
  realistic future for a voice assistant.
- **The per-target C++/GPU build is already paid for** (e.g. Fae is already shipping a GPU-compiled
  artifact and the CI matrix exists), making the in-process build burden marginal.

Because the `ProviderAdapter` seam makes adding `LlamaCppCrateAdapter` cheap later, the cost of
*deferring* option B is ~zero while the cost of *adopting* it now is high. That asymmetry is the
decision.

## Alternatives considered

- **In-process via `llama-cpp-2` / `eugenehp/llama-cpp-rs`.** Technically capable as of June 2026
  (mtmd, MTP, LoRA via C API). Rejected now for the build/coupling/isolation reasons above; retained as
  the future iOS path behind the seam.
- **In-process via `llama_cpp` (binedge).** Rejected outright — least maintained, text-leaning; not a
  serious option for Fae's multimodal needs even if going in-process.

## Related

- `docs/architecture/cross-platform-brain-llamacpp-2026-06-16.md` (B1–B4 pivot)
- ADR-002 (embedded Rust core — historical in-process C-ABI assumptions, explicitly superseded)
- ADR-003 (local LLM inference)
