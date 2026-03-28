# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-tune>=0.4.11", "datasets>=2.14.0"]
# ///

"""Launch LoRA SFT training via mlx-tune as a detached subprocess.

Uses mlx-tune's Unsloth-compatible API (FastLanguageModel + SFTTrainer)
instead of raw mlx_lm.lora for better learning rate scheduling, gradient
accumulation, and checkpoint management.
"""

import json
import os
import subprocess
import sys
import time

# Model map — uses Qwen3.5 to match Fae's production LLM stack.
MODEL_MAP = {
    "tiny": "mlx-community/Qwen3.5-2B-OptiQ-4bit",
    "small": "mlx-community/Qwen3.5-4B-4bit",
    "medium": "Brooooooklyn/Qwen3.5-9B-unsloth-mlx",
    "large": "mlx-community/Qwen3.5-35B-A3B-4bit",
}

PRESET_MAP = {
    "smoke": {
        "max_steps": 10,
        "batch_size": 1,
        "gradient_accumulation_steps": 1,
        "lr": 1e-4,
        "max_seq_length": 512,
        "lora_r": 8,
        "warmup_steps": 0,
    },
    "light": {
        "max_steps": 50,
        "batch_size": 2,
        "gradient_accumulation_steps": 2,
        "lr": 5e-5,
        "max_seq_length": 1024,
        "lora_r": 16,
        "warmup_steps": 5,
    },
    "standard": {
        "max_steps": 200,
        "batch_size": 4,
        "gradient_accumulation_steps": 4,
        "lr": 2e-5,
        "max_seq_length": 2048,
        "lora_r": 16,
        "warmup_steps": 10,
    },
    "deep": {
        "max_steps": 500,
        "batch_size": 4,
        "gradient_accumulation_steps": 4,
        "lr": 1e-5,
        "max_seq_length": 2048,
        "lora_r": 32,
        "warmup_steps": 20,
    },
}

# Standalone training script that runs as a detached process.
TRAIN_SCRIPT = '''
# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-tune>=0.4.11", "datasets>=2.14.0"]
# ///

"""Detached SFT training process — launched by train.py."""

import json
import sys
import traceback

def main():
    config = json.loads(sys.argv[1])

    from mlx_tune import FastLanguageModel, SFTTrainer, SFTConfig
    from datasets import load_dataset

    model_id = config["model_id"]
    data_dir = config["data_dir"]
    adapter_dir = config["adapter_dir"]
    params = config["params"]

    # Load model with 4-bit quantization.
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=model_id,
        max_seq_length=params["max_seq_length"],
        load_in_4bit=True,
        trust_remote_code=True,
    )

    # Apply LoRA adapters.
    model = FastLanguageModel.get_peft_model(
        model,
        r=params["lora_r"],
        lora_alpha=params["lora_r"],  # alpha = r is standard
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
        lora_dropout=0.05,
    )

    # Load SFT dataset.
    data_files = {"train": f"{data_dir}/train.jsonl"}
    valid_path = f"{data_dir}/valid.jsonl"
    import os
    if os.path.exists(valid_path):
        data_files["validation"] = valid_path

    dataset = load_dataset("json", data_files=data_files)

    # Configure training.
    sft_config = SFTConfig(
        output_dir=adapter_dir,
        per_device_train_batch_size=params["batch_size"],
        gradient_accumulation_steps=params["gradient_accumulation_steps"],
        learning_rate=params["lr"],
        lr_scheduler_type="cosine",
        warmup_steps=params["warmup_steps"],
        max_steps=params["max_steps"],
        max_seq_length=params["max_seq_length"],
        logging_steps=max(1, params["max_steps"] // 20),
        save_steps=max(10, params["max_steps"] // 5),
        save_total_limit=2,
        weight_decay=0.01,
    )

    # Train.
    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=dataset["train"],
        eval_dataset=dataset.get("validation"),
        args=sft_config,
    )

    result = trainer.train()

    # Save final adapter.
    model.save_pretrained(adapter_dir)

    # Write training metrics for evaluate.py.
    metrics = {
        "final_loss": getattr(result, "training_loss", None),
        "total_steps": params["max_steps"],
        "model_id": model_id,
        "lora_r": params["lora_r"],
        "max_seq_length": params["max_seq_length"],
    }
    with open(os.path.join(adapter_dir, "train_metrics.json"), "w") as f:
        json.dump(metrics, f, indent=2)

if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)
'''


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}

    target = params.get("target_model_preset", "auto")
    preset = params.get("training_preset", "light")
    max_iters = params.get("max_iterations", None)
    mode = params.get("mode", "sft")  # "sft" or "dpo"

    if mode == "dpo":
        # Delegate to train_dpo.py for DPO training.
        print(json.dumps({
            "error": "Use train_dpo script for DPO training.",
            "hint": "run_skill training-orchestrator train_dpo",
        }))
        return

    if target == "auto":
        ram_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip())
        ram_gb = ram_bytes // (1024**3)
        if ram_gb >= 48:
            target = "large"
        elif ram_gb >= 32:
            target = "medium"
        elif ram_gb >= 16:
            target = "small"
        else:
            target = "tiny"

    model_id = MODEL_MAP.get(target, MODEL_MAP["tiny"])
    train_params = dict(PRESET_MAP.get(preset, PRESET_MAP["light"]))

    if max_iters:
        train_params["max_steps"] = int(max_iters)

    data_dir = os.path.expanduser("~/Library/Application Support/fae/training/data")
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    adapter_dir = os.path.expanduser(f"~/Library/Application Support/fae/models/personal/{timestamp}")
    run_dir = os.path.expanduser("~/Library/Application Support/fae/training")
    log_path = os.path.join(run_dir, "train.log")

    os.makedirs(adapter_dir, exist_ok=True)
    os.makedirs(run_dir, exist_ok=True)

    train_file = os.path.join(data_dir, "train.jsonl")
    if not os.path.exists(train_file):
        print(json.dumps({"error": "No training data found. Run export_data first.", "path": train_file}))
        return

    # Write the detached training script to a temp file.
    script_path = os.path.join(run_dir, "_train_worker.py")
    with open(script_path, "w") as f:
        f.write(TRAIN_SCRIPT)

    # Build config for the worker.
    worker_config = json.dumps({
        "model_id": model_id,
        "data_dir": data_dir,
        "adapter_dir": adapter_dir,
        "params": train_params,
    })

    # Launch as detached uv process.
    cmd = [sys.executable, script_path, worker_config]

    with open(log_path, "w") as log_file:
        process = subprocess.Popen(
            cmd,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    run_info = {
        "pid": process.pid,
        "adapter_path": adapter_dir,
        "model_id": model_id,
        "preset": preset,
        "mode": "sft",
        "params": train_params,
        "started_at": timestamp,
        "log_path": log_path,
        "engine": "mlx-tune",
    }
    with open(os.path.join(run_dir, "run.json"), "w") as f:
        json.dump(run_info, f, indent=2)

    print(json.dumps({
        "status": "started",
        "pid": process.pid,
        "adapter_path": adapter_dir,
        "model_id": model_id,
        "preset": preset,
        "mode": "sft",
        "engine": "mlx-tune",
        "log_path": log_path,
    }))


if __name__ == "__main__":
    main()
