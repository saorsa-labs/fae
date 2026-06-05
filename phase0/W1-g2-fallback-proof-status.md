# W1 — G2 fallback proof status

Status: **done for first tool-call parity proof**  
Blocker class: **commit-blocker**  
Evidence grade: **measured-locally** + **repo-verified artifact**

## Result

A real two-engine G2 tool-call parity run passed.

- Result JSON: `bench/engine-parity/results/qwen06-mistral-qwen36-llama.json`
- Result report: `bench/engine-parity/results/qwen06-mistral-qwen36-llama.md`
- Primary: `mistral.rs` with `Qwen/Qwen3-0.6B`
- Fallback: live `llama-server` on `127.0.0.1:62447` with `qwen-3.6-dense-8bit`
- Case: `weather-tool-paris`
- Prompt/schema: same fixture prompt and `get_weather(city: string)` tool schema
- Normalized primary tool call: `get_weather({"city":"Paris"})`
- Normalized fallback tool call: `get_weather({"city":"Paris"})`
- `engine-parity check` status: `PASS`

## Commands run

```bash
cargo run --manifest-path bench/engine-parity/Cargo.toml -- \
  run-llama bench/engine-parity/fixtures/weather-tool-call.json \
  http://127.0.0.1:62447 qwen-3.6-dense-8bit \
  bench/engine-parity/results/qwen36-llama-probe.json

cargo run --manifest-path bench/engine-parity/Cargo.toml -- \
  run-mistral bench/engine-parity/results/qwen36-llama-probe.json \
  Qwen/Qwen3-0.6B \
  bench/engine-parity/results/qwen06-mistral-qwen36-llama.json

cargo run --manifest-path bench/engine-parity/Cargo.toml -- \
  check bench/engine-parity/results/qwen06-mistral-qwen36-llama.json
```

## Validation

```bash
cargo fmt --manifest-path bench/engine-parity/Cargo.toml
cargo clippy --manifest-path bench/engine-parity/Cargo.toml --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo check --manifest-path bench/engine-parity/Cargo.toml --all-targets
cargo run --manifest-path bench/engine-parity/Cargo.toml -- check bench/engine-parity/fixtures/weather-tool-call.json
cargo run --manifest-path bench/engine-parity/Cargo.toml -- render bench/engine-parity/fixtures/weather-tool-call.json
cargo run --manifest-path bench/engine-parity/Cargo.toml -- check bench/engine-parity/results/qwen06-mistral-qwen36-llama.json
cargo run --manifest-path bench/engine-parity/Cargo.toml -- render bench/engine-parity/results/qwen06-mistral-qwen36-llama.json
```

All passed.

## Caveats / follow-ups

- The first PASS uses `Qwen/Qwen3-0.6B` for the `mistral.rs` primary and `qwen-3.6-dense-8bit` for the live llama-server fallback. It proves same prompt/schema normalized tool-call parity across both engine paths, not same-exact-model parity.
- `google/gemma-4-E4B-it` load was attempted through the adapter but did not complete within 30 minutes in this run; repeat separately if the owner requires Gemma-4 E4B specifically for W1.
- Add a non-tool coherent text fixture before Apple v1, as requested by the broader G2 acceptance contract.

## Gate-exit impact

W1 no longer blocks on “no real adapter/no real run.” It has a measured local PASS artifact. Remaining Phase 0 gate work moves to W2/W3/W4/W5/W6 unless owner requires same-exact-model or Gemma-4 E4B parity before considering W1 cleared.
