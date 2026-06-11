# Spike S16 — Cross-platform personal-training lanes

> **Status:** Proposed (2026-06-11)
> **Goal:** Find a practical non-Apple training path for Fae personal LoRA/adapters while keeping MLX as the Apple lane.

## Candidates

- **MLX / mlx-lm / mlx-tune** — Apple baseline and current moat lane.
- **Unsloth** — primary non-Apple candidate: NVIDIA training is strongest; AMD ROCm and Intel XPU paths are documented and need target-machine proof.
- **PEFT + Transformers/Accelerate** — reference adapter format and fallback training path.
- **Axolotl** — YAML-driven advanced training pipeline for CUDA/multi-GPU and multimodal work.
- **torchtune** — historical/reference only unless maintenance status changes; upstream notes it is no longer actively maintained.

## Hardware matrix

| Lane | Target |
|---|---|
| Apple | M-series MLX |
| NVIDIA | Linux or Windows/WSL CUDA |
| AMD | Linux ROCm first; Windows only if toolchain is practical |
| Intel | Windows/Linux XPU for Arc/Ultra/Data Center |
| CPU | tiny smoke tests only |

## Acceptance criteria

1. Train the same tiny preference adapter on at least MLX and one non-Apple lane.
2. Export each adapter to a documented artifact set.
3. Convert or directly load into mistral.rs where possible.
4. Convert or directly load into llama.cpp where possible.
5. Run a fixed Fae preference eval and compare behavior delta.
6. Record wall time, peak memory, setup steps, failure modes, and license constraints.

## Key rule

Trainer choice is secondary. Fae needs **portable adapter artifacts** that can be served by the production runtime. Prefer PEFT/safetensors compatibility and deterministic conversion over trainer-specific magic.

## Output

- Recommended Apple lane.
- Recommended NVIDIA lane.
- AMD/Intel readiness status.
- Adapter format compatibility table.
- Whether `TrainingAdapter` should support local-only, remote user-owned node, or both.
