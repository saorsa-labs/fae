#!/bin/bash

fae_hf_cache_root() {
    if [[ -n "${HF_HUB_CACHE:-}" ]]; then
        printf '%s\n' "${HF_HUB_CACHE/#\~/$HOME}"
        return 0
    fi

    if [[ -n "${HF_HOME:-}" ]]; then
        local hf_home="${HF_HOME/#\~/$HOME}"
        printf '%s\n' "$hf_home/hub"
        return 0
    fi

    printf '%s\n' "$HOME/.cache/huggingface/hub"
}

fae_model_legacy_dir() {
    local model="$1"
    if [[ "$model" != *"/"* ]]; then
        return 1
    fi

    local org="${model%%/*}"
    local repo="${model#*/}"
    printf '%s\n' "$HOME/Library/Caches/models/$org/$repo"
}

fae_model_hf_repo_dir() {
    local model="$1"
    if [[ "$model" != *"/"* ]]; then
        return 1
    fi

    local cache_root
    cache_root="$(fae_hf_cache_root)"
    local repo_path="${model/\//--}"
    printf '%s\n' "$cache_root/models--$repo_path"
}

fae_model_hf_snapshot_dir() {
    local model="$1"
    local repo_dir
    repo_dir="$(fae_model_hf_repo_dir "$model")" || return 1

    local ref_file="$repo_dir/refs/main"
    if [[ -f "$ref_file" ]]; then
        local snapshot
        snapshot="$(<"$ref_file")"
        local snapshot_dir="$repo_dir/snapshots/$snapshot"
        if [[ -d "$snapshot_dir" ]]; then
            printf '%s\n' "$snapshot_dir"
            return 0
        fi
    fi

    local snapshots_dir="$repo_dir/snapshots"
    if [[ -d "$snapshots_dir" ]]; then
        local first_snapshot
        first_snapshot="$(find "$snapshots_dir" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)"
        if [[ -n "$first_snapshot" ]]; then
            printf '%s\n' "$first_snapshot"
            return 0
        fi
    fi

    return 1
}

fae_model_has_payload() {
    local directory="$1"
    [[ -d "$directory" ]] || return 1

    local config="$directory/config.json"
    [[ -f "$config" ]] || return 1

    if find "$directory" -maxdepth 1 \( -name '*.safetensors' -o -name '*.gguf' \) | grep -q .; then
        return 0
    fi

    return 1
}

fae_resolve_model_source() {
    local model="$1"

    if [[ -d "$model" ]]; then
        printf '%s\n' "$model"
        return 0
    fi

    if [[ "$model" == *"/"* ]]; then
        local snapshot_dir
        snapshot_dir="$(fae_model_hf_snapshot_dir "$model" 2>/dev/null || true)"
        if [[ -n "$snapshot_dir" ]] && fae_model_has_payload "$snapshot_dir"; then
            printf '%s\n' "$snapshot_dir"
            return 0
        fi

        local legacy_dir
        legacy_dir="$(fae_model_legacy_dir "$model" 2>/dev/null || true)"
        if [[ -n "$legacy_dir" ]] && fae_model_has_payload "$legacy_dir"; then
            printf '%s\n' "$legacy_dir"
            return 0
        fi
    fi

    printf '%s\n' "$model"
}
