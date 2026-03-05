#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Release a Forge tool: build release, package as skill, git tag, create bundle, update registry."""

import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys


FORGE_BASE = os.path.expanduser("~/.fae-forge")
WORKSPACE = os.path.join(FORGE_BASE, "workspace")
TOOLS_DIR = os.path.join(FORGE_BASE, "tools")
BUNDLES_DIR = os.path.join(FORGE_BASE, "bundles")
REGISTRY_PATH = os.path.join(FORGE_BASE, "registry.json")
FAE_SKILLS_DIR = os.path.expanduser("~/Library/Application Support/fae/skills")


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


def validate_version(version: str) -> str | None:
    """Return error message if version is invalid, else None."""
    if not re.match(r"^\d+\.\d+\.\d+$", version):
        return f"Invalid semver: {version!r}. Use format like '1.0.0'."
    return None


def sha256_file(path: str) -> str:
    """Compute SHA-256 hex digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def write_file(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)


def copy_file(src: str, dst: str) -> None:
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)


def activate_for_fae(name: str, tool_dir: str) -> dict:
    """Expose the released forge tool as a live Fae skill."""
    os.makedirs(FAE_SKILLS_DIR, exist_ok=True)
    live_path = os.path.join(FAE_SKILLS_DIR, name)

    if os.path.lexists(live_path):
        marker = os.path.join(live_path, ".forge-installed")
        if os.path.islink(live_path):
            os.unlink(live_path)
        elif os.path.isdir(live_path) and os.path.exists(marker):
            shutil.rmtree(live_path, ignore_errors=True)
        else:
            return {
                "activated": False,
                "activation_error": f"existing skill at {live_path} is not forge-managed",
            }

    try:
        os.symlink(tool_dir, live_path)
        return {"activated": True, "activation_mode": "symlink", "live_path": live_path}
    except OSError:
        shutil.copytree(tool_dir, live_path, dirs_exist_ok=True)
        with open(os.path.join(live_path, ".forge-installed"), "w") as f:
            f.write(tool_dir + "\n")
        return {"activated": True, "activation_mode": "copied", "live_path": live_path}


# ---------------------------------------------------------------------------
# Build release binaries
# ---------------------------------------------------------------------------

def build_release_zig_native(project_dir: str, name: str) -> dict:
    """Build native release binary. Returns artifact info."""
    result = subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseFast"],
        cwd=project_dir,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        return {"ok": False, "target": "arm64", "error": result.stderr.strip() or result.stdout.strip()}

    binary_path = os.path.join(project_dir, "zig-out", "bin", name)
    if not os.path.exists(binary_path):
        return {"ok": False, "target": "arm64", "error": f"Binary not found at {binary_path}"}

    return {
        "ok": True,
        "target": "arm64",
        "path": binary_path,
        "size_bytes": os.path.getsize(binary_path),
    }


def build_release_zig_wasm(project_dir: str, name: str) -> dict:
    """Build WASM release binary. Returns artifact info."""
    result = subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseFast", "-Dtarget=wasm32-wasi"],
        cwd=project_dir,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        return {"ok": False, "target": "wasm32-wasi", "error": result.stderr.strip() or result.stdout.strip()}

    wasm_path = os.path.join(project_dir, "zig-out", "bin", name)
    wasm_ext_path = wasm_path + ".wasm"
    actual_path = wasm_ext_path if os.path.exists(wasm_ext_path) else wasm_path

    if not os.path.exists(actual_path):
        return {"ok": False, "target": "wasm32-wasi", "error": f"WASM binary not found at {actual_path}"}

    return {
        "ok": True,
        "target": "wasm32-wasi",
        "path": actual_path,
        "size_bytes": os.path.getsize(actual_path),
    }


# ---------------------------------------------------------------------------
# Run.py wrapper template
# ---------------------------------------------------------------------------

def run_py_wrapper(name: str, has_native: bool, has_wasm: bool, has_python: bool) -> str:
    """Generate run.py wrapper that picks the right binary/script."""
    safe_name = name.replace("-", "_")
    return f"""\
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
\"\"\"Runner wrapper for {name}. Selects the best execution method available.\"\"\"

import json
import os
import platform
import shutil
import subprocess
import sys


SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
BIN_DIR = os.path.join(SKILL_DIR, "bin")


