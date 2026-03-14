# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Install acpx — the ACP agent client.

Tries multiple installation methods in order:
1. Detect existing installation (npx acpx, bun x acpx, or PATH binary)
2. Install via bun (preferred — fast, self-contained)
3. Install via npm (fallback — requires Node.js)
4. Build standalone binary via bun build --compile (no runtime deps)
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ACPX_VERSION = "0.3.0"
FAE_BIN_DIR = Path.home() / ".local" / "bin"


def run(cmd: list[str], timeout: int = 120) -> tuple[int, str, str]:
    """Run a command and return (exit_code, stdout, stderr)."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except FileNotFoundError:
        return 127, "", f"Command not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"Command timed out after {timeout}s"


def find_existing() -> dict | None:
    """Check if acpx is already available."""
    # Check PATH
    acpx_path = shutil.which("acpx")
    if acpx_path:
        code, out, _ = run([acpx_path, "config", "show"])
        if code == 0:
            return {"method": "path", "path": acpx_path, "version": ACPX_VERSION}

    # Check npx
    npx_path = shutil.which("npx")
    if npx_path:
        code, out, _ = run([npx_path, "acpx", "config", "show"])
        if code == 0:
            return {"method": "npx", "path": f"{npx_path} acpx", "version": ACPX_VERSION}

    # Check bun x
    bun_path = shutil.which("bun") or str(Path.home() / ".bun" / "bin" / "bun")
    if Path(bun_path).exists():
        code, out, _ = run([bun_path, "x", "acpx", "config", "show"])
        if code == 0:
            return {"method": "bunx", "path": f"{bun_path} x acpx", "version": ACPX_VERSION}

    # Check ~/.local/bin/acpx (standalone binary)
    standalone = FAE_BIN_DIR / "acpx"
    if standalone.exists() and os.access(standalone, os.X_OK):
        code, _, _ = run([str(standalone), "config", "show"])
        if code == 0:
            return {"method": "standalone", "path": str(standalone), "version": ACPX_VERSION}

    return None


def install_via_bun() -> dict | None:
    """Install acpx globally via bun."""
    bun_path = shutil.which("bun") or str(Path.home() / ".bun" / "bin" / "bun")
    if not Path(bun_path).exists():
        return None

    code, out, err = run([bun_path, "install", "-g", f"acpx@{ACPX_VERSION}"])
    if code == 0:
        # Find where bun installed it
        acpx = shutil.which("acpx")
        if acpx:
            return {"method": "bun_global", "path": acpx, "version": ACPX_VERSION}
        # Check bun's global bin
        bun_bin = Path.home() / ".bun" / "bin" / "acpx"
        if bun_bin.exists():
            return {"method": "bun_global", "path": str(bun_bin), "version": ACPX_VERSION}
    return None


def install_via_npm() -> dict | None:
    """Install acpx globally via npm."""
    npm_path = shutil.which("npm")
    if not npm_path:
        return None

    code, out, err = run([npm_path, "install", "-g", f"acpx@{ACPX_VERSION}"])
    if code == 0:
        acpx = shutil.which("acpx")
        if acpx:
            return {"method": "npm_global", "path": acpx, "version": ACPX_VERSION}
    return None


def build_standalone() -> dict | None:
    """Build acpx as a standalone binary via bun build --compile."""
    bun_path = shutil.which("bun") or str(Path.home() / ".bun" / "bin" / "bun")
    if not Path(bun_path).exists():
        return None

    import tempfile
    tmpdir = tempfile.mkdtemp(prefix="fae-acpx-build-")
    try:
        # Download and extract
        code, _, err = run(["npm", "pack", f"acpx@{ACPX_VERSION}", "--silent"], timeout=60)
        if code != 0:
            return None

        tgz = next(Path(".").glob("acpx-*.tgz"), None)
        if not tgz:
            return None

        shutil.move(str(tgz), f"{tmpdir}/acpx.tgz")
        code, _, _ = run(["tar", "xzf", f"{tmpdir}/acpx.tgz", "-C", tmpdir])
        if code != 0:
            return None

        pkg_dir = f"{tmpdir}/package"

        # Install deps
        run(["npm", "install", "--production", "--ignore-scripts"], timeout=60)

        # Compile
        FAE_BIN_DIR.mkdir(parents=True, exist_ok=True)
        out_path = str(FAE_BIN_DIR / "acpx")
        code, out, err = run(
            [bun_path, "build", f"{pkg_dir}/dist/cli.js", "--compile",
             "--target=bun-darwin-arm64", f"--outfile={out_path}"],
            timeout=180
        )
        if code == 0 and Path(out_path).exists():
            os.chmod(out_path, 0o755)
            return {"method": "standalone", "path": out_path, "version": ACPX_VERSION}
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    return None


def main(args: dict) -> dict:
    """Install acpx if not already available.

    Args:
        args: {method?: "bun"|"npm"|"standalone"|"auto"}
    Returns:
        {status, installed, method, path, version, message}
    """
    preferred = args.get("method", "auto")

    # Step 1: Check existing
    existing = find_existing()
    if existing:
        return {
            "status": "ok",
            "installed": True,
            "already_installed": True,
            "method": existing["method"],
            "path": existing["path"],
            "version": existing["version"],
            "message": f"acpx already available via {existing['method']} at {existing['path']}",
        }

    # Step 2: Install
    result = None
    tried = []

    if preferred in ("auto", "bun"):
        tried.append("bun")
        result = install_via_bun()

    if not result and preferred in ("auto", "npm"):
        tried.append("npm")
        result = install_via_npm()

    if not result and preferred in ("auto", "standalone"):
        tried.append("standalone")
        result = build_standalone()

    if result:
        return {
            "status": "ok",
            "installed": True,
            "already_installed": False,
            "method": result["method"],
            "path": result["path"],
            "version": result["version"],
            "message": f"Installed acpx v{result['version']} via {result['method']}",
        }

    return {
        "status": "error",
        "installed": False,
        "tried": tried,
        "message": (
            "Could not install acpx. Tried: " + ", ".join(tried) + ". "
            "Install bun (curl -fsSL https://bun.sh/install | bash) or "
            "Node.js (https://nodejs.org) then try again."
        ),
    }


if __name__ == "__main__":
    raw = sys.argv[1] if len(sys.argv) > 1 else "{}"
    try:
        input_args = json.loads(raw)
    except json.JSONDecodeError:
        input_args = {"method": raw}
    print(json.dumps(main(input_args), indent=2))
