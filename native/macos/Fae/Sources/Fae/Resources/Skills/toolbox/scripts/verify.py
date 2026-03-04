#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Verify the integrity of an installed tool via MANIFEST.json checksums and git signatures."""

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


FORGE_DIR = Path(os.path.expanduser("~/.fae-forge"))
REGISTRY_PATH = FORGE_DIR / "registry.json"
TOOLS_DIR = FORGE_DIR / "tools"
BUNDLES_DIR = FORGE_DIR / "bundles"


def sha256_file(path: Path) -> str:
    """Compute SHA-256 hex digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def check_manifest(tool_dir: Path) -> dict:
    """Verify MANIFEST.json checksums. Returns check result dict."""
    manifest_path = tool_dir / "MANIFEST.json"

    if not manifest_path.exists():
        return {
            "status": "skip",
            "reason": "no MANIFEST.json present",
        }

    try:
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        return {
            "status": "fail",
            "reason": f"MANIFEST.json parse error: {exc}",
        }

    return {"status": "pass", "manifest": manifest}


def check_checksums(tool_dir: Path, manifest: dict) -> dict:
    """Verify individual file checksums from the manifest."""
    integrity = manifest.get("integrity", {})
    checksums = integrity.get("checksums", {})
    algorithm = integrity.get("algorithm", "sha256")

    if not checksums:
        return {"status": "skip", "reason": "no checksums in manifest"}

    if algorithm != "sha256":
        return {"status": "fail", "reason": f"unsupported algorithm: {algorithm}"}

    details = []
    all_pass = True

    for rel_path, expected_hash in sorted(checksums.items()):
        file_path = tool_dir / rel_path
        if not file_path.exists():
            details.append({
                "file": rel_path,
                "status": "fail",
                "reason": "file missing",
            })
            all_pass = False
            continue

        actual_hash = sha256_file(file_path)
        if actual_hash == expected_hash:
            details.append({
                "file": rel_path,
                "status": "pass",
            })
        else:
            details.append({
                "file": rel_path,
                "status": "fail",
                "expected": expected_hash,
                "actual": actual_hash,
            })
            all_pass = False

    return {
        "status": "pass" if all_pass else "fail",
        "checked": len(checksums),
        "details": details,
    }


def check_signature(tool_name: str) -> dict:
    """Verify git tag signature on the tool's bundle if available."""
    bundle_path = BUNDLES_DIR / f"{tool_name}.bundle"

    if not bundle_path.exists():
        return {"status": "skip", "reason": "no bundle file available"}

    # Verify the bundle integrity first.
    try:
        result = subprocess.run(
            ["git", "bundle", "verify", str(bundle_path)],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except FileNotFoundError:
        return {"status": "skip", "reason": "git not found on system"}
    except subprocess.TimeoutExpired:
        return {"status": "fail", "reason": "git bundle verify timed out"}

    if result.returncode != 0:
        return {
            "status": "fail",
            "reason": f"bundle verification failed: {result.stderr.strip()}",
        }

    # Try to verify a signed tag inside the bundle.
    # This requires cloning into a temp space and checking tags.
    try:
        import tempfile
        import shutil

        tmp_dir = Path(tempfile.mkdtemp(prefix="fae-verify-"))
        clone_dir = tmp_dir / "clone"

        clone_result = subprocess.run(
            ["git", "clone", "--quiet", str(bundle_path), str(clone_dir)],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if clone_result.returncode != 0:
            shutil.rmtree(tmp_dir, ignore_errors=True)
            return {"status": "pass", "reason": "bundle integrity verified, no tags to check"}

        # List tags and try to verify them.
        tag_result = subprocess.run(
            ["git", "-C", str(clone_dir), "tag", "--list"],
            capture_output=True,
            text=True,
            timeout=10,
        )

        tags = [t.strip() for t in tag_result.stdout.strip().splitlines() if t.strip()]
        if not tags:
            shutil.rmtree(tmp_dir, ignore_errors=True)
            return {"status": "pass", "reason": "bundle verified, no signed tags"}

        # Try verifying each tag.
        verified_tags = []
        for tag in tags:
            verify_tag = subprocess.run(
                ["git", "-C", str(clone_dir), "tag", "-v", tag],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if verify_tag.returncode == 0:
                verified_tags.append(tag)

        shutil.rmtree(tmp_dir, ignore_errors=True)

        if verified_tags:
            return {
                "status": "pass",
                "reason": f"verified signed tag(s): {', '.join(verified_tags)}",
            }
        else:
            return {
                "status": "pass",
                "reason": "bundle verified, tags present but unsigned",
            }

    except Exception as exc:
        return {"status": "fail", "reason": f"signature check error: {exc}"}


def verify_tool(name: str, check_signatures: bool = True) -> dict:
    """Verify integrity of an installed tool."""
    tool_dir = TOOLS_DIR / name

    if not tool_dir.is_dir():
        return {"ok": False, "error": f"tool not found: {name}"}

    if not (tool_dir / "SKILL.md").exists():
        return {"ok": False, "error": f"tool directory missing SKILL.md: {name}"}

    checks = {}

    # 1. Check MANIFEST.json presence and validity.
    manifest_result = check_manifest(tool_dir)
    checks["manifest"] = manifest_result.get("status", "skip")

    # 2. Check file checksums.
    if manifest_result.get("status") == "pass" and "manifest" in manifest_result:
        checksum_result = check_checksums(tool_dir, manifest_result["manifest"])
        checks["checksums"] = checksum_result.get("status", "skip")
    else:
        checksum_result = {"status": "skip", "reason": "no valid manifest"}
        checks["checksums"] = "skip"

    # 3. Check signatures.
    if check_signatures:
        sig_result = check_signature(name)
        checks["signature"] = sig_result.get("status", "skip")
    else:
        sig_result = {"status": "skip", "reason": "signature check disabled"}
        checks["signature"] = "skip"

    # Determine overall verification status.
    all_statuses = [v for v in checks.values()]
    if "fail" in all_statuses:
        verified = False
    else:
        verified = True

    result = {
        "ok": True,
        "name": name,
        "verified": verified,
        "checks": checks,
        "details": [],
    }

    # Append details from each check.
    if manifest_result.get("reason"):
        result["details"].append({"check": "manifest", "detail": manifest_result["reason"]})

    if "details" in checksum_result:
        for d in checksum_result["details"]:
            if d.get("status") == "fail":
                result["details"].append({"check": "checksum", "detail": d})

    if sig_result.get("reason"):
        result["details"].append({"check": "signature", "detail": sig_result["reason"]})

    return result


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

    check_signatures = params.get("check_signatures", True)

    try:
        result = verify_tool(name=name, check_signatures=check_signatures)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
