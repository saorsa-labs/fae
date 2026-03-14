# Fae (macOS SwiftUI)

Swift-first native macOS app for Fae. This package is the primary app entrypoint and should be built/tested with SwiftPM.

## Current capabilities

- Native SwiftUI app with native orb/conversation/canvas windows
- Voice pipeline integration, settings/onboarding, approvals, and handoff UI
- Handoff payload publication via `NSUserActivity`
- Native mic permission + discovery and output route picker surfaces

## Build & test

From repository root:

```bash
cd native/macos/Fae
swift build
swift test
```

## Known build blockers

- First-time or clean builds may fail if SwiftPM cannot fetch remote dependencies/submodules (network/DNS required).
- First run may require large model downloads before runtime is ready.

## Benchmark reports

Current benchmark docs live at the repository root so people can see both what we test and what matters for Fae:

- [`../../docs/benchmarks/local-model-eval-2026-03-07.md`](../../docs/benchmarks/local-model-eval-2026-03-07.md) — what we test: RAM, TTFT, throughput, tool-calling, MMLU-style mini, Fae-capability, assistant-fit, and JSON/XML/YAML structured output
- [`../../docs/benchmarks/fae-priority-eval-2026-03-07.md`](../../docs/benchmarks/fae-priority-eval-2026-03-07.md) — what matters for Fae: tool use, strict instruction following, memory discipline, tool-result handling, speed, and RAM efficiency
- [`../../docs/benchmarks/llm-benchmarks.md`](../../docs/benchmarks/llm-benchmarks.md) — scoreboard / overview
- [`../../docs/guides/post-training-and-evaluation.md`](../../docs/guides/post-training-and-evaluation.md) — canonical guide for post-training methods, benchmark/eval gates, and the `mlx-tune` plan

`FaeBenchmark` now compiles against the same shared `FaeInference` / `MLXLLMEngine` path as the main app. Use the `just benchmark*` recipes or `just build-benchmark` so the Xcode-built binary picks up the required Metal bundle and the current `mlx-swift-lm` / Qwen behavior.

Canonical local model cache: `~/.cache/huggingface/hub`. The app runtime, training scripts, and benchmark path now resolve model IDs from that shared cache first. `~/Library/Caches/models/...` is legacy-only and can be deduplicated with `bash scripts/cleanup_legacy_model_caches.sh --apply`.

Current loadable text-model ladder in the app:

- `Auto`: `Qwen3.5 2B` / `4B` / `9B` by RAM
- manual quality mode: `Qwen3.5 27B`
- legacy `35B-A3B` preset now maps to `27B`

Sidecar PARO benchmarks currently favor `9B` and `27B`, but `mlx-swift-lm` in Fae cannot load those PARO checkpoints yet, so PARO remains benchmark-only for now.

## Notes

- iPhone/Watch session continuation still requires matching companion targets using the same activity type/payload contract.
- Legacy Rust embedding/IPC docs remain in root docs as archival context; SwiftPM app flow is the default for current development.
