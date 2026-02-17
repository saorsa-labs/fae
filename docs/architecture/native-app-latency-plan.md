# Native App Latency Validation Plan (Hybrid C ABI + IPC)

Status: Draft v0.

Companion architecture doc: `docs/architecture/native-app-v0.md`.

## v0.1 Status (This Worktree)

Implemented:

- real local IPC roundtrip microbench on Unix via UDS (`uds_ipc_roundtrip`)
- scheduler dedupe hardening for multi-writer contention (file lock + refresh on write)
- scheduler authority tests for lease heartbeat jitter windows and multi-writer contention

Pending:

- Windows named-pipe benchmark implementation (abstraction is in place; Unix path is complete)

## Purpose

Prevent latency regressions while introducing:

- C ABI host boundary for macOS native app
- local IPC host boundary for external frontends
- scheduler backend leadership and failover controls

This plan focuses on boundary overhead, queueing, and scheduling jitter, not model-quality tuning.

## Principles

- Keep hot voice path local and in-process where possible.
- Measure p50/p95/p99, not only averages.
- Fail rollout if control-plane overhead exceeds agreed budgets.
- Compare every change against a fixed baseline run.

## Scope

In scope:

- command dispatch overhead (ABI + IPC)
- event fanout latency
- queue depth/backpressure behavior
- scheduler trigger jitter and failover recovery
- typed-input-to-first-text response timing (control path visible impact)

Out of scope:

- model-dependent response quality
- WAN/network provider latency fluctuations
- microphone hardware variance across machines

## SLOs (v0 Targets)

### Host boundary overhead

- C ABI command dispatch (`runtime.status`, empty payload): p95 <= 0.25 ms
- Local IPC request/response (`host.ping`, small payload): p95 <= 3 ms
- Local IPC event delivery (host emit to client receive): p95 <= 5 ms

### Runtime control responsiveness

- `conversation.gate_set` command to effective gate state reflected in event: p95 <= 20 ms
- `conversation.inject_text` to `runtime.assistant_generating{active:true}`: p95 <= 40 ms

### Scheduler reliability and timing

- schedule trigger jitter (actual fire time - planned fire time): p95 <= 150 ms
- leader failover recovery (leader death to follower promoting): <= 20 s
- duplicate execution for same logical run key: 0

### Regression guardrail

- No more than +3% regression on existing typed conversational TTFT median under same backend/config.

## Measurement Matrix

### Mode A (macOS in-process C ABI)

- baseline: current in-process GUI path
- candidate: native shell -> `libfae` ABI
- compare: control path timings and TTFT regression

### Mode B (IPC host)

- baseline: direct host process internal command dispatch
- candidate: client -> IPC -> host
- compare: RTT and event latency only

## Metrics to Capture

Core timestamps (monotonic):

- command submitted
- command accepted
- command completed
- event emitted
- event delivered to frontend

Existing useful instrumentation points:

- STT timing logs in `src/stt/mod.rs`
- transcription timing in `src/pipeline/coordinator.rs`
- assistant generation state transitions via `RuntimeEvent::AssistantGenerating`

Required additions for v0 rollout (to implement):

- host command tracing span with request id
- host event tracing span with event id
- queue depth gauges per event subscriber
- scheduler lease transition logs with instance id

## Test Scenarios

1. ABI no-op command microbench
- repeatedly call `host.ping` and `runtime.status` through C ABI
- record 10k samples

2. IPC no-op command microbench
- repeatedly call `host.ping` through local IPC
- payload sizes: 64 B, 1 KB, 8 KB

3. Event fanout stress
- one producer emits 1k events/s synthetic stream
- clients: 1, 2, 4, 8 subscribers
- verify latency and drop policy behavior

4. Typed round-trip flow
- inject text prompt
- measure time to first assistant sentence event
- run with fixed local model/backend config

5. Scheduler leader failover
- run two host instances
- kill leader mid-window
- verify single takeover and no duplicate task execution

## Benchmark Protocol

- Run on fixed hardware profile (document CPU/GPU/RAM/macOS version).
- Disable unrelated background workloads.
- Warm-up run before measurement.
- Run each scenario 5 times.
- Report median and worst run.
- Store raw timing artifacts under diagnostics output.

## Rollout Gates

Must pass before default enablement:

- all SLOs above met in CI/local perf runs
- no duplicate scheduler execution in failover test
- no unbounded queue growth under stress
- no UI-thread blocking call sites in frontend adapters

## Immediate Next Steps

1. Add host-level timestamp envelope fields for command/event tracing.
2. Implement Windows named-pipe benchmark path behind the same local IPC bench API.
3. Add event fanout stress benchmark (multi-subscriber queue pressure).
4. Capture baseline deltas across repeated runs (5x protocol) and track regression thresholds.
