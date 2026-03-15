#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["huggingface_hub>=0.30.0"]
# ///
"""
Upload canonical Fae training JSONL files to a Hugging Face dataset repo.

Usage:
  hf auth login
  python3 scripts/upload_training_data_to_hf.py

  python3 scripts/upload_training_data_to_hf.py \
      --dataset-repo-id saorsa-labs/fae-training-data \
      --training-data-dir training/data

  HF_TOKEN=... python3 scripts/upload_training_data_to_hf.py

Auth priority:
  1. `HF_TOKEN` environment override
  2. Existing `hf auth login` / huggingface_hub cached login
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


CANONICAL_JSONL_FILES = (
    "sft_train.jsonl",
    "sft_val.jsonl",
    "dpo_train.jsonl",
    "dpo_val.jsonl",
)


def resolve_token(get_token_func) -> str:
    token = os.environ.get("HF_TOKEN", "").strip()
    if token:
        return token
    return (get_token_func() or "").strip()


def count_lines(path: Path) -> int:
    with path.open("r", encoding="utf-8") as handle:
        return sum(1 for _ in handle)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Upload Fae training data JSONL files to a Hugging Face dataset repo."
    )
    parser.add_argument(
        "--dataset-repo-id",
        default="saorsa-labs/fae-training-data",
        help="Hugging Face dataset repo ID (default: saorsa-labs/fae-training-data).",
    )
    parser.add_argument(
        "--training-data-dir",
        type=Path,
        default=None,
        help="Directory containing canonical JSONL files. Defaults to <project-root>/training/data.",
    )
    parser.add_argument(
        "--public",
        action="store_true",
        help="Make the dataset repo public. Default is private.",
    )
    parser.add_argument(
        "--commit-message",
        default="Update Fae training data",
        help="Commit message for the dataset upload.",
    )
    args = parser.parse_args()

    try:
        from huggingface_hub import HfApi, create_repo, get_token
    except ImportError:
        print(
            "ERROR: huggingface_hub is not installed.\n"
            "  Install with: pip install huggingface_hub",
            file=sys.stderr,
        )
        return 1

    hf_token = resolve_token(get_token)
    if not hf_token:
        print(
            "ERROR: no Hugging Face auth available.\n"
            "  Run `hf auth login` first, or set HF_TOKEN as an override.",
            file=sys.stderr,
        )
        return 1

    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent
    training_data_dir = (args.training_data_dir or (project_root / "training" / "data")).resolve()
    if not training_data_dir.exists():
        print(f"ERROR: training data directory does not exist: {training_data_dir}", file=sys.stderr)
        return 1

    jsonl_paths: list[Path] = []
    missing: list[str] = []
    for name in CANONICAL_JSONL_FILES:
        path = training_data_dir / name
        if path.exists() and path.is_file():
            jsonl_paths.append(path)
        else:
            missing.append(name)
    if missing:
        print(
            "ERROR: missing canonical training files:\n  - " + "\n  - ".join(missing),
            file=sys.stderr,
        )
        print(
            "  Run `python3 scripts/prepare_training_data.py --split` first.",
            file=sys.stderr,
        )
        return 1

    api = HfApi(token=hf_token)
    create_repo(
        repo_id=args.dataset_repo_id,
        repo_type="dataset",
        private=not args.public,
        exist_ok=True,
        token=hf_token,
    )

    manifest = {
        "dataset_repo_id": args.dataset_repo_id,
        "files": {
            path.name: {
                "line_count": count_lines(path),
                "size_bytes": path.stat().st_size,
            }
            for path in jsonl_paths
        },
    }

    manifest_path = training_data_dir / "hf_dataset_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    try:
        for path in jsonl_paths:
            api.upload_file(
                path_or_fileobj=str(path),
                path_in_repo=f"data/{path.name}",
                repo_id=args.dataset_repo_id,
                repo_type="dataset",
                commit_message=args.commit_message,
                token=hf_token,
            )
        api.upload_file(
            path_or_fileobj=str(manifest_path),
            path_in_repo="data/hf_dataset_manifest.json",
            repo_id=args.dataset_repo_id,
            repo_type="dataset",
            commit_message=args.commit_message,
            token=hf_token,
        )
    finally:
        try:
            manifest_path.unlink()
        except OSError:
            pass

    print(f"Dataset repo ready: https://huggingface.co/datasets/{args.dataset_repo_id}")
    for path in jsonl_paths:
        print(f"Uploaded: data/{path.name} ({count_lines(path)} rows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
