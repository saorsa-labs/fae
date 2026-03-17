# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Check whether personal model training appears to be in progress."""

import json
import os
import sys

RUN_STATE_PATH = os.path.expanduser("~/Library/Application Support/fae/training/run.json")


def _is_pid_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return False
    except OSError:
        return False


def main() -> None:
    params = {}
    if len(sys.argv) > 1:
        try:
            payload = json.loads(sys.argv[1])
            if isinstance(payload, dict):
                params = payload.get("params", payload) if payload.get("params") else payload
        except json.JSONDecodeError:
            params = {}

    run_state_path = os.path.expanduser(params.get("run_state_path", RUN_STATE_PATH))
    if not os.path.exists(run_state_path):
        print(json.dumps({"status": "idle", "running": False, "reason": "run_state_missing"}))
        return

    try:
        with open(run_state_path, "r", encoding="utf-8") as handle:
            state = json.load(handle)
    except (OSError, json.JSONDecodeError):
        print(json.dumps({"status": "unknown", "running": False, "reason": "invalid_run_state"}))
        return

    pid = state.get("pid")
    running = isinstance(pid, int) and _is_pid_running(pid)

    result = {
        "status": "running" if running else "not_running",
        "running": running,
        "pid": pid,
        "started_at": state.get("started_at"),
        "adapter_path": state.get("adapter_path"),
        "log_path": state.get("log_path"),
    }

    print(json.dumps(result))


if __name__ == "__main__":
    main()
