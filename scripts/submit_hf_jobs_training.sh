#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
UV_RUN="uv run --python 3.12 --with huggingface_hub"

MODEL_SIZE="${FAE_HFJ_MODEL_SIZE:-4b}"
TRAINING_MODE="${FAE_HFJ_MODE:-sft}"   # sft | orpo
DATASET_REPO_ID="${FAE_HFJ_DATASET_REPO_ID:-saorsa-labs/fae-training-data}"
NAMESPACE="${FAE_HFJ_NAMESPACE:-saorsa-labs}"
PUBLIC_REPO="${FAE_HFJ_PUBLIC_REPO:-0}"
DETACH="${FAE_HFJ_DETACH:-1}"

case "$MODEL_SIZE" in
    2b|tiny) BASE_MODEL="Qwen/Qwen3.5-2B"; DEFAULT_FLAVOR="a10g-small"; DEFAULT_TIMEOUT="2h"; DEFAULT_TRAIN_SAMPLES=256; DEFAULT_EVAL_SAMPLES=32; DEFAULT_MAX_STEPS=30 ;;
    4b|small) BASE_MODEL="Qwen/Qwen3.5-4B"; DEFAULT_FLAVOR="a10g-large"; DEFAULT_TIMEOUT="2h"; DEFAULT_TRAIN_SAMPLES=256; DEFAULT_EVAL_SAMPLES=32; DEFAULT_MAX_STEPS=30 ;;
    35b-a3b|34b-a3b|medium) BASE_MODEL="Qwen/Qwen3.5-35B-A3B"; DEFAULT_FLAVOR="a100-large"; DEFAULT_TIMEOUT="8h"; DEFAULT_TRAIN_SAMPLES=256; DEFAULT_EVAL_SAMPLES=32; DEFAULT_MAX_STEPS=12 ;;
    *)
        echo "ERROR: unsupported MODEL_SIZE '$MODEL_SIZE' (expected 2b|tiny, 4b|small, or 35b-a3b|34b-a3b|medium)" >&2
        exit 1
        ;;
esac

FLAVOR="${FAE_HFJ_FLAVOR:-$DEFAULT_FLAVOR}"
TIMEOUT="${FAE_HFJ_TIMEOUT:-$DEFAULT_TIMEOUT}"
MAX_STEPS="${FAE_HFJ_MAX_STEPS:-$DEFAULT_MAX_STEPS}"
MAX_TRAIN_SAMPLES="${FAE_HFJ_MAX_TRAIN_SAMPLES:-$DEFAULT_TRAIN_SAMPLES}"
MAX_EVAL_SAMPLES="${FAE_HFJ_MAX_EVAL_SAMPLES:-$DEFAULT_EVAL_SAMPLES}"
MAX_LENGTH="${FAE_HFJ_MAX_LENGTH:-1024}"
TRAIN_BATCH="${FAE_HFJ_TRAIN_BATCH:-1}"
EVAL_BATCH="${FAE_HFJ_EVAL_BATCH:-1}"
GRAD_ACCUM="${FAE_HFJ_GRAD_ACCUM:-16}"
LEARNING_RATE="${FAE_HFJ_LR:-}"
RUN_SUFFIX="${FAE_HFJ_RUN_SUFFIX:-$(date '+%Y%m%d-%H%M%S')}"

if [[ -n "${HF_TOKEN:-}" ]]; then
    HF_AUTH_OK=1
elif command -v hf >/dev/null 2>&1 && hf auth whoami >/dev/null 2>&1; then
    HF_AUTH_OK=1
else
    HF_AUTH_OK=0
fi

if [[ "$HF_AUTH_OK" -ne 1 ]]; then
    echo "ERROR: no Hugging Face auth detected." >&2
    echo "Run 'hf auth login' first, or set HF_TOKEN as an override." >&2
    exit 1
fi

DATA_ARGS=(
    "$SCRIPT_DIR/upload_training_data_to_hf.py"
    --dataset-repo-id "$DATASET_REPO_ID"
)
if [[ "$PUBLIC_REPO" == "1" ]]; then
    DATA_ARGS+=(--public)
