#!/bin/bash
# Small MLX LoRA smoke run for the current 4B/9B training targets.

set -euo pipefail

TARGET_MODEL="${1:-4b}"
RELEASE_TARGET=""

case "$TARGET_MODEL" in
    2b|tiny)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-2B-4bit}"
        MODEL_TAG="qwen35-2b"
        RELEASE_TARGET="saorsa-1.1-tiny"
        ;;
    4b|small)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-4B-4bit}"
        MODEL_TAG="qwen35-4b"
        RELEASE_TARGET="saorsa-1.1-small"
        ;;
    9b|8b|medium)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-9B-4bit}"
        MODEL_TAG="qwen35-9b"
        RELEASE_TARGET="saorsa-1.1-medium"
        ;;
    35b-a3b|34b-a3b|large)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-35B-A3B-4bit}"
        MODEL_TAG="qwen35-35b-a3b"
        RELEASE_TARGET="saorsa-1.1-large"
        ;;
    *)
        echo "Usage: $0 [2b|4b|8b|9b|34b-a3b|35b-a3b|tiny|small|medium|large]"
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
. "$SCRIPT_DIR/lib/model_cache.sh"
TRAINING_DATA_DIR="${FAE_TRAINING_DATA_DIR:-$PROJECT_ROOT/training/data}"
IMPORTS_DIR="${FAE_IMPORTS_DIR:-$PROJECT_ROOT/training/imports}"
SKIP_MARKDOWN_SOURCES="${FAE_SKIP_MARKDOWN_SOURCES:-0}"
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
GRAD_CHECKPOINT="${FAE_GRAD_CHECKPOINT:-0}"
GRAD_ACCUMULATION_STEPS="${FAE_GRAD_ACCUMULATION_STEPS:-1}"
DISABLE_VALIDATION="${FAE_DISABLE_VALIDATION:-0}"
TASKPOLICY_BACKGROUND="${FAE_TASKPOLICY_BACKGROUND:-0}"
RESUME_ADAPTER_FILE="${FAE_RESUME_ADAPTER_FILE:-}"
SKIP_PREPARE_DATA="${FAE_SKIP_PREPARE_DATA:-0}"

UV_RUN=(uv run --python 3.12 --with mlx-lm)
DATA_DIR_FOR_RUN="$TRAINING_DATA_DIR"
TEMP_DATA_DIR=""

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required"
    exit 1
fi

cleanup() {
    if [[ -n "$TEMP_DATA_DIR" && -d "$TEMP_DATA_DIR" ]]; then
        rm -rf "$TEMP_DATA_DIR"
    fi
}
trap cleanup EXIT

if [[ "$SKIP_PREPARE_DATA" != "1" ]]; then
    log "Preparing training data"
    PREPARE_CMD=(
        "${UV_RUN[@]}" python "$SCRIPT_DIR/prepare_training_data.py"
        --source-dir "$PROJECT_ROOT" \
        --output-dir "$TRAINING_DATA_DIR" \
        --imports-dir "$IMPORTS_DIR" \
        --split
    )
    if [[ "$SKIP_MARKDOWN_SOURCES" == "1" ]]; then
        PREPARE_CMD+=(--skip-markdown-sources)
    fi
    "${PREPARE_CMD[@]}"
else
    log "Skipping training-data preparation"
fi

if [[ ! -s "$TRAINING_DATA_DIR/sft_train.jsonl" ]]; then
    echo "ERROR: missing training split: $TRAINING_DATA_DIR/sft_train.jsonl"
    exit 1
fi

TEMP_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fae-train-data-XXXXXX")"
cp "$TRAINING_DATA_DIR/sft_train.jsonl" "$TEMP_DATA_DIR/train.jsonl"
if [[ "$DISABLE_VALIDATION" != "1" ]]; then
    if [[ ! -s "$TRAINING_DATA_DIR/sft_val.jsonl" ]]; then
        echo "ERROR: missing validation split: $TRAINING_DATA_DIR/sft_val.jsonl"
        exit 1
    fi
    cp "$TRAINING_DATA_DIR/sft_val.jsonl" "$TEMP_DATA_DIR/valid.jsonl"
fi
DATA_DIR_FOR_RUN="$TEMP_DATA_DIR"

mkdir -p "$(dirname "$ADAPTER_PATH")"

BASE_MODEL_SOURCE="$(fae_resolve_model_source "$BASE_MODEL")"

log "Starting smoke LoRA run"
log "Base model: $BASE_MODEL"
log "Resolved model source: $BASE_MODEL_SOURCE"
log "Release target: $RELEASE_TARGET"
log "Adapter path: $ADAPTER_PATH"
log "Data dir: $DATA_DIR_FOR_RUN"
log "Iterations: $ITERS"
log "Batch size: $BATCH_SIZE"
log "LoRA layers: $NUM_LAYERS"
log "Learning rate: $LEARNING_RATE"
log "Max seq length: $MAX_SEQ_LENGTH"
log "Steps/report: $STEPS_PER_REPORT"
log "Steps/eval: $STEPS_PER_EVAL"
log "Save every: $SAVE_EVERY"
log "Grad checkpoint: $GRAD_CHECKPOINT"
log "Grad accumulation: $GRAD_ACCUMULATION_STEPS"
log "Validation enabled: $([[ "$DISABLE_VALIDATION" == "1" ]] && echo no || echo yes)"
log "Background taskpolicy: $TASKPOLICY_BACKGROUND"
if [[ -n "$RESUME_ADAPTER_FILE" ]]; then
    log "Resume adapter file: $RESUME_ADAPTER_FILE"
fi

TRAIN_CMD=(
    "${UV_RUN[@]}" python -m mlx_lm lora
    --model "$BASE_MODEL_SOURCE"
    --train
    --data "$DATA_DIR_FOR_RUN"
    --batch-size "$BATCH_SIZE"
    --num-layers "$NUM_LAYERS"
    --iters "$ITERS"
    --learning-rate "$LEARNING_RATE"
    --adapter-path "$ADAPTER_PATH"
    --val-batches "$VAL_BATCHES"
    --max-seq-length "$MAX_SEQ_LENGTH"
    --mask-prompt
    --steps-per-report "$STEPS_PER_REPORT"
    --steps-per-eval "$STEPS_PER_EVAL"
    --save-every "$SAVE_EVERY"
    --grad-accumulation-steps "$GRAD_ACCUMULATION_STEPS"
)

if [[ "$GRAD_CHECKPOINT" == "1" ]]; then
    TRAIN_CMD+=(--grad-checkpoint)
fi

if [[ -n "$RESUME_ADAPTER_FILE" ]]; then
    TRAIN_CMD+=(--resume-adapter-file "$RESUME_ADAPTER_FILE")
fi

if [[ "$TASKPOLICY_BACKGROUND" == "1" ]]; then
    taskpolicy -b "${TRAIN_CMD[@]}"
else
    "${TRAIN_CMD[@]}"
fi

log "Smoke run complete"
log "Adapter path: $ADAPTER_PATH"
