# Daemon "glacial inference" triage — 2026-06-15

**Hardware:** Apple M5 Max / 128 GB, macOS (Metal 4, 40-core GPU).
**Symptom reported:** `fae-daemon` Gemma 4 turns at ~0.01–0.08 tok/s, 70–150 s ttfa.
**Prior triage hypothesis (handed to this investigation):** candle is executing on
CPU despite `Metal.framework` being linked — i.e. one of
(a) `metal` cargo feature links the framework but candle's Metal **compute backend**
is inactive, (b) `AutoDeviceMapParams` places all layers on CPU, or
(c) this mistral.rs/candle revision does not drive M5 silicon.

## Verdict: the CPU-execution hypothesis is FALSE. All three sub-hypotheses refuted.

The daemon runs Gemma 4 **on the M5 Max GPU at full speed**. The "glacial" latency is
the **Gemma-4-on-Metal NaN-logits failure** (already known —
`reference_gemma4_metal_nan_bug.md`) multiplied by the daemon's **4-attempt
prompt-length pad-retry loop**, each attempt re-prefilling the ~7.5k-token live
prompt. It is *repeated failed-then-retried inference*, not slow inference.

### Evidence (all from real runs on this M5 Max, 2026-06-15)

Pinned mistral.rs `c22c2e2b…`, candle `d2afd7f`, Gemma 4 E4B, ISQ Q4K, BF16.

**1. The `metal` compute backend is fully compiled (refutes hypothesis a).**
`cargo tree -p fae-engine --target aarch64-apple-darwin -e features` shows the
feature chain end-to-end:
```
mistralrs feature "metal" → mistralrs-core feature "metal" → candle-nn feature "metal"
candle-core feature "metal"   (explicitly enabled, not just "default")
```
`candle-core/metal` is the compute backend, not merely the framework link.

**2. Every layer loads on Metal (refutes hypothesis b).** Standalone run with
`RUST_LOG=info` (the Swift app swallows daemon tracing; the standalone run exposes it):
```
INFO auto_device_map: The following sub-models will not be device mapped and will be loaded on metal[4294969224]: vision, audio
INFO Model has 42 repeating layers.
INFO Layers 0-41: metal[4294969224] (108 GB)
```
All 42 transformer layers + vision + audio towers on `metal[…]`. Zero CPU offload.
The auto device-map budget is healthy: `metal_sysctl_floor_bytes()` correctly maps
`iogpu.wired_limit_mb = 0` (the OS default = "unset") to the 96 GB system-RAM floor
(`(128 GB * 3/4)`), so there is no undersized-budget spill.

**3. Clean Metal decode = 72.92 tok/s (refutes hypothesis c, and the whole CPU theory).**
A plain text turn (no audio, no tools, no oversized system prompt) through the
**real** `LocalMistralrsAdapter::load` path:
```
[text_tps] loaded google/gemma-4-E4B-it in 12.8s
[text_tps] ttfa=3.23s total=4.1s tokens=68 decode_tps=72.92 (steady-state, excludes prefill)
```
**72.92 tok/s.** CPU execution of E4B would be ~1–5 tok/s. The M5 GPU is driven
correctly and fast. (The "prefill ~200 tps" and "12B 8× slower" data points that
were read as a CPU signature are equally explained by the retry loop: a larger model
pays proportionally more per failed re-prefill, and prefill timing measured *during*
the retry storm is not steady-state.)

**4. The real failure is NaN logits at a specific prompt length.** Replaying a
captured live daemon payload (`/tmp/fae-dumps/inject-…-r4.json`: ~7.5k-token system
prompt, 36 tools, 5 messages, trailing audio) through `asr_replay`:
```
# production sampler path (topk=160 → CPU sampling):
Error: Inference(Invalid sampling probability at index 2: NaN. The model likely produced NaN/Inf logits.)

# deterministic/greedy path (device top-k):
Error: Inference(invalid Metal top-k softmax normalizer)
```
Two different sampler error strings, **one root cause: the model's forward pass emits
NaN/Inf logits for this prompt length.** The CPU-sampling workaround (`set_sampler_topk(160)`,
> `MAX_DEVICE_TOP_K = 128`) successfully avoids the Metal top-k kernel, but the logits
feeding the sampler are *already* NaN — so it fails anyway, just with a clearer message.

