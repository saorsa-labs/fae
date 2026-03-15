#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "accelerate>=1.7.0",
#   "bitsandbytes>=0.45.0",
#   "datasets>=3.0.0",
#   "huggingface_hub>=0.30.0",
#   "peft>=0.14.0",
#   "torch>=2.6.0",
#   "transformers>=4.54.0",
#   "trl>=0.22.0",
# ]
# ///
"""
Run LoRA ORPO on Hugging Face Jobs against Fae's DPO/ORPO JSONL data.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any


def normalize_content(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts: list[str] = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(part for part in parts if part).strip()
    if isinstance(value, dict):
        text = value.get("text")
        if isinstance(text, str):
            return text
        content = value.get("content")
        if isinstance(content, str):
            return content
        return ""
    return str(value)


def normalize_messages(messages: Any) -> list[dict[str, Any]]:
    if not isinstance(messages, list):
        return []
    normalized: list[dict[str, Any]] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "user")
        content = normalize_content(message.get("content"))
        normalized_message: dict[str, Any] = {"role": role, "content": content}
        name = message.get("name")
        if isinstance(name, str) and name:
            normalized_message["name"] = name
        normalized.append(normalized_message)
    return normalized


def resolve_token(get_token_func) -> str:
    token = os.environ.get("HF_TOKEN", "").strip()
    if token:
        return token
    return (get_token_func() or "").strip()


def model_alias_to_id(alias_or_id: str) -> str:
    aliases = {
        "2b": "Qwen/Qwen3.5-2B",
        "tiny": "Qwen/Qwen3.5-2B",
        "4b": "Qwen/Qwen3.5-4B",
        "small": "Qwen/Qwen3.5-4B",
        "35b-a3b": "Qwen/Qwen3.5-35B-A3B",
        "34b-a3b": "Qwen/Qwen3.5-35B-A3B",
        "medium": "Qwen/Qwen3.5-35B-A3B",
    }
    return aliases.get(alias_or_id.lower(), alias_or_id)


def lora_target_config(model_id: str) -> dict[str, list[str] | None]:
    lowered = model_id.lower()
    if "35b-a3b" in lowered or "34b-a3b" in lowered or "qwen3.5-35b-a3b" in lowered:
        return {
            "target_modules": [
                "q_proj",
                "k_proj",
                "v_proj",
                "o_proj",
                "mlp.shared_expert.gate_proj",
                "mlp.shared_expert.up_proj",
                "mlp.shared_expert.down_proj",
            ],
            "target_parameters": [
                "mlp.experts.gate_up_proj",
                "mlp.experts.down_proj",
            ],
        }
    return {
        "target_modules": [
            "q_proj",
            "k_proj",
            "v_proj",
            "o_proj",
            "gate_proj",
            "up_proj",
            "down_proj",
        ],
        "target_parameters": None,
    }


def load_jsonl_records(path: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                record = json.loads(text)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid JSONL in {path}:{line_number}: {exc}") from exc
            if not isinstance(record, dict):
                continue
            records.append(record)
    return records


def is_qwen35_moe(model_id: str) -> bool:
    lowered = model_id.lower()
    return "35b-a3b" in lowered or "34b-a3b" in lowered or "qwen3.5-35b-a3b" in lowered


def render_prompt(tokenizer, messages: list[dict[str, Any]]) -> str:
    cleaned = normalize_messages(messages)
    try:
        return tokenizer.apply_chat_template(
            cleaned,
            tokenize=False,
            add_generation_prompt=True,
        )
    except Exception:
        parts: list[str] = []
        for message in cleaned:
            parts.append(f"<|{message['role']}|>\n{message['content']}")
        parts.append("<|assistant|>\n")
        return "\n\n".join(parts)


def render_completion(messages: list[dict[str, Any]]) -> str:
    cleaned = normalize_messages(messages)
    if len(cleaned) == 1 and cleaned[0]["role"] == "assistant":
        return cleaned[0]["content"]
    return "\n".join(message["content"] for message in cleaned if message["content"]).strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run LoRA ORPO on HF Jobs.")
    parser.add_argument("--model-id", default="Qwen/Qwen3.5-4B")
    parser.add_argument("--dataset-repo-id", default="saorsa-labs/fae-training-data")
    parser.add_argument("--train-file", default="data/dpo_train.jsonl")
    parser.add_argument("--eval-file", default="data/dpo_val.jsonl")
    parser.add_argument("--output-dir", default="./outputs/orpo")
    parser.add_argument("--output-repo-id", default="")
    parser.add_argument("--public", action="store_true")
    parser.add_argument("--max-steps", type=int, default=25)
    parser.add_argument("--learning-rate", type=float, default=1e-5)
    parser.add_argument("--warmup-ratio", type=float, default=0.03)
    parser.add_argument("--per-device-train-batch-size", type=int, default=1)
    parser.add_argument("--per-device-eval-batch-size", type=int, default=1)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=16)
    parser.add_argument("--max-length", type=int, default=1024)
    parser.add_argument("--max-completion-length", type=int, default=256)
    parser.add_argument("--beta", type=float, default=0.1)
    parser.add_argument("--lora-r", type=int, default=16)
    parser.add_argument("--lora-alpha", type=int, default=32)
    parser.add_argument("--lora-dropout", type=float, default=0.05)
    parser.add_argument("--logging-steps", type=int, default=5)
    parser.add_argument("--eval-steps", type=int, default=10)
    parser.add_argument("--max-train-samples", type=int, default=0)
    parser.add_argument("--max-eval-samples", type=int, default=0)
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    import torch
    from datasets import Dataset
    from huggingface_hub import HfApi, create_repo, get_token, hf_hub_download
    from peft import LoraConfig
    from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
    from trl import ORPOConfig, ORPOTrainer

    token = resolve_token(get_token)
    model_id = model_alias_to_id(args.model_id)
    if is_qwen35_moe(model_id):
        raise ValueError(
            "Qwen/Qwen3.5-35B-A3B is currently SFT-only in the HF Jobs lane. "
            "Do not start ORPO/DPO on the MoE path until the SFT smoke run is clean."
        )
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    train_path = hf_hub_download(
        repo_id=args.dataset_repo_id,
        repo_type="dataset",
        filename=args.train_file,
        token=token or None,
    )
    eval_path = hf_hub_download(
        repo_id=args.dataset_repo_id,
        repo_type="dataset",
        filename=args.eval_file,
        token=token or None,
    )

    tokenizer = AutoTokenizer.from_pretrained(
        model_id,
        token=token or None,
        trust_remote_code=True,
    )
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "right"

    def normalize_row(row: dict[str, Any]) -> dict[str, str]:
        return {
            "prompt": render_prompt(tokenizer, row.get("prompt", [])),
            "chosen": render_completion(row.get("chosen", [])),
            "rejected": render_completion(row.get("rejected", [])),
        }

    raw_train_records = load_jsonl_records(train_path)
    raw_eval_records = load_jsonl_records(eval_path)
    train_dataset = Dataset.from_list([normalize_row(row) for row in raw_train_records])
    eval_dataset = Dataset.from_list([normalize_row(row) for row in raw_eval_records])

    if args.max_train_samples > 0:
        train_dataset = train_dataset.select(range(min(args.max_train_samples, len(train_dataset))))
    if args.max_eval_samples > 0:
        eval_dataset = eval_dataset.select(range(min(args.max_eval_samples, len(eval_dataset))))

    quantization_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,
        bnb_4bit_use_double_quant=True,
    )
    model = AutoModelForCausalLM.from_pretrained(
        model_id,
        token=token or None,
        trust_remote_code=True,
        device_map="auto",
        torch_dtype=torch.bfloat16,
        quantization_config=quantization_config,
        attn_implementation="sdpa",
    )
    model.config.use_cache = False

    target_config = lora_target_config(model_id)
    peft_config = LoraConfig(
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=target_config["target_modules"],
        target_parameters=target_config["target_parameters"],
    )

    trainer = ORPOTrainer(
        model=model,
        args=ORPOConfig(
            output_dir=str(output_dir),
            max_steps=args.max_steps,
            learning_rate=args.learning_rate,
            warmup_ratio=args.warmup_ratio,
            per_device_train_batch_size=args.per_device_train_batch_size,
            per_device_eval_batch_size=args.per_device_eval_batch_size,
            gradient_accumulation_steps=args.gradient_accumulation_steps,
            logging_steps=args.logging_steps,
            eval_strategy="steps",
            eval_steps=args.eval_steps,
            save_strategy="no",
            report_to="none",
            bf16=torch.cuda.is_available(),
            gradient_checkpointing=True,
            remove_unused_columns=False,
            max_length=args.max_length,
            max_completion_length=args.max_completion_length,
            beta=args.beta,
            seed=args.seed,
        ),
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        processing_class=tokenizer,
        peft_config=peft_config,
    )

    train_metrics = trainer.train().metrics
    eval_metrics = trainer.evaluate() if len(eval_dataset) else {}
    trainer.save_model(str(output_dir))
    tokenizer.save_pretrained(str(output_dir))

    summary = {
        "mode": "orpo",
        "model_id": model_id,
        "dataset_repo_id": args.dataset_repo_id,
        "train_file": args.train_file,
        "eval_file": args.eval_file,
        "train_rows": len(train_dataset),
        "eval_rows": len(eval_dataset),
        "train_metrics": train_metrics,
        "eval_metrics": eval_metrics,
        "args": vars(args),
        "lora_target_modules": target_config["target_modules"],
        "lora_target_parameters": target_config["target_parameters"],
    }
    summary_path = output_dir / "training_summary.json"
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
                    "Adapter produced by `scripts/hf_jobs_train_orpo.py`.",
                    "",
                    f"- Base model: `{model_id}`",
                    f"- Dataset repo: `{args.dataset_repo_id}`",
                    f"- Train file: `{args.train_file}`",
                    f"- Eval file: `{args.eval_file}`",
                    f"- Train rows: `{len(train_dataset)}`",
                    f"- Eval rows: `{len(eval_dataset)}`",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        api.upload_folder(
            folder_path=str(output_dir),
            repo_id=args.output_repo_id,
            repo_type="model",
            commit_message="Upload HF Jobs ORPO adapter",
            token=token or None,
        )

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
