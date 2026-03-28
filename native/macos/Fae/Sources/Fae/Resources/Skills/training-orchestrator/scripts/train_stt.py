# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-tune[audio]>=0.4.11", "datasets>=2.14.0"]
# ///

"""Launch STT fine-tuning for Qwen3-ASR via mlx-tune as a detached subprocess.

Fine-tunes Fae's speech-to-text model using conversation correction pairs
where the user corrected ASR misrecognitions ("my name is X not Y").
"""

import json
import os
import subprocess
import sys
import time

# STT models — only Qwen3-ASR matches Fae's production pipeline.
STT_MODEL_MAP = {
    "default": "mlx-community/Qwen3-ASR-1.7B-4bit",
}

PRESET_MAP = {
    "smoke": {
        "max_steps": 10,
        "batch_size": 2,
        "gradient_accumulation_steps": 1,
        "lr": 2e-4,
        "lora_r": 8,
        "max_seq_length": 448,
    },
    "light": {
        "max_steps": 30,
        "batch_size": 2,
        "gradient_accumulation_steps": 2,
        "lr": 1e-4,
        "lora_r": 16,
        "max_seq_length": 448,
    },
    "standard": {
        "max_steps": 60,
        "batch_size": 2,
        "gradient_accumulation_steps": 2,
        "lr": 5e-5,
        "lora_r": 16,
        "max_seq_length": 448,
    },
}

STT_TRAIN_SCRIPT = '''
# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-tune[audio]>=0.4.11", "datasets>=2.14.0"]
# ///

"""Detached STT training process — launched by train_stt.py."""

import json
import os
import sys
import traceback

def main():
    config = json.loads(sys.argv[1])

    from mlx_tune import FastSTTModel, STTSFTTrainer, STTSFTConfig
    from datasets import load_dataset

    model_id = config["model_id"]
    data_path = config["data_path"]
    adapter_dir = config["adapter_dir"]
    params = config["params"]

    # Load STT model.
    model, processor = FastSTTModel.from_pretrained(
        model_name=model_id,
        max_seq_length=params["max_seq_length"],
        trust_remote_code=True,
    )

    # Apply LoRA to both encoder and decoder.
    model = FastSTTModel.get_peft_model(
        model,
        r=params["lora_r"],
        lora_alpha=params["lora_r"],
        target_modules=["q_proj", "k_proj"],
        finetune_encoder=True,
        finetune_decoder=True,
    )

    # Load audio + transcript pairs.
    dataset = load_dataset("json", data_files={"train": data_path})

    # Configure training.
    stt_config = STTSFTConfig(
        output_dir=adapter_dir,
        per_device_train_batch_size=params["batch_size"],
        gradient_accumulation_steps=params["gradient_accumulation_steps"],
        learning_rate=params["lr"],
        max_steps=params["max_steps"],
        logging_steps=max(1, params["max_steps"] // 10),
        save_steps=max(5, params["max_steps"] // 5),
        save_total_limit=2,
    )

    trainer = STTSFTTrainer(
        model=model,
        processor=processor,
        train_dataset=dataset["train"],
        args=stt_config,
    )

    result = trainer.train()
    model.save_pretrained(adapter_dir)

    metrics = {
        "final_loss": getattr(result, "training_loss", None),
        "total_steps": params["max_steps"],
        "model_id": model_id,
        "mode": "stt",
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

    preset = params.get("training_preset", "light")
    max_iters = params.get("max_iterations", None)

    model_id = STT_MODEL_MAP["default"]
    train_params = dict(PRESET_MAP.get(preset, PRESET_MAP["light"]))

    if max_iters:
        train_params["max_steps"] = int(max_iters)

    # STT correction data — audio + corrected transcript pairs.
    data_dir = os.path.expanduser("~/Library/Application Support/fae/training/data")
    stt_data_path = os.path.join(data_dir, "stt_corrections.jsonl")

    if not os.path.exists(stt_data_path):
        print(json.dumps({
            "error": "No STT correction data found. Fae needs correction pairs from conversation.",
            "path": stt_data_path,
            "hint": "Corrections are captured when users say 'my name is X not Y'.",
        }))
        return

    with open(stt_data_path) as f:
        sample_count = sum(1 for _ in f)

    if sample_count < 3:
        print(json.dumps({
            "error": f"Only {sample_count} STT corrections — need at least 3.",
            "sample_count": sample_count,
        }))
        return

    timestamp = time.strftime("%Y%m%d-%H%M%S")
    adapter_dir = os.path.expanduser(f"~/Library/Application Support/fae/models/stt-personal/{timestamp}")
    run_dir = os.path.expanduser("~/Library/Application Support/fae/training")
    log_path = os.path.join(run_dir, "train.log")

    os.makedirs(adapter_dir, exist_ok=True)
    os.makedirs(run_dir, exist_ok=True)

    script_path = os.path.join(run_dir, "_train_stt_worker.py")
    with open(script_path, "w") as f:
        f.write(STT_TRAIN_SCRIPT)

    worker_config = json.dumps({
        "model_id": model_id,
        "data_path": stt_data_path,
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
        "mode": "stt",
        "params": train_params,
        "stt_corrections": sample_count,
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
        "mode": "stt",
        "stt_corrections": sample_count,
        "engine": "mlx-tune",
        "log_path": log_path,
    }))


if __name__ == "__main__":
    main()