### Why the live daemon looks "glacial" (the latency mechanism)

`fae-daemon/src/session.rs::inject_text` wraps each turn in a retry loop:
```rust
const NAN_RETRY_PADS: [usize; 3] = [4, 24, 80];
for (attempt, pad_units) in std::iter::once(0).chain(NAN_RETRY_PADS).enumerate() { … }
```
On a NaN-logits failure it pads the prompt and retries — up to **4 full attempts**,
each a complete re-prefill of the ~7.5k-token prompt + audio re-encode. When the live
prompt length sits in the bad window and the coarse pads don't shift it out (observed:
the r4 payload still NaNs after a content-length change), several/all attempts fail →
tens of seconds of wasted prefill → the 70–150 s ttfa and the apparent ~0.01–0.08 tok/s.

### Root cause (upstream)

`google/gemma-4-E4B-it` on candle's **Metal** backend produces non-finite logits when
the *total* prompt length lands in narrow windows relative to the prefill-chunk / SWA
boundary. The eager-attention softmax already runs in F32
(`mistralrs-core/src/attention/mod.rs:435-452`), so this is not naive BF16 softmax
overflow; it points at the flash/SWA prefill-chunk masking path (a fully-masked
attention row → `0/0` after softmax). Present at the pinned `c22c2e2b`. This is an
upstream candle/mistral.rs defect, not a Fae device-selection bug.

## Recommended fix

The brief's CPU-placement fixes do **not apply** — the device is already Metal with
all 42 layers on the GPU, so `Device::new_metal(0)` is already what `best_device`
returns, and forcing a single-Metal device-map is a no-op. There is nothing to "move
off CPU."

The defect is upstream (candle/mistral.rs Gemma-4 Metal prefill-chunk masking,
`mistralrs-core/src/vision_models/gemma4/text.rs` around the
`is_paged_prefill_chunk` / `make_causal_mask` / sliding-window mask path — a
fully-masked attention row at certain total lengths → `0/0` NaN after softmax). It
cannot be patched safely inside this repo while keeping `crates && just check` green,
because the fix lives in a vendored, git-pinned dependency's Metal kernel/masking code.

Recommended actions, in priority order:

1. **File upstream** against EricLBuehler/mistral.rs with the replayable payload
   (`/tmp/fae-dumps/inject-…-r4.json`) and the two error strings. This is the only
   real fix. Tracks the existing `reference_gemma4_metal_nan_bug.md` lead.
2. **Bump the pin** to a newer mistral.rs/candle rev — **TESTED, not a cure** (see
   "Pin-bump test" below). Bumping `c22c2e2b → master ab001013` (2026-06-15) leaves
   the deterministic repro FAILing on both Q4K and Q8_0. Re-test on future revs with
   `examples/nan_repro.rs`.
3. **Harden the daemon retry net** (`session.rs` `NAN_RETRY_PADS`): the current coarse
   `[4, 24, 80]` pads provably fail to escape on the r4 payload (it still NaN-ed after
   1-char, multi-word, and sentence-length trailing-content changes). A finer
   single-token-granularity sweep would raise the escape probability — but this needs a
   harness that *continues past the first NaN* to measure escape rate (the current
   `asr_replay` aborts on first `?`), so it is left as a follow-up rather than shipped
   unverified.

**What this branch contains:** `crates/fae-engine/examples/text_tps.rs` — the
text-only Metal decode probe used to produce the 72.92 / 57.46 tok/s baselines that
refute the CPU hypothesis. No production-code change is made, because the evidence
shows there is no device-placement bug to fix in Fae; the misdiagnosis was the bug
under investigation, and correcting it (with reproducible numbers) is the deliverable.

### Reproduction commands (all run on M5 Max, 2026-06-15)

