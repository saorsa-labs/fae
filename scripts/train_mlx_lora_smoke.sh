#!/bin/bash
# Small MLX LoRA smoke run for the current 4B/9B training targets.

set -euo pipefail

TARGET_MODEL="${1:-4b}"

case "$TARGET_MODEL" in
    4b)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-4B-4bit}"
        MODEL_TAG="qwen35-4b"
        ;;
    9b)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-9B-4bit}"
        MODEL_TAG="qwen35-9b"
        ;;
    *)
        echo "Usage: $0 [4b|9b]"
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TRAINING_DATA_DIR="${FAE_TRAINING_DATA_DIR:-$PROJECT_ROOT/training/data}"
RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
ADAPTER_PATH="${FAE_ADAPTER_PATH:-$PROJECT_ROOT/training/adapters/smoke-${MODEL_TAG}-${RUN_STAMP}}"

BATCH_SIZE="${FAE_BATCH_SIZE:-1}"
NUM_LAYERS="${FAE_NUM_LAYERS:-4}"
ITERS="${FAE_TRAIN_ITERS:-2}"
LEARNING_RATE="${FAE_LEARNING_RATE:-5e-5}"
VAL_BATCHES="${FAE_VAL_BATCHES:-1}"
MAX_SEQ_LENGTH="${FAE_MAX_SEQ_LENGTH:-2048}"
STEPS_PER_REPORT="${FAE_STEPS_PER_REPORT:-1}"
STEPS_PER_EVAL="${FAE_STEPS_PER_EVAL:-1}"
SAVE_EVERY="${FAE_SAVE_EVERY:-1000}"

UV_RUN=(uv run --python 3.12 --with mlx-lm)

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required"
    exit 1
fi

log "Preparing training data"
"${UV_RUN[@]}" python "$SCRIPT_DIR/prepare_training_data.py" \
    --source-dir "$PROJECT_ROOT" \
    --output-dir "$TRAINING_DATA_DIR" \
    --split

cp "$TRAINING_DATA_DIR/sft_train.jsonl" "$TRAINING_DATA_DIR/train.jsonl"
cp "$TRAINING_DATA_DIR/sft_val.jsonl" "$TRAINING_DATA_DIR/valid.jsonl"

mkdir -p "$(dirname "$ADAPTER_PATH")"

log "Starting smoke LoRA run"
log "Base model: $BASE_MODEL"
log "Adapter path: $ADAPTER_PATH"
log "Iterations: $ITERS"
log "Batch size: $BATCH_SIZE"
log "LoRA layers: $NUM_LAYERS"
log "Learning rate: $LEARNING_RATE"
log "Max seq length: $MAX_SEQ_LENGTH"
log "Steps/report: $STEPS_PER_REPORT"
log "Steps/eval: $STEPS_PER_EVAL"
log "Save every: $SAVE_EVERY"

"${UV_RUN[@]}" python -m mlx_lm lora \
    --model "$BASE_MODEL" \
    --train \
    --data "$TRAINING_DATA_DIR" \
    --batch-size "$BATCH_SIZE" \
    --num-layers "$NUM_LAYERS" \
    --iters "$ITERS" \
    --learning-rate "$LEARNING_RATE" \
    --adapter-path "$ADAPTER_PATH" \
    --val-batches "$VAL_BATCHES" \
    --max-seq-length "$MAX_SEQ_LENGTH" \
    --mask-prompt \
    --steps-per-report "$STEPS_PER_REPORT" \
    --steps-per-eval "$STEPS_PER_EVAL" \
    --save-every "$SAVE_EVERY"

log "Smoke run complete"
log "Adapter path: $ADAPTER_PATH"
