#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "accelerate>=1.7.0",
#   "huggingface_hub>=0.30.0",
#   "peft>=0.14.0",
#   "torch>=2.6.0",
#   "transformers>=4.54.0",
# ]
# ///
"""
Merge a Hugging Face PEFT adapter back into its upstream base model on HF Jobs.

Preferred large-model promotion path:
  1. Train a PEFT adapter on HF Jobs
  2. Merge it into the upstream HF model on HF Jobs
  3. Convert the merged HF model to MLX locally
  4. Benchmark it with the standard Fae local gate
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def resolve_token(get_token_func) -> str:
    token = os.environ.get("HF_TOKEN", "").strip()
    if token:
        return token
    return (get_token_func() or "").strip()


def is_qwen35_moe(model_id: str) -> bool:
    lowered = model_id.lower()
    return "35b-a3b" in lowered or "34b-a3b" in lowered or "qwen3.5-35b-a3b" in lowered


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Merge a PEFT adapter into its HF base model.")
    parser.add_argument("--adapter-repo-id", required=True)
    parser.add_argument("--base-model-id", default="")
    parser.add_argument("--output-dir", default="./outputs/merged")
    parser.add_argument("--output-repo-id", default="")
    parser.add_argument("--public", action="store_true")
    parser.add_argument(
        "--dtype",
        choices=("float16", "bfloat16", "float32"),
        default="float16",
        help="Model load and save dtype for the merged model.",
    )
    parser.add_argument(
        "--max-shard-size",
        default="5GB",
        help="Shard size used when saving the merged model.",
    )
    parser.add_argument(
        "--trust-remote-code",
        action="store_true",
        default=True,
        help="Trust remote model code when loading upstream Qwen models.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    import torch
    from huggingface_hub import HfApi, create_repo, get_token
    from peft import PeftConfig, PeftModel
    from transformers import AutoModelForCausalLM, AutoModelForImageTextToText, AutoTokenizer

    dtype_map = {
        "float16": torch.float16,
        "bfloat16": torch.bfloat16,
        "float32": torch.float32,
    }

    token = resolve_token(get_token)
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    if args.base_model_id:
        base_model_id = args.base_model_id
    else:
        peft_config = PeftConfig.from_pretrained(args.adapter_repo_id, token=token or None)
        base_model_id = peft_config.base_model_name_or_path

    model_loader = AutoModelForImageTextToText if is_qwen35_moe(base_model_id) else AutoModelForCausalLM
    model = model_loader.from_pretrained(
        base_model_id,
        token=token or None,
        trust_remote_code=args.trust_remote_code,
        device_map="auto",
        low_cpu_mem_usage=True,
        torch_dtype=dtype_map[args.dtype],
        attn_implementation="sdpa",
    )

    tokenizer_source = args.adapter_repo_id
    try:
        tokenizer = AutoTokenizer.from_pretrained(
            tokenizer_source,
            token=token or None,
            trust_remote_code=args.trust_remote_code,
        )
    except Exception:
        tokenizer_source = base_model_id
        tokenizer = AutoTokenizer.from_pretrained(
            tokenizer_source,
            token=token or None,
            trust_remote_code=args.trust_remote_code,
        )

    peft_model = PeftModel.from_pretrained(
        model,
        args.adapter_repo_id,
        token=token or None,
        is_trainable=False,
    )
    merged_model = peft_model.merge_and_unload(progressbar=True)

    merged_model.save_pretrained(
        str(output_dir),
        safe_serialization=True,
        max_shard_size=args.max_shard_size,
    )
    tokenizer.save_pretrained(str(output_dir))

    summary = {
        "mode": "merge",
        "adapter_repo_id": args.adapter_repo_id,
        "base_model_id": base_model_id,
        "tokenizer_source": tokenizer_source,
        "dtype": args.dtype,
        "max_shard_size": args.max_shard_size,
        "model_loader": model_loader.__name__,
    }
    summary_path = output_dir / "merge_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.output_repo_id:
        api = HfApi(token=token or None)
        create_repo(
            repo_id=args.output_repo_id,
            repo_type="model",
            private=not args.public,
            exist_ok=True,
            token=token or None,
        )
        readme_path = output_dir / "README.md"
        readme_path.write_text(
            "\n".join(
                [
                    f"# {args.output_repo_id.split('/')[-1]}",
                    "",
                    "Merged model produced by `scripts/hf_jobs_merge_peft_adapter.py`.",
                    "",
                    f"- Base model: `{base_model_id}`",
                    f"- Adapter repo: `{args.adapter_repo_id}`",
                    f"- Dtype: `{args.dtype}`",
                    f"- Max shard size: `{args.max_shard_size}`",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        api.upload_folder(
            folder_path=str(output_dir),
            repo_id=args.output_repo_id,
            repo_type="model",
            commit_message="Upload merged HF model",
            token=token or None,
        )

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
