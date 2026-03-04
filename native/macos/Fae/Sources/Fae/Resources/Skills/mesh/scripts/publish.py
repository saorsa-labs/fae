#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Publish a forge-built tool to the mesh network for peer discovery and download."""

import json
import os
import sys
import time
from pathlib import Path

FORGE_DIR = Path(os.path.expanduser("~")) / ".fae-forge"
REGISTRY_FILE = FORGE_DIR / "registry.json"
PID_FILE = FORGE_DIR / "serve.pid"
BUNDLES_DIR = FORGE_DIR / "bundles"
TOOLS_DIR = FORGE_DIR / "tools"


def load_registry() -> dict:
    """Load the tool registry."""
    if not REGISTRY_FILE.exists():
        return {"tools": {}}
    try:
        with open(REGISTRY_FILE, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"tools": {}}


def is_server_running() -> tuple[bool, int]:
    """Check if the catalog server is running. Returns (running, port)."""
    if not PID_FILE.exists():
        return False, 0
    try:
        pid_data = json.loads(PID_FILE.read_text(encoding="utf-8"))
        pid = pid_data.get("pid", 0)
        port = pid_data.get("port", 0)
        os.kill(pid, 0)
        return True, port
    except (ProcessLookupError, PermissionError, OSError, json.JSONDecodeError, ValueError):
        return False, 0


def find_bundle(name: str) -> Path | None:
    """Find the latest bundle for a tool."""
    if not BUNDLES_DIR.exists():
        return None
    bundles = sorted(BUNDLES_DIR.glob(f"{name}*.bundle"), reverse=True)
    return bundles[0] if bundles else None


def publish_tool(name: str, target: str) -> dict:
    """Publish a tool to the mesh network."""
    registry = load_registry()
    tools = registry.get("tools", {})

    if name not in tools:
        return {
            "ok": False,
            "error": f"Tool '{name}' not found in registry. Build and release it with the forge skill first.",
        }

    tool_info = tools[name]
    version = tool_info.get("version", "0.0.0")

    # Verify the tool directory exists.
    tool_dir = TOOLS_DIR / name
    if not tool_dir.exists():
        return {
            "ok": False,
            "error": f"Tool directory not found at {tool_dir}. Release the tool with forge first.",
        }

    # Verify a bundle exists.
    bundle = find_bundle(name)
    if bundle is None:
        return {
            "ok": False,
            "error": f"No bundle found for '{name}'. Release the tool with forge first.",
        }

    # Ensure the catalog server is running for LAN publishing.
    if target in ("all", "lan"):
        running, port = is_server_running()
        if not running:
            return {
                "ok": False,
                "error": "Catalog server is not running. Start it first: run_skill mesh serve start",
            }
        # Tool is automatically available via the server's /catalog and /tools endpoints.
        # Update the publish timestamp in the registry.
        tool_info["published_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        tool_info["published_to"] = target
        registry["tools"][name] = tool_info
        REGISTRY_FILE.write_text(json.dumps(registry, indent=2), encoding="utf-8")

        return {
            "ok": True,
            "name": name,
            "version": version,
            "published_to": target,
            "catalog_port": port,
            "bundle": str(bundle),
            "bundle_size_bytes": bundle.stat().st_size,
        }

    # Specific peer target -- notify them (future: POST /notify).
    if target not in ("all", "lan"):
        # For now, just verify the tool is ready and report.
        running, port = is_server_running()
        return {
            "ok": True,
            "name": name,
            "version": version,
            "published_to": target,
            "catalog_port": port if running else None,
            "bundle": str(bundle),
            "bundle_size_bytes": bundle.stat().st_size,
            "note": f"Tool is ready for peer '{target}' to fetch. Ensure the catalog server is running.",
        }

    return {"ok": False, "error": "Unexpected state."}


def main() -> None:
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    name = params.get("name", "")
    target = params.get("target", "all")

    if not name:
        print(json.dumps({"ok": False, "error": "Missing required parameter: name"}))
        return

    # Normalize name.
    name = name.strip().lower()

    try:
        result = publish_tool(name, target)
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
