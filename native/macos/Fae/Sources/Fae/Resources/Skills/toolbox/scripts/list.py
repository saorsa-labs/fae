#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""List all installed tools in the Fae forge registry."""

import json
import os
import sys
from datetime import datetime
from pathlib import Path


FORGE_DIR = Path(os.path.expanduser("~/.fae-forge"))
REGISTRY_PATH = FORGE_DIR / "registry.json"
TOOLS_DIR = FORGE_DIR / "tools"


def load_registry() -> dict:
    """Load the registry file, returning an empty structure if missing."""
    if not REGISTRY_PATH.exists():
        return {"version": 1, "tools": {}}
    try:
        with open(REGISTRY_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or "tools" not in data:
            return {"version": 1, "tools": {}}
        return data
    except (json.JSONDecodeError, OSError):
        return {"version": 1, "tools": {}}


def dir_size_bytes(path: Path) -> int:
    """Compute total size in bytes of all files under a directory."""
    total = 0
    try:
        for entry in path.rglob("*"):
            if entry.is_file():
                total += entry.stat().st_size
    except OSError:
        pass
    return total


def format_size(size_bytes: int) -> str:
    """Format byte count as human-readable string."""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    else:
        return f"{size_bytes / (1024 * 1024):.1f} MB"


def list_tools(verbose: bool = False) -> dict:
    """List all installed tools, detecting orphans on disk."""
    registry = load_registry()
    registered = registry.get("tools", {})

    tools = []
    seen_dirs = set()

    # Walk registered tools.
    for name, meta in sorted(registered.items()):
        tool_path = Path(meta.get("path", str(TOOLS_DIR / name)))
        exists_on_disk = tool_path.is_dir()
        seen_dirs.add(tool_path.name)

        entry = {
            "name": name,
            "version": meta.get("version", "unknown"),
            "description": meta.get("description", ""),
            "lang": meta.get("lang", "unknown"),
            "installed": meta.get("installed", ""),
            "source": meta.get("source", "unknown"),
            "on_disk": exists_on_disk,
        }

        if verbose:
            entry["path"] = str(tool_path)
            if exists_on_disk:
                entry["size"] = format_size(dir_size_bytes(tool_path))

        tools.append(entry)

    # Scan for orphans (on disk but not in registry).
    orphans = []
    if TOOLS_DIR.is_dir():
        for child in sorted(TOOLS_DIR.iterdir()):
            if child.is_dir() and child.name not in seen_dirs:
                skill_md = child / "SKILL.md"
                orphan_entry = {
                    "name": child.name,
                    "status": "orphan",
                    "has_skill_md": skill_md.exists(),
                }
                if verbose:
                    orphan_entry["path"] = str(child)
                    orphan_entry["size"] = format_size(dir_size_bytes(child))
                orphans.append(orphan_entry)

    result = {
        "ok": True,
        "tools": tools,
        "count": len(tools),
    }

    if orphans:
        result["orphans"] = orphans
        result["orphan_count"] = len(orphans)

    return result


def main() -> int:
    try:
        payload = sys.stdin.read().strip()
        if not payload:
            request = {}
        else:
            request = json.loads(payload)
    except json.JSONDecodeError:
        print(json.dumps({"ok": False, "error": "invalid JSON input"}))
        return 1

    params = request.get("params", {})
    verbose = params.get("verbose", False)

    try:
        result = list_tools(verbose=verbose)
        print(json.dumps(result, indent=2, ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
