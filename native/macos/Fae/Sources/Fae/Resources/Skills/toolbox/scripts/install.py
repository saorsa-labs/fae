#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Install a tool from a git bundle, directory, or archive into the Fae forge."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


FORGE_DIR = Path(os.path.expanduser("~/.fae-forge"))
REGISTRY_PATH = FORGE_DIR / "registry.json"
TOOLS_DIR = FORGE_DIR / "tools"
BUNDLES_DIR = FORGE_DIR / "bundles"
FAE_SKILLS_DIR = Path(os.path.expanduser("~/Library/Application Support/fae/skills"))

# Files that constitute a valid skill layout.
SKILL_MARKER = "SKILL.md"


def load_registry() -> dict:
    """Load registry, creating default structure if missing."""
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
        # Clean up temp file on failure.
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


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


def sha256_dir(path: Path) -> str:
    """Compute a combined SHA-256 for all files in a directory (sorted, deterministic)."""
    h = hashlib.sha256()
    for file_path in sorted(path.rglob("*")):
        if file_path.is_file():
            rel = file_path.relative_to(path)
            h.update(str(rel).encode("utf-8"))
            h.update(sha256_file(file_path).encode("utf-8"))
    return h.hexdigest()


def detect_lang(tool_dir: Path) -> str:
    """Detect primary language of a tool from its contents."""
    scripts_dir = tool_dir / "scripts"
    bin_dir = tool_dir / "bin"

    if scripts_dir.is_dir() and any(scripts_dir.glob("*.py")):
        return "python"
    if bin_dir.is_dir() and any(bin_dir.iterdir()):
        return "binary"
    return "instruction"


def parse_skill_md(skill_md_path: Path) -> dict:
    """Extract YAML frontmatter fields from a SKILL.md file."""
    try:
        text = skill_md_path.read_text(encoding="utf-8")
    except OSError:
        return {}

    # Simple YAML frontmatter parser (between --- delimiters).
    if not text.startswith("---"):
        return {}

    end = text.find("---", 3)
    if end < 0:
        return {}

    frontmatter = text[3:end].strip()
    result = {}
    for line in frontmatter.splitlines():
        line = line.strip()
        if ":" in line and not line.startswith("#"):
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key in ("name", "description", "version"):
                result[key] = val
    return result


def verify_manifest(tool_dir: Path) -> list[str]:
    """Verify MANIFEST.json checksums if present. Returns list of issues."""
    manifest_path = tool_dir / "MANIFEST.json"
    if not manifest_path.exists():
        return []

    try:
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        return [f"MANIFEST.json parse error: {exc}"]

    integrity = manifest.get("integrity", {})
    checksums = integrity.get("checksums", {})
    algorithm = integrity.get("algorithm", "sha256")

    if algorithm != "sha256":
        return [f"unsupported hash algorithm: {algorithm}"]

    issues = []
    for rel_path, expected_hash in checksums.items():
        file_path = tool_dir / rel_path
        if not file_path.exists():
            issues.append(f"missing file: {rel_path}")
            continue
        actual_hash = sha256_file(file_path)
        if actual_hash != expected_hash:
            issues.append(
                f"checksum mismatch: {rel_path} "
                f"(expected {expected_hash[:12]}..., got {actual_hash[:12]}...)"
            )

    return issues


