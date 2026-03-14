#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="${FAE_PARO_RESULTS_DIR:-$PROJECT_ROOT/scripts/benchmark-results}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
SUMMARY_PATH="$RESULTS_DIR/paro-qwen35-baseline-matrix_${STAMP}.json"

# Default to the Fae-relevant tiers. Add 0.8 with FAE_PARO_INCLUDE_08B=1 if desired.
SIZES=(2b 4b 9b 27b)
if [[ "${FAE_PARO_INCLUDE_08B:-0}" == "1" ]]; then
    SIZES=(0.8b "${SIZES[@]}")
fi
if [[ -n "${FAE_PARO_SIZES:-}" ]]; then
    IFS=',' read -r -a SIZES <<<"${FAE_PARO_SIZES}"
fi

standard_model_for() {
    case "$1" in
        0.8b) echo "mlx-community/Qwen3.5-0.8B-4bit" ;;
        2b) echo "mlx-community/Qwen3.5-2B-4bit" ;;
        4b) echo "mlx-community/Qwen3.5-4B-4bit" ;;
        9b) echo "mlx-community/Qwen3.5-9B-4bit" ;;
        27b) echo "mlx-community/Qwen3.5-27B-4bit" ;;
        *) echo "Unsupported size: $1" >&2; exit 1 ;;
    esac
}

paro_model_for() {
    case "$1" in
        0.8b) echo "z-lab/Qwen3.5-0.8B-PARO" ;;
        2b) echo "z-lab/Qwen3.5-2B-PARO" ;;
        4b) echo "z-lab/Qwen3.5-4B-PARO" ;;
        9b) echo "z-lab/Qwen3.5-9B-PARO" ;;
        27b) echo "z-lab/Qwen3.5-27B-PARO" ;;
        *) echo "Unsupported size: $1" >&2; exit 1 ;;
    esac
}

cd "$PROJECT_ROOT"
mkdir -p "$RESULTS_DIR"

tmp_summary="$(mktemp)"
printf '{\n  "date": "%s",\n  "runs": [\n' "$(date -Iseconds)" >"$tmp_summary"
first=1

for size in "${SIZES[@]}"; do
    std_model="$(standard_model_for "$size")"
    paro_model="$(paro_model_for "$size")"
    std_label="qwen35_${size}_standard"
    paro_label="qwen35_${size}_paro"

    echo "==> [$size] text/serialization/no-think comparison"
    text_json="$(bash "$PROJECT_ROOT/scripts/run_qwen9b_quantization_ab.sh" \
        --standard-model "$std_model" \
        --standard-label "$std_label" \
        --paro-model "$paro_model" \
        --paro-label "$paro_label")"

    echo "==> [$size] tool-calling comparison"
    tool_json="$(python3 "$PROJECT_ROOT/scripts/benchmark_qwen9b_toolcalling_servers.py" \
        --standard-model "$std_model" \
        --standard-label "${std_label}_server" \
        --paro-model "$paro_model" \
        --paro-label "${paro_label}_server")"

    if [[ $first -eq 0 ]]; then
        printf ',\n' >>"$tmp_summary"
    fi
    first=0

    python3 - <<PY >>"$tmp_summary"
import json
from pathlib import Path
size = ${size@Q}
text_path = Path(${text_json@Q}.strip())
tool_path = Path(${tool_json@Q}.strip())
text = json.loads(text_path.read_text())
tool = json.loads(tool_path.read_text())
print(json.dumps({
    "size": size,
    "text_result": str(text_path),
    "tool_result": str(tool_path),
    "text_comparison": text["comparison"],
    "tool_scores": {
        k: v for k, v in tool.items()
        if k not in {"date", "reference_corpus", "models"}
    }
}, indent=2), end="")
PY
done

printf '\n  ]\n}\n' >>"$tmp_summary"
mv "$tmp_summary" "$SUMMARY_PATH"
echo "$SUMMARY_PATH"
