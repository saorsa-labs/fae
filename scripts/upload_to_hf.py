#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["huggingface_hub>=0.20.0"]
# ///
"""
Upload Fae companion model artifacts to HuggingFace.

Uploads:
  - Model weights, tokenizer, and config → saorsa-labs/saorsa1-tiny-pre-release
  - Training data JSONL files           → saorsa-labs/fae-training-data (dataset repo)

Usage:
  HF_TOKEN=your_token python3 scripts/upload_to_hf.py \\
      --model-path models/sft-merged/ \\
      --repo-id saorsa-labs/saorsa1-tiny-pre-release

  # Upload as public:
  HF_TOKEN=your_token python3 scripts/upload_to_hf.py \\
      --model-path models/sft-merged/ \\
      --public

  # Skip training data upload:
  HF_TOKEN=your_token python3 scripts/upload_to_hf.py \\
      --model-path models/sft-merged/ \\
      --no-upload-data

Reads HF_TOKEN from environment. Never pass the token as a command-line argument.
"""

import argparse
import os
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Upload Fae companion model to HuggingFace."
    )
    parser.add_argument(
        "--model-path",
        type=Path,
        required=True,
        help="Local path to the merged model directory (output of mlx_lm.fuse).",
    )
    parser.add_argument(
        "--repo-id",
        default="saorsa-labs/saorsa1-tiny-pre-release",
        help="HuggingFace model repo ID (default: saorsa-labs/saorsa1-tiny-pre-release).",
    )
    parser.add_argument(
        "--dataset-repo-id",
        default="saorsa-labs/fae-training-data",
        help="HuggingFace dataset repo ID for training data (default: saorsa-labs/fae-training-data).",
    )
    parser.add_argument(
        "--training-data-dir",
        type=Path,
        default=None,
        help="Directory containing dpo.jsonl and sft.jsonl. Defaults to <project-root>/training_data/.",
    )
    parser.add_argument(
        "--public",
        action="store_true",
        help="Make repos public (default: private).",
    )
    parser.add_argument(
        "--no-upload-data",
        action="store_true",
        help="Skip uploading training data to dataset repo.",
    )
    parser.add_argument(
        "--commit-message",
        default="Upload saorsa1-tiny-pre-release (MLX LoRA SFT fine-tune)",
        help="Commit message for the model upload.",
    )
    args = parser.parse_args()

    # ------------------------------------------------------------------
    # Import huggingface_hub (deferred so the script gives a helpful error
    # if the package is missing, rather than a bare ImportError at the top)
    # ------------------------------------------------------------------
    try:
        from huggingface_hub import HfApi, create_repo
    except ImportError:
        print(
            "ERROR: huggingface_hub is not installed.\n"
            "  Install with: pip install huggingface_hub",
            file=sys.stderr,
        )
        return 1

    # ------------------------------------------------------------------
    # Read HF_TOKEN
    # ------------------------------------------------------------------
    hf_token = os.environ.get("HF_TOKEN", "").strip()
    if not hf_token:
        print(
            "ERROR: HF_TOKEN environment variable is not set.\n"
            "  Set it before running: export HF_TOKEN=your_token",
            file=sys.stderr,
        )
        return 1

    # ------------------------------------------------------------------
    # Validate model path
    # ------------------------------------------------------------------
    model_path = args.model_path.resolve()
    if not model_path.exists():
        print(f"ERROR: Model path does not exist: {model_path}", file=sys.stderr)
        print("  Run scripts/train_mlx_lora.sh first to produce the merged model.", file=sys.stderr)
        return 1

    if not model_path.is_dir():
        print(f"ERROR: Model path is not a directory: {model_path}", file=sys.stderr)
        return 1

    # Check that the directory has some model files
    model_files = list(model_path.iterdir())
    if not model_files:
        print(f"ERROR: Model directory is empty: {model_path}", file=sys.stderr)
        return 1

    print(f"Model path: {model_path}")
    print(f"Model files: {[f.name for f in model_files]}")
    print()

    # ------------------------------------------------------------------
    # Resolve training data directory
    # ------------------------------------------------------------------
    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent
    training_data_dir = (args.training_data_dir or (project_root / "training" / "data")).resolve()

    # ------------------------------------------------------------------
    # Initialize HF API
    # ------------------------------------------------------------------
    api = HfApi(token=hf_token)
    private = not args.public
    repo_visibility = "private" if private else "public"

    print(f"HuggingFace org/user: {args.repo_id.split('/')[0]}")
    print(f"Visibility:           {repo_visibility}")
    print()

    # ------------------------------------------------------------------
    # Create or verify model repo
    # ------------------------------------------------------------------
    print(f"=== Model repo: {args.repo_id} ===")
    try:
        repo_url = create_repo(
            repo_id=args.repo_id,
            repo_type="model",
            private=private,
            exist_ok=True,
            token=hf_token,
        )
        print(f"Repo ready: {repo_url}")
    except Exception as e:
        print(f"ERROR creating model repo: {e}", file=sys.stderr)
        return 1

    # ------------------------------------------------------------------
    # Upload model card README if it exists in the project
    # ------------------------------------------------------------------
    # Derive the model card path from the repo ID (e.g. saorsa-labs/saorsa1-worker-pre-release → saorsa1-worker-pre-release)
    model_name = args.repo_id.split("/")[-1]
    model_card_path = project_root / "training" / "models" / model_name / "README.md"
    if model_card_path.exists():
        print(f"Uploading model card from: {model_card_path}")
        try:
            api.upload_file(
                path_or_fileobj=str(model_card_path),
                path_in_repo="README.md",
                repo_id=args.repo_id,
                repo_type="model",
                commit_message="Add model card",
                token=hf_token,
            )
            print("Model card uploaded.")
        except Exception as e:
            print(f"WARNING: Could not upload model card: {e}")
    else:
        print(f"Note: No model card found at {model_card_path} — skipping")

    print()

    # ------------------------------------------------------------------
    # Upload model folder (weights, tokenizer, config)
    # ------------------------------------------------------------------
    print(f"Uploading model folder: {model_path}")
    print("This may take several minutes depending on model size and connection speed...")
    print()

    try:
        api.upload_folder(
            folder_path=str(model_path),
            repo_id=args.repo_id,
            repo_type="model",
            commit_message=args.commit_message,
            token=hf_token,
        )
        print("Model upload complete.")
    except Exception as e:
        print(f"ERROR uploading model folder: {e}", file=sys.stderr)
        return 1

    model_url = f"https://huggingface.co/{args.repo_id}"
    print(f"Model repo URL: {model_url}")
    print()

    # ------------------------------------------------------------------
    # Upload training data (optional)
    # ------------------------------------------------------------------
    if not args.no_upload_data:
        print(f"=== Dataset repo: {args.dataset_repo_id} ===")

        jsonl_files = list(training_data_dir.glob("*.jsonl"))
        if not jsonl_files:
            print(f"Note: No JSONL files found in {training_data_dir}")
            print("  Run scripts/prepare_training_data.py first to generate training data.")
        else:
            try:
                dataset_url = create_repo(
                    repo_id=args.dataset_repo_id,
                    repo_type="dataset",
                    private=private,
                    exist_ok=True,
                    token=hf_token,
                )
                print(f"Dataset repo ready: {dataset_url}")
            except Exception as e:
                print(f"WARNING: Could not create dataset repo: {e}")
                print("  Skipping training data upload.")
                jsonl_files = []

            for jsonl_path in sorted(jsonl_files):
                print(f"Uploading {jsonl_path.name}...")
                try:
                    api.upload_file(
                        path_or_fileobj=str(jsonl_path),
                        path_in_repo=f"data/{jsonl_path.name}",
                        repo_id=args.dataset_repo_id,
                        repo_type="dataset",
                        commit_message=f"Add {jsonl_path.name}",
                        token=hf_token,
                    )
                    print(f"  Uploaded: {jsonl_path.name}")
                except Exception as e:
                    print(f"  WARNING: Could not upload {jsonl_path.name}: {e}")

            if jsonl_files:
                dataset_url_str = f"https://huggingface.co/datasets/{args.dataset_repo_id}"
                print(f"Dataset repo URL: {dataset_url_str}")

        print()

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    print("=== Upload complete ===")
    print(f"Model:   https://huggingface.co/{args.repo_id}")
    if not args.no_upload_data:
        print(f"Dataset: https://huggingface.co/datasets/{args.dataset_repo_id}")
    print()
    print("To use this model in Fae, add to ~/Library/Application Support/fae/config.toml:")
    print("  [llm]")
    print(f'  voiceModelPreset = "custom"')
    print(f'  customModelPath = "{args.repo_id}"')

    return 0


if __name__ == "__main__":
    sys.exit(main())
