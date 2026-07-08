#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "huggingface_hub>=0.24",
#     "tomli; python_version < '3.11'",
# ]
# ///
"""Install NVIDIA parakeet-tdt-0.6b-v2 (Int8 ONNX) ASR artifacts for the
sherpa-onnx ASR lane into the per-user Fae data directory.

Destination — the daemon's ``parakeet_models_dir()`` PRODUCTION default (NOT the
``FAE_PARAKEET_MODELS_DIR`` eval override, which is kept for offline/eval)::

    macOS:  ~/Library/Application Support/fae/models/parakeet
    Linux:  $XDG_DATA_HOME/fae/models/parakeet   (or ~/.local/share/fae/models/parakeet)

The four artifacts (encoder/decoder/joiner Int8 ONNX + tokens.txt, ~661 MB) are
size + SHA-256 verified against the Parakeet entries in ``models.lock`` — the
SAME lock the daemon fail-closes on at load time — so the installer and the
loader can never disagree on a pin. A file that already exists and hash-matches
is left untouched (idempotent); a missing/truncated/mismatched file is
re-downloaded and re-verified, and any residual mismatch aborts (fail-closed).

This mirrors ``scripts/install-kokoro-model.py`` (uv --script, huggingface_hub,
idempotent, fail-closed SHA verify) but targets the per-user data dir rather than
repo-local bundle resources, and sources its pins from ``models.lock`` instead of
a hand-maintained dict. The llama.cpp ``-hf`` downloader is deliberately NOT
used. With the artifacts installed here, ``asr.engine = "parakeet"`` loads them
directly; if they are absent/corrupt the daemon prints a LOUD message and falls
back to the Gemma (Qwen3-ASR) lane.

Usage::

    just install-parakeet-models
    # or directly:
    uv run --script scripts/install-parakeet-models.py
    uv run --script scripts/install-parakeet-models.py --dest /tmp/parakeet-models --force
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sys
import tempfile
from pathlib import Path

try:  # Python 3.11+ stdlib; fall back to tomli on 3.9/3.10.
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - dependency declared for <3.11
    import tomli as tomllib  # type: ignore[no-redef]

ROOT = Path(__file__).resolve().parents[1]
SHIPPED_LOCK = ROOT / "native" / "macos" / "Fae" / "Sources" / "Fae" / "Resources" / "Models" / "models.lock"
REPO_ID = "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
REVISION = "1ab9323565ddb038682214b292f588070a538ce2"
# The four files the sherpa-onnx transducer loads, in load order.
FILENAMES = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]


def data_dir() -> Path:
    """Mirror the daemon's ``data_directory()`` cross-platform base."""
    home = Path.home()
    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / "fae"
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        return Path(xdg) / "fae"
    return home / ".local" / "share" / "fae"


def asr_engine_is_parakeet() -> bool:
    """Mirror the daemon's ``asr_engine_choice()``: ``FAE_ASR_ENGINE`` env wins,
    else ``[asr] engine`` in the data-dir ``config.toml``, else ``gemma``. The
    ~661 MB fetch only runs when parakeet is the selected ASR engine, so the
    installer is safe to invoke unconditionally; ``--force`` bypasses this gate
    (and the idempotent skip) for an explicit manual pre-fetch."""
    raw = os.environ.get("FAE_ASR_ENGINE")
    if raw is None or not raw.strip():
        config = data_dir() / "config.toml"
        if config.is_file():
            try:
                with config.open("rb") as handle:
                    parsed = tomllib.load(handle)
                raw = str(parsed.get("asr", {}).get("engine", ""))
            except (OSError, tomllib.TOMLDecodeError):
                raw = ""
    return bool(raw) and raw.strip().lower() == "parakeet"


