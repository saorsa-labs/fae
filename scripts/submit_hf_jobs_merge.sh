#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ADAPTER_REPO_ID="${FAE_HFJ_MERGE_ADAPTER_REPO_ID:-}"
BASE_MODEL_ID="${FAE_HFJ_MERGE_BASE_MODEL_ID:-}"
NAMESPACE="${FAE_HFJ_NAMESPACE:-saorsa-labs}"
PUBLIC_REPO="${FAE_HFJ_MERGE_PUBLIC:-0}"
DETACH="${FAE_HFJ_MERGE_DETACH:-1}"
RUN_SUFFIX="${FAE_HFJ_MERGE_RUN_SUFFIX:-$(date '+%Y%m%d-%H%M%S')}"

if [[ -z "$ADAPTER_REPO_ID" ]]; then
    echo "ERROR: FAE_HFJ_MERGE_ADAPTER_REPO_ID is required" >&2
    exit 1
fi

if [[ -n "${HF_TOKEN:-}" ]]; then
    HF_AUTH_OK=1
elif command -v hf >/dev/null 2>&1 && hf auth whoami >/dev/null 2>&1; then
    HF_AUTH_OK=1
else
    HF_AUTH_OK=0
fi

if [[ "$HF_AUTH_OK" -ne 1 ]]; then
    echo "ERROR: no Hugging Face auth detected." >&2
    echo "Run 'hf auth login' first, or set HF_TOKEN as an override." >&2
    exit 1
fi

lowered_repo="$(printf '%s' "$ADAPTER_REPO_ID" | tr '[:upper:]' '[:lower:]')"
if [[ -n "$BASE_MODEL_ID" ]]; then
    lowered_base="$(printf '%s' "$BASE_MODEL_ID" | tr '[:upper:]' '[:lower:]')"
else
    lowered_base="$lowered_repo"
fi

if [[ "$lowered_base" == *"35b-a3b"* || "$lowered_base" == *"34b-a3b"* ]]; then
    DEFAULT_FLAVOR="a100-large"
    DEFAULT_TIMEOUT="8h"
elif [[ "$lowered_base" == *"4b"* ]]; then
    DEFAULT_FLAVOR="a10g-large"
    DEFAULT_TIMEOUT="2h"
else
    DEFAULT_FLAVOR="a10g-small"
    DEFAULT_TIMEOUT="2h"
fi

FLAVOR="${FAE_HFJ_MERGE_FLAVOR:-$DEFAULT_FLAVOR}"
TIMEOUT="${FAE_HFJ_MERGE_TIMEOUT:-$DEFAULT_TIMEOUT}"
DTYPE="${FAE_HFJ_MERGE_DTYPE:-float16}"
MAX_SHARD_SIZE="${FAE_HFJ_MERGE_MAX_SHARD_SIZE:-5GB}"
OUTPUT_REPO_ID="${FAE_HFJ_MERGE_OUTPUT_REPO_ID:-${ADAPTER_REPO_ID}-merged-${RUN_SUFFIX}}"

HF_JOB_CMD=(
    hf jobs uv run
    --flavor "$FLAVOR"
    --timeout "$TIMEOUT"
    --namespace "$NAMESPACE"
    --secrets HF_TOKEN
)

if [[ "$DETACH" == "1" ]]; then
    HF_JOB_CMD+=(--detach)
fi

HF_JOB_CMD+=(
    "$SCRIPT_DIR/hf_jobs_merge_peft_adapter.py"
    --adapter-repo-id "$ADAPTER_REPO_ID"
    --output-repo-id "$OUTPUT_REPO_ID"
    --dtype "$DTYPE"
    --max-shard-size "$MAX_SHARD_SIZE"
)

if [[ -n "$BASE_MODEL_ID" ]]; then
    HF_JOB_CMD+=(--base-model-id "$BASE_MODEL_ID")
fi

if [[ "$PUBLIC_REPO" == "1" ]]; then
    HF_JOB_CMD+=(--public)
fi

echo "[hf-jobs] Submitting merge job"
echo "  adapter repo:    $ADAPTER_REPO_ID"
echo "  base model:      ${BASE_MODEL_ID:-<from adapter config>}"
echo "  flavor:          $FLAVOR"
echo "  timeout:         $TIMEOUT"
echo "  output repo:     $OUTPUT_REPO_ID"
echo "  dtype:           $DTYPE"
echo "  max shard size:  $MAX_SHARD_SIZE"
echo

"${HF_JOB_CMD[@]}"
