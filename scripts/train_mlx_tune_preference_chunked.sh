#!/bin/bash
# Resumable chunked mlx-tune preference runner for more stable 9B/35B experiments.

set -euo pipefail

TARGET_MODEL="${1:-9b}"
METHOD="${2:-orpo}"

case "$TARGET_MODEL" in
    2b|tiny)
        MODEL_TAG="qwen35-2b"
        ;;
    4b|small)
        MODEL_TAG="qwen35-4b"
        ;;
    9b|8b|medium)
        MODEL_TAG="qwen35-9b"
        ;;
    35b-a3b|34b-a3b|large)
        MODEL_TAG="qwen35-35b-a3b"
        ;;
    *)
        echo "Usage: $0 [2b|4b|8b|9b|34b-a3b|35b-a3b|tiny|small|medium|large] [dpo|orpo]"
        exit 1
        ;;
esac

if [[ "$METHOD" != "dpo" && "$METHOD" != "orpo" ]]; then
    echo "ERROR: method must be dpo or orpo"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
OUTPUT_DIR="${FAE_PREFERENCE_OUTPUT_DIR:-$PROJECT_ROOT/training/adapters/chunked-${MODEL_TAG}-${METHOD}-${RUN_STAMP}}"
MERGED_OUTPUT_DIR="${FAE_PREFERENCE_MERGED_OUTPUT_DIR:-$PROJECT_ROOT/training/models/chunked-${MODEL_TAG}-${METHOD}-${RUN_STAMP}}"
TOTAL_STEPS="${FAE_PREF_TOTAL_STEPS:-64}"
CHUNK_STEPS="${FAE_PREF_CHUNK_STEPS:-8}"
INITIAL_COMPLETED_STEPS="${FAE_PREF_INITIAL_COMPLETED_STEPS:-0}"
INITIAL_RESUME_DIR="${FAE_PREF_INITIAL_RESUME_DIR:-}"
COOLDOWN_SECONDS="${FAE_PREF_CHUNK_COOLDOWN_SECONDS:-0}"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if [[ "$TOTAL_STEPS" -lt 1 || "$CHUNK_STEPS" -lt 1 || "$INITIAL_COMPLETED_STEPS" -lt 0 ]]; then
    echo "ERROR: FAE_PREF_TOTAL_STEPS and FAE_PREF_CHUNK_STEPS must be >= 1, and FAE_PREF_INITIAL_COMPLETED_STEPS must be >= 0"
    exit 1
fi

if [[ "$INITIAL_COMPLETED_STEPS" -gt "$TOTAL_STEPS" ]]; then
    echo "ERROR: FAE_PREF_INITIAL_COMPLETED_STEPS cannot exceed FAE_PREF_TOTAL_STEPS"
    exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required"
    exit 1
fi

remaining=$((TOTAL_STEPS - INITIAL_COMPLETED_STEPS))
completed="$INITIAL_COMPLETED_STEPS"
resume_dir="$INITIAL_RESUME_DIR"
chunk=1
skip_prepare=0

if [[ -n "$resume_dir" && ! -d "$resume_dir" ]]; then
    echo "ERROR: initial resume adapter dir not found: $resume_dir"
    exit 1
fi

if [[ "$remaining" -eq 0 ]]; then
    log "Nothing to do: completed steps already match target"
    log "Output dir: $OUTPUT_DIR"
    exit 0
fi

mkdir -p "$(dirname "$OUTPUT_DIR")" "$(dirname "$MERGED_OUTPUT_DIR")"

while [[ "$remaining" -gt 0 ]]; do
    current_chunk="$CHUNK_STEPS"
    if [[ "$remaining" -lt "$current_chunk" ]]; then
        current_chunk="$remaining"
    fi

    log "Chunk $chunk starting ($current_chunk steps, $completed/$TOTAL_STEPS completed)"

    chunk_env=(
        FAE_PREFERENCE_OUTPUT_DIR="$OUTPUT_DIR"
        FAE_PREF_MAX_STEPS="$current_chunk"
        FAE_PREF_SAVE_STEPS="$current_chunk"
        FAE_PREF_SKIP_PREPARE="$skip_prepare"
    )

    if [[ "$remaining" -eq "$current_chunk" ]]; then
        chunk_env+=(
            FAE_PREF_SKIP_MERGE=0
            FAE_PREFERENCE_MERGED_OUTPUT_DIR="$MERGED_OUTPUT_DIR"
        )
    else
        chunk_env+=(FAE_PREF_SKIP_MERGE=1)
    fi

    for name in \
        FAE_BASE_MODEL \
        FAE_TRAINING_DATA_DIR \
        FAE_IMPORTS_DIR \
        FAE_SKIP_MARKDOWN_SOURCES \
        FAE_PREFERENCE_DATA_DIR \
        FAE_PREF_INPUT \
        FAE_PREF_LEARNING_RATE \
        FAE_PREF_BETA \
        FAE_PREF_BATCH_SIZE \
        FAE_PREF_GRAD_ACCUMULATION_STEPS \
        FAE_PREF_MAX_SEQ_LENGTH \
        FAE_PREF_LOGGING_STEPS \
        FAE_PREF_SEED \
        FAE_PREF_NUM_LAYERS \
        FAE_PREF_LORA_R \
        FAE_PREF_LORA_ALPHA \
        FAE_PREF_TARGET_MODULES \
        FAE_PREF_TASKPOLICY_BACKGROUND
    do
        if [[ -n "${!name:-}" ]]; then
            chunk_env+=("$name=${!name}")
        fi
    done

    if [[ -n "$resume_dir" ]]; then
        chunk_env+=(FAE_PREF_RESUME_ADAPTER_DIR="$resume_dir")
    fi

    env "${chunk_env[@]}" bash "$SCRIPT_DIR/train_mlx_tune_preference.sh" "$TARGET_MODEL" "$METHOD"

    resume_dir="$OUTPUT_DIR/adapters"
    if [[ ! -f "$resume_dir/adapters.safetensors" ]]; then
        echo "ERROR: expected adapter file not found after chunk $chunk: $resume_dir/adapters.safetensors"
        exit 1
    fi

    completed=$((completed + current_chunk))
    remaining=$((remaining - current_chunk))
    skip_prepare=1
    chunk=$((chunk + 1))

    if [[ "$remaining" -gt 0 && "$COOLDOWN_SECONDS" -gt 0 ]]; then
        log "Cooling down for ${COOLDOWN_SECONDS}s before next chunk"
        sleep "$COOLDOWN_SECONDS"
    fi
done

log "Chunked preference training complete"
log "Output dir: $OUTPUT_DIR"
log "Merged output dir: $MERGED_OUTPUT_DIR"
