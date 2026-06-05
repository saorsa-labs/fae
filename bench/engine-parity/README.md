# Engine Parity Harness (G2) — Spec

> Phase 0 scaffold for fallback realism. This directory defines the proof required before `llama.cpp` can be called a real fallback for `mistral.rs`.

## Status

Scaffold plus real `mistral.rs` and `llama-server` adapters. A first G2 PASS result exists under `results/qwen06-mistral-qwen36-llama.{json,md}`: same prompt and tool schema, `mistral.rs` primary (`Qwen/Qwen3-0.6B`) and `llama-server` fallback (`qwen-3.6-dense-8bit`) both emitted normalized `get_weather({"city":"Paris"})`.

## Goal

Prove that Fae's engine abstraction can run the same agent-critical workload through:

1. primary: `mistral.rs` in-process;
2. fallback: `llama.cpp` via `llama-server` OpenAI-compatible HTTP;
3. one common `ProviderAdapter`-style contract.

## Minimal acceptance contract

A passing run must demonstrate:

- same prompt and same tool schema sent to both engines;
- equivalent structured tool call, e.g. `get_weather({"city":"Paris"})`;
- coherent text generation for a non-tool prompt;
- result document records model, hardware, OS, load time, TTFT, tok/s, and raw normalized tool call;
- no claim of parity if either engine is unavailable or returns malformed tool output.

Optional STT parity:

- same WAV clip through the selected STT path;
- transcript equivalence or WER threshold documented;
- note whether path is unified E4B audio or cascaded fallback.

## Proposed layout

```text
bench/engine-parity/
├── README.md
├── Cargo.toml                 # minimal scaffold crate
├── src/
│   ├── main.rs                # CLI: check/render result JSON
│   └── lib.rs                 # ProviderAdapter contract + result types
├── fixtures/
│   └── weather-tool-call.json # fixture proving result schema/check path
└── results/
    └── .gitkeep
```

The current crate provides the shared result schema, tool-call normalization/comparison, `check`, `render`, `run-llama`, `run-mistral`, and `run-both`. The first real two-engine run passes for a tool-call fixture. Broader G2 follow-ups remain: repeat with the target Gemma-4 E4B primary when load time is practical, add a coherent non-tool prompt case, and record hardware/OS metadata in richer result docs.

## Recommended G2 implementation path

1. Start with `llama-server` HTTP, not FFI. It is simpler and matches the fallback posture. Phase 1 integration assumes HTTP-based `llama-server` fallback unless G2 later proves an FFI path with equal reliability.
2. Use a small smoke model first, then Gemma-4 E4B/Qwen3-14B once downloads are available.
3. Normalize tool-call output into `{name, arguments}` before comparison.
4. Treat performance as diagnostic, not the pass/fail criterion.
5. Write `results/<model>-<date>.md` for every run.

## Example future commands

```bash
cargo build --release --manifest-path bench/engine-parity/Cargo.toml

cargo run --manifest-path bench/engine-parity/Cargo.toml -- \
  check bench/engine-parity/fixtures/weather-tool-call.json

cargo run --manifest-path bench/engine-parity/Cargo.toml -- \
  render bench/engine-parity/fixtures/weather-tool-call.json

# Run the llama-server fallback adapter against a live server:
# llama-server -m /path/to/model.gguf --port 8080 --chat-template qwen3
cargo run --manifest-path bench/engine-parity/Cargo.toml -- \
  run-llama bench/engine-parity/fixtures/weather-tool-call.json \
  http://127.0.0.1:8080 qwen3-0.6b \
  bench/engine-parity/results/qwen3-0.6b-llama.json

# Complete real two-engine run:
cargo run --manifest-path bench/engine-parity/Cargo.toml -- \
  run-both bench/engine-parity/fixtures/weather-tool-call.json \
  Qwen/Qwen3-0.6B http://127.0.0.1:62447 qwen-3.6-dense-8bit \
  bench/engine-parity/results/qwen06-mistral-qwen36-llama.json
```

## G2 pass criteria

G2 passes only when:

- the harness exists and builds;
- both adapters implement the same contract;
- at least one tool-call parity run succeeds;
- results are committed under `bench/engine-parity/results/` or summarized in `docs/spikes/`;
- failures are not hidden behind fallback wording.

Until then, `llama.cpp fallback` remains a design intent, not proven fallback realism.