def install_from_bundle(bundle_path: Path, dest_dir: Path) -> Path:
    """Clone a git bundle into a temporary directory, return the cloned path."""
    # Verify the bundle first.
    result = subprocess.run(
        ["git", "bundle", "verify", str(bundle_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip()
        raise ValueError(f"git bundle verify failed: {stderr}")

    # Clone the bundle into a temp directory.
    tmp_dir = Path(tempfile.mkdtemp(prefix="fae-forge-"))
    clone_dir = tmp_dir / "clone"
    result = subprocess.run(
        ["git", "clone", str(bundle_path), str(clone_dir)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        stderr = result.stderr.strip()
        raise ValueError(f"git clone failed: {stderr}")

    return clone_dir


def copy_skill_layout(src: Path, dest: Path) -> None:
    """Copy skill-relevant files from src to dest, excluding .git."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True)

    for item in src.iterdir():
        if item.name == ".git":
            continue
        dst_item = dest / item.name
        if item.is_dir():
            shutil.copytree(item, dst_item, dirs_exist_ok=True)
        else:
            shutil.copy2(item, dst_item)


def activate_for_fae(name: str, tool_dir: Path) -> dict:
    """Expose an installed forge tool as a live Fae skill."""
    FAE_SKILLS_DIR.mkdir(parents=True, exist_ok=True)
    live_path = FAE_SKILLS_DIR / name

    if live_path.exists() or live_path.is_symlink():
        if live_path.is_symlink() or (live_path / ".forge-installed").exists():
            if live_path.is_dir() and not live_path.is_symlink():
                shutil.rmtree(live_path, ignore_errors=True)
            else:
                live_path.unlink(missing_ok=True)
        else:
            return {
                "activated": False,
                "activation_error": f"existing skill at {live_path} is not forge-managed",
            }

    try:
        live_path.symlink_to(tool_dir, target_is_directory=True)
        return {"activated": True, "activation_mode": "symlink", "live_path": str(live_path)}
    except OSError:
        shutil.copytree(tool_dir, live_path, dirs_exist_ok=True)
        (live_path / ".forge-installed").write_text(f"{tool_dir}\n", encoding="utf-8")
        return {"activated": True, "activation_mode": "copied", "live_path": str(live_path)}


def install_tool(
    source: str,
    name: str | None = None,
    verify: bool = True,
    force: bool = False,
) -> dict:
    """Install a tool from a bundle or directory."""
    source_path = Path(os.path.expanduser(source)).resolve()
    tmp_clone = None

    try:
        if not source_path.exists():
            return {"ok": False, "error": f"source not found: {source}"}

        # Determine the source directory.
        if source_path.is_file() and source_path.suffix == ".bundle":
            tmp_clone = install_from_bundle(source_path, TOOLS_DIR)
            src_dir = tmp_clone
        elif source_path.is_dir():
            src_dir = source_path
        else:
            return {"ok": False, "error": f"source must be a .bundle file or directory: {source}"}

        # Validate the source has a SKILL.md.
        if not (src_dir / SKILL_MARKER).exists():
            return {"ok": False, "error": f"no SKILL.md found in source: {src_dir}"}

        # Determine tool name.
        if name is None:
            meta = parse_skill_md(src_dir / SKILL_MARKER)
            name = meta.get("name", src_dir.name)

        # Sanitize name (alphanumeric, hyphens, underscores only).
        safe_name = "".join(
            c if c.isalnum() or c in "-_" else "-" for c in name.lower()
        ).strip("-")
        if not safe_name:
            return {"ok": False, "error": f"invalid tool name derived from: {name}"}

        # Check for existing installation.
        dest_dir = TOOLS_DIR / safe_name
        if dest_dir.exists() and not force:
            return {
                "ok": False,
                "error": f"tool '{safe_name}' already installed. Use force=true to overwrite.",
            }

        # Create forge directories.
        TOOLS_DIR.mkdir(parents=True, exist_ok=True)
        BUNDLES_DIR.mkdir(parents=True, exist_ok=True)

        # Copy the bundle file to bundles/ for resharing.
        if source_path.is_file() and source_path.suffix == ".bundle":
            bundle_dest = BUNDLES_DIR / f"{safe_name}.bundle"
            shutil.copy2(source_path, bundle_dest)

        # Copy skill layout to tools/.
        copy_skill_layout(src_dir, dest_dir)

        # Verify checksums if requested.
        verification_issues = []
        if verify:
            verification_issues = verify_manifest(dest_dir)

        # Parse metadata from installed SKILL.md.
        meta = parse_skill_md(dest_dir / SKILL_MARKER)

        # Compute directory hash.
        dir_hash = sha256_dir(dest_dir)

        # Determine source type.
        if source_path.suffix == ".bundle":
            source_type = "local"
        elif "peer" in str(source_path).lower():
            source_type = "peer"
        else:
            source_type = "manual"

        # Update registry.
        registry = load_registry()
        registry["tools"][safe_name] = {
            "name": safe_name,
            "version": meta.get("version", "0.1"),
            "description": meta.get("description", ""),
            "lang": detect_lang(dest_dir),
            "sha256": dir_hash,
            "installed": datetime.now(timezone.utc).isoformat(),
            "source": source_type,
            "path": str(dest_dir),
            "original_source": str(source_path),
        }
        save_registry(registry)

        activation = activate_for_fae(safe_name, dest_dir)

        result = {
            "ok": True,
            "name": safe_name,
            "version": meta.get("version", "0.1"),
            "installed_at": str(dest_dir),
        }
        result.update(activation)

        if verification_issues:
            result["verification_warnings"] = verification_issues

        return result

    finally:
        # Clean up temp clone directory.
        if tmp_clone is not None:
            parent = tmp_clone.parent
            shutil.rmtree(parent, ignore_errors=True)


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
    source = params.get("source", "")
    if not source:
        print(json.dumps({"ok": False, "error": "source parameter is required"}))
        return 1

    try:
        result = install_tool(
            source=source,
            name=params.get("name"),
            verify=params.get("verify", True),
            force=params.get("force", False),
        )
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if result.get("ok") else 1
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