def load_pins(models_lock: Path) -> dict[str, dict[str, object]]:
    """Read the four sherpa-onnx Parakeet artifacts' size + SHA-256 from the
    shipped ``models.lock``. Fails closed if the lock is missing, unparseable, or
    does not pin exactly these four artifacts on the pinned repo/revision."""
    if not models_lock.is_file():
        raise SystemExit(f"models.lock not found: {models_lock}")
    with models_lock.open("rb") as handle:
        lock = tomllib.load(handle)
    pins: dict[str, dict[str, object]] = {}
    for art in lock.get("artifact", []):
        if art.get("loader") != "sherpa-onnx":
            continue
        if art.get("source_repo") != REPO_ID or art.get("source_revision") != REVISION:
            raise SystemExit(
                f"models.lock sherpa-onnx artifact pins unexpected source "
                f"{art.get('source_repo')}@{art.get('source_revision')}"
            )
        filename = art.get("filename")
        sha = str(art.get("sha256", "")).strip().lower()
        size = int(art.get("size_bytes", 0))
        if not filename or size == 0 or len(sha) != 64:
            raise SystemExit(f"models.lock artifact {art.get('id')} has an incomplete pin")
        pins[str(filename)] = {"size": size, "sha256": sha, "id": art.get("id", filename)}
    missing = [f for f in FILENAMES if f not in pins]
    if missing:
        raise SystemExit(
            f"models.lock is missing sherpa-onnx Parakeet artifacts: {missing}. "
            f"Regenerate the lock or point --models-lock at one with the entries."
        )
    return pins


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def matches(path: Path, expected: dict[str, object]) -> bool:
    """True when ``path`` exists and matches the pinned size + SHA-256."""
    if not path.is_file():
        return False
    if path.stat().st_size != int(expected["size"]):
        return False
    return sha256_file(path) == str(expected["sha256"])


def verify(path: Path, name: str, expected: dict[str, object]) -> None:
    """Fail-closed size + SHA-256 check; raises SystemExit on any mismatch."""
    if not path.is_file() or path.stat().st_size != int(expected["size"]):
        raise SystemExit(f"{name}: size mismatch (expected {expected['size']})")
    if sha256_file(path) != str(expected["sha256"]):
        raise SystemExit(
            f"{name}: SHA-256 mismatch — refusing to install an unverified artifact "
            f"(models.lock id {expected['id']})"
        )


def hf_token() -> str | None:
    return os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")


def source_file(name: str, expected: dict[str, object], staged: Path) -> None:
    """Download ``name`` from the pinned HF repo into ``staged`` and verify it."""
    print(f"  ↓ downloading {name} from {REPO_ID}@{REVISION[:9]}")
    try:
        from huggingface_hub import hf_hub_download
    except ImportError as err:  # pragma: no cover - environment dependent
        raise SystemExit(
            "huggingface_hub is required to download Parakeet; run via "
            "`just install-parakeet-models` (uv provides the dependency)"
        ) from err

    # revision-pinned so a repo-side tag/force-push can't swap the bytes under us;
    # the SHA-256 verify below is the hard gate regardless.
    downloaded = hf_hub_download(
        repo_id=REPO_ID,
        revision=REVISION,
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
        default=data_dir() / "models" / "parakeet",
        help="destination directory (default: <fae data>/models/parakeet — the "
        "daemon production default; FAE_PARAKEET_MODELS_DIR remains the eval override)",
    )
    ap.add_argument(
        "--models-lock",
        type=Path,
        default=SHIPPED_LOCK,
        help="models.lock to source the size + SHA-256 pins from",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="bypass the asr.engine=parakeet gate AND re-download even if a valid file is present",
    )
    args = ap.parse_args()

    if not args.force and not asr_engine_is_parakeet():
        print(
            'asr.engine != "parakeet" — skipping the ~661 MB Parakeet fetch. '
            'Set asr.engine = "parakeet" (or FAE_ASR_ENGINE=parakeet), or pass '
            "--force to pre-fetch regardless."
        )
        return 0

    pins = load_pins(args.models_lock)
    dest: Path = args.dest.expanduser().resolve()
    dest.mkdir(parents=True, exist_ok=True)

    for name in FILENAMES:
        expected = pins[name]
        target = dest / name
        if not args.force and matches(target, expected):
            print(f"✓ {name} already present (size + sha256 verified)")
            continue
        with tempfile.NamedTemporaryFile(dir=dest, prefix=f".{name}.", delete=False) as tmp:
            staged = Path(tmp.name)
        try:
            source_file(name, expected, staged)
            staged.chmod(0o644)
            os.replace(staged, target)
        finally:
            if staged.exists():
                staged.unlink()
        print(f"✓ installed {name} (size + sha256 verified): {target}")

    print(f"✓ Parakeet ASR artifacts installed: {dest}")
    print(
        "  Enable with: asr.engine = \"parakeet\" (or FAE_ASR_ENGINE=parakeet). "
        "The daemon verifies these against models.lock at load time and falls "
        "back to the Gemma (Qwen3-ASR) lane if any is missing/mismatched."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