```
# clean Metal decode baseline (refutes CPU): ~73 tok/s
RUST_LOG=warn FAE_MODEL_ID=google/gemma-4-E4B-it \
  cargo run --release -p fae-engine --example text_tps -- --max 300

# device placement (all layers on metal[…]):
RUST_LOG=info FAE_MODEL_ID=google/gemma-4-E4B-it \
  cargo run --release -p fae-engine --example asr_isolation -- --wav /tmp/asr_q_16k.wav --mode transcribe

# the real failure on the live prompt shape (NaN logits):
RUST_LOG=info FAE_MODEL_ID=google/gemma-4-E4B-it \
  cargo run --release -p fae-engine --example asr_replay -- --payload /tmp/fae-dumps/inject-1781284748314-r4.json
```

## Pin-bump test (2026-06-15) — `c22c2e2b → ab001013` does NOT cure the NaN

**Upstream status:** mistral.rs issue **#2214** (this project's report — exact repro:
38,000-char filler system + 633-char user) and cross-ref **#2051** are both **OPEN**
with no fix PR and no closing reference. The only commit touching the Gemma-4 path
since the pin is **#2227 (`2ff671b9`, diffusiongemma)** — it adds a
`requires_full_prefill_queries` guard to the KV-sharing fast-prefill plan
(`gemma4/text.rs`), which is unrelated to the Metal attention/ISQ kernel tiling the
issue author identified as root cause. **candle is pinned at the same `d2afd7f`** on
both mistral.rs revs, so the kernel where the NaN lives is byte-identical.

