#!/usr/bin/env python3
"""Run mlx-tune DPO or ORPO on exported preference JSONL."""

import argparse
import json
import random
import warnings
from pathlib import Path

from mlx_tune import (
    FastLanguageModel,
    DPOTrainer,
    DPOConfig,
    ORPOTrainer,
    ORPOConfig,
)


def read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def parse_target_modules(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def set_train_mode(model: object) -> None:
    actual_model = getattr(model, "model", model)
    train = getattr(actual_model, "train", None)
    if callable(train):
        train()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--method", choices=["dpo", "orpo"], default="orpo")
    parser.add_argument("--model", required=True)
    parser.add_argument("--train-data", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--merged-output-dir", type=Path)
    parser.add_argument("--resume-adapter-dir", type=Path)
    parser.add_argument("--max-seq-length", type=int, default=2048)
    parser.add_argument("--max-steps", type=int, default=20)
    parser.add_argument("--learning-rate", type=float, default=2e-6)
    parser.add_argument("--beta", type=float, default=0.1)
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=1)
    parser.add_argument("--logging-steps", type=int, default=1)
    parser.add_argument("--save-steps", type=int, default=20)
    parser.add_argument("--seed", type=int, default=3407)
    parser.add_argument("--num-layers", type=int)
    parser.add_argument("--lora-r", type=int, default=8)
    parser.add_argument("--lora-alpha", type=int, default=16)
    parser.add_argument(
        "--target-modules",
        default="q_proj,k_proj,v_proj,o_proj",
        help="Comma-separated LoRA target modules",
    )
    args = parser.parse_args()

    dataset = read_jsonl(args.train_data)
    if not dataset:
        raise SystemExit("No preference rows found")
    random.Random(args.seed).shuffle(dataset)

    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=args.model,
        max_seq_length=args.max_seq_length,
    )
    model = FastLanguageModel.get_peft_model(
        model,
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        target_modules=parse_target_modules(args.target_modules),
        use_gradient_checkpointing=True,
    )
    if args.resume_adapter_dir is not None:
        if args.num_layers is not None:
            warnings.warn(
                "--num-layers is ignored when resuming; adapter_config.json "
                "controls the previously applied LoRA layer count.",
                stacklevel=2,
            )
        model.load_adapter(str(args.resume_adapter_dir))
    elif args.num_layers is not None and hasattr(model, "_apply_lora"):
        model._apply_lora(num_layers=args.num_layers)

    common_kwargs = {
        "output_dir": str(args.output_dir),
        "learning_rate": args.learning_rate,
        "per_device_train_batch_size": args.batch_size,
        "gradient_accumulation_steps": args.gradient_accumulation_steps,
        "max_steps": args.max_steps,
        "logging_steps": args.logging_steps,
        "save_steps": args.save_steps,
        "max_seq_length": args.max_seq_length,
    }

    if args.method == "dpo":
        trainer = DPOTrainer(
            model=model,
            train_dataset=dataset,
            tokenizer=tokenizer,
            args=DPOConfig(beta=args.beta, **common_kwargs),
        )
    else:
        trainer = ORPOTrainer(
            model=model,
            train_dataset=dataset,
            tokenizer=tokenizer,
            args=ORPOConfig(beta=args.beta, **common_kwargs),
        )

    set_train_mode(model)
    result = trainer.train()

    if args.merged_output_dir is not None:
        args.merged_output_dir.mkdir(parents=True, exist_ok=True)
        model.save_pretrained_merged(str(args.merged_output_dir), tokenizer)
        result["merged_output_dir"] = str(args.merged_output_dir)

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
