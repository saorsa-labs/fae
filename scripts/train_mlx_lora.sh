#!/bin/bash
# =============================================================================
# Fae companion model fine-tuning — MLX LoRA
# Base:   mlx-community/Qwen3.5-0.8B-bf16  (bf16 for best fine-tuning quality)
# Target: saorsa-labs/saorsa1-tiny-pre-release
# Method: SFT LoRA → fuse → (DPO when mlx-lm supports it)
# =============================================================================
#
# PREREQUISITES:
#   uv (install via: curl -LsSf https://astral.sh/uv/install.sh | sh)
#   hf auth login   (preferred)
#   # or: export HF_TOKEN=your_huggingface_token
#
# Uses uv to install mlx-lm 0.31.1+ in an isolated Python 3.12 environment.
# This bypasses macOS system Python (3.9) which cannot run Qwen3.5 models,
# and avoids mlx wheel availability issues on macOS 26 beta.
#
# USAGE:
#   bash scripts/train_mlx_lora.sh
#
# Expected runtime on M2 Pro (16GB): 45-75 minutes for SFT pass.
# Expected runtime on M3 Max (64GB): 20-40 minutes.
#
# Model ID confirmed: mlx-community/Qwen3.5-0.8B-bf16 exists on HuggingFace.
# Qwen3.5-0.8B does not have a separate -Instruct variant; the base model
# supports instruction following natively via its chat template.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these before running
# ---------------------------------------------------------------------------

# Base model HuggingFace ID
# Using bf16 from mlx-community for best fine-tuning quality (no pre-quantization loss).
# mlx-lm will quantize after fine-tuning via the fuse step if desired.
# Alternative: "Qwen/Qwen3.5-0.8B" (HF safetensors — mlx-lm converts automatically)
BASE_MODEL="mlx-community/Qwen3.5-0.8B-bf16"

# Target repo on HuggingFace
HF_REPO="saorsa-labs/saorsa1-tiny-pre-release"

# Paths (relative to project root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TRAINING_DATA_DIR="$PROJECT_ROOT/training/data"
ADAPTERS_DIR="$PROJECT_ROOT/training/adapters"
MODELS_DIR="$PROJECT_ROOT/training/models"

SFT_ADAPTER_PATH="$ADAPTERS_DIR/sft"
SFT_MERGED_PATH="$MODELS_DIR/sft-merged"

# Training hyperparameters for SFT pass
SFT_BATCH_SIZE=4
SFT_NUM_LAYERS=16     # Number of LoRA layers (higher = more capacity, more VRAM)
SFT_ITERS=600         # Training iterations
SFT_LR=1e-4           # Learning rate
SFT_VAL_BATCHES=10    # Validation batches per eval

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: '$1' not found. Install with: $2"
        exit 1
    fi
}

hf_auth_available() {
    if command -v hf &>/dev/null && hf auth whoami &>/dev/null; then
        return 0
    fi

    $UV_RUN python -c "from huggingface_hub import get_token; raise SystemExit(0 if get_token() else 1)" \
        &>/dev/null
}

# ---------------------------------------------------------------------------
# Step 0: Check prerequisites
# ---------------------------------------------------------------------------

log "=== Step 0: Checking prerequisites ==="

# Use uv to run Python 3.12 with mlx-lm 0.31.1+ (supports qwen3_5 model type).
# System Python 3.9 / mlx-lm 0.22.0 cannot run Qwen3.5 models.
# uv creates an isolated environment and downloads dependencies automatically.
UV_RUN="uv run --python 3.12 --with mlx-lm --with huggingface_hub"

# Check uv is available
if ! command -v uv &>/dev/null; then
    echo "ERROR: 'uv' not found. Install with:"
    echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

