# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Activate a trained personal adapter."""

import json
import os
import sys


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}

    adapter_path = params.get("adapter_path")
    current_adapter = params.get("current_adapter_path")

    if not adapter_path:
        run_path = os.path.expanduser("~/Library/Application Support/fae/training/run.json")
        if os.path.exists(run_path):
            with open(run_path) as f:
                run_info = json.load(f)
            adapter_path = run_info.get("adapter_path")

    if not adapter_path or not os.path.exists(adapter_path):
        print(json.dumps({"error": "No adapter found to deploy.", "adapter_path": adapter_path}))
        return

    adapter_file = os.path.join(adapter_path, "adapters.safetensors")
    if not os.path.exists(adapter_file):
        print(json.dumps({"error": "Adapter file not found.", "path": adapter_file}))
        return

    print(json.dumps({
        "status": "deployed",
        "adapter_path": adapter_path,
        "previous_adapter_path": current_adapter,
        "message": "Personal adapter activated. Use self_config to update training.personalAdapterPath.",
    }))


if __name__ == "__main__":
    main()
