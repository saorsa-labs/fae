#!/bin/bash
# Run isolated 9B HF lane SFT experiments and benchmark each lane.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RUN_STAMP="${FAE_LANE_RUN_STAMP:-$(date '+%Y%m%d-%H%M%S')}"
LANE_IMPORT_ROOT="${FAE_LANE_IMPORT_ROOT:-$PROJECT_ROOT/training/imports/hf-lanes}"
LANE_DATA_ROOT="${FAE_LANE_DATA_ROOT:-$PROJECT_ROOT/training/data/hf-lanes}"
LANE_ADAPTER_ROOT="${FAE_LANE_ADAPTER_ROOT:-$PROJECT_ROOT/training/adapters}"
RESULTS_MANIFEST="${FAE_LANE_RESULTS_MANIFEST:-$PROJECT_ROOT/training/hf-lane-results-${RUN_STAMP}.json}"
INSTRUCTION_LIMIT="${FAE_INSTRUCTION_LIMIT:-200}"
TOOL_USE_LIMIT="${FAE_TOOL_USE_LIMIT:-250}"
NO_TOOL_LIMIT="${FAE_NO_TOOL_LIMIT:-250}"
MEMORY_LIMIT="${FAE_MEMORY_LIMIT:-300}"

TOTAL_ITERS="${FAE_TOTAL_ITERS:-8}"
CHUNK_ITERS="${FAE_CHUNK_ITERS:-2}"
NUM_LAYERS="${FAE_NUM_LAYERS:-4}"
MAX_SEQ_LENGTH="${FAE_MAX_SEQ_LENGTH:-512}"
LEARNING_RATE="${FAE_LEARNING_RATE:-5e-5}"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required"
    exit 1
fi

if [[ "$#" -gt 0 ]]; then
    LANES=("$@")
else
    LANES=("instruction" "tool-balance" "memory")
fi

mkdir -p "$LANE_IMPORT_ROOT" "$LANE_DATA_ROOT" "$LANE_ADAPTER_ROOT" "$(dirname "$RESULTS_MANIFEST")"

RESULTS_JSON="[]"

for lane in "${LANES[@]}"; do
    log "Importing lane data: $lane"
    uv run --python 3.12 --with datasets python "$SCRIPT_DIR/import_hf_lane_data.py" \
        --lane "$lane" \
        --output-dir "$LANE_IMPORT_ROOT" \
        --instruction-limit "$INSTRUCTION_LIMIT" \
        --tool-use-limit "$TOOL_USE_LIMIT" \
        --no-tool-limit "$NO_TOOL_LIMIT" \
        --memory-limit "$MEMORY_LIMIT"

    lane_import_dir="$LANE_IMPORT_ROOT/$lane"
    lane_data_dir="$LANE_DATA_ROOT/$lane-$RUN_STAMP"
    lane_adapter_dir="$LANE_ADAPTER_ROOT/qwen35-9b-${lane}-${RUN_STAMP}"
    candidate_name="qwen35-9b-${lane}-${RUN_STAMP}"
    lane_max_seq_length="$MAX_SEQ_LENGTH"
    if [[ "$lane" == "instruction" ]]; then
        lane_max_seq_length="${FAE_INSTRUCTION_MAX_SEQ_LENGTH:-1024}"
    fi

    log "Training lane: $lane"
    env \
        FAE_IMPORTS_DIR="$lane_import_dir" \
        FAE_TRAINING_DATA_DIR="$lane_data_dir" \
        FAE_ADAPTER_PATH="$lane_adapter_dir" \
        FAE_TOTAL_ITERS="$TOTAL_ITERS" \
        FAE_CHUNK_ITERS="$CHUNK_ITERS" \
        FAE_NUM_LAYERS="$NUM_LAYERS" \
        FAE_MAX_SEQ_LENGTH="$lane_max_seq_length" \
        FAE_LEARNING_RATE="$LEARNING_RATE" \
        FAE_GRAD_CHECKPOINT=1 \
        FAE_DISABLE_VALIDATION=1 \
        FAE_TASKPOLICY_BACKGROUND=1 \
        bash "$SCRIPT_DIR/train_mlx_lora_chunked.sh" 9b

    log "Benchmarking lane: $lane"
    bash "$SCRIPT_DIR/fuse_and_benchmark_candidate.sh" \
        --base-model mlx-community/Qwen3.5-9B-4bit \
        --adapter-dir "$lane_adapter_dir" \
        --candidate-name "$candidate_name"

    benchmark_json="$(ls -t "$PROJECT_ROOT/scripts/benchmark-results/${candidate_name}_targeted_"*.json | head -n 1)"
    fused_dir="$(ls -td "$PROJECT_ROOT/training/models/${candidate_name}-fused-"* | head -n 1)"

    RESULTS_JSON="$(
        python3 - <<'PY' "$RESULTS_JSON" "$lane" "$lane_import_dir" "$lane_data_dir" "$lane_adapter_dir" "$fused_dir" "$benchmark_json"
import json
import sys

rows = json.loads(sys.argv[1])
rows.append(
    {
        "lane": sys.argv[2],
        "imports_dir": sys.argv[3],
        "training_data_dir": sys.argv[4],
        "adapter_dir": sys.argv[5],
        "fused_dir": sys.argv[6],
        "benchmark_json": sys.argv[7],
    }
)
print(json.dumps(rows))
PY
    )"
done

python3 - <<'PY' "$RESULTS_JSON" "$RESULTS_MANIFEST"
import json
import sys
from pathlib import Path

Path(sys.argv[2]).write_text(json.dumps(json.loads(sys.argv[1]), indent=2) + "\n", encoding="utf-8")
print(f"Wrote results manifest to {sys.argv[2]}")
PY
