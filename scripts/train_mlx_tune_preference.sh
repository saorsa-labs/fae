#!/bin/bash
# Train preference adapters with mlx-tune DPO or ORPO.

set -euo pipefail

TARGET_MODEL="${1:-4b}"
METHOD="${2:-orpo}"

case "$TARGET_MODEL" in
    0.8b|0_8b|mini)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-0.8B-4bit}"
        MODEL_TAG="qwen35-0.8b"
        DEFAULT_TARGET_MODULES="q_proj,k_proj,v_proj,o_proj,gate_proj,up_proj,down_proj"
        ;;
    2b|tiny)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-2B-4bit}"
        MODEL_TAG="qwen35-2b"
        DEFAULT_TARGET_MODULES="q_proj,k_proj,v_proj,o_proj,gate_proj,up_proj,down_proj"
        ;;
    4b|small)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-4B-4bit}"
        MODEL_TAG="qwen35-4b"
        DEFAULT_TARGET_MODULES="q_proj,k_proj,v_proj,o_proj,gate_proj,up_proj,down_proj"
        ;;
    9b|8b|medium)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-9B-4bit}"
        MODEL_TAG="qwen35-9b"
        DEFAULT_TARGET_MODULES="q_proj,k_proj,v_proj,o_proj,gate_proj,up_proj,down_proj"
        ;;
    27b|xl|quality)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-27B-4bit}"
        MODEL_TAG="qwen35-27b"
        DEFAULT_TARGET_MODULES="q_proj,k_proj,v_proj,o_proj,gate_proj,up_proj,down_proj"
        ;;
    35b-a3b|34b-a3b|large)
        BASE_MODEL="${FAE_BASE_MODEL:-mlx-community/Qwen3.5-35B-A3B-4bit}"
        MODEL_TAG="qwen35-35b-a3b"
        DEFAULT_TARGET_MODULES="q_proj,k_proj,v_proj,o_proj,mlp.shared_expert.gate_proj,mlp.shared_expert.up_proj,mlp.shared_expert.down_proj,mlp.switch_mlp.gate_proj,mlp.switch_mlp.up_proj,mlp.switch_mlp.down_proj"
        ;;
    *)
        echo "Usage: $0 [0.8b|2b|4b|8b|9b|27b|34b-a3b|35b-a3b|mini|tiny|small|medium|xl|quality|large] [dpo|orpo]"
        exit 1
        ;;
esac

if [[ "$METHOD" != "dpo" && "$METHOD" != "orpo" ]]; then
    echo "ERROR: method must be dpo or orpo"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
. "$SCRIPT_DIR/lib/model_cache.sh"

UV_RUN=(
    uv run
    --python 3.12
    --with mlx-lm
    --with transformers
    --with jinja2
    --with "mlx-tune @ git+https://github.com/ARahim3/mlx-tune@main"
)

RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
SOURCE_DIR="${FAE_SOURCE_DIR:-$PROJECT_ROOT}"
TRAINING_DATA_DIR="${FAE_TRAINING_DATA_DIR:-$PROJECT_ROOT/training/data}"
IMPORTS_DIR="${FAE_IMPORTS_DIR:-$PROJECT_ROOT/training/imports}"
SKIP_MARKDOWN_SOURCES="${FAE_SKIP_MARKDOWN_SOURCES:-0}"
PREF_DIR="${FAE_PREFERENCE_DATA_DIR:-$TRAINING_DATA_DIR/mlx_tune/$MODEL_TAG}"
OUTPUT_DIR="${FAE_PREFERENCE_OUTPUT_DIR:-$PROJECT_ROOT/training/adapters/${MODEL_TAG}-${METHOD}-${RUN_STAMP}}"
MERGED_OUTPUT_DIR="${FAE_PREFERENCE_MERGED_OUTPUT_DIR:-$PROJECT_ROOT/training/models/${MODEL_TAG}-${METHOD}-${RUN_STAMP}}"
MAX_STEPS="${FAE_PREF_MAX_STEPS:-20}"
LEARNING_RATE="${FAE_PREF_LEARNING_RATE:-2e-6}"
BETA="${FAE_PREF_BETA:-0.1}"
BATCH_SIZE="${FAE_PREF_BATCH_SIZE:-1}"
GRAD_ACCUM="${FAE_PREF_GRAD_ACCUMULATION_STEPS:-1}"
MAX_SEQ_LENGTH="${FAE_PREF_MAX_SEQ_LENGTH:-2048}"
SAVE_STEPS="${FAE_PREF_SAVE_STEPS:-20}"
LOGGING_STEPS="${FAE_PREF_LOGGING_STEPS:-1}"
SEED="${FAE_PREF_SEED:-3407}"
NUM_LAYERS="${FAE_PREF_NUM_LAYERS:-}"
LORA_R="${FAE_PREF_LORA_R:-8}"
LORA_ALPHA="${FAE_PREF_LORA_ALPHA:-16}"
TARGET_MODULES="${FAE_PREF_TARGET_MODULES:-$DEFAULT_TARGET_MODULES}"
EXPORT_INPUT="${FAE_PREF_INPUT:-$TRAINING_DATA_DIR/dpo_train.jsonl}"
BASE_MODEL_SOURCE="$(fae_resolve_model_source "$BASE_MODEL")"
RESUME_ADAPTER_DIR="${FAE_PREF_RESUME_ADAPTER_DIR:-}"
SKIP_PREPARE="${FAE_PREF_SKIP_PREPARE:-0}"
SKIP_MERGE="${FAE_PREF_SKIP_MERGE:-0}"
TASKPOLICY_BACKGROUND="${FAE_PREF_TASKPOLICY_BACKGROUND:-0}"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

