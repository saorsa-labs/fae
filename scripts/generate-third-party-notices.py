#!/usr/bin/env python3
"""Generate the machine-derived dependency-notice section of THIRD_PARTY_LICENSES.md.

Coverage (everything Fae redistributes, evidenced by the repo):

  * Rust crates        — the full resolved graph from each workspace, via
                         `cargo metadata --locked` (authoritative licenses +
                         sources), with a Cargo.lock fallback so the list is
                         always complete even when the registry index is cold.
  * Vendored crates    — vendored mistral.rs / candle path crates (under
                         vendor/), recorded with their upstream provenance.
  * Swift deps         — `.package(url:)` declarations in Package.swift, pinned
                         requirement + upstream repo + curated SPDX license.
  * Native runtimes    — llama.cpp + Piper sidecars pinned by SHA-256 in the
                         scripts/*-runtime.lock.json lock files.

The hand-curated preamble of THIRD_PARTY_LICENSES.md (model/CC-BY notices etc.)
is PRESERVED verbatim: only the region between the BEGIN/END generated markers
is rewritten. Run with no args to regenerate in place, `--check` to fail CI when
the committed file is stale, or `--self-test` to validate the parsers.

Stdlib-only (no PyPI deps). Production script: no panics on untrusted input.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_FILE = REPO_ROOT / "THIRD_PARTY_LICENSES.md"
BEGIN_MARKER = "<!-- BEGIN GENERATED DEPENDENCY NOTICES -->"
END_MARKER = "<!-- END GENERATED DEPENDENCY NOTICES -->"

# First-party Saorsa Labs crates (workspace members + published x0x crates +
# the orb UI shell). None of these carry third-party notice obligations.
FIRST_PARTY_CRATES = {
    "fae-control-plane", "fae-envelope-gate", "fae-pii-membrane", "fae-metaopt",
    "fae-engine", "fae-audio", "fae-acp", "fae-daemon", "fae-symphony-runner",
    "fae-ui-shell",
    "x0x-symphony-core", "x0x-symphony-orchestrator", "x0x-symphony-signing",
    "x0x-symphony-tracker-x0x-crdt", "x0x-symphony-workspace",
}

# Rust workspaces whose resolved graphs are enumerated for the notice.
RUST_WORKSPACES = [
    REPO_ROOT / "crates",
    REPO_ROOT / "native" / "rust" / "fae-ui-shell",
]

# Vendored third-party crates live under vendor/; map the subdir to upstream.
VENDOR_UPSTREAM = {
    "candle": ("https://github.com/huggingface/candle", "MIT"),
    "mistral.rs": ("https://github.com/EricLBuehler/mistral.rs", "Apache-2.0"),
}

# Swift Package Manager dependencies declared in Package.swift.
# SPDX values are recorded per upstream repository LICENSE at the pinned
# revision; re-verify on bump. Sourced from each repo's LICENSE file.
SWIFT_LICENSE_MAP = {
    "Sparkle": ("MIT", "https://github.com/sparkle-project/Sparkle"),
    "mlx-swift-lm": ("MIT", "https://github.com/ml-explore/mlx-swift-lm"),
    "mlx-audio-swift": ("MIT", "https://github.com/Blaizzy/mlx-audio-swift"),
    "GRDB.swift": ("MIT", "https://github.com/groue/GRDB.swift"),
    "TOMLKit": ("Apache-2.0", "https://github.com/LebJe/TOMLKit"),
    "silero-vad-swift": ("MIT", "https://github.com/paean-ai/silero-vad-swift"),
    "swift-sdk": ("MIT", "https://github.com/modelcontextprotocol/swift-sdk"),
}

RUNTIME_LOCKS = [
    (REPO_ROOT / "scripts" / "llamacpp-runtime.lock.json", "llama.cpp llama-server",
     "https://github.com/ggml-org/llama.cpp", "MIT"),
    (REPO_ROOT / "scripts" / "piper-runtime.lock.json", "rhasspy piper TTS",
     "https://github.com/rhasspy/piper", "MIT"),
]


def _run_cargo_metadata(workspace: Path) -> list[dict] | None:
    """Return packages from `cargo metadata --locked`, or None on failure.

    Failure (cold registry index / no toolchain) is non-fatal: the caller falls
    back to Cargo.lock so the notice list is still complete; licenses are then
    marked unknown rather than fabricated.
    """
    try:
        proc = subprocess.run(
            ["cargo", "metadata", "--format-version=1", "--locked"],
            cwd=workspace, capture_output=True, text=True, timeout=180,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout).get("packages", [])
    except json.JSONDecodeError:
        return None


def _crates_io_url(name: str) -> str:
    return f"https://crates.io/crates/{name}"


def _classify(pkg: dict) -> tuple[str, str | None]:
    """Return (category, source_url) for a cargo-metadata package.

    category ∈ {"rust", "vendored", "skip"}. source_url is the human-facing
    provenance link (crates.io / git / upstream repo).
    """
    name = pkg.get("name", "")
    source = pkg.get("source") or ""
    manifest = pkg.get("manifest_path", "")
    if name in FIRST_PARTY_CRATES:
        return "skip", None
    if source.startswith("registry+"):
        return "rust", _crates_io_url(name)
    if source.startswith("git+"):
        # git+https://host/owner/repo.git?<rev>#<sha>
        git_url = source.split("?")[0].split("+", 1)[1]
        return "rust", git_url
    # source is null → path dependency. Decide first-party vs vendored.
    try:
        rel = Path(manifest).resolve().relative_to(REPO_ROOT)
    except (ValueError, OSError):
        return "skip", None
    parts = rel.parts
    if parts and parts[0] == "vendor" and len(parts) > 1:
        vendor_root = parts[1]
        upstream = VENDOR_UPSTREAM.get(vendor_root, (f"vendor/{vendor_root}", "UNKNOWN"))
        return "vendored", upstream[0]
    # Other local path deps (e.g. ../../apple/FaeHandoffKit, repo-internal) →
    # first-party or already covered; skip to avoid noise.
    return "skip", None


def _parse_cargo_lock(lockfile: Path) -> list[dict]:
    """Best-effort TOML-ish parse of [[package]] blocks in a Cargo.lock."""
    if not lockfile.is_file():
        return []
    text = lockfile.read_text(encoding="utf-8")
    out: list[dict] = []
    for block in text.split("[[package]]")[1:]:
        crate: dict = {}
        for line in block.splitlines():
            line = line.strip()
            m = re.match(r'^name\s*=\s*"(.+)"', line)
            if m:
                crate["name"] = m.group(1)
                continue
            m = re.match(r'^version\s*=\s*"(.+)"', line)
            if m:
                crate["version"] = m.group(1)
                continue
            m = re.match(r'^source\s*=\s*"(.+)"', line)
            if m:
                src = m.group(1)
                if src.startswith("registry+"):
                    crate["source"] = _crates_io_url(crate.get("name", ""))
                elif src.startswith("git+"):
                    crate["source"] = src.split("?")[0].split("+", 1)[1]
                else:
                    crate["source"] = ""
        if "name" in crate and "version" in crate:
            out.append(crate)
    return out


def collect_rust() -> tuple[list[dict], list[dict]]:
    """Return (registry_crates, vendored_crates) across all Rust workspaces.

    Dedups by (name, version, source); a crate resolving to multiple versions is
    listed once per resolved version (the supply-chain truth).
    """
    seen: dict[tuple[str, str, str], dict] = {}
    vendored: dict[tuple[str, str], dict] = {}
    for ws in RUST_WORKSPACES:
        packages = _run_cargo_metadata(ws)
        if packages is None:
            # Fallback: Cargo.lock has name/version/source but no license.
            for crate in _parse_cargo_lock(ws / "Cargo.lock"):
                key = (crate["name"], crate["version"], crate.get("source", ""))
                if key not in seen:
                    crate.setdefault("license", "UNKNOWN (see registry)")
                    seen[key] = crate
            continue
        for pkg in packages:
            category, src_url = _classify(pkg)
            if category == "skip":
                continue
            license_field = (pkg.get("license") or "").strip() or "UNKNOWN (see registry)"
            entry = {
                "name": pkg.get("name", ""),
                "version": pkg.get("version", ""),
                "license": license_field,
                "source": src_url or "",
                "repository": (pkg.get("repository") or "").strip(),
            }
            if category == "vendored":
                vkey = (entry["name"], entry["version"])
                vendored.setdefault(vkey, entry)
            else:
                key = (entry["name"], entry["version"], entry["source"])
                seen.setdefault(key, entry)
    return list(seen.values()), list(vendored.values())


def _fmt_license_group(license_str: str, crates: list[dict]) -> list[str]:
    lines = [f"#### `{license_str}`", ""]
    for c in sorted(crates, key=lambda x: x["name"].lower()):
        link = c.get("source") or c.get("repository") or ""
        suffix = f" — {link}" if link else ""
        lines.append(f"- `{c['name']} {c['version']}`{suffix}")
    lines.append("")
    return lines


def render_rust(registry: list[dict]) -> list[str]:
    if not registry:
        return ["### Rust crates", "", "_None resolved._", ""]
    # Group by exact SPDX expression (the legal license string).
    groups: dict[str, list[dict]] = {}
    unknown: list[dict] = []
    for c in registry:
        lic = c["license"]
        if lic.startswith("UNKNOWN"):
            unknown.append(c)
        else:
            groups.setdefault(lic, []).append(c)
    lines = [f"### Rust crates ({len(registry)} resolved)", "",
             "Full resolved dependency graph of the Fae Rust workspaces "
             "(`crates/` + `native/rust/fae-ui-shell/`), grouped by SPDX "
             "license. Fae's own workspace crates are excluded.", ""]
    for lic in sorted(groups, key=lambda k: (-len(groups[k]), k)):
        lines += _fmt_license_group(lic, groups[lic])
    if unknown:
        lines += _fmt_license_group("UNKNOWN (license not declared in manifest)", unknown)
    return lines


def render_vendored(vendored: list[dict]) -> list[str]:
    if not vendored:
        return []
    lines = ["### Vendored Rust crates", "",
             "These third-party crates are committed under `vendor/` and patched "
             "in-repo via `[patch]` in `crates/Cargo.toml`; their upstream "
             "commit provenance is recorded there.", ""]
    for v in sorted(vendored, key=lambda x: x["name"].lower()):
        lic = v.get("license") or "UNKNOWN"
        link = v.get("source") or ""
        suffix = f" — {link}" if link else ""
        lines.append(f"- `{v['name']} {v['version']}` ({lic}){suffix}")
    lines.append("")
    return lines


# --- Swift SPM -------------------------------------------------------------

_SPM_PKG_RE = re.compile(
    r'\.package\(\s*(?:url:\s*)?["\']([^"\']+)["\']\s*,\s*([^\)]+)\)'
)


def collect_swift() -> list[dict]:
    pkg_swift = REPO_ROOT / "native" / "macos" / "Fae" / "Package.swift"
    if not pkg_swift.is_file():
        return []
    deps: list[dict] = []
    seen: set[str] = set()
    for m in _SPM_PKG_RE.finditer(pkg_swift.read_text(encoding="utf-8")):
        url = m.group(1).strip()
        req = m.group(2).strip().rstrip(",").strip()
        # Derive package identity: owner/repo from URL.
        repo_name = url.rstrip("/").split("/")[-1]
        if repo_name.endswith(".git"):
            repo_name = repo_name[:-4]
        if repo_name in seen:
            continue
        seen.add(repo_name)
        spdx, upstream = SWIFT_LICENSE_MAP.get(repo_name, ("UNKNOWN (verify upstream)", url))
        deps.append({
            "name": repo_name, "requirement": req, "license": spdx,
            "url": upstream,
        })
    return deps


def render_swift(deps: list[dict]) -> list[str]:
    if not deps:
        return ["### Swift Package Manager dependencies", "", "_None declared._", ""]
    lines = [f"### Swift Package Manager dependencies ({len(deps)})", "",
             "Declared in `native/macos/Fae/Package.swift`. SPDX license recorded "
             "per upstream repository LICENSE at the pinned revision; re-verify on "
             "bump. First-party path dependencies (e.g. FaeHandoffKit) are excluded.", ""]
    for d in sorted(deps, key=lambda x: x["name"].lower()):
        lines.append(
            f"- `{d['name']}` — {d['requirement']} — {d['license']} — {d['url']}"
        )
    lines.append("")
    return lines


# --- Native runtimes -------------------------------------------------------

def collect_runtimes() -> list[dict]:
    out: list[dict] = []
    for lockpath, label, upstream, spdx in RUNTIME_LOCKS:
        if not lockpath.is_file():
            continue
        try:
            data = json.loads(lockpath.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        # Pick a representative release tag (single-runtime files use `runtime`,
        # multi-platform files use `runtimes`).
        tag = ""
        if isinstance(data.get("runtime"), dict):
            tag = data["runtime"].get("release_tag", "")
        elif isinstance(data.get("runtimes"), dict):
            for v in data["runtimes"].values():
                tag = v.get("release_tag", "")
                break
        out.append({"label": label, "tag": tag, "url": upstream,
                    "license": spdx, "lock": lockpath.relative_to(REPO_ROOT).as_posix()})
    return out


def render_runtimes(runtimes: list[dict]) -> list[str]:
    if not runtimes:
        return []
    lines = ["### Pinned native runtimes", "",
             "Native sidecar runtimes are SHA-256 pinned (archive + binary) and "
             "fail-closed verified before load by the installer scripts.", ""]
    for r in runtimes:
        tag = f" `{r['tag']}`" if r["tag"] else ""
        lines.append(
            f"- {r['label']}{tag} — {r['url']} — {r['license']} "
            f"(pinned in `{r['lock']}`)"
        )
    lines.append("")
    return lines


# --- Orchestration ---------------------------------------------------------

def render_generated() -> str:
    registry, vendored = collect_rust()
    swift = collect_swift()
    runtimes = collect_runtimes()
    # Static sources note (NOT a wall-clock timestamp) so the generated region
    # is byte-reproducible and `--check` is stable across machines/time.
    sources = (
        "`cargo metadata --locked` (crates/, native/rust/fae-ui-shell/) + "
        "`native/macos/Fae/Package.swift` + scripts/*-runtime.lock.json"
    )
    parts = [
        BEGIN_MARKER,
        "<!-- Generated by scripts/generate-third-party-notices.py — DO NOT EDIT. -->",
        "<!-- Re-run: python3 scripts/generate-third-party-notices.py  (CI: --check) -->",
        f"<!-- Sources: {sources}. -->",
        "",
        "## Dependency notices (generated)",
        "",
        "Fae is licensed under GNU AGPL-3.0-or-later (see `LICENSE`). This "
        "generated section enumerates the *additional* third-party obligations "
        "of every dependency Fae redistributes — Rust crates, vendored crates, "
        "Swift packages, and pinned native runtimes — with the SPDX license "
        "under which each is redistributed. Where a license is marked UNKNOWN, "
        "verify the upstream manifest before distribution.",
        "",
    ]
    parts += render_rust(registry)
    parts += render_vendored(vendored)
    parts += render_swift(swift)
    parts += render_runtimes(runtimes)
    parts += [f"_{len(registry)} Rust crates, {len(vendored)} vendored, "
              f"{len(swift)} Swift packages, {len(runtimes)} native runtimes._", ""]
    parts.append(END_MARKER)
    parts.append("")
    return "\n".join(parts)


def read_preamble() -> str:
    """Return the hand-curated content preceding the generated markers."""
    if not OUTPUT_FILE.is_file():
        return (
            "# Third-Party Licenses & Acknowledgements\n\n"
            "This file collects the third-party notices Fae is required to carry.\n\n"
            "---\n\n"
        )
    text = OUTPUT_FILE.read_text(encoding="utf-8")
    idx = text.find(BEGIN_MARKER)
    if idx == -1:
        # No markers yet: keep existing content, ensure trailing separator.
        return text.rstrip("\n") + "\n\n---\n\n"
    return text[:idx]


def regenerate() -> str:
    return read_preamble() + render_generated()


def check_stale() -> int:
    """Exit 0 if the committed generated region matches a fresh render, else 1."""
    if not OUTPUT_FILE.is_file():
        print(f"::error::{OUTPUT_FILE.name} does not exist; run the generator first")
        return 1
    on_disk = OUTPUT_FILE.read_text(encoding="utf-8")
    fresh = regenerate()
    if on_disk == fresh:
        print(f"✓ {OUTPUT_FILE.name} generated notices are up to date")
        return 0
    disk_region = on_disk[on_disk.find(BEGIN_MARKER):] if BEGIN_MARKER in on_disk else ""
    print(
        "::error::" + OUTPUT_FILE.name + " generated notices are stale.\n"
        "The committed generated region does not match the locked manifests.\n"
        "Re-run: python3 scripts/generate-third-party-notices.py\n"
        "First diverging region (committed, truncated):\n"
        + disk_region[:600]
    )
    return 1


# --- Self-test (contract pin for tests; no network) ------------------------

_SAMPLE_PKG_SWIFT = (
    '.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),\n'
    '.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),\n'
    '.package(path: "../../apple/FaeHandoffKit"),\n'
)


def _self_test() -> int:
    failures = 0
    # SPM regex parses url packages, ignores path deps.
    found = [m.group(1) for m in _SPM_PKG_RE.finditer(_SAMPLE_PKG_SWIFT)]
    if found != ["https://github.com/sparkle-project/Sparkle",
                 "https://github.com/groue/GRDB.swift"]:
        print(f"FAIL: SPM regex parsed {found}")
        failures += 1
    # Cargo.lock fallback parser extracts name/version/source.
    sample_lock = (
        '[[package]]\nname = "serde"\nversion = "1.0.228"\n'
        'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
        'checksum = "deadbeef"\n'
    )
    tmp = REPO_ROOT / ".selftest-Cargo.lock"
    tmp.write_text(sample_lock, encoding="utf-8")
    parsed = _parse_cargo_lock(tmp)
    tmp.unlink(missing_ok=True)
    if not parsed or parsed[0].get("name") != "serde" \
            or parsed[0].get("version") != "1.0.228" \
            or parsed[0].get("source") != "https://crates.io/crates/serde":
        print(f"FAIL: Cargo.lock fallback parsed {parsed}")
        failures += 1
    # First-party classifier skips workspace members.
    fake = {"name": "fae-daemon", "source": None,
            "manifest_path": str(REPO_ROOT / "crates" / "x")}
    cat, _ = _classify(fake)
    if cat != "skip":
        print(f"FAIL: first-party crate classified as {cat}")
        failures += 1
    # Vendored classifier resolves upstream.
    fake = {"name": "candle-core", "source": None,
            "manifest_path": str(REPO_ROOT / "vendor" / "candle" / "candle-core" / "Cargo.toml")}
    cat, src = _classify(fake)
    if cat != "vendored" or src != "https://github.com/huggingface/candle":
        print(f"FAIL: vendored crate classified as {cat}/{src}")
        failures += 1
    if failures == 0:
        print("✓ generate-third-party-notices self-test passed")
        return 0
    print(f"::error::{failures} self-test assertion(s) failed")
    return 1


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--check", action="store_true",
                   help="fail (exit 1) if the committed generated notices are stale")
    p.add_argument("--self-test", action="store_true",
                   help="run built-in parser assertions; no network side effects")
    args = p.parse_args(argv)
    if args.self_test:
        return _self_test()
    if args.check:
        return check_stale()
    OUTPUT_FILE.write_text(regenerate(), encoding="utf-8")
    print(f"✓ regenerated {OUTPUT_FILE.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
