#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CORPUS="${FAE_QUANT_CORPUS:-$PROJECT_ROOT/scripts/benchmark-results/qwen3.5-9b_20260313-172928.json}"
OUT_DIR="${FAE_QUANT_OUT_DIR:-$PROJECT_ROOT/scripts/benchmark-results}"
THROUGHPUT_CONTEXTS="${FAE_QUANT_THROUGHPUT_CONTEXTS:-short,1k,8.5k}"

cd "$PROJECT_ROOT"

uv run --python 3.12 \
  --with mlx-lm \
  --with 'paroquant[mlx]' \
  python "$PROJECT_ROOT/scripts/benchmark_qwen9b_quantizations.py" \
  --corpus "$CORPUS" \
  --output-dir "$OUT_DIR" \
  --throughput-contexts "$THROUGHPUT_CONTEXTS" \
  "$@"