MLX_LM_VERSION=$($UV_RUN python -c "import mlx_lm; print(getattr(mlx_lm, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
log "mlx-lm version: $MLX_LM_VERSION (via uv Python 3.12)"

# Check Hugging Face auth is available for upload step
if ! hf_auth_available; then
    echo "WARNING: no Hugging Face auth detected."
    echo "  Training will proceed, but the upload step will be skipped."
    echo "  Run 'hf auth login' before running, or set HF_TOKEN as an override."
fi

log "Prerequisites OK"
echo

# ---------------------------------------------------------------------------
# Step 1: Prepare training data
# ---------------------------------------------------------------------------

log "=== Step 1: Preparing training data ==="

$UV_RUN python "$SCRIPT_DIR/prepare_training_data.py" \
    --source-dir "$PROJECT_ROOT" \
    --output-dir "$TRAINING_DATA_DIR" \
    --split

# Verify the output files exist and are non-empty
for required_file in "sft_train.jsonl" "sft_val.jsonl"; do
    path="$TRAINING_DATA_DIR/$required_file"
    if [[ ! -s "$path" ]]; then
        echo "ERROR: Expected training data file not found or empty: $path"
        echo "  Check prepare_training_data.py output above for errors."
        exit 1
    fi
done

SFT_TRAIN_COUNT=$(wc -l < "$TRAINING_DATA_DIR/sft_train.jsonl")
SFT_VAL_COUNT=$(wc -l < "$TRAINING_DATA_DIR/sft_val.jsonl")
log "SFT training: $SFT_TRAIN_COUNT train, $SFT_VAL_COUNT val examples"
echo

# ---------------------------------------------------------------------------
# Step 2: SFT pass — train LoRA adapter
# ---------------------------------------------------------------------------
#
# mlx_lm.lora trains a Low-Rank Adaptation (LoRA) on top of the base model.
# The adapter contains only the delta weights, not the full model — it is small
# (a few hundred MB for 16 layers on a 0.8B model).
#
# --data expects a directory containing train.jsonl and valid.jsonl, OR explicit
# train/valid JSONL paths. We copy our split files to the expected names first.
# ---------------------------------------------------------------------------

log "=== Step 2: SFT LoRA training ==="

mkdir -p "$ADAPTERS_DIR"

# mlx_lm.lora expects train.jsonl and valid.jsonl in the data directory
cp "$TRAINING_DATA_DIR/sft_train.jsonl" "$TRAINING_DATA_DIR/train.jsonl"
cp "$TRAINING_DATA_DIR/sft_val.jsonl" "$TRAINING_DATA_DIR/valid.jsonl"

log "Starting SFT training..."
log "  Base model:    $BASE_MODEL"
log "  Adapter path:  $SFT_ADAPTER_PATH"
log "  Iterations:    $SFT_ITERS"
log "  Batch size:    $SFT_BATCH_SIZE"
log "  LoRA layers:   $SFT_NUM_LAYERS"
log "  Learning rate: $SFT_LR"
echo

# uv run ensures we get mlx-lm 0.31.1+ with qwen3_5 model support
$UV_RUN python -m mlx_lm lora \
    --model "$BASE_MODEL" \
    --train \
    --data "$TRAINING_DATA_DIR" \
    --batch-size $SFT_BATCH_SIZE \
    --num-layers $SFT_NUM_LAYERS \
    --iters $SFT_ITERS \
    --learning-rate $SFT_LR \
    --adapter-path "$SFT_ADAPTER_PATH" \
    --val-batches $SFT_VAL_BATCHES \
    --mask-prompt \
    --steps-per-report 10 \
    --steps-per-eval 100 \
    --save-every 100

log "SFT training complete. Adapter saved to: $SFT_ADAPTER_PATH"
echo

# ---------------------------------------------------------------------------
# Step 3: Fuse SFT adapter into base model
# ---------------------------------------------------------------------------
#
# Fusing bakes the LoRA delta weights into the base model weights, producing
# a standalone model that can be loaded without the adapter. The fused model
# is larger than the adapter alone but easier to deploy and use in Fae.
# ---------------------------------------------------------------------------

log "=== Step 3: Fusing SFT adapter ==="

mkdir -p "$MODELS_DIR"

log "Fusing adapter into base model..."
log "  Input:  $BASE_MODEL + $SFT_ADAPTER_PATH"
log "  Output: $SFT_MERGED_PATH"
echo

$UV_RUN python -m mlx_lm fuse \
    --model "$BASE_MODEL" \
    --adapter-path "$SFT_ADAPTER_PATH" \
    --save-path "$SFT_MERGED_PATH"

log "Fuse complete. Merged model saved to: $SFT_MERGED_PATH"
echo

# ---------------------------------------------------------------------------
# Step 4: DPO pass (PENDING — mlx-lm does not yet have native DPO)
# ---------------------------------------------------------------------------
#
# As of mid-2025, mlx-lm does not have a built-in DPO trainer.
# The DPO training data (training_data/dpo.jsonl) is prepared and ready to use
# once DPO support is added to mlx-lm.
#
# OPTION A (preferred): Wait for mlx-lm DPO support and run this script again.
#   Track: https://github.com/ml-explore/mlx-lm for DPO PR/release.
#   When available, the command will look roughly like:
#
#     python3 -m mlx_lm.dpo \
#         --model "$SFT_MERGED_PATH" \
#         --train \
#         --data "$TRAINING_DATA_DIR" \
#         --batch-size 2 \
#         --num-layers 16 \
#         --iters 400 \
#         --learning-rate 5e-5 \
#         --adapter-path "$ADAPTERS_DIR/dpo/" \
#         --val-batches 10
#
#     python3 -m mlx_lm.fuse \
#         --model "$SFT_MERGED_PATH" \
#         --adapter-path "$ADAPTERS_DIR/dpo/" \
#         --save-path "$MODELS_DIR/dpo-merged/"
#
# OPTION B: Export to Transformers format + TRL DPO on CUDA.
#   This requires a CUDA machine or HuggingFace AutoTrain access.
#   Export the SFT-merged model:
#
#     python3 -m mlx_lm.convert \
#         --hf-path "$SFT_MERGED_PATH" \
#         --mlx-path "$MODELS_DIR/sft-merged-hf/" \
#         --dtype float16
#
#   Then run TRL DPO with dpo.jsonl on the exported model.
#   After DPO, convert back with mlx_lm.convert --hf-path to --mlx-path.

log "=== Step 4: DPO pass (skipped — mlx-lm DPO not yet available) ==="
log "DPO training data is ready at: $TRAINING_DATA_DIR/dpo.jsonl"
log "See script comments for DPO options when mlx-lm adds DPO support."
echo

# ---------------------------------------------------------------------------
# Step 5: Upload to HuggingFace
# ---------------------------------------------------------------------------

log "=== Step 5: Uploading to HuggingFace ==="

if ! hf_auth_available; then
    log "Skipping upload: no Hugging Face auth detected"
    log "To upload manually, run:"
    log "  hf auth login"
    log "  python3 $SCRIPT_DIR/upload_to_hf.py \\"
    log "    --model-path $SFT_MERGED_PATH \\"
    log "    --repo-id $HF_REPO"
else
    $UV_RUN python "$SCRIPT_DIR/upload_to_hf.py" \
        --model-path "$SFT_MERGED_PATH" \
        --repo-id "$HF_REPO"
fi

echo

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

log "=== Training pipeline complete ==="
log ""
log "Outputs:"
log "  SFT adapter:    $SFT_ADAPTER_PATH"
log "  Merged model:   $SFT_MERGED_PATH"
log ""
log "To test in Fae, add to ~/Library/Application Support/fae/config.toml:"
log "  [llm]"
log "  voiceModelPreset = \"custom\""
log "  customModelPath = \"$SFT_MERGED_PATH\""
log ""
log "Or point to the HuggingFace repo after upload:"
log "  customModelPath = \"$HF_REPO\""
