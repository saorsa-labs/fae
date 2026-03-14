#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/fuse_and_benchmark_candidate.sh \
    --base-model mlx-community/Qwen3.5-4B-4bit \
    --adapter-dir /abs/path/to/adapter-dir \
    [--checkpoint-file /abs/path/to/0000004_adapters.safetensors] \
    [--candidate-name short-name]

Fuses a trained adapter or checkpoint into a local MLX model directory and runs
the targeted post-train benchmark gate:
  --tools --assistant-fit --fae-capabilities --no-think --serialization
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
. "$SCRIPT_DIR/lib/model_cache.sh"
MACOS_DIR="$PROJECT_ROOT/native/macos/Fae"
BENCH_BIN="$MACOS_DIR/.build/xcode-benchmark-derived/Build/Products/Debug/FaeBenchmark"
BENCH_RESULTS_DIR="$PROJECT_ROOT/scripts/benchmark-results"
FUSED_MODELS_DIR="$PROJECT_ROOT/training/models"

BASE_MODEL=""
ADAPTER_DIR=""
CHECKPOINT_FILE=""
CANDIDATE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-model)
            BASE_MODEL="$2"
            shift 2
            ;;
        --adapter-dir)
            ADAPTER_DIR="$2"
            shift 2
            ;;
        --checkpoint-file)
            CHECKPOINT_FILE="$2"
            shift 2
            ;;
        --candidate-name)
            CANDIDATE_NAME="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$BASE_MODEL" || -z "$ADAPTER_DIR" ]]; then
    usage
    exit 1
fi

if [[ ! -d "$ADAPTER_DIR" ]]; then
    echo "ERROR: adapter dir not found: $ADAPTER_DIR"
    exit 1
fi

if [[ -n "$CHECKPOINT_FILE" && ! -f "$CHECKPOINT_FILE" ]]; then
    echo "ERROR: checkpoint file not found: $CHECKPOINT_FILE"
    exit 1
fi

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

prepare_adapter_dir() {
    local adapter_dir="$1"
    local checkpoint_file="$2"

    if [[ -z "$checkpoint_file" ]]; then
        printf '%s\n' "$adapter_dir"
        return 0
    fi

    local temp_dir
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fae-adapter-XXXXXX")"
    cp "$adapter_dir/adapter_config.json" "$temp_dir/adapter_config.json"
    cp "$checkpoint_file" "$temp_dir/adapters.safetensors"
    printf '%s\n' "$temp_dir"
}

if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required"
    exit 1
fi

mkdir -p "$FUSED_MODELS_DIR" "$BENCH_RESULTS_DIR"

BASE_MODEL_SOURCE="$(fae_resolve_model_source "$BASE_MODEL")"
ADAPTER_INPUT_DIR="$(prepare_adapter_dir "$ADAPTER_DIR" "$CHECKPOINT_FILE")"

STAMP="$(date '+%Y%m%d-%H%M%S')"
if [[ -z "$CANDIDATE_NAME" ]]; then
    CANDIDATE_NAME="$(basename "$ADAPTER_DIR")"
    if [[ -n "$CHECKPOINT_FILE" ]]; then
        CANDIDATE_NAME="${CANDIDATE_NAME}-$(basename "$CHECKPOINT_FILE" .safetensors)"
    fi
fi

FUSED_PATH="$FUSED_MODELS_DIR/${CANDIDATE_NAME}-fused-${STAMP}"
FUSE_LOG="$PROJECT_ROOT/training/${CANDIDATE_NAME}-fuse-${STAMP}.log"
BENCH_OUTPUT="$BENCH_RESULTS_DIR/${CANDIDATE_NAME}_targeted_${STAMP}.json"

log "Building benchmark binary"
(cd "$MACOS_DIR" && just build-benchmark >/dev/null)

log "Fusing candidate"
log "  base model source: $BASE_MODEL_SOURCE"
log "  adapter dir:       $ADAPTER_INPUT_DIR"
log "  fused output:      $FUSED_PATH"

set +e
uv run --python 3.12 --with mlx-lm python -m mlx_lm fuse \
    --model "$BASE_MODEL_SOURCE" \
    --adapter-path "$ADAPTER_INPUT_DIR" \
    --save-path "$FUSED_PATH" | tee "$FUSE_LOG"
fuse_status=$?
set -e

if [[ ! -f "$FUSED_PATH/model.safetensors" ]]; then
    if [[ ! -f "$FUSED_PATH/model.safetensors.index.json" ]] && ! find "$FUSED_PATH" -maxdepth 1 -name 'model-*.safetensors' | grep -q .; then
        echo "ERROR: fuse failed and no fused model was produced"
        exit "$fuse_status"
    fi
fi

if [[ $fuse_status -ne 0 ]]; then
    log "Fuse exited non-zero, but fused weights exist. Continuing."
fi

log "Running targeted benchmark"
"$BENCH_BIN" \
    --model "$FUSED_PATH" \
    --tools \
    --assistant-fit \
    --fae-capabilities \
    --no-think \
    --serialization \
    --output "$BENCH_OUTPUT"

if [[ "$ADAPTER_INPUT_DIR" != "$ADAPTER_DIR" ]]; then
    rm -rf "$ADAPTER_INPUT_DIR"
fi

log "Done"
log "  fused model:    $FUSED_PATH"
log "  benchmark json: $BENCH_OUTPUT"
log "  fuse log:       $FUSE_LOG"
