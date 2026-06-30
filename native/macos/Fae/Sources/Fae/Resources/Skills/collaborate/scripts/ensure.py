#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Ensure the x0xd daemon is running and report the user's x0x identity.

Actions (params.action):
  status   (default) — is the daemon up? return identity if so.
  start    — start x0xd if it isn't running (requires the `x0x` binary installed).
  identity — return the agent/machine/user identity.
"""

import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _x0x import X0x, X0xError, read_params, emit, fail  # noqa: E402

# Where the x0x CLI commonly lives, beyond whatever is on PATH.
EXTRA_BIN_DIRS = [
    os.path.expanduser("~/.cargo/bin"),
    os.path.expanduser("~/.local/bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
]


def find_x0x() -> str | None:
    """Locate the `x0x` CLI binary on PATH or in common install dirs."""
    found = shutil.which("x0x")
    if found:
        return found
    for d in EXTRA_BIN_DIRS:
        candidate = os.path.join(d, "x0x")
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def identity(client: X0x) -> dict:
    """GET /agent and shape it for voice."""
    agent = client.get("/agent")
    user_id = agent.get("user_id")
    has_user = bool(user_id)
    return {
        "agent_id": agent.get("agent_id"),
        "machine_id": agent.get("machine_id"),
        "user_id": user_id,
        "has_user_id": has_user,
    }


def identity_summary(ident: dict, instance: str | None) -> str:
    who = instance or "default"
    aid = (ident.get("agent_id") or "")[:12]
    if ident.get("has_user_id"):
        return f"x0x is ready ({who} identity). You have a human identity; agent {aid}…."
    return (
        f"x0x is ready ({who} identity), agent {aid}…. "
        "No human identity yet — you can create one to be findable by name."
    )


def do_status(client: X0x, instance: str | None) -> dict:
    if not client.is_running():
        return {
            "ok": True,
            "running": False,
            "instance": instance or "default",
            "summary": "The x0x daemon is not running. Say the word and I'll start it.",
        }
    ident = identity(client)
    return {
        "ok": True,
        "running": True,
        "instance": instance or "default",
        **ident,
        "summary": identity_summary(ident, instance),
    }


def do_start(client: X0x, instance: str | None) -> dict:
    if client.is_running():
        ident = identity(client)
        return {
            "ok": True,
            "running": True,
            "started": False,
            "instance": instance or "default",
            **ident,
            "summary": "x0x was already running. " + identity_summary(ident, instance),
        }

    binary = find_x0x()
    if not binary:
        raise X0xError(
            "x0x is not installed (no `x0x` binary found on PATH or in "
            "~/.cargo/bin, ~/.local/bin, /opt/homebrew/bin). "
            "I can't start the network until x0x is installed — let's set that up first."
        )

    argv = [binary]
    if instance:
        argv += ["--name", instance]
    argv += ["start"]
    try:
        # x0x start daemonizes and returns; cap it so we never hang.
        subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)
    except subprocess.TimeoutExpired:
        raise X0xError("Starting x0x timed out. Please check the x0x installation.")
    except OSError as e:
        raise X0xError(f"Could not launch x0x: {e}")

    # The daemon writes api.port/api-token on startup; re-read by reconstructing the client.
    deadline = time.monotonic() + 15.0
    while time.monotonic() < deadline:
        probe = X0x(instance)
        if probe.is_running():
            ident = identity(probe)
            return {
                "ok": True,
                "running": True,
                "started": True,
                "instance": instance or "default",
                **ident,
                "summary": "Started x0x. " + identity_summary(ident, instance),
            }
        time.sleep(1.0)

    raise X0xError(
        "I launched x0x but it didn't come up within 15 seconds. "
        "It may still be starting — try again in a moment."
    )


def do_identity(client: X0x, instance: str | None) -> dict:
    client.require_running()
    ident = identity(client)
    return {
        "ok": True,
        "instance": instance or "default",
        **ident,
        "summary": identity_summary(ident, instance),
    }


def main() -> None:
    params = read_params()
    action = (params.get("action") or "status").strip().lower()
    instance = params.get("instance")
    client = X0x(instance)
    try:
        if action == "status":
            emit(do_status(client, instance))
        elif action == "start":
            emit(do_start(client, instance))
        elif action == "identity":
            emit(do_identity(client, instance))
        else:
            fail(f"Unknown action '{action}'. Use status, start, or identity.")
    except X0xError as e:
        fail(str(e))


if __name__ == "__main__":
    main()
