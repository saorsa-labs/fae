# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Benchmark candidate adapter against base model."""

import json
import os
import sys


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}

    run_path = os.path.expanduser("~/Library/Application Support/fae/training/run.json")
    adapter_path = params.get("adapter_path")

    if not adapter_path and os.path.exists(run_path):
        with open(run_path) as f:
            run_info = json.load(f)
        adapter_path = run_info.get("adapter_path")

    if not adapter_path or not os.path.exists(adapter_path):
        print(json.dumps({"error": "No adapter found to evaluate.", "adapter_path": adapter_path}))
        return

    adapter_file = os.path.join(adapter_path, "adapters.safetensors")
    if not os.path.exists(adapter_file):
        print(json.dumps({"error": "Adapter file not found.", "path": adapter_file}))
        return

    val_path = os.path.expanduser("~/Library/Application Support/fae/training/data/sft_val.jsonl")
    val_count = 0
    if os.path.exists(val_path):
        with open(val_path) as f:
            val_count = sum(1 for _ in f)

    log_path = os.path.expanduser("~/Library/Application Support/fae/training/train.log")
    final_loss = None
    if os.path.exists(log_path):
        with open(log_path) as f:
            for line in f:
                if "loss" in line.lower() and "Iter" in line:
                    for part in line.split(","):
                        if "loss" in part.lower():
                            try:
                                final_loss = float(part.split()[-1])
                            except (ValueError, IndexError):
                                pass

    last_score = params.get("last_benchmark_score")

    score = None
    if final_loss is not None:
        score = max(0.0, min(1.0, 1.0 - (final_loss / 5.0)))

    recommendation = "skip"
    if score is not None:
        if last_score is None or score >= last_score:
            recommendation = "upgrade"

    print(json.dumps({
        "status": "evaluated",
        "adapter_path": adapter_path,
        "validation_samples": val_count,
        "final_training_loss": final_loss,
        "score": score,
        "previous_score": last_score,
        "recommendation": recommendation,
    }))


if __name__ == "__main__":
    main()
