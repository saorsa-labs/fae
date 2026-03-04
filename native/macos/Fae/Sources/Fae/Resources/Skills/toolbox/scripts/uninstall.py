#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Remove an installed tool from the Fae forge registry and disk."""

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path


FORGE_DIR = Path(os.path.expanduser("~/.fae-forge"))
REGISTRY_PATH = FORGE_DIR / "registry.json"
TOOLS_DIR = FORGE_DIR / "tools"
BUNDLES_DIR = FORGE_DIR / "bundles"

# Fae personal skills directory (for symlink cleanup).
FAE_SKILLS_DIR = Path(os.path.expanduser(
    "~/Library/Application Support/fae/skills"
))


def load_registry() -> dict:
    """Load registry, returning empty structure if missing."""
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


def save_registry(registry: dict) -> None:
    """Atomically write registry via temp file + rename."""
    FORGE_DIR.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=str(FORGE_DIR), prefix=".registry_", suffix=".json"
    )
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(registry, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp_path, str(REGISTRY_PATH))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def remove_skill_symlink(name: str) -> bool:
    """Remove symlink from Fae's skills directory if it points to this tool."""
    link_path = FAE_SKILLS_DIR / name
    if link_path.is_symlink():
        try:
            target = link_path.resolve()
            expected = (TOOLS_DIR / name).resolve()
            if target == expected or not link_path.exists():
                link_path.unlink()
                return True
        except OSError:
            pass
    # Also check if it is a regular directory copy (not symlink).
    if link_path.is_dir() and not link_path.is_symlink():
        # Only remove if it looks like a forge-installed tool.
        marker = link_path / ".forge-installed"
        if marker.exists():
            shutil.rmtree(link_path, ignore_errors=True)
            return True
    return False


def uninstall_tool(name: str, keep_bundle: bool = True) -> dict:
    """Uninstall a tool by name."""
    registry = load_registry()
    registered = registry.get("tools", {})

    # Check if tool exists in registry or on disk.
    tool_dir = TOOLS_DIR / name
    in_registry = name in registered
    on_disk = tool_dir.is_dir()

    if not in_registry and not on_disk:
        return {"ok": False, "error": f"tool not found: {name}"}

    removed_from_disk = False
    removed_from_registry = False
    bundle_kept = False
    symlink_removed = False

    # Remove from disk.
    if on_disk:
        try:
            shutil.rmtree(tool_dir)
            removed_from_disk = True
        except OSError as exc:
            return {"ok": False, "error": f"failed to remove tool directory: {exc}"}

    # Remove from registry.
    if in_registry:
        del registered[name]
        registry["tools"] = registered
        save_registry(registry)
        removed_from_registry = True

    # Handle bundle.
    bundle_path = BUNDLES_DIR / f"{name}.bundle"
    if bundle_path.exists():
        if keep_bundle:
            bundle_kept = True
        else:
            try:
                bundle_path.unlink()
            except OSError:
                pass

    # Clean up symlinks in Fae's skills directory.
    symlink_removed = remove_skill_symlink(name)

    return {
        "ok": True,
        "name": name,
        "removed": True,
        "removed_from_disk": removed_from_disk,
        "removed_from_registry": removed_from_registry,
        "bundle_kept": bundle_kept,
        "symlink_removed": symlink_removed,
    }


def main() -> int:
    try:
        payload = sys.stdin.read().strip()
        if not payload:
            print(json.dumps({"ok": False, "error": "empty request"}))
            return 1

        request = json.loads(payload)
    except json.JSONDecodeError:
        print(json.dumps({"ok": False, "error": "invalid JSON input"}))
        return 1

    params = request.get("params", {})
    name = params.get("name", "")
    if not name:
        print(json.dumps({"ok": False, "error": "name parameter is required"}))
        return 1

    keep_bundle = params.get("keep_bundle", True)

    try:
        result = uninstall_tool(name=name, keep_bundle=keep_bundle)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if result.get("ok") else 1
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
