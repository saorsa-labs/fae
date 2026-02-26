#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLONE_DIR="$PROJECT_DIR/.spm-clones"
MAX_ATTEMPTS="${SPM_BOOTSTRAP_MAX_ATTEMPTS:-5}"
BASE_DELAY="${SPM_BOOTSTRAP_BASE_DELAY_SECONDS:-2}"

mkdir -p "$CLONE_DIR"

if swift package resolve -help 2>&1 | grep -q -- '--cloned-source-packages-dir'; then
  RESOLVE_CMD=(swift package --package-path "$PROJECT_DIR" resolve --cloned-source-packages-dir "$CLONE_DIR")
else
  RESOLVE_CMD=(swift package --package-path "$PROJECT_DIR" resolve)
fi

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  echo "[spm-bootstrap] resolve attempt $attempt/$MAX_ATTEMPTS"
  if "${RESOLVE_CMD[@]}"; then
    echo "[spm-bootstrap] resolve succeeded"
    exit 0
  fi

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    break
  fi

  delay=$(( BASE_DELAY * (2 ** (attempt - 1)) ))
  echo "[spm-bootstrap] resolve failed; retrying in ${delay}s"
  sleep "$delay"
  attempt=$((attempt + 1))
done

echo "[spm-bootstrap] resolve failed after $MAX_ATTEMPTS attempts" >&2
exit 1
