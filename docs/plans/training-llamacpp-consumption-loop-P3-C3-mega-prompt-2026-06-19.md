# P3 / C3 — Close the training → llama.cpp daemon consumption loop (mega-prompt, 2026-06-19)

> **Role split.** You are the IMPLEMENTING TEAM. The main session is the REVIEWER and will
> verify your hand-back against the **real git diff + a re-run gate + live output**, not your
> report. Implement AND test the phase to completion, then HAND BACK with verbatim self-captured
> evidence. **Do NOT commit or push** — the reviewer commits after verifying.
>
> Work in your assigned **git worktree** (not the main repo tree). Branch off the trunk
> `llamacpp-serving-adapter`.

## Objective

Trained personal LoRA adapters must reach the **llama.cpp daemon brain** (the product's real LLM
lane), not just the MLX fallback. Wire the nightly loop end to end:

```
train (PEFT, portable) → convert_to_gguf.py → personal.gguf
   → daemon engine.reload(personal_adapter=path) → llama-server reloaded with the adapter
   → engine.set_adapter_scale(1.0) serves personalized; set_adapter_scale(0.0) = instant rollback
```

**DONE:** a forced/triggered improvement cycle produces a GGUF LoRA that the **daemon** loads and
serves at **scale=1**, with **instant scale=0 rollback**, proven LIVE via daemon-log attribution
**and** a behavioral A/B probe (a fact learnable only from the adapter — see the C2 "MOONLIT-HERON"
pattern). Existing approval/eval gates are respected (the mandatory FaeBenchmark hard-gate is
formalized later in P9/C4 — do not bypass current gates, but do not build P9 here).

## Decision already made (do not relitigate)

The nightly **daemon-targeted** loop uses the **PEFT producer** (`train_peft.py` →
`convert_to_gguf.py`), which is cross-platform (device-auto MPS/CUDA/CPU) and C2-proven. **MLX-tune
stays an out-of-loop, Apple-fast experimental lane** — its `.safetensors` adapters have no proven
GGUF path and are OUT OF SCOPE here. Do not try to convert MLX adapters to GGUF.

## Verified current state (anchors — confirm before relying on them)

Both ends already exist and are individually proven; only the Swift orchestration that connects them
is missing.

### Producer — EXISTS, manually proven (commit c3ff6265, gap C2)
- `native/macos/Fae/Sources/Fae/Resources/Skills/training-orchestrator/scripts/train_peft.py`
  — portable LoRA SFT (peft + transformers; LoRA on LM attn/MLP only — `lm_head` breaks GGUF
  convert; examples formatted with the model CHAT TEMPLATE).
- `.../training-orchestrator/scripts/convert_to_gguf.py` — PEFT → GGUF via llama.cpp
  `convert_lora_to_gguf`, base config resolved offline from the HF cache.
- Proven E2E on M5 Max: synth SFT → train_peft (200 steps, loss 1.8e-5) → convert → `personal.gguf`
  → llama-server; scale 0 = base refusal, scale 1 = learned fact. **This is the path to wire.**

### Daemon consumption — EXISTS, authz-scoped, tested (commits e583b517 B3, 41157018 B3b)
- `crates/fae-daemon/src/session.rs` — `engine.reload` (payload `{ "personal_adapter": "<gguf>" }`
  or `null` for base) dispatches `reload_adapter` → `engine.reload_adapter(path)`; and
  `engine.set_adapter_scale` (payload `{ "scale": <f32, clamped 0..2> }`).
- `crates/fae-engine/.../llamacpp_adapter.rs` — `reload_adapter` swaps the llama-server sidecar
  (`--lora <gguf> --lora-init-without-apply`, loaded inert); `set_adapter_scale` stores an
  `AtomicU32`; every completion body gets `"lora":[{"id":0,"scale":<scale>}]` only when an adapter
  is loaded. Instant scale=1↔scale=0 A/B without a server restart.
- **Authz**: `engine.set_adapter_scale` / `engine.reload` require the **`ModelManagement` scope**
  (daemon tests: `engine_set_adapter_scale_denied_without_model_management_scope`). Live de-risk
  examples: `crates/fae-engine/examples/llama_reload.rs`, `llama_smoke.rs`.
