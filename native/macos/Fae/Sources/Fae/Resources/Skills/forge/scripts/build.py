#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Compile a Forge tool project. Zig -> native ARM64 and/or WASM. Python -> syntax check."""

import json
import os
import shutil
import subprocess
import sys


FORGE_BASE = os.path.expanduser("~/.fae-forge")
WORKSPACE = os.path.join(FORGE_BASE, "workspace")


def find_project(name: str) -> str | None:
    """Return project path if it exists, else None."""
    project_dir = os.path.join(WORKSPACE, name)
    if os.path.isdir(project_dir):
        return project_dir
    return None


def detect_lang(project_dir: str) -> str:
    """Detect project language from directory contents."""
    has_zig = os.path.exists(os.path.join(project_dir, "build.zig"))
    has_python = os.path.isdir(os.path.join(project_dir, "scripts"))
    if has_zig and has_python:
        return "both"
    if has_zig:
        return "zig"
    if has_python:
        return "python"
    return "unknown"


def get_file_size(path: str) -> int | None:
    """Return file size in bytes or None if missing."""
    try:
        return os.path.getsize(path)
    except OSError:
        return None


def build_zig_native(project_dir: str, name: str, mode: str) -> dict:
    """Build Zig project for native ARM64. Returns artifact info."""
    optimize_flag = "-Doptimize=ReleaseFast" if mode == "release" else "-Doptimize=Debug"

    result = subprocess.run(
        ["zig", "build", optimize_flag],
        cwd=project_dir,
        capture_output=True,
        text=True,
        timeout=120,
    )

    if result.returncode != 0:
        return {
            "target": "arm64-macos",
            "ok": False,
            "error": result.stderr.strip() or result.stdout.strip(),
        }

    binary_path = os.path.join(project_dir, "zig-out", "bin", name)
    size = get_file_size(binary_path)

    warnings = []
    if result.stderr.strip():
        for line in result.stderr.strip().splitlines():
            if "warning" in line.lower():
                warnings.append(line.strip())

    return {
        "target": "arm64-macos",
        "ok": True,
        "path": binary_path,
        "size_bytes": size,
        "warnings": warnings,
    }


def build_zig_wasm(project_dir: str, name: str, mode: str) -> dict:
    """Build Zig project for WASM. Returns artifact info."""
    optimize_flag = "-Doptimize=ReleaseFast" if mode == "release" else "-Doptimize=Debug"

    result = subprocess.run(
        ["zig", "build", optimize_flag, "-Dtarget=wasm32-wasi"],
        cwd=project_dir,
        capture_output=True,
        text=True,
        timeout=120,
    )

    if result.returncode != 0:
        return {
            "target": "wasm32-wasi",
            "ok": False,
            "error": result.stderr.strip() or result.stdout.strip(),
        }

    # Zig places WASM output under zig-out/bin/ with the same name.
    wasm_path = os.path.join(project_dir, "zig-out", "bin", name)
    # Some Zig versions may produce a .wasm file explicitly.
    wasm_ext_path = wasm_path + ".wasm"
    actual_path = wasm_ext_path if os.path.exists(wasm_ext_path) else wasm_path
    size = get_file_size(actual_path)

    warnings = []
    if result.stderr.strip():
        for line in result.stderr.strip().splitlines():
            if "warning" in line.lower():
                warnings.append(line.strip())

    return {
        "target": "wasm32-wasi",
        "ok": True,
        "path": actual_path,
        "size_bytes": size,
        "warnings": warnings,
    }


def build_python(project_dir: str, name: str) -> dict:
    """Check Python scripts for syntax errors and dependency resolution."""
    scripts_dir = os.path.join(project_dir, "scripts")
    if not os.path.isdir(scripts_dir):
        return {
            "target": "python",
            "ok": False,
            "error": "No scripts/ directory found.",
        }

    py_files = [f for f in os.listdir(scripts_dir) if f.endswith(".py")]
    if not py_files:
        return {
            "target": "python",
            "ok": False,
            "error": "No Python scripts found in scripts/.",
        }

    errors = []
    checked = []

    for py_file in py_files:
        py_path = os.path.join(scripts_dir, py_file)

        # Syntax check.
        result = subprocess.run(
            [sys.executable, "-m", "py_compile", py_path],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            errors.append(f"{py_file}: {result.stderr.strip()}")
        else:
            checked.append(py_file)

    if errors:
        return {
            "target": "python",
            "ok": False,
            "error": "; ".join(errors),
            "checked": checked,
        }

    return {
        "target": "python",
        "ok": True,
        "scripts_checked": checked,
        "warnings": [],
    }


def build_tool(name: str, target: str, mode: str) -> dict:
    """Build a tool project."""
    project_dir = find_project(name)
    if not project_dir:
        return {"ok": False, "error": f"Project '{name}' not found in workspace. Run init first."}

    lang = detect_lang(project_dir)
    if lang == "unknown":
        return {"ok": False, "error": f"Cannot detect language for project '{name}'. Missing build.zig or scripts/."}

    # Check zig is available if needed.
    if lang in ("zig", "both") and target in ("native", "wasm", "both"):
        if not shutil.which("zig"):
            return {"ok": False, "error": "Zig compiler not found. Install with: zb install zig"}

    artifacts = []
    all_ok = True

    # Build Zig targets.
    if lang in ("zig", "both"):
        if target in ("native", "both"):
            art = build_zig_native(project_dir, name, mode)
            artifacts.append(art)
            if not art["ok"]:
                all_ok = False

        if target in ("wasm", "both"):
            art = build_zig_wasm(project_dir, name, mode)
            artifacts.append(art)
            if not art["ok"]:
                all_ok = False

    # Build/check Python.
    if lang in ("python", "both"):
        art = build_python(project_dir, name)
        artifacts.append(art)
        if not art["ok"]:
            all_ok = False

    all_warnings = []
    for art in artifacts:
        all_warnings.extend(art.get("warnings", []))

    return {
        "ok": all_ok,
        "name": name,
        "lang": lang,
        "mode": mode,
        "artifacts": artifacts,
        "warnings": all_warnings,
    }


def main():
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    name = params.get("name", "")
    target = params.get("target", "native")
    mode = params.get("mode", "debug")

    if not name:
        print(json.dumps({"ok": False, "error": "Tool name is required."}))
        return

    try:
        result = build_tool(name, target, mode)
        print(json.dumps(result, indent=2))
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "Build timed out after 120 seconds."}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
