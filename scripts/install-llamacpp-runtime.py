#!/usr/bin/env python3
"""Install Fae's pinned llama.cpp runtime.

Downloads the locked llama.cpp release asset for the current (or requested)
platform, verifies archive SHA-256 + size, extracts `llama-server` plus its
sibling shared libraries, verifies the extracted binary SHA-256 + size, and
installs the runtime into a Fae-owned directory. No PATH lookup, Homebrew, or
user-global install is required.

The runtime lock (`scripts/llamacpp-runtime.lock.json`) carries one entry per
platform under `runtimes` (keys: `macos-arm64`, `linux-x86_64`, `linux-aarch64`).
A legacy top-level `runtime` object (macOS arm64) is still honoured for
backward compatibility.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform as _platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "scripts" / "llamacpp-runtime.lock.json"
# macOS keeps its existing in-bundle resource path so the macOS recipes are
# unchanged. Linux installs land next to the package staging dir by default;
# packaging always passes an explicit --install-dir.
MACOS_INSTALL = ROOT / "native" / "macos" / "Fae" / "Resources" / "LlamaCpp"
LINUX_INSTALL = ROOT / "build" / "linux" / "LlamaCpp"


def detect_platform() -> str:
    """Map the host OS+arch onto a runtime-lock platform key."""
    system = sys.platform
    machine = _platform.machine().lower()
    if system == "darwin":
        if machine in ("arm64", "aarch64"):
            return "macos-arm64"
        raise SystemExit(f"unsupported macOS architecture: {machine} (only arm64)")
    if system.startswith("linux"):
        if machine in ("x86_64", "amd64"):
            return "linux-x86_64"
        if machine in ("aarch64", "arm64"):
            return "linux-aarch64"
        raise SystemExit(f"unsupported Linux architecture: {machine}")
    raise SystemExit(f"unsupported platform: {system}")


def default_install_dir(platform_key: str) -> Path:
    return MACOS_INSTALL if platform_key.startswith("macos") else LINUX_INSTALL


def select_runtime(data: dict, platform_key: str) -> dict:
    runtimes = data.get("runtimes")
    if isinstance(runtimes, dict) and platform_key in runtimes:
        return runtimes[platform_key]
    # Backward compatibility: a schema-v1 lock only has the top-level macOS entry.
    legacy = data.get("runtime")
    if legacy is not None and legacy.get("platform") == platform_key:
        return legacy
    available = sorted((runtimes or {}).keys())
    raise SystemExit(
        f"no runtime entry for platform {platform_key}; available: {available or ['(legacy runtime only)']}"
    )


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _safe_target(out_dir: Path, member_name: str) -> Path | None:
    """Resolve an archive member to a path under out_dir, stripping the top dir.

    Returns None for members that have no payload below the top directory
    (the bare top-level directory entry). Raises on path traversal.
    """
    parts = Path(member_name).parts
    if len(parts) < 2:
        return None
    rel = Path(*parts[1:])
    if rel.is_absolute() or ".." in rel.parts:
        raise SystemExit(f"unsafe archive path: {member_name}")
    return out_dir / rel


def extract_tar(archive: Path, out_dir: Path) -> None:
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            target = _safe_target(out_dir, member.name)
            if target is None:
                continue
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            extracted = tar.extractfile(member)
            if extracted is None:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("wb") as f:
                shutil.copyfileobj(extracted, f)
            if member.mode & 0o111:
                target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def extract_zip(archive: Path, out_dir: Path) -> None:
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            target = _safe_target(out_dir, info.filename)
            if target is None:
                continue
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, target.open("wb") as f:
                shutil.copyfileobj(src, f)
            # Preserve the executable bit recorded in the zip's external attrs.
            mode = (info.external_attr >> 16) & 0o7777
            if mode & 0o111:
                target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def safe_extract_runtime(archive: Path, out_dir: Path, archive_format: str) -> None:
    """Extract the release payload under out_dir, stripping the top directory.

    llama-server has @rpath / RUNPATH shared-library dependencies in the same
    directory, so copying only the executable is insufficient. Keep the whole
    release payload together.
    """
    if archive_format == "zip":
        extract_zip(archive, out_dir)
    else:
        extract_tar(archive, out_dir)


def download(url: str, dest: Path) -> None:
    try:
        with urllib.request.urlopen(url, timeout=120) as r, dest.open("wb") as f:
            shutil.copyfileobj(r, f)
        return
    except (urllib.error.URLError, OSError) as err:
        print(f"python urllib download failed ({err}); retrying with curl", file=sys.stderr)
    curl = shutil.which("curl") or "/usr/bin/curl"
    subprocess.run([curl, "-fL", "--retry", "3", "--output", str(dest), url], check=True)


def archive_format_of(rt: dict) -> str:
    fmt = rt.get("archive_format")
    if fmt:
        return fmt
    name = rt.get("asset_name", "")
    return "zip" if name.endswith(".zip") else "tar.gz"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", help="runtime platform key (default: auto-detect from host)")
    ap.add_argument("--install-dir", type=Path, default=None,
                    help="install directory (default: platform-specific)")
    ap.add_argument("--lock", type=Path, default=LOCK)
    ap.add_argument("--force", action="store_true", help="redownload/reinstall even if binary exists")
    args = ap.parse_args()

    data = json.loads(args.lock.read_text())
    platform_key = args.platform or detect_platform()
    rt = select_runtime(data, platform_key)
    archive_format = archive_format_of(rt)

    install_dir = (args.install_dir or default_install_dir(platform_key)).expanduser().resolve()
    binary = install_dir / rt["binary"]
    if binary.exists() and not args.force:
        # A cached binary must still be verified against the lock before we trust
        # it — skipping verification would let a tampered/corrupt binary be
        # trusted forever. Only the DOWNLOAD is skipped, never the SHA check.
        expected_binary_sha = rt.get("binary_sha256")
        if expected_binary_sha is None:
            print(f"✓ llama.cpp runtime already installed: {binary}")
            return 0
        binary_digest = sha256_file(binary)
        if binary_digest == expected_binary_sha:
            print(f"✓ llama.cpp runtime already installed (sha256 verified): {binary}")
            return 0
        print(
            f"⚠ cached binary sha256 mismatch: expected {expected_binary_sha}, "
            f"got {binary_digest} — re-downloading"
        )

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
        print(f"✓ archive sha256 verified: {digest}")
        tmp_extract = Path(td) / "extract"
        tmp_extract.mkdir()
        safe_extract_runtime(archive, tmp_extract, archive_format)
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
            print(f"✓ binary sha256 verified: {binary_digest}")
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"✓ Installed llama.cpp {rt['release_tag']} {rt['platform']} runtime: {install_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
