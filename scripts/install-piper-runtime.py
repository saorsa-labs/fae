#!/usr/bin/env python3
"""Install Fae's pinned Piper TTS runtime (Linux only).

Downloads the locked rhasspy/piper release tarball for the current (or
requested) Linux platform, verifies archive SHA-256 + size, extracts the
`piper` executable plus its sibling shared libraries (ONNX Runtime, espeak-ng),
verifies the extracted binary SHA-256 + size, then downloads + SHA-verifies the
pinned voice model (`.onnx` + `.onnx.json`) into a `voices/` subdir.

This mirrors `install-llamacpp-runtime.py`: the Piper sidecar is an ADR-010
SHA-pinned binary (no PATH lookup, no apt/pip), and the macOS Kokoro/voice-tts
lane never uses it. macOS is intentionally unsupported here.

The runtime lock (`scripts/piper-runtime.lock.json`) carries one entry per Linux
platform under `runtimes` (keys: `linux-x86_64`, `linux-aarch64`) plus a shared
`voice` object listing the plain voice files.
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
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "scripts" / "piper-runtime.lock.json"
# Piper is the Linux TTS lane; installs land next to the package staging dir by
# default. Packaging always passes an explicit --install-dir.
LINUX_INSTALL = ROOT / "build" / "linux" / "Piper"


def detect_platform() -> str:
    """Map the host OS+arch onto a Piper runtime-lock platform key."""
    system = sys.platform
    machine = _platform.machine().lower()
    if system.startswith("linux"):
        if machine in ("x86_64", "amd64"):
            return "linux-x86_64"
        if machine in ("aarch64", "arm64"):
            return "linux-aarch64"
        raise SystemExit(f"unsupported Linux architecture: {machine}")
    raise SystemExit(
        f"Piper runtime is Linux-only (got {system}); macOS uses the Kokoro/voice-tts lane"
    )


def select_runtime(data: dict, platform_key: str) -> dict:
    runtimes = data.get("runtimes")
    if isinstance(runtimes, dict) and platform_key in runtimes:
        return runtimes[platform_key]
    available = sorted((runtimes or {}).keys())
    raise SystemExit(f"no Piper runtime entry for platform {platform_key}; available: {available}")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _safe_target(out_dir: Path, member_name: str) -> Path | None:
    """Resolve an archive member to a path under out_dir, stripping the top dir.

    Returns None for the bare top-level directory entry. Raises on path
    traversal.
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


def download(url: str, dest: Path) -> None:
    try:
        with urllib.request.urlopen(url, timeout=120) as r, dest.open("wb") as f:
            shutil.copyfileobj(r, f)
        return
    except (urllib.error.URLError, OSError) as err:
        print(f"python urllib download failed ({err}); retrying with curl", file=sys.stderr)
    curl = shutil.which("curl") or "/usr/bin/curl"
    subprocess.run([curl, "-fL", "--retry", "3", "--output", str(dest), url], check=True)


def install_runtime(rt: dict, install_dir: Path, force: bool) -> Path:
    """Download + verify the Piper tarball; return the verified `piper` binary."""
    binary = install_dir / rt["binary"]
    if binary.exists() and not force:
        # A cached binary must still be verified against the lock before we trust
        # it — skipping verification would let a tampered/corrupt binary be
        # trusted forever. Only the DOWNLOAD is skipped, never the SHA check.
        expected_binary_sha = rt.get("binary_sha256")
        if expected_binary_sha is None:
            print(f"✓ Piper runtime already installed: {binary}")
            return binary
        binary_digest = sha256_file(binary)
        if binary_digest == expected_binary_sha:
            print(f"✓ Piper runtime already installed (sha256 verified): {binary}")
            return binary
        print(
            f"⚠ cached binary sha256 mismatch: expected {expected_binary_sha}, "
            f"got {binary_digest} — re-downloading"
        )

    install_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="fae-piper-") as td:
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
        extract_tar(archive, tmp_extract)
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
    return binary


def install_voice(voice: dict, voices_dir: Path, force: bool) -> None:
    """Download + SHA-verify each pinned voice file into voices_dir."""
    voices_dir.mkdir(parents=True, exist_ok=True)
    for entry in voice.get("files", []):
        dest = voices_dir / entry["filename"]
        if dest.exists() and not force:
            actual = sha256_file(dest)
            if actual == entry["sha256"]:
                print(f"✓ voice file already verified: {dest}")
                continue
            print(f"… voice file present but hash differs, redownloading: {dest}")
        print(f"↓ Downloading {entry['url']}")
        tmp = dest.with_name(dest.name + ".tmp")
        download(entry["url"], tmp)
        size = tmp.stat().st_size
        if size != int(entry["size_bytes"]):
            raise SystemExit(
                f"voice {entry['filename']} size mismatch: expected {entry['size_bytes']}, got {size}"
            )
        digest = sha256_file(tmp)
        if digest != entry["sha256"]:
            raise SystemExit(
                f"voice {entry['filename']} sha256 mismatch: expected {entry['sha256']}, got {digest}"
            )
        os.replace(tmp, dest)
        print(f"✓ voice sha256 verified: {digest}  ({entry['filename']})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", help="runtime platform key (default: auto-detect from host)")
    ap.add_argument("--install-dir", type=Path, default=None,
                    help="install directory (default: build/linux/Piper)")
    ap.add_argument("--lock", type=Path, default=LOCK)
    ap.add_argument("--force", action="store_true", help="redownload/reinstall even if present")
    args = ap.parse_args()

    data = json.loads(args.lock.read_text())
    platform_key = args.platform or detect_platform()
    rt = select_runtime(data, platform_key)

    install_dir = (args.install_dir or LINUX_INSTALL).expanduser().resolve()
    binary = install_runtime(rt, install_dir, args.force)

    voice = data.get("voice")
    if voice:
        install_voice(voice, install_dir / "voices", args.force)

    print(f"✓ Installed Piper {rt['release_tag']} {rt['platform']} runtime: {binary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
