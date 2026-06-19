#!/usr/bin/env python3
"""Build Linux installers (.deb + AppImage) for the Fae brain.

Off-macOS the Fae product is the Rust daemon + orb-host + the integrity-gated
llama.cpp runtime (no Swift app). This script assembles a staging tree, then
emits:

  * a Debian package (`.deb`) installing to FHS paths under `/usr/lib/fae`, with
    `fae-daemon` + `fae-ui-shell` on the user's PATH via `/usr/bin` symlinks, and
  * an AppImage (self-contained, portable single file),

bundling: the cross/native-built `fae-daemon` and `fae-ui-shell`, the
SHA-verified llama.cpp runtime for the target arch, and the shipped
`models.lock` (so the daemon's fail-closed integrity gate has its lock).

The `.deb` is GPG-signed with a *detached* signature (`<deb>.asc`), which is the
same `gpg --verify` roundtrip on any host. `dpkg-deb` is preferred; if it is
unavailable (e.g. proving the layout on macOS) a portable `ar`+`tar` fallback
produces a byte-identical-format Debian archive.

Real release signing uses an owner-provisioned key (a CI secret); for local
proof, pass `--gpg-key <fingerprint>` for a throwaway test key.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Debian arch <-> Rust target triple <-> runtime-lock platform key.
ARCH_MAP = {
    "amd64": {
        "triple": "x86_64-unknown-linux-gnu",
        "runtime_platform": "linux-x86_64",
        "appimage_arch": "x86_64",
    },
    "arm64": {
        "triple": "aarch64-unknown-linux-gnu",
        "runtime_platform": "linux-aarch64",
        "appimage_arch": "aarch64",
    },
}

PACKAGE = "fae"
MAINTAINER = "Saorsa Labs <david@saorsalabs.com>"
DESCRIPTION = "Fae — a voice-first local AI companion (daemon + orb-host)"
# Runtime deps the prebuilt binaries dynamically link against.
DEPENDS = "libc6, libasound2, libgtk-3-0, libwebkit2gtk-4.1-0, libayatana-appindicator3-1"


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print("  $ " + " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, check=True, **kw)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def make_executable(path: Path) -> None:
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def assemble_payload(staging: Path, arch: str, version: str,
                     daemon: Path, ui_shell: Path | None) -> Path:
    """Lay out the FHS install tree under <staging>/payload and return it."""
    info = ARCH_MAP[arch]
    payload = staging / "payload"
    fae_root = payload / "usr" / "lib" / "fae"
    bin_dir = fae_root / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (payload / "usr" / "bin").mkdir(parents=True, exist_ok=True)

    shutil.copy2(daemon, bin_dir / "fae-daemon")
    make_executable(bin_dir / "fae-daemon")
    if ui_shell is not None:
        shutil.copy2(ui_shell, bin_dir / "fae-ui-shell")
        make_executable(bin_dir / "fae-ui-shell")

    # PATH symlinks (relative, FHS-friendly).
    for name in (["fae-daemon", "fae-ui-shell"] if ui_shell else ["fae-daemon"]):
        link = payload / "usr" / "bin" / name
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(Path("../lib/fae/bin") / name)

    # Integrity-gated llama.cpp runtime → /usr/lib/fae/llamacpp
    # (matches bundled_llama_server_path: <bin>/../lib/fae/llamacpp/llama-server
    #  resolves because <bin> is /usr/lib/fae/bin, so ../ is /usr/lib/fae).
    runtime_dir = fae_root / "llamacpp"
    run([sys.executable, str(ROOT / "scripts" / "install-llamacpp-runtime.py"),
         "--platform", info["runtime_platform"],
         "--install-dir", str(runtime_dir), "--force"])

    # Shipped models.lock so the daemon's fail-closed gate has its lock at the
    # FHS data path it looks up (XDG / ~/.local/share is per-user; the packaged
    # lock is the reference copy installed under the app dir).
    models_lock_src = ROOT / "native" / "macos" / "Fae" / "Sources" / "Fae" / "Resources" / "Models" / "models.lock"
    shutil.copy2(models_lock_src, fae_root / "models.lock")
    return payload


def write_control(staging: Path, payload: Path, arch: str, version: str) -> Path:
    """Write the DEBIAN/control dir and return the control root."""
    installed_kb = sum(
        f.stat().st_size for f in payload.rglob("*") if f.is_file()
    ) // 1024
    debian = payload / "DEBIAN"
    debian.mkdir(parents=True, exist_ok=True)
    control = (
        f"Package: {PACKAGE}\n"
        f"Version: {version}\n"
        f"Section: utils\n"
        f"Priority: optional\n"
        f"Architecture: {arch}\n"
        f"Maintainer: {MAINTAINER}\n"
        f"Installed-Size: {installed_kb}\n"
        f"Depends: {DEPENDS}\n"
        f"Description: {DESCRIPTION}\n"
        " Fae runs entirely on-device: the fae-daemon LLM lane (llama.cpp\n"
        " sidecar) plus the fae-ui-shell orb host. No cloud, no API keys.\n"
    )
    (debian / "control").write_text(control)
    return debian


def build_deb_dpkg(payload: Path, out: Path) -> None:
    run(["dpkg-deb", "--root-owner-group", "--build", str(payload), str(out)])


def _ar_member(name: str, data: bytes) -> bytes:
    """One GNU/BSD-common `ar` member header + payload (2-byte padded).

    The Debian `.deb` `ar` archive uses the portable common format: a 60-byte
    ASCII header per member, payload padded to an even length with `\\n`. We
    emit it by hand so the build does not depend on the host `ar` (macOS ships
    a Mach-O `ar` that rewrites archives with a symbol table — not a valid
    Debian archive).
    """
    header = (
        f"{name:<16}"   # name (16)
        f"{0:<12}"      # mtime (12) — 0 for reproducibility
        f"{0:<6}"       # owner uid (6)
        f"{0:<6}"       # owner gid (6)
        f"{'100644':<8}"  # mode (8)
        f"{len(data):<10}"  # size (10)
        "\x60\x0a"      # magic trailer `\x60\n`
    ).encode("ascii")
    assert len(header) == 60, len(header)
    pad = b"\n" if len(data) % 2 else b""
    return header + data + pad


def build_deb_portable(payload: Path, debian: Path, out: Path, version: str, arch: str) -> None:
    """Build a Debian binary package without dpkg-deb (macOS proof path).

    A `.deb` is an `ar` archive (magic `!<arch>\\n`) of exactly three members in
    order: `debian-binary`, `control.tar.gz`, `data.tar.gz`.
    """
    with tempfile.TemporaryDirectory(prefix="fae-deb-") as td:
        tmp = Path(td)

        # control.tar.gz: the DEBIAN/ contents at archive root.
        control_tar = tmp / "control.tar.gz"
        with tarfile.open(control_tar, "w:gz") as tar:
            for item in sorted(debian.iterdir()):
                tar.add(item, arcname=item.name)

        # data.tar.gz: the payload minus DEBIAN/, rooted at "./".
        data_tar = tmp / "data.tar.gz"
        with tarfile.open(data_tar, "w:gz") as tar:
            for item in sorted(payload.iterdir()):
                if item.name == "DEBIAN":
                    continue
                tar.add(item, arcname="./" + item.name)

        if out.exists():
            out.unlink()
        with out.open("wb") as f:
            f.write(b"!<arch>\n")
            f.write(_ar_member("debian-binary", b"2.0\n"))
            f.write(_ar_member("control.tar.gz", control_tar.read_bytes()))
            f.write(_ar_member("data.tar.gz", data_tar.read_bytes()))


def gpg_sign_detached(target: Path, key: str) -> Path:
    sig = target.with_suffix(target.suffix + ".asc")
    if sig.exists():
        sig.unlink()
    cmd = ["gpg", "--batch", "--yes", "--armor", "--local-user", key]
    # A passphrase-protected key (the CI release key) needs loopback pinentry so
    # gpg never tries to prompt on a headless runner. An unprotected key (the
    # local throwaway test key) signs fine without it. The passphrase is read
    # from GPG_PASSPHRASE so it never lands on the process argv.
    passphrase = os.environ.get("GPG_PASSPHRASE")
    stdin = None
    if passphrase:
        cmd += ["--pinentry-mode", "loopback", "--passphrase-fd", "0"]
        stdin = (passphrase + "\n").encode()
    cmd += ["--detach-sign", "--output", str(sig), str(target)]
    print("  $ gpg --batch --yes --armor --local-user … --detach-sign")
    subprocess.run(cmd, check=True, input=stdin)
    # Prove the roundtrip immediately.
    run(["gpg", "--verify", str(sig), str(target)])
    return sig


def build_appimage(payload: Path, out_dir: Path, arch: str, version: str) -> Path | None:
    """Assemble an AppDir and (if appimagetool is present) emit an AppImage.

    Without appimagetool (e.g. on macOS) the AppDir is still produced and a
    `.AppDir.tar.gz` archive is emitted so the layout is verifiable; CI runs
    appimagetool to produce the single-file `.AppImage`.
    """
    info = ARCH_MAP[arch]
    appdir = out_dir / f"Fae-{arch}.AppDir"
    if appdir.exists():
        shutil.rmtree(appdir)
    # Mirror the FHS payload (drop DEBIAN/, which is .deb-only).
    shutil.copytree(payload, appdir, ignore=shutil.ignore_patterns("DEBIAN"))

    apprun = appdir / "AppRun"
    apprun.write_text(
        "#!/bin/sh\n"
        'HERE="$(dirname "$(readlink -f "$0")")"\n'
        'exec "$HERE/usr/lib/fae/bin/fae-ui-shell" "$@"\n'
    )
    make_executable(apprun)
    (appdir / "fae.desktop").write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Fae\n"
        "Exec=fae-ui-shell\n"
        "Icon=fae\n"
        "Categories=Utility;\n"
    )
    # A 1x1 placeholder icon keeps appimagetool happy; the real orb icon is P6.
    (appdir / "fae.png").write_bytes(_PLACEHOLDER_PNG)

    appimagetool = shutil.which("appimagetool")
    if appimagetool:
        out = out_dir / f"Fae-{version}-{info['appimage_arch']}.AppImage"
        env = dict(os.environ, ARCH=info["appimage_arch"])
        run([appimagetool, "--no-appstream", str(appdir), str(out)], env=env)
        make_executable(out)
        return out
    # macOS proof: archive the AppDir so its structure is inspectable.
    print("  ! appimagetool absent — emitting AppDir tarball (CI builds the .AppImage)")
    tarball = out_dir / f"Fae-{arch}.AppDir.tar.gz"
    with tarfile.open(tarball, "w:gz") as tar:
        tar.add(appdir, arcname=appdir.name)
    return tarball


# A minimal valid 1x1 transparent PNG.
_PLACEHOLDER_PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000d49444154789c6360000002000001e221bc330000000049454e44ae426082"
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", choices=sorted(ARCH_MAP), required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--daemon", type=Path, required=True, help="path to built fae-daemon")
    ap.add_argument("--ui-shell", type=Path, default=None, help="path to built fae-ui-shell")
    ap.add_argument("--out-dir", type=Path, default=ROOT / "build" / "linux" / "dist")
    ap.add_argument("--gpg-key", default=None, help="GPG key id/fingerprint to sign the .deb")
    ap.add_argument("--skip-appimage", action="store_true")
    args = ap.parse_args()

    if not args.daemon.is_file():
        raise SystemExit(f"daemon not found: {args.daemon}")
    if args.ui_shell is not None and not args.ui_shell.is_file():
        raise SystemExit(f"ui-shell not found: {args.ui_shell}")

    out_dir = args.out_dir.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="fae-pkg-") as td:
        staging = Path(td)
        print(f"== Assembling payload ({args.arch}, v{args.version}) ==")
        payload = assemble_payload(staging, args.arch, args.version, args.daemon, args.ui_shell)
        debian = write_control(staging, payload, args.arch, args.version)

        deb = out_dir / f"{PACKAGE}_{args.version}_{args.arch}.deb"
        print("== Building .deb ==")
        if shutil.which("dpkg-deb"):
            build_deb_dpkg(payload, deb)
        else:
            print("  ! dpkg-deb absent — using portable ar/tar builder (CI uses dpkg-deb)")
            build_deb_portable(payload, debian, deb, args.version, args.arch)
        print(f"  → {deb}  ({deb.stat().st_size} bytes, sha256 {sha256_file(deb)})")

        if args.gpg_key:
            print("== GPG-signing .deb (detached) ==")
            sig = gpg_sign_detached(deb, args.gpg_key)
            print(f"  → {sig} (verified)")
        else:
            print("  ! no --gpg-key: skipping signature (real key is a CI secret)")

        if not args.skip_appimage:
            print("== Building AppImage ==")
            img = build_appimage(payload, out_dir, args.arch, args.version)
            if img:
                print(f"  → {img}  ({img.stat().st_size} bytes)")
                if args.gpg_key and img.suffix == ".AppImage":
                    gpg_sign_detached(img, args.gpg_key)

    print("== done ==")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
