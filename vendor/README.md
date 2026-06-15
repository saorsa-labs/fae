# Vendored upstream source (branch `daemon-metal-fix`)

This directory contains **committed copies** of two upstream Rust crates,
vendored so the candle Metal SDPA kernel is editable and is the exact code the
`crates/` workspace builds against. It exists to carry the Gemma-4 Metal
NaN-logits fix (mistral.rs #2214) until that fix lands upstream.

## What is vendored, and from where

| Path                | Upstream repo                          | Pinned rev                                 |
|---------------------|----------------------------------------|--------------------------------------------|
| `vendor/mistral.rs` | `https://github.com/EricLBuehler/mistral.rs` | `c22c2e2b622a815821e59056c2b5952b4cbbe010` |
| `vendor/candle`     | `https://github.com/huggingface/candle.git`  | `d2afd7f7f746ac72236f81736135de1fcd543426` |

These are the exact revisions cargo had pinned in `crates/Cargo.lock` before
vendoring. The source was copied verbatim from the local cargo git checkouts
(`~/.cargo/git/checkouts/...`) at those revs with `.git` metadata stripped, so
the trees are byte-identical to the pinned upstream commits except for the
in-repo fix described below.

Verify provenance:

```bash
# every candle source file is identical to the pinned upstream checkout,
# except the single fixed file:
diff -rq ~/.cargo/git/checkouts/candle-*/d2afd7f vendor/candle
# -> only candle-metal-kernels/src/kernels/sdpa.rs differs
```

## How the build uses it

`crates/Cargo.toml` redirects the upstream git dependencies to these local
paths with a `[patch]` section (the patch keys are the upstream URLs, which are
rev-agnostic, so every rev of those URLs resolves to the vendored path). No
network fetch of mistral.rs/candle happens; the workspace compiles the vendored
source directly.

`crates/justfile` exports `RUSTFLAGS := ""` for all recipes. The dev shell sets
`RUSTFLAGS="-D warnings"`, which cargo applies even to dependencies and bypasses
the automatic lint-cap that normally shields *git/registry* deps (path deps are
not capped against env RUSTFLAGS). Clearing it lets upstream's own warnings stay
warnings; our zero-warning gate is the explicit `cargo clippy -- -D warnings`
step, which still hard-fails on our crates while capping lints on the vendored
path deps.

## The fix

`vendor/candle/candle-metal-kernels/src/kernels/sdpa.rs`, `call_sdpa_full`:

```rust
// When an explicit additive mask is supplied it already encodes causality
// ... so the in-kernel `do_causal` path is redundant ... -> 0/0 = NaN ...
let do_causal = do_causal && !has_mask;
```

This is the **only** change to the vendored source. It is upstream-PR-ready for
EricLBuehler/candle; see `docs/architecture/daemon-perf-triage-2026-06-15.md`
("RESOLVED") for the full root-cause analysis, evidence, and verification.

## Un-vendoring

Once the candle fix lands upstream and the pin is bumped to include it, delete
the two `[patch]` blocks in `crates/Cargo.toml` and remove this `vendor/`
directory.
