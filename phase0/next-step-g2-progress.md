# G2 progress — engine parity scaffold

Implemented `bench/engine-parity` Rust crate with real `mistral.rs` primary and OpenAI-compatible `llama-server` fallback adapters.

## What exists

- `bench/engine-parity/Cargo.toml`
- `bench/engine-parity/src/lib.rs`
- `bench/engine-parity/src/main.rs`
- `bench/engine-parity/fixtures/weather-tool-call.json`
- `bench/engine-parity/results/.gitkeep`

The crate defines:

- `ProviderAdapter` trait shape;
- normalized tool-call/result data structures;
- OpenAI-style tool call normalization;
- expected-vs-primary-vs-fallback tool-call comparison;
- `engine-parity check <result.json>`;
- `engine-parity render <result.json>`;
- `engine-parity run-llama <input-result.json> <endpoint> <model> <output-result.json>` for a live `llama-server /v1/chat/completions` fallback run;
- `engine-parity run-mistral <input-result.json> <model-id> <output-result.json>` for a live `mistral.rs` primary run;
- `engine-parity run-both <input-result.json> <mistral-model-id> <llama-endpoint> <llama-model> <output-result.json>` for a real two-engine parity run.

## What this does NOT prove

A first real W1/G2 tool-call PASS exists:

- result JSON: `bench/engine-parity/results/qwen06-mistral-qwen36-llama.json`
- result report: `bench/engine-parity/results/qwen06-mistral-qwen36-llama.md`
- primary: `mistral.rs` with `Qwen/Qwen3-0.6B`
- fallback: live `llama-server` at `127.0.0.1:62447` with `qwen-3.6-dense-8bit`
- normalized tool call from both: `get_weather({"city":"Paris"})`

Caveats: this clears the first tool-call fallback proof, but broader G2 hardening should still repeat with the target Gemma-4 E4B primary when load time is practical and add a non-tool coherent text case.

## Validation run

```bash
cargo fmt --manifest-path bench/engine-parity/Cargo.toml
cargo clippy --manifest-path bench/engine-parity/Cargo.toml --all-features --all-targets -- -D warnings -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo check --manifest-path bench/engine-parity/Cargo.toml --all-targets
cargo run --manifest-path bench/engine-parity/Cargo.toml -- check bench/engine-parity/fixtures/weather-tool-call.json
cargo run --manifest-path bench/engine-parity/Cargo.toml -- render bench/engine-parity/fixtures/weather-tool-call.json
cargo run --manifest-path bench/engine-parity/Cargo.toml -- check bench/engine-parity/results/qwen06-mistral-qwen36-llama.json
cargo run --manifest-path bench/engine-parity/Cargo.toml -- render bench/engine-parity/results/qwen06-mistral-qwen36-llama.json
```

All passed for the scaffold.
