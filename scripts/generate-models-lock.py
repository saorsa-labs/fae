#!/usr/bin/env python3
"""Generate a fail-closed models.lock from a real Hugging Face snapshot.

The script walks the snapshot directory, follows Hugging Face cache symlinks to
blob content, and emits [[artifact]] entries with size + SHA-256 for every file.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import pathlib
import re
import sys


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_id(model_id: str, relative: pathlib.Path) -> str:
    raw = f"{model_id}-{relative.as_posix()}".lower()
    return re.sub(r"[^a-z0-9]+", "-", raw).strip("-")


def toml_string(value: str) -> str:
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def snapshot_revision(snapshot: pathlib.Path) -> str:
    name = snapshot.name
    if re.fullmatch(r"[0-9a-f]{40}", name):
        return name
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=pathlib.Path, help="HF snapshot directory to lock")
    parser.add_argument(
        "--model-id", required=True, help="Source repo id, e.g. google/gemma-4-E4B-it"
    )
    parser.add_argument(
        "--output", type=pathlib.Path, required=True, help="models.lock output path"
    )
    parser.add_argument("--loader", default="mistralrs")
    parser.add_argument("--role", default="llm")
    parser.add_argument("--license", default="gemma")
    parser.add_argument("--hardware-profile", default="Apple Silicon Metal via mistral.rs")
    parser.add_argument("--approved-by", default="owner")
    parser.add_argument(
        "--created-at",
        help="UTC timestamp to embed (defaults to current time, e.g. 2026-06-13T17:30:32Z)",
    )
    args = parser.parse_args()

    snapshot = args.snapshot.expanduser().resolve()
    if not snapshot.is_dir():
        print(f"snapshot directory not found: {snapshot}", file=sys.stderr)
        return 2

    files = sorted(path for path in snapshot.rglob("*") if path.is_file() or path.is_symlink())
    if not files:
        print(f"snapshot contains no files: {snapshot}", file=sys.stderr)
        return 2

    created_at = args.created_at or (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    revision = snapshot_revision(snapshot)
    lines: list[str] = [
        "# Generated from a real Hugging Face snapshot by scripts/generate-models-lock.py",
        "schema_version = 1",
        f"created_at = {toml_string(created_at)}",
        "",
    ]

    for path in files:
        relative = path.relative_to(snapshot)
        real_path = path.resolve()
        size = real_path.stat().st_size
        checksum = sha256_file(real_path)
        lines.extend(
            [
                "[[artifact]]",
                f"id = {toml_string(artifact_id(args.model_id, relative))}",
                f"role = {toml_string(args.role)}",
                f"loader = {toml_string(args.loader)}",
                f"source_repo = {toml_string(args.model_id)}",
                f"source_revision = {toml_string(revision)}",
                f"filename = {toml_string(relative.as_posix())}",
                f"size_bytes = {size}",
                f"sha256 = {toml_string(checksum)}",
                'signature = ""',
                f"license = {toml_string(args.license)}",
                f"hardware_profile = {toml_string(args.hardware_profile)}",
                f"approved_by = {toml_string(args.approved_by)}",
                f"created_at = {toml_string(created_at)}",
                "",
            ]
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {args.output} ({len(files)} artifacts from {snapshot})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
