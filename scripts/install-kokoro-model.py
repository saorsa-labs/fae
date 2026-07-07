#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["huggingface_hub>=0.24"]
# ///
"""Install Fae's bundled Kokoro-82M TTS model into repo-local resources.

The daemon's macOS TTS lane (voice-tts / mlx-rs) loads Kokoro from the repo id in
`FAE_TTS_MODEL_ID`. `voice_tts::load_model` treats that value as a LOCAL directory
when it exists on disk and loads it directly — no HuggingFace fetch (which
currently 401s against the mlx-audio cache layout the Rust `hf_hub` client can't
read). This script populates::

    native/macos/Fae/Resources/Kokoro/{config.json,kokoro-v1_0.safetensors}

so the bundle step can embed it (`<app>/Contents/Resources/Kokoro/`) and
`DaemonLLMEngine` can point the daemon at the local path.

Only these two files are needed: `voice_tts::download_model` reads `config.json`
plus one `.safetensors` and returns the parent dir. The upstream `voices/` and
`samples/` subdirs are NOT copied — Fae's own voice ships separately as
`fae.safetensors`.

Source order, per file:
  (a) copy from the local HF cache (`mlx-audio/prince-canuma_Kokoro-82M`) if present
  (b) else download `prince-canuma/Kokoro-82M` via huggingface_hub, authing with
      `HF_TOKEN` (env) or `~/.cache/huggingface/token`

Every file is SHA-256 + size verified against the pinned expected values below,
which match the Kokoro entries in
`native/macos/Fae/Sources/Fae/Resources/Models/models.lock`. Idempotent: a file
that already exists and hash-matches is left untouched.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "native" / "macos" / "Fae" / "Resources" / "Kokoro"
LOCAL_CACHE = (
    Path.home()
    / ".cache"
    / "huggingface"
    / "hub"
    / "mlx-audio"
    / "prince-canuma_Kokoro-82M"
)
REPO_ID = "prince-canuma/Kokoro-82M"

# Pinned expected artifacts. These MUST stay in lock-step with the Kokoro entries
# in models.lock; the daemon fail-closes on any divergence at load time.
FILES: dict[str, dict[str, object]] = {
    "config.json": {
        "size": 2351,
        "sha256": "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f",
    },
    "kokoro-v1_0.safetensors": {
        "size": 327115152,
        "sha256": "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8",
    },
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def matches(path: Path, expected: dict[str, object]) -> bool:
    """True when `path` exists and matches the pinned size + SHA-256."""
    if not path.is_file():
        return False
    if path.stat().st_size != int(expected["size"]):
        return False
    return sha256_file(path) == expected["sha256"]


def verify(path: Path, name: str, expected: dict[str, object]) -> None:
    """Fail-closed size + SHA-256 check; raises SystemExit on any mismatch."""
    size = path.stat().st_size
    if size != int(expected["size"]):
        raise SystemExit(f"{name} size mismatch: expected {expected['size']}, got {size}")
    digest = sha256_file(path)
    if digest != expected["sha256"]:
        raise SystemExit(
            f"{name} sha256 mismatch: expected {expected['sha256']}, got {digest}"
        )


def hf_token() -> str | None:
    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    if token:
        return token.strip()
    token_file = Path.home() / ".cache" / "huggingface" / "token"
    if token_file.is_file():
        text = token_file.read_text().strip()
        if text:
            return text
    return None


def source_file(name: str, expected: dict[str, object], staged: Path) -> None:
    """Materialise `name` at `staged`, verifying it against the pin.

    (a) copy from the local HF cache when present and hash-matching; else
    (b) download from the pinned HF repo via huggingface_hub.
    """
    cached = LOCAL_CACHE / name
    if matches(cached, expected):
        print(f"  ↪ copying {name} from local HF cache")
        shutil.copyfile(cached, staged)
        verify(staged, name, expected)
        return

    print(f"  ↓ downloading {name} from {REPO_ID}")
    try:
        from huggingface_hub import hf_hub_download
    except ImportError as err:  # pragma: no cover - environment dependent
        raise SystemExit(
            "huggingface_hub is required to download Kokoro; run via "
            "`just install-kokoro-model` (uv provides the dependency)"
        ) from err

    downloaded = hf_hub_download(
        repo_id=REPO_ID,
        filename=name,
        token=hf_token(),
    )
    shutil.copyfile(downloaded, staged)
    verify(staged, name, expected)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--dest",
        type=Path,
        default=DEST,
        help="destination directory (default: repo Resources/Kokoro)",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="re-copy/re-download even if a valid file is already present",
    )
    args = ap.parse_args()

    dest: Path = args.dest.expanduser().resolve()
    dest.mkdir(parents=True, exist_ok=True)

    for name, expected in FILES.items():
        target = dest / name
        if not args.force and matches(target, expected):
            print(f"✓ {name} already present (sha256 verified)")
            continue
        with tempfile.NamedTemporaryFile(
            dir=dest, prefix=f".{name}.", delete=False
        ) as tmp:
            staged = Path(tmp.name)
        try:
            source_file(name, expected, staged)
            # NamedTemporaryFile creates 0600; bundled resources should be
            # world-readable like the upstream files (0644).
            staged.chmod(0o644)
            os.replace(staged, target)
        finally:
            if staged.exists():
                staged.unlink()
        print(f"✓ installed {name} (sha256 verified): {target}")

    print(f"✓ Kokoro-82M TTS model installed: {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