fi

echo "[hf-jobs] Syncing training data to $DATASET_REPO_ID"
$UV_RUN python "${DATA_ARGS[@]}"

if [[ "$TRAINING_MODE" == "sft" ]]; then
    JOB_SCRIPT="$SCRIPT_DIR/hf_jobs_train_sft.py"
    DEFAULT_LR="2e-4"
    OUTPUT_REPO_ID="${FAE_HFJ_OUTPUT_REPO_ID:-saorsa-labs/fae-qwen35-${MODEL_SIZE}-${TRAINING_MODE}-${RUN_SUFFIX}}"
    JOB_ARGS=(
        --model-id "$BASE_MODEL"
        --dataset-repo-id "$DATASET_REPO_ID"
        --output-repo-id "$OUTPUT_REPO_ID"
        --max-steps "$MAX_STEPS"
        --learning-rate "${LEARNING_RATE:-$DEFAULT_LR}"
        --per-device-train-batch-size "$TRAIN_BATCH"
        --per-device-eval-batch-size "$EVAL_BATCH"
        --gradient-accumulation-steps "$GRAD_ACCUM"
        --max-length "$MAX_LENGTH"
        --max-train-samples "$MAX_TRAIN_SAMPLES"
        --max-eval-samples "$MAX_EVAL_SAMPLES"
    )
else
    if [[ "$MODEL_SIZE" == "35b-a3b" || "$MODEL_SIZE" == "34b-a3b" || "$MODEL_SIZE" == "medium" ]]; then
        echo "ERROR: 35B-A3B is currently SFT-only in the HF Jobs lane." >&2
        exit 1
    fi
    JOB_SCRIPT="$SCRIPT_DIR/hf_jobs_train_orpo.py"
    DEFAULT_LR="1e-5"
    OUTPUT_REPO_ID="${FAE_HFJ_OUTPUT_REPO_ID:-saorsa-labs/fae-qwen35-${MODEL_SIZE}-${TRAINING_MODE}-${RUN_SUFFIX}}"
    JOB_ARGS=(
        --model-id "$BASE_MODEL"
        --dataset-repo-id "$DATASET_REPO_ID"
        --output-repo-id "$OUTPUT_REPO_ID"
        --max-steps "$MAX_STEPS"
        --learning-rate "${LEARNING_RATE:-$DEFAULT_LR}"
        --per-device-train-batch-size "$TRAIN_BATCH"
        --per-device-eval-batch-size "$EVAL_BATCH"
        --gradient-accumulation-steps "$GRAD_ACCUM"
        --max-length "$MAX_LENGTH"
        --max-train-samples "$MAX_TRAIN_SAMPLES"
        --max-eval-samples "$MAX_EVAL_SAMPLES"
    )
fi

if [[ "$PUBLIC_REPO" == "1" ]]; then
    JOB_ARGS+=(--public)
fi

HF_JOB_CMD=(
    hf jobs uv run
    --flavor "$FLAVOR"
    --timeout "$TIMEOUT"
    --namespace "$NAMESPACE"
    --secrets HF_TOKEN
)

if [[ "$DETACH" == "1" ]]; then
    HF_JOB_CMD+=(--detach)
fi

HF_JOB_CMD+=("$JOB_SCRIPT")
HF_JOB_CMD+=("${JOB_ARGS[@]}")

echo "[hf-jobs] Submitting $TRAINING_MODE job"
echo "  base model:     $BASE_MODEL"
echo "  flavor:         $FLAVOR"
echo "  timeout:        $TIMEOUT"
echo "  dataset repo:   $DATASET_REPO_ID"
echo "  output repo:    $OUTPUT_REPO_ID"
echo "  max steps:      $MAX_STEPS"
echo "  train samples:  $MAX_TRAIN_SAMPLES"
echo "  eval samples:   $MAX_EVAL_SAMPLES"
echo

"${HF_JOB_CMD[@]}"
