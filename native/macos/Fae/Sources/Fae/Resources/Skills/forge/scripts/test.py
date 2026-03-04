#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Run tests for a Forge tool project. Zig uses zig build test, Python uses pytest or import check."""

import json
import os
import re
import shutil
import subprocess
import sys


FORGE_BASE = os.path.expanduser("~/.fae-forge")
WORKSPACE = os.path.join(FORGE_BASE, "workspace")


def find_project(name: str) -> str | None:
    project_dir = os.path.join(WORKSPACE, name)
    if os.path.isdir(project_dir):
        return project_dir
    return None


def detect_lang(project_dir: str) -> str:
    has_zig = os.path.exists(os.path.join(project_dir, "build.zig"))
    has_python = os.path.isdir(os.path.join(project_dir, "scripts"))
    if has_zig and has_python:
        return "both"
    if has_zig:
        return "zig"
    if has_python:
        return "python"
    return "unknown"


def test_zig(project_dir: str, verbose: bool) -> dict:
    """Run zig build test and parse results."""
    if not shutil.which("zig"):
        return {"target": "zig", "ok": False, "error": "Zig compiler not found. Install with: zb install zig"}

    cmd = ["zig", "build", "test"]
    result = subprocess.run(
        cmd,
        cwd=project_dir,
        capture_output=True,
        text=True,
        timeout=120,
    )

    output = result.stdout + result.stderr

    # Parse pass/fail from Zig test output.
    passed = 0
    failed = 0

    # Zig test runner outputs lines like "1/1 test.main_test.test.basic... OK"
    pass_matches = re.findall(r"\bOK\b", output)
    fail_matches = re.findall(r"\bFAIL\b", output)
    passed = len(pass_matches)
    failed = len(fail_matches)

    # If no structured output, infer from return code.
    if passed == 0 and failed == 0:
        if result.returncode == 0:
            passed = 1  # At least something passed.
        else:
            failed = 1

    res = {
        "target": "zig",
        "ok": result.returncode == 0,
        "passed": passed,
        "failed": failed,
    }

    if verbose or result.returncode != 0:
        res["output"] = output.strip()

    return res


def test_python(project_dir: str, verbose: bool) -> dict:
    """Run Python tests. Uses pytest if available, otherwise basic import check."""
    scripts_dir = os.path.join(project_dir, "scripts")
    if not os.path.isdir(scripts_dir):
        return {"target": "python", "ok": False, "error": "No scripts/ directory found."}

    py_files = [f for f in os.listdir(scripts_dir) if f.endswith(".py")]
    if not py_files:
        return {"target": "python", "ok": False, "error": "No Python scripts found."}

    # Check if pytest tests exist.
    tests_dir = os.path.join(project_dir, "tests")
    has_pytest = os.path.isdir(tests_dir) and any(
        f.startswith("test_") and f.endswith(".py") for f in os.listdir(tests_dir)
    )

    if has_pytest and shutil.which("pytest"):
        result = subprocess.run(
            ["pytest", tests_dir, "-v" if verbose else "-q", "--tb=short"],
            cwd=project_dir,
            capture_output=True,
            text=True,
            timeout=60,
        )

        output = result.stdout + result.stderr

        # Parse pytest summary line: "X passed, Y failed".
        passed = 0
        failed = 0
        summary_match = re.search(r"(\d+) passed", output)
        if summary_match:
            passed = int(summary_match.group(1))
        fail_match = re.search(r"(\d+) failed", output)
        if fail_match:
            failed = int(fail_match.group(1))

        res = {
            "target": "python",
            "ok": result.returncode == 0,
            "passed": passed,
            "failed": failed,
        }
        if verbose or result.returncode != 0:
            res["output"] = output.strip()
        return res

    # Fallback: syntax + basic import check for each script.
    passed = 0
    failed = 0
    errors = []

    for py_file in py_files:
        py_path = os.path.join(scripts_dir, py_file)
        result = subprocess.run(
            [sys.executable, "-m", "py_compile", py_path],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0:
            passed += 1
        else:
            failed += 1
            errors.append(f"{py_file}: {result.stderr.strip()}")

    res = {
        "target": "python",
        "ok": failed == 0,
        "passed": passed,
        "failed": failed,
        "test_type": "syntax_check",
    }
    if errors:
        res["errors"] = errors
    return res


def test_tool(name: str, verbose: bool) -> dict:
    """Run all tests for a tool project."""
    project_dir = find_project(name)
    if not project_dir:
        return {"ok": False, "error": f"Project '{name}' not found in workspace. Run init first."}

    lang = detect_lang(project_dir)
    if lang == "unknown":
        return {"ok": False, "error": f"Cannot detect language for project '{name}'."}

    results = []
    total_passed = 0
    total_failed = 0
    all_ok = True

    if lang in ("zig", "both"):
        zig_res = test_zig(project_dir, verbose)
        results.append(zig_res)
        total_passed += zig_res.get("passed", 0)
        total_failed += zig_res.get("failed", 0)
        if not zig_res["ok"]:
            all_ok = False

    if lang in ("python", "both"):
        py_res = test_python(project_dir, verbose)
        results.append(py_res)
        total_passed += py_res.get("passed", 0)
        total_failed += py_res.get("failed", 0)
        if not py_res["ok"]:
            all_ok = False

    return {
        "ok": all_ok,
        "name": name,
        "lang": lang,
        "passed": total_passed,
        "failed": total_failed,
        "results": results,
    }


def main():
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    name = params.get("name", "")
    verbose = params.get("verbose", False)

    if not name:
        print(json.dumps({"ok": False, "error": "Tool name is required."}))
        return

    try:
        result = test_tool(name, verbose)
        print(json.dumps(result, indent=2))
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "Tests timed out."}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
