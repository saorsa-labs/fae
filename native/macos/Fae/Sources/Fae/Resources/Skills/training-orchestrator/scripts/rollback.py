# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Revert to the previous personal adapter."""

import json
import os
import sys


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}

    previous_path = params.get("previous_adapter_path")

    if not previous_path:
        print(json.dumps({"error": "No previous adapter path provided."}))
        return

    if not os.path.exists(previous_path):
        print(json.dumps({
            "error": "Previous adapter not found on disk.",
            "path": previous_path,
        }))
        return

    adapter_file = os.path.join(previous_path, "adapters.safetensors")
    if not os.path.exists(adapter_file):
        print(json.dumps({
            "status": "cleared",
            "message": "Previous adapter directory exists but has no adapter file. Clearing adapter path.",
            "adapter_path": None,
        }))
        return

    print(json.dumps({
        "status": "rolled_back",
        "adapter_path": previous_path,
        "message": "Reverted to previous adapter. Use self_config to update training.personalAdapterPath.",
    }))


if __name__ == "__main__":
    main()