- **Daemon-side gap**: `reload_adapter` passes the path to llama-server **unchecked** — no
  existence check, no path confinement, no integrity record. A bad/poisoned path crashes the
  sidecar and leaves the daemon deaf (old child already killed). MUST be addressed (see Stage 4).

### Swift orchestration — the BROKEN LINKS
- `Scheduler/TrainingBridge.swift` — `launchTraining`/`pollUntilComplete`/`evaluateAdapter` produce
  an MLX `.safetensors` adapter dir only; **never invokes `convert_to_gguf.py`; emits no GGUF.**
- `ML/DaemonLLMEngine.swift` — **zero adapter API**: no reload, no set-scale, no `engine.reload`
  command construction. (Wire frame: `{"v":2,"request_id":...,"command":...,"payload":{...}}`.)
- `Scheduler/AdapterDeploymentManager.swift` — `deploy()` only persists `currentAdapterPath` to
  `ImprovementStore`; activates no engine.
- `Scheduler/ImprovementCycleCoordinator.swift` — `performDeploy` calls `adapterPatchCallback?(path)`
  (a closure); the comment says *"nil until FaeCore wires it in"* — **FaeCore never sets it.** Dead end.
- `Pipeline/PipelineCoordinator.swift:applyAdapterChange` → `llmEngine.swapAdapter()` — **MLX only**;
  no daemon branch. Reached from `Core/FaeCore.swift:~2380` on `training.personal_adapter_path`.

## Work items (dependency order — each is a hand-back checkpoint)

### Stage 1 — TrainingBridge emits a verified GGUF
- After PEFT training completes, invoke `convert_to_gguf.py` (via the same `uv run --script` pattern
  TrainingBridge already uses for the mlx-tune scripts) to produce `personal.gguf` under
  `FaeDirectories.personalModelsDirectory` (`models/personal/`).
- The nightly daemon-targeted training path trains via `train_peft.py` (NOT `train.py`/mlx-tune).
  Keep the mlx-tune path compiling and callable, but the loop that feeds the daemon uses PEFT.
- Done: a `TrainingBridge` method returns a verified GGUF path (file exists, non-empty); a unit test
  covers the success + missing-GGUF failure paths.