**Empirical test** via `examples/nan_repro.rs` (the exact #2214 synthetic payload),
real runs on M5 Max, `RESULT: PASS`/`FAIL`:

| mistral.rs rev | Q4K | Q8_0 |
|---|---|---|
| `c22c2e2b` (current pin, BEFORE) | **FAIL** (NaN) | **FAIL** (NaN) |
| `ab001013` (master HEAD, AFTER bump) | **FAIL** (NaN) | **FAIL** (NaN) |

Verbatim on all four runs:
```
RESULT: FAIL (inference failed: Invalid sampling probability at index 2: NaN. The model likely produced NaN/Inf logits.)
```

**Outcome:** bump **reverted** (Cargo.toml + Cargo.lock back to `c22c2e2b`). The bump
compiled cleanly against the new API (E4B loaded in 13 s; only public-API change was
an added `BlockDenoisingProgress` export — no adapter breakage), so a future bump is
mechanically safe; it just doesn't fix the NaN yet. Kept on the branch: the
`nan_repro.rs` regression harness (re-run on any future pin to detect a FAIL→PASS) and
a Cargo.toml comment recording this negative result.

```
# deterministic NaN repro (FAIL on c22c2e2b, both quants):
FAE_ISQ=Q4K  FAE_MODEL_ID=google/gemma-4-E4B-it cargo run --release -p fae-engine --example nan_repro
FAE_ISQ=Q8_0 FAE_MODEL_ID=google/gemma-4-E4B-it cargo run --release -p fae-engine --example nan_repro
```

## RESOLVED (2026-06-15) — vendored candle kernel fix, branch `daemon-metal-fix`

The NaN is **fixed at source** in a vendored copy of the candle Metal SDPA
dispatch. The CPU-execution theory above stands (there is no device-placement
bug); the surviving defect was the Gemma-4 Metal NaN, now root-caused and cured.

### Vendoring

`mistral.rs` and `candle` are vendored as committed source under `vendor/`, at
the exact cargo-pinned revs (copied from the local `~/.cargo/git` checkouts,
`.git` stripped):

- `vendor/mistral.rs` = EricLBuehler/mistral.rs @ `c22c2e2b622a815821e59056c2b5952b4cbbe010`
- `vendor/candle`     = huggingface/candle      @ `d2afd7f7f746ac72236f81736135de1fcd543426`

`crates/Cargo.toml` redirects the git deps to these paths via `[patch]` (keys
are the upstream URLs, rev-agnostic). The workspace builds against the editable
vendored kernels; the un-fixed `nan_repro` reproduced the FAIL **through the
vendored copies** before the fix, proving we execute the code we edit.
`crates/justfile` clears the dev shell's `RUSTFLAGS="-D warnings"` for all
recipes (env `-D warnings` bypasses cargo's lint-cap for *path* deps and would
turn upstream's own warnings into hard errors); the zero-warning gate for our
crates remains the explicit `cargo clippy -- -D warnings` step (clippy caps
lints on path deps, so they warn but never fail the build).

### Root cause

The text-decoder prefill attention dispatches (head_dim 256, BF16, custom mask)
to candle's **steel `attention` prefill kernel** via `candle_nn::ops::sdpa` →
`call_sdpa_full`, with **both** an explicit additive causal/sliding mask *and*
`do_causal = true`. The mask already encodes causality (mistral.rs's own comment
in `attention/mod.rs`: "The mask carries causality already"); `do_causal` then
*redundantly* re-applies causality through the kernel's `kb_lim` block-truncation
(`scaled_dot_product_attention.metal:2065-2068`) plus its separate causal
triangle loop (`:2120-2141`). The combination drives a query row fully masked at
specific **periodic** total lengths → `sum(exp scores) = 0` → the final
normalize `Otile.row_bin_op<DivOp>(sum_score)` does `0 / 0 = NaN` → NaN logits.

Quant-independent (Q4K and Q8_0 both fail), as expected: the defect is in the
attention masking path, not the ISQ matmul.

### Evidence (all real runs, M5 Max, 2026-06-15)

1. **Periodicity map** (`examples/nan_sweep.rs`, 48 lengths, base 36000, +128
   chars, Q4K): baseline FAILs in narrow bands —
   `[37280-37664], [38304-38688], [39328-39584], [40224-40608], [41248-41632]`
   — **band-start period ≈ 1024 chars**, ~512-char-wide windows. This periodic
   "partial-tile" signature is the fingerprint of a masking-boundary bug, not
   BF16 overflow. Baseline summary: **19/48 FAIL**.
2. **Backend isolation**: an env probe confirmed the prefill takes
   `candle_sdpa_steel q_len=8427 k_len=8427 head_dim=256 do_causal=true
   mask=true`. Routing the same prompt to the slow `naive_sdpa` path
   (`FAE_NO_STEEL_SDPA=1`) → **PASS** (27.2 s). The steel kernel is the source.
3. **`do_causal` isolation**: forcing `do_causal=false` for the steel call when
   a mask is present → **PASS at full steel speed (5.7 s vs 6.5 s baseline)**,
   while the baseline (do_causal=true) FAILs. This pins the bug to the
   redundant in-kernel causal path and shows the fix is free.
4. **Heisenbug corroboration**: inserting a host-side NaN scan (device sync)
   between layers makes the run PASS — consistent with a GPU-async/degenerate
   masking hazard, not a deterministic host-visible arithmetic error.

### The fix (candle, upstream-PR-ready)

One line in `vendor/candle/candle-metal-kernels/src/kernels/sdpa.rs`
(`call_sdpa_full`): `let do_causal = do_causal && !has_mask;` (with a comment).
When an explicit mask is supplied it already encodes causality, so the kernel's
`do_causal` constant is forced off, avoiding the buggy redundant path with no
correctness loss and no measurable perf change. The `.metal` shader is
**unchanged** (earlier kernel-guard experiments — a `DivOp` zero-guard and a
pre-softmax score sanitizer — did NOT cure it and were reverted; the defect is
structural to the `kb_lim`/triangle interaction, not the final divide alone).

### Verification

- `nan_repro` **FAIL → PASS** for **both Q4K (5.6 s) and Q8_0 (5.4 s)**.
- `nan_sweep` (same 48 lengths as baseline): **Q4K 0/48 FAIL** (was 19/48);
  Q8_0 0/48 FAIL — every previously-failing length across all five periodic
  windows now passes.
- `text_tps` decode throughput unchanged (no regression) — the do_causal
  upper-triangle skip is not the prefill bottleneck.

### Upstreaming / follow-ups

- Upstream the candle `sdpa.rs` one-liner to EricLBuehler/candle and reference
  it on mistral.rs #2214; un-vendor once it lands (delete the two `[patch]`
  blocks).
- The daemon's `NAN_RETRY_PADS` pad-retry loop (`fae-daemon/src/session.rs`,
  the 4× re-prefill that caused the 70-150 s ttfa) is now dead weight on the
  vendored build and can be removed in a follow-up once the fix soaks.
