# Upstream PR draft — candle: don't combine `do_causal` with an explicit mask in Metal `call_sdpa_full`

**Target:** `EricLBuehler/candle` (the fork mistral.rs pins; the same kernel exists
in upstream `huggingface/candle`). Cross-reference `EricLBuehler/mistral.rs#2214`
and `#2051`.

**File:** `candle-metal-kernels/src/kernels/sdpa.rs` (`call_sdpa_full`).

## Summary

The Metal steel `attention` prefill kernel produces **NaN logits at specific,
periodic sequence lengths** when invoked with *both* an explicit additive
attention mask *and* `do_causal = true`. Gemma-4 on Metal triggers this on every
turn whose total prompt length lands in a bad window.

## Root cause

When a caller supplies an explicit causal/sliding-window mask, that mask already
encodes causality. Passing `do_causal = true` additionally enables the kernel's
in-shader causal handling: the `kb_lim` block-truncation
(`scaled_dot_product_attention.metal`, `if (do_causal) { … kb_lim = … }`) plus
the separate causal-triangle masking loop. The two causal mechanisms overlap and,
at sequence lengths where the partial K-tile boundary lines up unfavourably, a
query row ends up with **every** score masked to `-inf`. Its softmax normalizer
`sum(exp) == 0`, and the final `Otile.row_bin_op<DivOp>(sum_score)` computes
`0 / 0 = NaN`, poisoning the output and hence the logits.

The failure is periodic in total length (≈ one period per `BK`-aligned boundary)
and quant-independent — it is in the attention masking path, not the matmul.

## Fix

```rust
// candle-metal-kernels/src/kernels/sdpa.rs, in call_sdpa_full, after has_mask:
let do_causal = do_causal && !has_mask;
```

When an explicit mask is present it carries causality, so the in-kernel
`do_causal` path is redundant; disabling it avoids the degenerate fully-masked
row. No correctness change (the mask still enforces causality) and no measurable
performance change (the upper-triangle skip is not the prefill bottleneck;
measured identical prefill latency on an M5 Max).

## Why not patch the kernel's divide instead

Guarding the final `DivOp` (`y == 0 ? 0 : x / y`) and/or sanitizing non-finite
pre-softmax scores were both tried and did **not** cure it — the defect is
structural to the `kb_lim` + triangle interaction under a redundant mask, not the
final divide alone. The minimal correct fix is to not double-apply causality.

## Verification (Gemma-4-E4B, Metal, Apple M5 Max)

- Deterministic repro (38,000-char system prompt): **FAIL → PASS**, both Q4K and
  Q8_0 ISQ.
- Length sweep, 48 lengths spanning 5 periodic failure windows: **19/48 FAIL →
  0/48 FAIL** for Q4K, and 0/48 FAIL for Q8_0.
- Clean-decode throughput unchanged (~70-74 tok/s, run-to-run variance).
