#!/bin/bash
# Run the synthetic surgical 9B lane against the two stubborn benchmark misses.

set -euo pipefail

MODE="${1:-sft}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RUN_STAMP="${FAE_SURGICAL_RUN_STAMP:-$(date '+%Y%m%d-%H%M%S')}"
IMPORT_DIR="${FAE_SURGICAL_IMPORT_DIR:-$PROJECT_ROOT/training/imports/surgical/9b}"
DATA_DIR="${FAE_SURGICAL_DATA_DIR:-$PROJECT_ROOT/training/data/surgical/9b-$RUN_STAMP}"
ADAPTER_DIR="${FAE_SURGICAL_ADAPTER_DIR:-$PROJECT_ROOT/training/adapters/qwen35-9b-surgical-${MODE}-$RUN_STAMP}"
MODEL_DIR="${FAE_SURGICAL_MODEL_DIR:-$PROJECT_ROOT/training/models/qwen35-9b-surgical-${MODE}-$RUN_STAMP}"
TOTAL_STEPS="${FAE_SURGICAL_TOTAL_STEPS:-16}"
CHUNK_STEPS="${FAE_SURGICAL_CHUNK_STEPS:-1}"
NUM_LAYERS="${FAE_SURGICAL_NUM_LAYERS:-2}"
MAX_SEQ_LENGTH="${FAE_SURGICAL_MAX_SEQ_LENGTH:-384}"
LEARNING_RATE="${FAE_SURGICAL_LEARNING_RATE:-5e-5}"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if [[ "$MODE" != "sft" && "$MODE" != "orpo" ]]; then
    echo "Usage: $0 [sft|orpo]"
    exit 1
fi

log "Generating surgical lane data"
python3 "$SCRIPT_DIR/generate_surgical_lane_data.py" --output-dir "$IMPORT_DIR"

if [[ "$MODE" == "sft" ]]; then
    log "Running surgical SFT lane"
    env \
        FAE_IMPORTS_DIR="$IMPORT_DIR" \
        FAE_SKIP_MARKDOWN_SOURCES=1 \
        FAE_TRAINING_DATA_DIR="$DATA_DIR" \
        FAE_ADAPTER_PATH="$ADAPTER_DIR" \
        FAE_TOTAL_ITERS="$TOTAL_STEPS" \
        FAE_CHUNK_ITERS="$CHUNK_STEPS" \
        FAE_NUM_LAYERS="$NUM_LAYERS" \
        FAE_MAX_SEQ_LENGTH="$MAX_SEQ_LENGTH" \
        FAE_LEARNING_RATE="$LEARNING_RATE" \
        FAE_GRAD_CHECKPOINT=1 \
        FAE_DISABLE_VALIDATION=1 \
        FAE_TASKPOLICY_BACKGROUND=1 \
        bash "$SCRIPT_DIR/train_mlx_lora_chunked.sh" 9b

    log "Benchmarking surgical SFT lane"
    bash "$SCRIPT_DIR/fuse_and_benchmark_candidate.sh" \
        --base-model mlx-community/Qwen3.5-9B-4bit \
        --adapter-dir "$ADAPTER_DIR" \
        --candidate-name "qwen35-9b-surgical-sft-$RUN_STAMP"
else
    log "Running surgical ORPO lane"
    env \
        FAE_IMPORTS_DIR="$IMPORT_DIR" \
        FAE_SKIP_MARKDOWN_SOURCES=1 \
        FAE_TRAINING_DATA_DIR="$DATA_DIR" \
        FAE_PREFERENCE_OUTPUT_DIR="$ADAPTER_DIR" \
        FAE_PREFERENCE_MERGED_OUTPUT_DIR="$MODEL_DIR" \
        FAE_PREF_TOTAL_STEPS="$TOTAL_STEPS" \
        FAE_PREF_CHUNK_STEPS="$CHUNK_STEPS" \
        FAE_PREF_NUM_LAYERS="$NUM_LAYERS" \
        FAE_PREF_MAX_SEQ_LENGTH="$MAX_SEQ_LENGTH" \
        FAE_PREF_LEARNING_RATE=2e-6 \
        FAE_PREF_TASKPOLICY_BACKGROUND=1 \
        bash "$SCRIPT_DIR/train_mlx_tune_preference_chunked.sh" 9b orpo

    log "Benchmarking surgical ORPO lane"
    "$PROJECT_ROOT/native/macos/Fae/.build/xcode-benchmark-derived/Build/Products/Debug/FaeBenchmark" \
        --model "$MODEL_DIR" \
        --tools \
        --assistant-fit \
        --fae-capabilities \
        --no-think \
        --serialization \
        --output "$PROJECT_ROOT/scripts/benchmark-results/qwen35-9b-surgical-orpo-${RUN_STAMP}.json"
fi
