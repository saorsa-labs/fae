# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Check acpx installation status and available agents."""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str], timeout: int = 10) -> tuple[int, str, str]:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return 1, "", ""


def find_acpx() -> str | None:
    """Find acpx binary path."""
    # Direct PATH
    p = shutil.which("acpx")
    if p:
        return p
    # ~/.local/bin
    local = Path.home() / ".local" / "bin" / "acpx"
    if local.exists() and os.access(local, os.X_OK):
        return str(local)
    # bun global
    bun_acpx = Path.home() / ".bun" / "bin" / "acpx"
    if bun_acpx.exists():
        return str(bun_acpx)
    return None


def check_agent(name: str, commands: list[list[str]]) -> dict:
    """Check if a specific agent CLI is available."""
    for cmd in commands:
        code, out, _ = run(cmd)
        if code == 0:
            return {"name": name, "available": True, "command": " ".join(cmd)}
    return {"name": name, "available": False}


def main(args: dict) -> dict:
    """Check acpx status and available agents."""
    acpx_path = find_acpx()

    agents = [
        check_agent("claude", [["claude", "--version"], ["claude-code", "--version"]]),
        check_agent("codex", [["codex", "--version"]]),
        check_agent("gemini", [["gemini", "--version"]]),
        check_agent("copilot", [["copilot", "--version"], ["github-copilot-cli", "--version"]]),
    ]

    # Also check if bun/npm are available for installation
    has_bun = shutil.which("bun") is not None or (Path.home() / ".bun" / "bin" / "bun").exists()
    has_npm = shutil.which("npm") is not None
    has_node = shutil.which("node") is not None

    available_agents = [a for a in agents if a["available"]]

    return {
        "status": "ok",
        "acpx_installed": acpx_path is not None,
        "acpx_path": acpx_path,
        "available_agents": available_agents,
        "all_agents": agents,
        "can_install": has_bun or has_npm,
        "runtime": {
            "bun": has_bun,
            "npm": has_npm,
            "node": has_node,
        },
        "session_dir": str(Path.home() / ".acpx"),
        "session_dir_exists": (Path.home() / ".acpx").exists(),
    }


if __name__ == "__main__":
    raw = sys.argv[1] if len(sys.argv) > 1 else "{}"
    try:
        input_args = json.loads(raw)
    except json.JSONDecodeError:
        input_args = {}
    print(json.dumps(main(input_args), indent=2))
