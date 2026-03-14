#!/bin/bash
# Import selected HF dataset lanes, train isolated SFT pilots, and benchmark them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RUN_STAMP="${FAE_MATRIX_RUN_STAMP:-$(date '+%Y%m%d-%H%M%S')}"
LANE_IMPORT_ROOT="${FAE_MATRIX_IMPORT_ROOT:-$PROJECT_ROOT/training/imports/hf-datasets}"
LANE_DATA_ROOT="${FAE_MATRIX_DATA_ROOT:-$PROJECT_ROOT/training/data/hf-datasets}"
LANE_ADAPTER_ROOT="${FAE_MATRIX_ADAPTER_ROOT:-$PROJECT_ROOT/training/adapters}"
RESULTS_MANIFEST="${FAE_MATRIX_RESULTS_MANIFEST:-$PROJECT_ROOT/training/hf-dataset-matrix-${RUN_STAMP}.json}"
DELETE_FUSED="${FAE_MATRIX_DELETE_FUSED:-1}"

WHEN2CALL_SFT_LIMIT="${FAE_WHEN2CALL_SFT_LIMIT:-400}"
WHEN2CALL_PREF_LIMIT="${FAE_WHEN2CALL_PREF_LIMIT:-250}"
TOOLACE_LIMIT="${FAE_TOOLACE_LIMIT:-400}"
USER_PROFILE_LIMIT="${FAE_USER_PROFILE_LIMIT:-400}"

MODELS_CSV="${FAE_MATRIX_MODELS:-4b,9b,35b-a3b}"
LANES_CSV="${FAE_MATRIX_LANES:-when2call,toolace,user-profile}"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

base_benchmark_for_model() {
    case "$1" in
        4b|small)
            printf '%s\n' "$PROJECT_ROOT/scripts/benchmark-results/qwen3.5-4b_20260313-172055.json"
            ;;
        9b|8b|medium)
            printf '%s\n' "$PROJECT_ROOT/scripts/benchmark-results/qwen3.5-9b_20260313-172928.json"
            ;;
        35b-a3b|34b-a3b|large)
            printf '%s\n' "$PROJECT_ROOT/scripts/benchmark-results/qwen3.5-35b-a3b_targeted_20260313-current.json"
            ;;
        *)
            echo "ERROR: unsupported model for base benchmark: $1" >&2
            exit 1
            ;;
    esac
}

base_model_id_for_model() {
    case "$1" in
        4b|small)
            printf '%s\n' "mlx-community/Qwen3.5-4B-4bit"
            ;;
        9b|8b|medium)
            printf '%s\n' "mlx-community/Qwen3.5-9B-4bit"
            ;;
        35b-a3b|34b-a3b|large)
            printf '%s\n' "mlx-community/Qwen3.5-35B-A3B-4bit"
            ;;
        *)
            echo "ERROR: unsupported model for base model id: $1" >&2
            exit 1
            ;;
    esac
}

apply_model_recipe() {
    case "$1" in
        4b|small)
            MODEL_TOTAL_ITERS="${FAE_MATRIX_4B_TOTAL_ITERS:-8}"
            MODEL_CHUNK_ITERS="${FAE_MATRIX_4B_CHUNK_ITERS:-2}"
            MODEL_NUM_LAYERS="${FAE_MATRIX_4B_NUM_LAYERS:-4}"
            MODEL_MAX_SEQ_LENGTH="${FAE_MATRIX_4B_MAX_SEQ_LENGTH:-512}"
            MODEL_LEARNING_RATE="${FAE_MATRIX_4B_LEARNING_RATE:-3e-5}"
            ;;
        9b|8b|medium)
            MODEL_TOTAL_ITERS="${FAE_MATRIX_9B_TOTAL_ITERS:-4}"
            MODEL_CHUNK_ITERS="${FAE_MATRIX_9B_CHUNK_ITERS:-1}"
            MODEL_NUM_LAYERS="${FAE_MATRIX_9B_NUM_LAYERS:-2}"
            MODEL_MAX_SEQ_LENGTH="${FAE_MATRIX_9B_MAX_SEQ_LENGTH:-384}"
            MODEL_LEARNING_RATE="${FAE_MATRIX_9B_LEARNING_RATE:-3e-5}"
            ;;
        35b-a3b|34b-a3b|large)
            MODEL_TOTAL_ITERS="${FAE_MATRIX_35B_TOTAL_ITERS:-4}"
            MODEL_CHUNK_ITERS="${FAE_MATRIX_35B_CHUNK_ITERS:-1}"
            MODEL_NUM_LAYERS="${FAE_MATRIX_35B_NUM_LAYERS:-2}"
            MODEL_MAX_SEQ_LENGTH="${FAE_MATRIX_35B_MAX_SEQ_LENGTH:-512}"
            MODEL_LEARNING_RATE="${FAE_MATRIX_35B_LEARNING_RATE:-2e-5}"
            ;;
        *)
            echo "ERROR: unsupported model recipe: $1" >&2
            exit 1
            ;;
    esac
}

split_csv() {
    python3 - <<'PY' "$1"
import sys
items=[item.strip() for item in sys.argv[1].split(",") if item.strip()]
for item in items:
    print(item)
PY
}

if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required"
    exit 1
fi

