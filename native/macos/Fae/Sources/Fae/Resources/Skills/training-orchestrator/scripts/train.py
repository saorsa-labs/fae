# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Launch LoRA training as a detached subprocess."""

import json
import os
import subprocess
import sys
import time

MODEL_MAP = {
    "tiny": "mlx-community/Qwen2.5-3B-Instruct-4bit",
    "small": "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "medium": "mlx-community/Qwen2.5-14B-Instruct-4bit",
}

PRESET_MAP = {
    "smoke": {"iters": 10, "batch_size": 1, "num_layers": 4, "lr": "1e-4", "max_seq_length": 512},
    "light": {"iters": 50, "batch_size": 2, "num_layers": 8, "lr": "5e-5", "max_seq_length": 1024},
    "standard": {"iters": 200, "batch_size": 4, "num_layers": 16, "lr": "2e-5", "max_seq_length": 2048},
    "deep": {"iters": 500, "batch_size": 4, "num_layers": 32, "lr": "1e-5", "max_seq_length": 2048},
}


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}

    target = params.get("target_model_preset", "auto")
    preset = params.get("training_preset", "light")
    max_iters = params.get("max_iterations", None)

    if target == "auto":
        ram_bytes = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]).strip())
        ram_gb = ram_bytes // (1024**3)
        if ram_gb >= 48:
            target = "medium"
        elif ram_gb >= 24:
            target = "small"
        else:
            target = "tiny"

    model_id = MODEL_MAP.get(target, MODEL_MAP["tiny"])
    train_params = dict(PRESET_MAP.get(preset, PRESET_MAP["light"]))

    if max_iters:
        train_params["iters"] = int(max_iters)

    data_dir = os.path.expanduser("~/Library/Application Support/fae/training/data")
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    adapter_dir = os.path.expanduser(f"~/Library/Application Support/fae/models/personal/{timestamp}")
    run_dir = os.path.expanduser("~/Library/Application Support/fae/training")
    log_path = os.path.join(run_dir, "train.log")

    os.makedirs(adapter_dir, exist_ok=True)
    os.makedirs(run_dir, exist_ok=True)

    sft_train = os.path.join(data_dir, "sft_train.jsonl")
    if not os.path.exists(sft_train):
        print(json.dumps({"error": "No training data found. Run export_data first.", "path": sft_train}))
        return

    cmd = [
        sys.executable, "-m", "mlx_lm.lora",
        "--model", model_id,
        "--data", data_dir,
        "--adapter-path", adapter_dir,
        "--iters", str(train_params["iters"]),
        "--batch-size", str(train_params["batch_size"]),
        "--num-layers", str(train_params["num_layers"]),
        "--learning-rate", str(train_params["lr"]),
        "--max-seq-length", str(train_params["max_seq_length"]),
    ]

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
        "params": train_params,
        "started_at": timestamp,
        "log_path": log_path,
    }
    with open(os.path.join(run_dir, "run.json"), "w") as f:
        json.dump(run_info, f, indent=2)

    print(json.dumps({
        "status": "started",
        "pid": process.pid,
        "adapter_path": adapter_dir,
        "model_id": model_id,
        "preset": preset,
        "log_path": log_path,
    }))


if __name__ == "__main__":
    main()
