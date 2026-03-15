# HF Jobs Training

> Cloud training lane for Fae when local MLX runs stop being the right tool.
>
> Last updated: March 15, 2026.

---

## Why this exists

Local MLX training is still useful for fast iteration on smaller models, but it has obvious limits:

- Apple Silicon training gets brittle once runs get long or MoE-heavy
- longer runs hit Metal interactivity failures
- large-model iteration is slower than it needs to be

For the current three-model suite, Fae now has a Hugging Face Jobs lane for:

- fresh `Qwen3.5 4B` training
- fresh `Qwen3.5-35B-A3B` MoE training
- repeatable cloud reruns of the `Qwen3.5 2B` lane behind `saorsa-1.1-tiny`

This does **not** change the app runtime path:

- the Fae app still downloads public models anonymously
- `hf auth login` is for internal training and publishing only

---

## Auth split

Two different auth stories are intentional here.

### App runtime

Fae should behave like a real user install:

- public model repos
- unauthenticated download path
- no dependence on private Hub credentials

Do not make app startup or model switching depend on `hf auth login`.

### Internal training and publishing

For us, the preferred path is:

```bash
hf auth login
```

That cached login is reused by:

- `huggingface_hub`
- `hf jobs`
- the repo upload scripts

`HF_TOKEN` remains supported as an override for CI or one-off automation.

---

## Canonical dataset repo

The cloud lane expects the current canonical JSONL splits in a dataset repo:

- default repo: `saorsa-labs/fae-training-data`
- canonical files:
  - `data/sft_train.jsonl`
  - `data/sft_val.jsonl`
  - `data/dpo_train.jsonl`
  - `data/dpo_val.jsonl`

To sync the current local splits:

```bash
python3 scripts/upload_training_data_to_hf.py
```

That script prefers `hf auth login` and only falls back to `HF_TOKEN`.

---

## Training scripts

Fae now has two self-contained HF Jobs UV scripts:

- [hf_jobs_train_sft.py](../../scripts/hf_jobs_train_sft.py)
- [hf_jobs_train_orpo.py](../../scripts/hf_jobs_train_orpo.py)

They are designed to run directly on Hugging Face infrastructure via:

```bash
hf jobs uv run scripts/hf_jobs_train_sft.py ...
hf jobs uv run scripts/hf_jobs_train_orpo.py ...
```

The scripts:

- download the canonical dataset files from the dataset repo
- load the upstream Qwen3.5 base model on CUDA
- run LoRA training with TRL + PEFT
- upload the resulting adapter to a model repo if `--output-repo-id` is provided

The active upstream base IDs for cloud training are:

- `Qwen/Qwen3.5-2B`
- `Qwen/Qwen3.5-4B`
- `Qwen/Qwen3.5-35B-A3B`

This keeps cloud training anchored to the real upstream weights, not the local MLX quantized checkpoints.

### MoE note for `35B-A3B`

`Qwen3.5-35B-A3B` is a separate MoE lane, not just the dense recipe scaled up.

Current training stance:

- start with `SFT`, not ORPO/DPO
- use a separate hardware default (`h200`)
- LoRA-target attention and `shared_expert` modules
- use PEFT `target_parameters` for raw expert tensors like `mlp.experts.gate_up_proj` and `mlp.experts.down_proj`
- do not tune router gating first
- load the model through the conditional-generation auto class, not plain `AutoModelForCausalLM`

---

## Submission wrapper

The normal entry point is:

```bash
bash scripts/submit_hf_jobs_training.sh
```

Defaults:

- model size: `4b`
- mode: `sft`
- dataset repo: `saorsa-labs/fae-training-data`
- detached submission: yes

Useful overrides:

```bash
FAE_HFJ_MODEL_SIZE=medium \
FAE_HFJ_MODE=sft \
FAE_HFJ_MAX_STEPS=12 \
bash scripts/submit_hf_jobs_training.sh
```

```bash
FAE_HFJ_MODEL_SIZE=4b \
FAE_HFJ_MODE=orpo \
FAE_HFJ_MAX_STEPS=25 \
bash scripts/submit_hf_jobs_training.sh
```

```bash
FAE_HFJ_OUTPUT_REPO_ID=saorsa-labs/fae-qwen35-4b-sft-smoke \
bash scripts/submit_hf_jobs_training.sh
```

---

## Hardware presets

Current conservative defaults in the wrapper:

- `2B` → `a10g-small`
- `4B` → `a10g-large`
- `35B-A3B` → `a100-large` for smoke validation on the current CLI, then reconsider larger flavors after the first clean run

These are starting points, not permanent law. The point is to keep the first run stable and cost-capped.

Current HF Jobs hardware pricing can be listed with:

```bash
hf jobs hardware
```

Important operational notes:

- Hugging Face Jobs requires prepaid account credits.
- If submission fails with `402 Payment Required`, top up the namespace before retrying.
- The current local `hf` CLI may reject some newer flavors even if `hf jobs hardware` lists them. If `h200` is rejected by `hf jobs uv run`, fall back to `a100-large` or update the CLI.

---

## Promotion loop

Cloud training does not change the benchmark gate.

The loop stays:

1. freeze a base benchmark
2. train a candidate
3. fuse or adapt as needed for local evaluation
4. rerun the same benchmark gate
5. compare base vs candidate
6. only promote if the candidate actually wins

For Fae, that still means tool calling remains a hard gate.

---

## What this does not solve

This lane does **not** solve PARO training directly.

Right now the practical order is still:

1. train upstream Qwen
2. merge
3. benchmark
4. only then consider any later quantization experiment

So HF Jobs is a better control plane for large training runs, not a replacement for the rest of the evaluation discipline.
