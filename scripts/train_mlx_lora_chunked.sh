#!/bin/bash
# Resumable chunked MLX LoRA runner for more stable 4B/9B experiments.

set -euo pipefail

TARGET_MODEL="${1:-4b}"

case "$TARGET_MODEL" in
    2b|4b|8b|9b|34b-a3b|35b-a3b|tiny|small|medium|large)
        ;;
    *)
        echo "Usage: $0 [2b|4b|8b|9b|34b-a3b|35b-a3b|tiny|small|medium|large]"
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TRAINING_DATA_DIR="${FAE_TRAINING_DATA_DIR:-$PROJECT_ROOT/training/data}"
IMPORTS_DIR="${FAE_IMPORTS_DIR:-$PROJECT_ROOT/training/imports}"
SKIP_MARKDOWN_SOURCES="${FAE_SKIP_MARKDOWN_SOURCES:-0}"
RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
MODEL_TAG="qwen35-${TARGET_MODEL}"
ADAPTER_PATH="${FAE_ADAPTER_PATH:-$PROJECT_ROOT/training/adapters/chunked-${MODEL_TAG}-${RUN_STAMP}}"
TOTAL_ITERS="${FAE_TOTAL_ITERS:-16}"
CHUNK_ITERS="${FAE_CHUNK_ITERS:-4}"
INITIAL_RESUME_FILE="${FAE_INITIAL_RESUME_FILE:-}"
INITIAL_COMPLETED_ITERS="${FAE_INITIAL_COMPLETED_ITERS:-0}"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if [[ "$TOTAL_ITERS" -lt 1 || "$CHUNK_ITERS" -lt 1 || "$INITIAL_COMPLETED_ITERS" -lt 0 ]]; then
    echo "ERROR: FAE_TOTAL_ITERS and FAE_CHUNK_ITERS must be >= 1, and FAE_INITIAL_COMPLETED_ITERS must be >= 0"
    exit 1
fi

if [[ "$INITIAL_COMPLETED_ITERS" -gt "$TOTAL_ITERS" ]]; then
    echo "ERROR: FAE_INITIAL_COMPLETED_ITERS cannot exceed FAE_TOTAL_ITERS"
    exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required"
    exit 1
fi

log "Preparing split training data once for chunked run"
PREPARE_CMD=(
    uv run --python 3.12 --with mlx-lm python "$SCRIPT_DIR/prepare_training_data.py"
    --source-dir "$PROJECT_ROOT" \
    --output-dir "$TRAINING_DATA_DIR" \
    --imports-dir "$IMPORTS_DIR" \
    --split
)
if [[ "$SKIP_MARKDOWN_SOURCES" == "1" ]]; then
    PREPARE_CMD+=(--skip-markdown-sources)
fi
"${PREPARE_CMD[@]}" >/dev/null

mkdir -p "$(dirname "$ADAPTER_PATH")"

remaining=$((TOTAL_ITERS - INITIAL_COMPLETED_ITERS))
completed="$INITIAL_COMPLETED_ITERS"
resume_file="$INITIAL_RESUME_FILE"
chunk=1

if [[ -n "$resume_file" && ! -f "$resume_file" ]]; then
    echo "ERROR: initial resume adapter file not found: $resume_file"
    exit 1
fi

if [[ "$remaining" -eq 0 ]]; then
    log "Nothing to do: completed iterations already match target"
    log "Adapter path: $ADAPTER_PATH"
    exit 0
fi

while [[ "$remaining" -gt 0 ]]; do
    current_chunk="$CHUNK_ITERS"
    if [[ "$remaining" -lt "$current_chunk" ]]; then
        current_chunk="$remaining"
    fi

    log "Chunk $chunk starting ($current_chunk iterations, $completed/$TOTAL_ITERS completed)"

    chunk_env=(
        FAE_ADAPTER_PATH="$ADAPTER_PATH"
        FAE_SKIP_PREPARE_DATA=1
        FAE_TRAIN_ITERS="$current_chunk"
        FAE_SAVE_EVERY="$current_chunk"
    )

    for name in \
        FAE_BASE_MODEL \
        FAE_BATCH_SIZE \
        FAE_NUM_LAYERS \
        FAE_LEARNING_RATE \
        FAE_VAL_BATCHES \
        FAE_MAX_SEQ_LENGTH \
        FAE_STEPS_PER_REPORT \
        FAE_STEPS_PER_EVAL \
        FAE_GRAD_CHECKPOINT \
        FAE_GRAD_ACCUMULATION_STEPS \
        FAE_DISABLE_VALIDATION \
        FAE_TASKPOLICY_BACKGROUND \
        FAE_TRAINING_DATA_DIR \
        FAE_IMPORTS_DIR \
        FAE_SKIP_MARKDOWN_SOURCES
    do
        if [[ -n "${!name:-}" ]]; then
            chunk_env+=("$name=${!name}")
        fi
    done

    if [[ -n "$resume_file" ]]; then
        chunk_env+=(FAE_RESUME_ADAPTER_FILE="$resume_file")
    fi

    env "${chunk_env[@]}" bash "$SCRIPT_DIR/train_mlx_lora_smoke.sh" "$TARGET_MODEL"

    resume_file="$ADAPTER_PATH/adapters.safetensors"
    if [[ ! -f "$resume_file" ]]; then
        echo "ERROR: expected adapter file not found after chunk $chunk: $resume_file"
        exit 1
    fi

    completed=$((completed + current_chunk))
    remaining=$((remaining - current_chunk))
    chunk=$((chunk + 1))
done

log "Chunked training complete"
log "Adapter path: $ADAPTER_PATH"
