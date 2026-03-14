#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/model_cache.sh"

usage() {
    cat <<'EOF'
Usage:
  bash scripts/cleanup_legacy_model_caches.sh [--apply] [model-id ...]

Removes duplicate legacy model directories under ~/Library/Caches/models when
the same model is already present in the shared Hugging Face cache.

Default is dry-run. Pass --apply to actually delete the legacy duplicate.
EOF
}

APPLY=0
MODELS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)
            APPLY=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            MODELS+=("$1")
            shift
            ;;
    esac
done

legacy_listing() {
    local directory="$1"
    find -H "$directory" -maxdepth 1 \( -type f -o -type l \) -print \
        | sed 's#.*/##' \
        | sort
}

file_hash_if_present() {
    local path="$1"
    if [[ -f "$path" || -L "$path" ]]; then
        shasum "$path" | awk '{print $1}'
    fi
}

size_kb() {
    du -sk "$1" | awk '{print $1}'
}

default_models() {
    find "$HOME/Library/Caches/models" -mindepth 2 -maxdepth 2 -type d \
        | sed "s#^$HOME/Library/Caches/models/##" \
        | sort
}

if [[ "${#MODELS[@]}" -eq 0 ]]; then
    while IFS= read -r model; do
        MODELS+=("$model")
    done < <(default_models)
fi

total_removed_kb=0
removed_count=0

for model in "${MODELS[@]}"; do
    if [[ "$model" != *"/"* ]]; then
        echo "SKIP $model: expected model ID like org/repo"
        continue
    fi

    legacy_dir="$(fae_model_legacy_dir "$model" || true)"
    hf_dir="$(fae_model_hf_snapshot_dir "$model" || true)"

    if [[ -z "$legacy_dir" || -z "$hf_dir" ]]; then
        echo "SKIP $model: missing legacy or HF cache directory"
        continue
    fi

    if ! fae_model_has_payload "$legacy_dir"; then
        echo "SKIP $model: legacy cache has no model payload"
        continue
    fi

    if ! fae_model_has_payload "$hf_dir"; then
        echo "SKIP $model: HF cache has no model payload"
        continue
    fi

    legacy_config_hash="$(file_hash_if_present "$legacy_dir/config.json")"
    hf_config_hash="$(file_hash_if_present "$hf_dir/config.json")"
    legacy_index_hash="$(file_hash_if_present "$legacy_dir/model.safetensors.index.json")"
    hf_index_hash="$(file_hash_if_present "$hf_dir/model.safetensors.index.json")"
    legacy_files="$(legacy_listing "$legacy_dir")"
    hf_files="$(legacy_listing "$hf_dir")"

    if [[ "$legacy_config_hash" != "$hf_config_hash" ]]; then
        echo "SKIP $model: config hash mismatch"
        continue
    fi

    if [[ -n "$legacy_index_hash" || -n "$hf_index_hash" ]]; then
        if [[ "$legacy_index_hash" != "$hf_index_hash" ]]; then
            echo "SKIP $model: weight index hash mismatch"
            continue
        fi
    fi

    if [[ "$legacy_files" != "$hf_files" ]]; then
        echo "SKIP $model: file manifest mismatch"
        continue
    fi

    legacy_kb="$(size_kb "$legacy_dir")"
    if [[ "$APPLY" -eq 1 ]]; then
        rm -rf "$legacy_dir"
        removed_count=$((removed_count + 1))
        total_removed_kb=$((total_removed_kb + legacy_kb))
        echo "REMOVED $model: reclaimed $((legacy_kb / 1024)) MiB from $legacy_dir"
    else
        echo "WOULD REMOVE $model: $((legacy_kb / 1024)) MiB at $legacy_dir"
    fi
done

if [[ "$APPLY" -eq 1 ]]; then
    echo "Removed $removed_count duplicate legacy cache(s), reclaimed approximately $((total_removed_kb / 1024)) MiB."
else
    echo "Dry run only. Re-run with --apply to delete verified duplicates."
fi