mapfile -t MODELS < <(split_csv "$MODELS_CSV")
mapfile -t LANES < <(split_csv "$LANES_CSV")

mkdir -p "$LANE_IMPORT_ROOT" "$LANE_DATA_ROOT" "$LANE_ADAPTER_ROOT" "$(dirname "$RESULTS_MANIFEST")"

RESULTS_JSON="[]"

for lane in "${LANES[@]}"; do
    log "Importing lane data: $lane"
    uv run --python 3.12 --with datasets python "$SCRIPT_DIR/import_hf_lane_data.py" \
        --lane "$lane" \
        --output-dir "$LANE_IMPORT_ROOT" \
        --when2call-sft-limit "$WHEN2CALL_SFT_LIMIT" \
        --when2call-pref-limit "$WHEN2CALL_PREF_LIMIT" \
        --toolace-limit "$TOOLACE_LIMIT" \
        --user-profile-limit "$USER_PROFILE_LIMIT"
done

for model in "${MODELS[@]}"; do
    apply_model_recipe "$model"
    base_benchmark="$(base_benchmark_for_model "$model")"
    base_model_id="$(base_model_id_for_model "$model")"

    for lane in "${LANES[@]}"; do
        lane_import_dir="$LANE_IMPORT_ROOT/$lane"
        lane_data_dir="$LANE_DATA_ROOT/${lane}-${model}-${RUN_STAMP}"
        lane_adapter_dir="$LANE_ADAPTER_ROOT/qwen35-${model}-${lane}-${RUN_STAMP}"
        candidate_name="qwen35-${model}-${lane}-${RUN_STAMP}"

        log "Training lane=$lane model=$model"
        env \
            FAE_IMPORTS_DIR="$lane_import_dir" \
            FAE_SKIP_MARKDOWN_SOURCES=1 \
            FAE_TRAINING_DATA_DIR="$lane_data_dir" \
            FAE_ADAPTER_PATH="$lane_adapter_dir" \
            FAE_TOTAL_ITERS="$MODEL_TOTAL_ITERS" \
            FAE_CHUNK_ITERS="$MODEL_CHUNK_ITERS" \
            FAE_NUM_LAYERS="$MODEL_NUM_LAYERS" \
            FAE_MAX_SEQ_LENGTH="$MODEL_MAX_SEQ_LENGTH" \
            FAE_LEARNING_RATE="$MODEL_LEARNING_RATE" \
            FAE_GRAD_CHECKPOINT=1 \
            FAE_DISABLE_VALIDATION=1 \
            FAE_TASKPOLICY_BACKGROUND=1 \
            bash "$SCRIPT_DIR/train_mlx_lora_chunked.sh" "$model"

        log "Benchmarking lane=$lane model=$model"
        bash "$SCRIPT_DIR/fuse_and_benchmark_candidate.sh" \
            --base-model "$base_model_id" \
            --adapter-dir "$lane_adapter_dir" \
            --candidate-name "$candidate_name"

        benchmark_json="$(ls -t "$PROJECT_ROOT/scripts/benchmark-results/${candidate_name}_targeted_"*.json | head -n 1)"
        fused_dir="$(ls -td "$PROJECT_ROOT/training/models/${candidate_name}-fused-"* | head -n 1)"
        metrics_json="$(
            python3 - <<'PY' "$benchmark_json"
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())["models"][0]

def score(name: str, key: str):
    rows = data.get(name, [])
    if not rows:
        return {"correct": 0, "total": 0}
    return {"correct": sum(1 for row in rows if row.get(key)), "total": len(rows)}

print(json.dumps({
    "tool_calling": score("tool_calling", "correct"),
    "fae_capability_eval": score("fae_capability_eval", "correct"),
    "assistant_fit_eval": score("assistant_fit_eval", "correct"),
    "serialization_eval": score("serialization_eval", "correct"),
    "no_think_compliance": score("no_think_compliance", "compliant"),
}))
PY
        )"

        RESULTS_JSON="$(
            python3 - <<'PY' "$RESULTS_JSON" "$lane" "$model" "$base_benchmark" "$lane_import_dir" "$lane_data_dir" "$lane_adapter_dir" "$fused_dir" "$benchmark_json" "$metrics_json" "$DELETE_FUSED"
import json
import sys

rows = json.loads(sys.argv[1])
rows.append(
    {
        "lane": sys.argv[2],
        "model": sys.argv[3],
        "base_benchmark": sys.argv[4],
        "imports_dir": sys.argv[5],
        "training_data_dir": sys.argv[6],
        "adapter_dir": sys.argv[7],
        "fused_dir": sys.argv[8],
        "benchmark_json": sys.argv[9],
        "metrics": json.loads(sys.argv[10]),
        "fused_deleted": sys.argv[11] == "1",
    }
)
print(json.dumps(rows))
PY
        )"

        if [[ "$DELETE_FUSED" == "1" && -d "$fused_dir" ]]; then
            rm -rf "$fused_dir"
        fi
    done
done

python3 - <<'PY' "$RESULTS_JSON" "$RESULTS_MANIFEST"
import json
import sys
from pathlib import Path

Path(sys.argv[2]).write_text(json.dumps(json.loads(sys.argv[1]), indent=2) + "\n", encoding="utf-8")
print(f"Wrote results manifest to {sys.argv[2]}")
PY
