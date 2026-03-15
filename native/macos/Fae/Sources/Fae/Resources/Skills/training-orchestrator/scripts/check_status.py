# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Poll training progress."""

import json
import os
import sys


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}

    run_path = os.path.expanduser("~/Library/Application Support/fae/training/run.json")
    if not os.path.exists(run_path):
        print(json.dumps({"status": "no_run", "message": "No training run found."}))
        return

    with open(run_path) as f:
        run_info = json.load(f)

    pid = run_info.get("pid")
    adapter_path = run_info.get("adapter_path", "")
    log_path = run_info.get("log_path", "")

    running = False
    if pid:
        try:
            os.kill(pid, 0)
            running = True
        except (ProcessLookupError, PermissionError):
            running = False

    latest_iter = None
    latest_loss = None
    if log_path and os.path.exists(log_path):
        try:
            with open(log_path) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("Iter "):
                        parts = line.split(":")
                        if parts:
                            iter_part = parts[0].replace("Iter ", "").strip()
                            try:
                                latest_iter = int(iter_part)
                            except ValueError:
                                pass
                        if "loss" in line.lower():
                            for part in line.split(","):
                                if "loss" in part.lower():
                                    try:
                                        latest_loss = float(part.split()[-1])
                                    except (ValueError, IndexError):
                                        pass
        except OSError:
            pass

    adapter_exists = os.path.exists(os.path.join(adapter_path, "adapters.safetensors"))

    if running:
        status = "running"
    elif adapter_exists:
        status = "completed"
    else:
        status = "failed"

    result = {
        "status": status,
        "pid": pid,
        "adapter_path": adapter_path,
        "adapter_exists": adapter_exists,
    }
    if latest_iter is not None:
        result["latest_iteration"] = latest_iter
    if latest_loss is not None:
        result["latest_loss"] = latest_loss
    if run_info.get("model_id"):
        result["model_id"] = run_info["model_id"]
    if run_info.get("started_at"):
        result["started_at"] = run_info["started_at"]

    print(json.dumps(result))


if __name__ == "__main__":
    main()
