#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  bash scripts/convert_and_benchmark_hf_candidate.sh \
    --hf-model saorsa-labs/fae-qwen35-35b-a3b-sft-smoke-merged \
    [--candidate-name short-name]

Converts a merged Hugging Face model to local MLX format with the same affine
4-bit quantization used by Fae's current base models, then runs the targeted
benchmark gate:
  --tools --assistant-fit --fae-capabilities --no-think --serialization
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MACOS_DIR="$PROJECT_ROOT/native/macos/Fae"
BENCH_BIN="$MACOS_DIR/.build/xcode-benchmark-derived/Build/Products/Debug/FaeBenchmark"
BENCH_RESULTS_DIR="$PROJECT_ROOT/scripts/benchmark-results"
MODELS_DIR="$PROJECT_ROOT/training/models"

HF_MODEL=""
CANDIDATE_NAME=""
Q_BITS="${FAE_MLX_CONVERT_Q_BITS:-4}"
Q_GROUP_SIZE="${FAE_MLX_CONVERT_Q_GROUP_SIZE:-64}"
Q_MODE="${FAE_MLX_CONVERT_Q_MODE:-affine}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hf-model)
            HF_MODEL="$2"
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

if [[ -z "$HF_MODEL" ]]; then
    usage
    exit 1
fi

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required"
    exit 1
fi

mkdir -p "$MODELS_DIR" "$BENCH_RESULTS_DIR"

STAMP="$(date '+%Y%m%d-%H%M%S')"
if [[ -z "$CANDIDATE_NAME" ]]; then
    CANDIDATE_NAME="$(basename "$HF_MODEL")"
fi

MLX_PATH="$MODELS_DIR/${CANDIDATE_NAME}-mlx-${STAMP}"
CONVERT_LOG="$PROJECT_ROOT/training/${CANDIDATE_NAME}-convert-${STAMP}.log"
BENCH_OUTPUT="$BENCH_RESULTS_DIR/${CANDIDATE_NAME}_targeted_${STAMP}.json"

log "Building benchmark binary"
(cd "$MACOS_DIR" && just build-benchmark >/dev/null)

log "Converting merged HF model to MLX"
log "  hf model:        $HF_MODEL"
log "  mlx output:      $MLX_PATH"
log "  quantization:    ${Q_BITS}-bit group ${Q_GROUP_SIZE} (${Q_MODE})"

uv run --python 3.12 --with mlx-lm python -m mlx_lm convert \
    --hf-path "$HF_MODEL" \
    --mlx-path "$MLX_PATH" \
    --trust-remote-code \
    --quantize \
    --q-bits "$Q_BITS" \
    --q-group-size "$Q_GROUP_SIZE" \
    --q-mode "$Q_MODE" | tee "$CONVERT_LOG"

log "Running targeted benchmark"
"$BENCH_BIN" \
    --model "$MLX_PATH" \
    --tools \
    --assistant-fit \
    --fae-capabilities \
    --no-think \
    --serialization \
    --output "$BENCH_OUTPUT"

log "Done"
log "  mlx model:       $MLX_PATH"
log "  benchmark json:  $BENCH_OUTPUT"
log "  convert log:     $CONVERT_LOG"