### Stage 2 — DaemonLLMEngine adapter API
- Add `reloadAdapter(path: String?)` → sends `engine.reload` with `{ "personal_adapter": path }`.
- Add `setAdapterScale(_ scale: Float)` → sends `engine.set_adapter_scale` with `{ "scale": scale }`.
- **CRITICAL — authz scope.** The daemon client identity `DaemonLLMEngine` authenticates as MUST
  hold the **`ModelManagement` scope**, or both commands are DENIED at the daemon. This is the same
  class as the prior `UnknownClient` release-blocker (client/scope drift). VERIFY the client's
  granted scopes include `ModelManagement`; if not, grant it at the registration seam (prefer the
  shared `fae_control_plane::BOOTSTRAP_CLIENT_ID` constant so daemon registration and Swift auth
  can't drift). Prove with a live reload that is NOT denied.
- Map daemon error replies (`reload_failed`, `set_adapter_scale_failed`, `missing_scale`, authz
  denial) to typed Swift errors — never silently swallow.
- Done: unit tests for frame construction; a live daemon log showing the reload + set-scale commands
  accepted (not denied).

### Stage 3 — Wire the deploy callback + daemon branch
- `FaeCore` sets `ImprovementCycleCoordinator.setAdapterPatchCallback { path in ... }` so deploy is
  no longer a dead end. The closure, **when the daemon LLM lane is active** (`llm.useDaemonEngine`):
  `daemonEngine.reloadAdapter(path)` then `setAdapterScale(1.0)`; **else** the existing MLX
  `applyAdapterChange` path.
- `applyAdapterChange` (and the `training.personal_adapter_path` self-config path) gains the same
  daemon branch — daemon lane active → daemon reload+scale; MLX lane → `swapAdapter`.
- **Rollback**: `self_config(action: rollback_improvement)` and the deploy-rollback path drive
  `setAdapterScale(0.0)` (instant) on the daemon lane (and/or `reloadAdapter(nil)` to drop to base).
  Keep MLX rollback behavior for the MLX lane.
- Done: a triggered deploy on the daemon lane reaches the daemon (log-attributed); rollback flips
  scale to 0 live.

### Stage 4 — Daemon adapter safety gate (Rust)
- In `reload_adapter` (or `LlamaServerHandle::spawn`), before handing a path to llama-server:
  (a) reject a non-existent / unreadable file with a clear `EngineError`; (b) **confine** the
  adapter path to the personal-adapters directory (reject arbitrary absolute paths injected via
  NDJSON — this is a remotely-reachable command); (c) record the loaded adapter's SHA-256 + path so
  `runtime.status` can report which adapter/scale is live (and so rollback/audit has a record).
- Note: a runtime-generated personal adapter cannot be pinned in `models.lock` (it doesn't exist at
  build time) — so this is **path-confinement + existence + a local trust record**, NOT a static
  SHA pin. Do not weaken the existing model/mmproj `models.lock` gate.
- Failure semantics: if reload fails mid-swap, surface a loud error; do not leave the daemon
  silently deaf without signaling. (A full auto-recover-to-previous-sidecar is a nice-to-have; at
  minimum the failure must be reported, not swallowed.)
- Done: unit tests for the existence + confinement rejections; `runtime.status` reports adapter+scale.

### Stage 5 — End-to-end live proof
- Drive a forced/triggered improvement cycle (or a minimal harness that exercises the real path:
  train_peft on a tiny synth probe dataset embedding a unique token → convert → deploy → daemon).
- Capture LIVE: daemon-log attribution of `engine.reload` + `engine.set_adapter_scale`; a behavioral
  A/B — the probe fact is ABSENT at scale=0 and PRESENT at scale=1 through the **daemon** lane;
  rollback (scale→0) live-removes it.

## DONE criteria (all required)
1. A triggered cycle produces a GGUF the **daemon** loads and serves at scale=1; instant scale=0
   rollback — proven LIVE (daemon log + behavioral A/B probe, not a label).
2. Daemon client holds `ModelManagement` scope; reload/set-scale are accepted, not denied.
3. Daemon rejects non-existent / out-of-confinement adapter paths; `runtime.status` reports the live
   adapter+scale.
4. Existing approval/eval gates respected (no new auto-deploy bypass). MLX lane behavior unchanged.

## Evidence floor (hand back ALL of these, verbatim)
- `git diff --stat` for the whole branch.
- Rust (touched crates): `env -u RUSTFLAGS` → `cargo fmt --check`, `cargo clippy --all-targets
  -- -D warnings`, `cargo nextest run` (or the crate `just check`). Paste the tail showing pass counts.
- Swift: `swift build` clean (paste tail). Targeted tests for the new Swift adapter/bridge logic.
- LIVE: the daemon-log lines for reload + set-scale; the behavioral A/B transcript (scale 0 vs 1);
  the rollback transcript. Label your captures so the reviewer can map each to a DONE criterion.

## Traps & rules (heed — these have bitten before)
- **Reviewer verifies live, not your report.** A prior agent FABRICATED a completion report (0 tool
  uses, invented diffs). Capture real output; the reviewer re-runs the gate.
- **Bundling trap.** `just build` alone does NOT update the running app/daemon. To prove the live
  path you must do the full embed/sign/bundle chain (`just run-dev` embeds orb shell + daemon +
  llama.cpp runtime). A repo-built daemon that can't find the bundled `llama-server` exits → MLX
  fallback (the exact B1.5 root cause). Pass `FAE_LLAMACPP_RUNTIME_DIR` / `FAE_LLAMA_BIN` if running
  the daemon outside the bundle.
- **MLX ops CRASH under `swift test`.** QUIT the dev app before any local `swift test`. The full
  suite also times out on Contacts/AddressBook XPC noise — run TARGETED tests.
- **`env -u RUSTFLAGS`** is required for crate builds in this repo.
- **ADR-010**: llama.cpp stays a `llama-server` sidecar; no in-process FFI. Adapter activation is
  launch-arg `--lora` + per-request scale, NOT a runtime HTTP endpoint (llama-server has none).
- **Integrity**: any downloaded model/binary stays SHA-pinned + fail-closed; `FAE_MODELS_LOCK=off`
  only under `FAE_DEV`. Do not weaken it for the adapter path (Stage 4 is confinement, not a pin).
- **Surgical changes**: touch only what the loop needs. Don't refactor mlx-tune or the MLX lane.
- **Per-phase hand-back**: stop at each Stage checkpoint if you want a reviewer gate, or run through
  and hand back the whole phase with per-stage evidence — but never commit/push.