def find_native_binary() -> str | None:
    \"\"\"Find the native binary for the current platform.\"\"\"
    machine = platform.machine().lower()
    candidates = []
    if machine in ("arm64", "aarch64"):
        candidates.append(os.path.join(BIN_DIR, "{name}-arm64"))
    candidates.append(os.path.join(BIN_DIR, "{name}-x86_64"))
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def find_wasm_binary() -> str | None:
    \"\"\"Find the WASM binary and wasmtime runtime.\"\"\"
    wasm_path = os.path.join(BIN_DIR, "{name}.wasm")
    if os.path.isfile(wasm_path) and shutil.which("wasmtime"):
        return wasm_path
    return None


def find_python_script() -> str | None:
    \"\"\"Find the Python script.\"\"\"
    scripts_dir = os.path.join(SKILL_DIR, "scripts")
    script_path = os.path.join(scripts_dir, "{safe_name}.py")
    if os.path.isfile(script_path):
        return script_path
    return None


def run_binary(binary_path: str, stdin_data: str) -> str:
    \"\"\"Run a native binary with stdin piped.\"\"\"
    result = subprocess.run(
        [binary_path],
        input=stdin_data,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        return json.dumps({{"ok": False, "error": result.stderr.strip() or f"Exit code {{result.returncode}}"}})
    return result.stdout


def run_wasm(wasm_path: str, stdin_data: str) -> str:
    \"\"\"Run a WASM binary via wasmtime with stdin piped.\"\"\"
    result = subprocess.run(
        ["wasmtime", wasm_path],
        input=stdin_data,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        return json.dumps({{"ok": False, "error": result.stderr.strip() or f"Exit code {{result.returncode}}"}})
    return result.stdout


def run_python(script_path: str, stdin_data: str) -> str:
    \"\"\"Run a Python script with stdin piped.\"\"\"
    result = subprocess.run(
        [sys.executable, script_path],
        input=stdin_data,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        return json.dumps({{"ok": False, "error": result.stderr.strip() or f"Exit code {{result.returncode}}"}})
    return result.stdout


def main():
    stdin_data = sys.stdin.read()

    # Try native binary first (fastest).
    native = find_native_binary()
    if native:
        print(run_binary(native, stdin_data), end="")
        return

    # Try WASM via wasmtime (portable).
    wasm = find_wasm_binary()
    if wasm:
        print(run_wasm(wasm, stdin_data), end="")
        return

    # Try Python script (most compatible).
    script = find_python_script()
    if script:
        print(run_python(script, stdin_data), end="")
        return

    print(json.dumps({{"ok": False, "error": "No executable found for {name}. Check bin/ or scripts/ directory."}}))


if __name__ == "__main__":
    main()
"""


# ---------------------------------------------------------------------------
# Packaging
# ---------------------------------------------------------------------------

def read_skill_description(project_dir: str) -> str:
    """Read description from SKILL.md frontmatter."""
    skill_path = os.path.join(project_dir, "SKILL.md")
    if not os.path.exists(skill_path):
        return "A custom Fae tool"
    with open(skill_path) as f:
        content = f.read()
    match = re.search(r"^description:\s*(.+)$", content, re.MULTILINE)
    return match.group(1).strip() if match else "A custom Fae tool"


def update_skill_md_version(project_dir: str, version: str) -> None:
    """Update version in SKILL.md frontmatter."""
    skill_path = os.path.join(project_dir, "SKILL.md")
    if not os.path.exists(skill_path):
        return
    with open(skill_path) as f:
        content = f.read()
    updated = re.sub(
        r'(version:\s*")[^"]*(")',
        f'\\g<1>{version}\\g<2>',
        content,
    )
    with open(skill_path, "w") as f:
        f.write(updated)


def package_tool(
    project_dir: str,
    name: str,
    version: str,
    lang: str,
    native_artifact: dict | None,
    wasm_artifact: dict | None,
) -> str:
    """Package tool into ~/.fae-forge/tools/{name}/. Returns tool dir path."""
    tool_dir = os.path.join(TOOLS_DIR, name)

    # Clean previous release.
    if os.path.exists(tool_dir):
        shutil.rmtree(tool_dir)
    os.makedirs(tool_dir, exist_ok=True)

    # Copy SKILL.md.
    skill_src = os.path.join(project_dir, "SKILL.md")
    if os.path.exists(skill_src):
        copy_file(skill_src, os.path.join(tool_dir, "SKILL.md"))

    has_native = False
    has_wasm = False
    has_python = False

    # Copy binaries.
    if native_artifact and native_artifact.get("ok"):
        bin_dir = os.path.join(tool_dir, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        dst = os.path.join(bin_dir, f"{name}-arm64")
        copy_file(native_artifact["path"], dst)
        os.chmod(dst, 0o755)
        has_native = True

    if wasm_artifact and wasm_artifact.get("ok"):
        bin_dir = os.path.join(tool_dir, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        dst = os.path.join(bin_dir, f"{name}.wasm")
        copy_file(wasm_artifact["path"], dst)
        has_wasm = True

    # Copy Python scripts.
    scripts_src = os.path.join(project_dir, "scripts")
    if os.path.isdir(scripts_src):
        scripts_dst = os.path.join(tool_dir, "scripts")
        shutil.copytree(scripts_src, scripts_dst, dirs_exist_ok=True)
        has_python = True

    # Write run.py wrapper.
    run_py_path = os.path.join(tool_dir, "scripts", "run.py")
    write_file(run_py_path, run_py_wrapper(name, has_native, has_wasm, has_python))
    os.chmod(run_py_path, 0o755)

    # Generate MANIFEST.json with integrity checksums.
    checksums = {}
    for root, _dirs, files in os.walk(tool_dir):
        for fname in files:
            fpath = os.path.join(root, fname)
            relpath = os.path.relpath(fpath, tool_dir)
            if relpath == "MANIFEST.json":
                continue
            checksums[relpath] = sha256_file(fpath)

    capabilities = ["execute"]
    allowed_tools = ["run_skill"]
    risk_tier = "medium"

    if has_native or has_wasm:
        allowed_tools.append("bash")
        risk_tier = "high"

    manifest = {
        "schemaVersion": 1,
        "capabilities": capabilities,
        "allowedTools": allowed_tools,
        "allowedDomains": [],
        "dataClasses": ["local_files"],
        "riskTier": risk_tier,
        "timeoutSeconds": 60,
        "integrity": {
            "algorithm": "sha256",
            "checksums": checksums,
            "signature": None,
        },
    }

    manifest_path = os.path.join(tool_dir, "MANIFEST.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    return tool_dir


# ---------------------------------------------------------------------------
# Git operations
# ---------------------------------------------------------------------------

def git_commit_and_tag(project_dir: str, name: str, version: str, sign: bool) -> dict:
    """Commit changes, create tag, create bundle. Returns status dict."""
    git_env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Fae Forge",
        "GIT_COMMITTER_NAME": "Fae Forge",
        "GIT_AUTHOR_EMAIL": "forge@fae.local",
        "GIT_COMMITTER_EMAIL": "forge@fae.local",
    }

    results = {"commit": False, "tag": False, "bundle": False}

    # Stage all changes.
    subprocess.run(
        ["git", "add", "-A"],
        cwd=project_dir,
        capture_output=True,
        check=True,
        env=git_env,
    )

    # Commit.
    commit_result = subprocess.run(
        ["git", "commit", "-m", f"Release v{version}"],
        cwd=project_dir,
        capture_output=True,
        text=True,
        env=git_env,
    )
    results["commit"] = commit_result.returncode == 0

    # Tag.
    tag_cmd = ["git", "tag"]
    if sign:
        tag_cmd.append("-s")
    tag_cmd.extend([f"v{version}", "-m", f"Release v{version}"])

    tag_result = subprocess.run(
        tag_cmd,
        cwd=project_dir,
        capture_output=True,
        text=True,
        env=git_env,
    )
    results["tag"] = tag_result.returncode == 0
    if not results["tag"]:
        # If signing fails, try unsigned.
        if sign:
            tag_cmd_unsigned = ["git", "tag", f"v{version}", "-m", f"Release v{version}"]
            tag_result = subprocess.run(
                tag_cmd_unsigned,
                cwd=project_dir,
                capture_output=True,
                text=True,
                env=git_env,
            )
            results["tag"] = tag_result.returncode == 0
            if results["tag"]:
                results["tag_signed"] = False

    # Create bundle.
    os.makedirs(BUNDLES_DIR, exist_ok=True)
    bundle_name = f"{name}-v{version}.bundle"
    bundle_path = os.path.join(BUNDLES_DIR, bundle_name)

    bundle_result = subprocess.run(
        ["git", "bundle", "create", bundle_path, f"v{version}"],
        cwd=project_dir,
        capture_output=True,
        text=True,
        env=git_env,
    )

    if bundle_result.returncode != 0:
        # Fallback: bundle HEAD.
        bundle_result = subprocess.run(
            ["git", "bundle", "create", bundle_path, "HEAD"],
            cwd=project_dir,
            capture_output=True,
            text=True,
            env=git_env,
        )

    results["bundle"] = bundle_result.returncode == 0
    results["bundle_path"] = bundle_path if results["bundle"] else None
    results["bundle_sha256"] = sha256_file(bundle_path) if results["bundle"] and os.path.exists(bundle_path) else None

    return results


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

def update_registry(name: str, version: str, description: str, lang: str, tool_dir: str, bundle_info: dict) -> None:
    """Update ~/.fae-forge/registry.json with tool metadata."""
    registry = {}
    if os.path.exists(REGISTRY_PATH):
        try:
            with open(REGISTRY_PATH) as f:
                registry = json.load(f)
        except (json.JSONDecodeError, OSError):
            registry = {}

    if "tools" not in registry:
        registry["tools"] = {}

    registry["tools"][name] = {
        "name": name,
        "version": version,
        "description": description,
        "lang": lang,
        "installed_at": tool_dir,
        "bundle": bundle_info.get("bundle_path"),
        "bundle_sha256": bundle_info.get("bundle_sha256"),
        "released_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }

    os.makedirs(os.path.dirname(REGISTRY_PATH), exist_ok=True)
    with open(REGISTRY_PATH, "w") as f:
        json.dump(registry, f, indent=2)
        f.write("\n")


# ---------------------------------------------------------------------------
# Main release flow
# ---------------------------------------------------------------------------

def release_tool(name: str, version: str, sign: bool) -> dict:
    """Full release pipeline for a tool."""
    project_dir = find_project(name)
    if not project_dir:
        return {"ok": False, "error": f"Project '{name}' not found in workspace. Run init first."}

    err = validate_version(version)
    if err:
        return {"ok": False, "error": err}

    lang = detect_lang(project_dir)
    if lang == "unknown":
        return {"ok": False, "error": f"Cannot detect language for project '{name}'."}

    # Update SKILL.md version.
    update_skill_md_version(project_dir, version)

    # Build release binaries.
    native_artifact = None
    wasm_artifact = None
    build_errors = []

    if lang in ("zig", "both"):
        if not shutil.which("zig"):
            return {"ok": False, "error": "Zig compiler not found. Install with: zb install zig"}

        native_artifact = build_release_zig_native(project_dir, name)
        if not native_artifact["ok"]:
            build_errors.append(f"Native build failed: {native_artifact.get('error', 'unknown')}")

        wasm_artifact = build_release_zig_wasm(project_dir, name)
        if not wasm_artifact["ok"]:
            # WASM failure is non-fatal -- log but continue.
            wasm_artifact = None

    if lang in ("python", "both"):
        # Syntax check Python scripts.
        scripts_dir = os.path.join(project_dir, "scripts")
        if os.path.isdir(scripts_dir):
            for py_file in os.listdir(scripts_dir):
                if not py_file.endswith(".py"):
                    continue
                py_path = os.path.join(scripts_dir, py_file)
                result = subprocess.run(
                    [sys.executable, "-m", "py_compile", py_path],
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                if result.returncode != 0:
                    build_errors.append(f"Python syntax error in {py_file}: {result.stderr.strip()}")

    if build_errors and lang in ("zig",):
        # For pure Zig projects, native build failure is fatal.
        return {"ok": False, "error": "Release build failed.", "details": build_errors}

    # Read description for registry.
    description = read_skill_description(project_dir)

    # Package into tools directory.
    tool_dir = package_tool(project_dir, name, version, lang, native_artifact, wasm_artifact)

    # Git commit, tag, and bundle.
    git_info = {"commit": False, "tag": False, "bundle": False, "bundle_path": None, "bundle_sha256": None}
    try:
        git_info = git_commit_and_tag(project_dir, name, version, sign)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        git_info["error"] = str(e)

    # Update registry.
    try:
        update_registry(name, version, description, lang, tool_dir, git_info)
    except Exception as e:
        git_info["registry_error"] = str(e)

    activation = activate_for_fae(name, tool_dir)

    result = {
        "ok": True,
        "name": name,
        "version": version,
        "lang": lang,
        "installed_at": tool_dir,
        "bundle": git_info.get("bundle_path"),
        "bundle_sha256": git_info.get("bundle_sha256"),
        "git": {
            "commit": git_info.get("commit", False),
            "tag": git_info.get("tag", False),
            "bundle_created": git_info.get("bundle", False),
        },
        "message": f"Tool '{name}' v{version} released and installed at {tool_dir}.",
    }
    result.update(activation)
    return result


def main():
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    name = params.get("name", "")
    version = params.get("version", "")
    sign = params.get("sign", True)

    if not name:
        print(json.dumps({"ok": False, "error": "Tool name is required."}))
        return
    if not version:
        print(json.dumps({"ok": False, "error": "Version is required (e.g., '1.0.0')."}))
        return

    try:
        result = release_tool(name, version, sign)
        print(json.dumps(result, indent=2))
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": "Release build timed out after 120 seconds."}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