run_uv_python() {
    "${UV_RUN[@]}" python -u "$@"
}

if [[ "$SKIP_PREPARE" != "1" ]]; then
    log "Preparing training data"
    PREPARE_CMD=(
        "$SCRIPT_DIR/prepare_training_data.py"
        --source-dir "$SOURCE_DIR" \
        --output-dir "$TRAINING_DATA_DIR" \
        --imports-dir "$IMPORTS_DIR" \
        --split
    )
    if [[ "$SKIP_MARKDOWN_SOURCES" == "1" ]]; then
        PREPARE_CMD+=(--skip-markdown-sources)
    fi
    run_uv_python "${PREPARE_CMD[@]}"
else
    log "Skipping training-data preparation"
fi

if [[ ! -s "$EXPORT_INPUT" ]]; then
    echo "ERROR: missing preference split: $EXPORT_INPUT"
    exit 1
fi

mkdir -p "$PREF_DIR"

log "Exporting mlx-tune preference dataset"
run_uv_python "$SCRIPT_DIR/export_mlx_tune_preference_data.py" \
    --input "$EXPORT_INPUT" \
    --output "$PREF_DIR/${METHOD}_train.jsonl" \
    --tokenizer "$BASE_MODEL_SOURCE"

log "Starting mlx-tune $METHOD run"
log "Base model: $BASE_MODEL"
log "Resolved model source: $BASE_MODEL_SOURCE"
log "Preference data: $PREF_DIR/${METHOD}_train.jsonl"
log "Output dir: $OUTPUT_DIR"
if [[ "$SKIP_MERGE" == "1" ]]; then
    log "Merged output dir: skipped"
else
    log "Merged output dir: $MERGED_OUTPUT_DIR"
fi
log "Background taskpolicy: $TASKPOLICY_BACKGROUND"
if [[ -n "$RESUME_ADAPTER_DIR" ]]; then
    log "Resume adapter dir: $RESUME_ADAPTER_DIR"
fi

TRAIN_CMD=(
    "${UV_RUN[@]}" python -u "$SCRIPT_DIR/run_mlx_tune_preference.py"
    --method "$METHOD" \
    --model "$BASE_MODEL_SOURCE" \
    --train-data "$PREF_DIR/${METHOD}_train.jsonl" \
    --output-dir "$OUTPUT_DIR" \
    --max-seq-length "$MAX_SEQ_LENGTH" \
    --max-steps "$MAX_STEPS" \
    --learning-rate "$LEARNING_RATE" \
    --beta "$BETA" \
    --batch-size "$BATCH_SIZE" \
    --gradient-accumulation-steps "$GRAD_ACCUM" \
    --logging-steps "$LOGGING_STEPS" \
    --save-steps "$SAVE_STEPS" \
    --seed "$SEED" \
    --lora-r "$LORA_R" \
    --lora-alpha "$LORA_ALPHA" \
    --target-modules "$TARGET_MODULES"
)

if [[ -n "$NUM_LAYERS" ]]; then
    TRAIN_CMD+=(--num-layers "$NUM_LAYERS")
fi

if [[ "$SKIP_MERGE" != "1" ]]; then
    TRAIN_CMD+=(--merged-output-dir "$MERGED_OUTPUT_DIR")
fi

if [[ -n "$RESUME_ADAPTER_DIR" ]]; then
    TRAIN_CMD+=(--resume-adapter-dir "$RESUME_ADAPTER_DIR")
fi

if [[ "$TASKPOLICY_BACKGROUND" == "1" ]]; then
    if ! command -v taskpolicy >/dev/null 2>&1; then
        echo "ERROR: taskpolicy requested but not available"
        exit 1
    fi
    taskpolicy -b "${TRAIN_CMD[@]}"
else
    "${TRAIN_CMD[@]}"
fi

log "mlx-tune $METHOD run complete"
log "Output dir: $OUTPUT_DIR"
if [[ "$SKIP_MERGE" != "1" ]]; then
    log "Merged output dir: $MERGED_OUTPUT_DIR"
fi
