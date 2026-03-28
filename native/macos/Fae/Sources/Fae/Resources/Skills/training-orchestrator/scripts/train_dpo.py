# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-tune>=0.4.11", "datasets>=2.14.0"]
# ///

"""Launch DPO preference training via mlx-tune as a detached subprocess.

Uses correction pairs extracted by training-data-bridge/extract_corrections.py
to train the model to prefer corrected responses over rejected ones.
"""

import json
import os
import subprocess
import sys
import time

# Same model map as train.py — Qwen3.5 to match Fae's production stack.
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
        "lr": 5e-7,
        "beta": 0.1,
        "max_seq_length": 1024,
        "lora_r": 8,
    },
    "light": {
        "max_steps": 30,
        "batch_size": 1,
        "gradient_accumulation_steps": 2,
        "lr": 5e-7,
        "beta": 0.1,
        "max_seq_length": 1024,
        "lora_r": 16,
    },
    "standard": {
        "max_steps": 100,
        "batch_size": 2,
        "gradient_accumulation_steps": 4,
        "lr": 2e-7,
        "beta": 0.1,
        "max_seq_length": 2048,
        "lora_r": 16,
    },
}

# Standalone DPO training script.
DPO_TRAIN_SCRIPT = '''
# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-tune>=0.4.11", "datasets>=2.14.0"]
# ///

"""Detached DPO training process — launched by train_dpo.py."""

import json
import os
import sys
import traceback

def main():
    config = json.loads(sys.argv[1])

    from mlx_tune import FastLanguageModel, DPOTrainer, DPOConfig
    from datasets import load_dataset

    model_id = config["model_id"]
    dpo_data_path = config["dpo_data_path"]
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
        lora_alpha=params["lora_r"],
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
        lora_dropout=0.05,
    )

    # Load DPO dataset — expects {prompt, chosen, rejected} fields.
    dataset = load_dataset("json", data_files={"train": dpo_data_path})

    # Configure DPO training.
    dpo_config = DPOConfig(
        output_dir=adapter_dir,
        beta=params["beta"],
        per_device_train_batch_size=params["batch_size"],
        gradient_accumulation_steps=params["gradient_accumulation_steps"],
        learning_rate=params["lr"],
        max_steps=params["max_steps"],
        max_seq_length=params["max_seq_length"],
        logging_steps=max(1, params["max_steps"] // 10),
        save_steps=max(5, params["max_steps"] // 5),
        save_total_limit=2,
    )

    # Train with DPO.
    trainer = DPOTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=dataset["train"],
        args=dpo_config,
    )

    result = trainer.train()

    # Save final adapter.
    model.save_pretrained(adapter_dir)

    # Write metrics.
    metrics = {
        "final_loss": getattr(result, "training_loss", None),
        "total_steps": params["max_steps"],
        "model_id": model_id,
        "mode": "dpo",
        "beta": params["beta"],
        "lora_r": params["lora_r"],
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

    # DPO data comes from training-data-bridge/extract_corrections.py output.
    data_dir = os.path.expanduser("~/Library/Application Support/fae/training/data")
    dpo_data_path = os.path.join(data_dir, "dpo_pairs.jsonl")

    if not os.path.exists(dpo_data_path):
        print(json.dumps({
            "error": "No DPO correction pairs found. Run training-data-bridge extract_corrections first.",
            "path": dpo_data_path,
        }))
        return

    # Check we have enough pairs for meaningful training.
    with open(dpo_data_path) as f:
        pair_count = sum(1 for _ in f)

    if pair_count < 5:
        print(json.dumps({
            "error": f"Only {pair_count} DPO pairs found — need at least 5 for meaningful training.",
            "pair_count": pair_count,
        }))
        return

    timestamp = time.strftime("%Y%m%d-%H%M%S")
    adapter_dir = os.path.expanduser(f"~/Library/Application Support/fae/models/personal/dpo-{timestamp}")
    run_dir = os.path.expanduser("~/Library/Application Support/fae/training")
    log_path = os.path.join(run_dir, "train.log")

    os.makedirs(adapter_dir, exist_ok=True)
    os.makedirs(run_dir, exist_ok=True)

    # Write worker script.
    script_path = os.path.join(run_dir, "_train_dpo_worker.py")
    with open(script_path, "w") as f:
        f.write(DPO_TRAIN_SCRIPT)

    worker_config = json.dumps({
        "model_id": model_id,
        "dpo_data_path": dpo_data_path,
        "adapter_dir": adapter_dir,
        "params": train_params,
    })

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
        "mode": "dpo",
        "params": train_params,
        "dpo_pairs": pair_count,
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
        "mode": "dpo",
        "dpo_pairs": pair_count,
        "engine": "mlx-tune",
        "log_path": log_path,
    }))


if __name__ == "__main__":
    main()
