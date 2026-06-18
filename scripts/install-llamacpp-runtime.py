#!/usr/bin/env python3
"""Install Fae's pinned llama.cpp runtime.

Downloads the locked llama.cpp release asset, verifies SHA-256 + size, extracts
`llama-server`, and installs it into a Fae-owned runtime directory. No PATH
lookup, Homebrew, or user-global install is required.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "scripts" / "llamacpp-runtime.lock.json"
DEFAULT_INSTALL = ROOT / "native" / "macos" / "Fae" / "Resources" / "LlamaCpp"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_extract_runtime(archive: Path, out_dir: Path) -> None:
    """Extract the release payload under out_dir, stripping the top directory.

    llama-server has @rpath dylib dependencies in the same directory, so copying
    only the executable is insufficient. Keep the whole release payload together.
    """
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            parts = Path(member.name).parts
            if len(parts) < 2:
                continue
            rel = Path(*parts[1:])
            if rel.is_absolute() or ".." in rel.parts:
                raise SystemExit(f"unsafe archive path: {member.name}")
            target = out_dir / rel
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            extracted = tar.extractfile(member)
            if extracted is None:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("wb") as f:
                shutil.copyfileobj(extracted, f)
            # Preserve executability for release tools/binaries.
            if member.mode & 0o111:
                target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def download(url: str, dest: Path) -> None:
    try:
        with urllib.request.urlopen(url, timeout=120) as r, dest.open("wb") as f:
            shutil.copyfileobj(r, f)
        return
    except (urllib.error.URLError, OSError) as err:
        print(f"python urllib download failed ({err}); retrying with curl", file=sys.stderr)
    subprocess.run(["/usr/bin/curl", "-fL", "--retry", "3", "--output", str(dest), url], check=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--install-dir", type=Path, default=DEFAULT_INSTALL,
                    help=f"install directory (default: {DEFAULT_INSTALL})")
    ap.add_argument("--lock", type=Path, default=LOCK)
    ap.add_argument("--force", action="store_true", help="redownload/reinstall even if binary exists")
    args = ap.parse_args()

    data = json.loads(args.lock.read_text())
    rt = data["runtime"]
    install_dir = args.install_dir.expanduser().resolve()
    binary = install_dir / rt["binary"]
    if binary.exists() and not args.force:
        print(f"✓ llama.cpp runtime already installed: {binary}")
        return 0

    install_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="fae-llamacpp-") as td:
        archive = Path(td) / rt["asset_name"]
        print(f"↓ Downloading {rt['url']}")
        download(rt["url"], archive)
        size = archive.stat().st_size
        if size != int(rt["size_bytes"]):
            raise SystemExit(f"size mismatch: expected {rt['size_bytes']}, got {size}")
        digest = sha256_file(archive)
        if digest != rt["sha256"]:
            raise SystemExit(f"sha256 mismatch: expected {rt['sha256']}, got {digest}")
        tmp_extract = Path(td) / "extract"
        tmp_extract.mkdir()
        safe_extract_runtime(archive, tmp_extract)
        tmp_install = install_dir.with_name(install_dir.name + ".tmp")
        if tmp_install.exists():
            shutil.rmtree(tmp_install)
        shutil.copytree(tmp_extract, tmp_install)
        if install_dir.exists():
            shutil.rmtree(install_dir)
        os.replace(tmp_install, install_dir)
        binary = install_dir / rt["binary"]
        if not binary.exists():
            raise SystemExit(f"installed runtime missing {binary}")
        expected_binary_size = rt.get("binary_size_bytes")
        if expected_binary_size is not None and binary.stat().st_size != int(expected_binary_size):
            raise SystemExit(
                f"binary size mismatch: expected {expected_binary_size}, got {binary.stat().st_size}"
            )
        expected_binary_sha = rt.get("binary_sha256")
        if expected_binary_sha is not None:
            binary_digest = sha256_file(binary)
            if binary_digest != expected_binary_sha:
                raise SystemExit(
                    f"binary sha256 mismatch: expected {expected_binary_sha}, got {binary_digest}"
                )
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"✓ Installed llama.cpp {rt['release_tag']} {rt['platform']} runtime: {install_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
