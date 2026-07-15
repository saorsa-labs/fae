#!/usr/bin/env python3
"""Deterministic structural + behavioral tests for Fae release workflows.

No network. No secret values. This suite is a regression guard over the
behavioral contracts of the release/CI surface:

  1. tag ↔ VERSION consistency (preflight version resolution parity),
  2. required-secret fail-closed diagnostics,
  3. runtime-verification fail-closed behavior (SHA + ELF honesty),
  4. Linux artifact integrity / architecture honesty,
  5. the dry-run-vs-tag-push advisory (warning/error) policy,
  plus the intended PR≡tag gate-equivalence contract for the Rust surface.

It inspects the root ``VERSION`` file, the workflow YAML (as text), and the
release helper scripts. Where production logic lives in importable pure-Python
modules (``install-llamacpp-runtime.py``, ``build-linux-package.py``) it imports
those READ-ONLY and exercises real behavior with crafted inputs / fixtures.

The assertions target BEHAVIOR and INVARIANTS, not exact line formatting, so a
refactor that preserves the contract still passes while an edit that silently
weakens a fail-closed branch fails loudly.

Out of scope (intentionally):
  - release-validation.yml / PR template / release-evidence* (QA-owned).
  - cargo-deny advisory policy: ``crates/deny.toml`` has no ``[advisories]``
    section today and the advisory gate is being added separately by the
    security peer; pinning it here would test in-flight code.
  - full PR-vs-tag TEST-suite equivalence (a known uv/skill-install gap at tag
    time); only the *version-resolution* preflight parity is pinned here.

Run:
    python3 scripts/ci/test_release_workflows.py
    python3 -m unittest scripts.ci.test_release_workflows
    python3 scripts/ci/test_release_workflows.py -v
"""

from __future__ import annotations

import io
import json
import os
import re
import struct
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
WF = ROOT / ".github" / "workflows"
SCRIPTS = ROOT / "scripts"

RELEASE_YML = "release.yml"
RELEASE_LINUX_YML = "release-linux.yml"
CI_LINUX_YML = "ci-linux.yml"
RUST_GATE_YML = "rust-gate.yml"
SUPPLY_CHAIN_YML = "supply-chain-gate.yml"

# Release workflows whose preflight must agree on tag ↔ VERSION resolution.
PREFLIGHT_WORKFLOWS = (RELEASE_YML, RELEASE_LINUX_YML)


# ─────────────────────────────────────────────────────────────────────────────
# Text helpers (structural, not line-exact)
# ─────────────────────────────────────────────────────────────────────────────

def _wf_text(name: str) -> str:
    path = WF / name
    return path.read_text(encoding="utf-8")


def _wf_exists(name: str) -> bool:
    return (WF / name).is_file()


def _script_text(name: str) -> str:
    return (SCRIPTS / name).read_text(encoding="utf-8")


def _has_line_with(text: str, *needles: str) -> bool:
    """True if some line contains all needles (case-insensitive)."""
    low = [n.lower() for n in needles]
    return any(all(n in line.lower() for n in low) for line in text.splitlines())


def _step_blocks(text: str) -> list[str]:
    """Split a workflow into per-step text blocks.

    A step begins at a line indented exactly 6 spaces followed by ``- `` (the
    standard ``      - name:`` / ``      - uses:`` step indent). The block runs
    to the next such line. Matrix ``include`` entries (10-space indent) and
    job-level keys (2-space indent) are NOT matched, so each block is one step.
    """
    import re

    starts = [m.start() for m in re.finditer(r"(?m)^      - ", text)]
    starts.append(len(text))
    return [text[starts[i]:starts[i + 1]] for i in range(len(starts) - 1)]


def _steps_referencing(text: str, needle: str) -> list[str]:
    """Step blocks whose text mentions ``needle`` (e.g. a secret name)."""
    return [b for b in _step_blocks(text) if needle in b]


def _matrix_rows(text: str) -> list[tuple[str, str, str]]:
    """Extract (arch, triple, runtime_platform) rows from a workflow matrix.

    The keys appear once per matrix entry, in order, so zipping the ordered
    captures reconstructs each row. Returns [] if the workflow has no matrix.
    """
    import re

    archs = re.findall(r"(?m)^\s+- arch:\s*(\S+)", text)
    triples = re.findall(r"(?m)^\s+triple:\s*(\S+)", text)
    plats = re.findall(r"(?m)^\s+runtime_platform:\s*(\S+)", text)
    if not (len(archs) == len(triples) == len(plats)):
        return []
    return list(zip(archs, triples, plats))


def _first_index(text: str, needle: str) -> int:
    return text.index(needle)


def _import_script(name: str):
    """Import a sibling script as a module (read-only; no side effects at import
    because each script guards ``main()`` under ``__name__ == "__main__"``)."""
    import importlib.util

    path = SCRIPTS / name
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    assert spec and spec.loader, f"cannot import {name}"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _ar_members(data: bytes) -> list[tuple[str, bytes]]:
    """Parse a common-format ``ar`` archive into [(name, payload), ...]."""
    assert data.startswith(b"!<arch>\n"), "bad ar magic"
    members = []
    off = 8
    while off + 60 <= len(data):
        header = data[off:off + 60]
        name = header[0:16].decode("ascii", "replace").rstrip()
        size = int(header[48:58].decode("ascii", "replace").strip())
        body = data[off + 60:off + 60 + size]
        members.append((name, body))
        off += 60 + size
        if size % 2:  # 2-byte member padding
            off += 1
    return members


def _elf64_header(e_machine: int) -> bytes:
    """A minimal 20-byte little-endian 64-bit ELF header with the given e_machine."""
    b = bytearray(20)
    b[0:4] = b"\x7fELF"
    b[4] = 2   # EI_CLASS = ELFCLASS64
    b[5] = 1   # EI_DATA  = ELFDATA2LSB (little-endian)
    struct.pack_into("<H", b, 18, e_machine)
    return bytes(b)


# Standard ELF e_machine codes.
EM_X86_64 = 0x3E
EM_AARCH64 = 0xB7


# ─────────────────────────────────────────────────────────────────────────────
# 1. Tag ↔ VERSION consistency
# ─────────────────────────────────────────────────────────────────────────────

class TestVersionConsistency(unittest.TestCase):
    """VERSION is the canonical version; a pushed tag must equal it (fail-closed)."""

    def test_version_file_is_a_single_semver_token(self):
        raw = (ROOT / "VERSION").read_text(encoding="utf-8")
        version = raw.strip()
        self.assertTrue(version, "VERSION file is empty")
        # The workflow does `cat VERSION | tr -d '[:space:]'`; the file must be
        # one logical token with no internal whitespace.
        self.assertFalse(
            any(ch.isspace() for ch in version),
            f"VERSION contains internal whitespace: {version!r}",
        )
        self.assertRegex(
            version, r"^\d+\.\d+\.\d+", "VERSION is not semver-like (X.Y.Z)"
        )

    def test_legacy_native_version_matches_canonical_root(self):
        canonical = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        legacy = (ROOT / "native/macos/Fae/VERSION").read_text(encoding="utf-8").strip()
        self.assertEqual(
            legacy,
            canonical,
            "native/macos/Fae/VERSION drifted from canonical root VERSION",
        )

    def test_preflight_tag_version_resolution_parity(self):
        """Both release workflows fail-closed when the pushed tag != VERSION.

        Scoped to the PREFLIGHT version-resolution contract (tag strip, compare,
        ::error:: + exit 1, plus a workflow_dispatch override). This deliberately
        does NOT assert full test-suite equivalence between PR CI and the tag
        gate (a known uv/skill-install gap, tracked separately).
        """
        for wf in PREFLIGHT_WORKFLOWS:
            text = _wf_text(wf)
            with self.subTest(workflow=wf):
                # Strips the ``v`` prefix off the tag ref.
                self.assertIn("refs/tags/v", text, f"{wf}: no tag-ref prefix strip")
                # Reads the VERSION file.
                self.assertIn("VERSION", text, f"{wf}: does not read VERSION file")
                # Fail-closed on mismatch: an error annotation on the same line
                # as a version/VERSION reference, and a hard non-zero exit.
                self.assertTrue(
                    _has_line_with(text, "::error::", "version"),
                    f"{wf}: no ::error:: on tag/version mismatch",
                )
                self.assertIn("exit 1", text, f"{wf}: no exit 1 on version mismatch")

    def test_preflight_allows_workflow_dispatch_override(self):
        """A manual dispatch may override the version (dry-run path)."""
        for wf in PREFLIGHT_WORKFLOWS:
            text = _wf_text(wf)
            with self.subTest(workflow=wf):
                self.assertIn("workflow_dispatch", text, f"{wf}: no dispatch trigger")
                # The dispatch path reads an inputs.version override.
                self.assertIn(
                    "inputs.version", text, f"{wf}: no dispatch version input"
                )


# ─────────────────────────────────────────────────────────────────────────────
# 2. Required-secret fail-closed diagnostics
# ─────────────────────────────────────────────────────────────────────────────

# Secrets that MUST be present (non-empty) for a real tag-push release. For each,
# at least one step that references the secret must carry an ::error:: + exit 1
# guard on the missing case. (We assert PRESENCE diagnostics only, never values,
# per the MacRelease contract.)
STRICT_REQUIRED_SECRETS = [
    (RELEASE_YML, "MACOS_CERTIFICATE"),
    (RELEASE_YML, "MACOS_CERTIFICATE_PASSWORD"),
    (RELEASE_YML, "KEYCHAIN_PASSWORD"),
    (RELEASE_YML, "MACOS_SIGNING_IDENTITY"),
    (RELEASE_YML, "MACOS_NOTARIZATION_APPLE_ID"),
    (RELEASE_YML, "MACOS_NOTARIZATION_PASSWORD"),
    (RELEASE_YML, "MACOS_NOTARIZATION_TEAM_ID"),
    (RELEASE_LINUX_YML, "GPG_PASSPHRASE"),
]


class TestRequiredSecretDiagnostics(unittest.TestCase):
    """Every required release secret has a fail-closed missing-secret guard."""

    def test_each_strict_secret_has_error_plus_exit_guard(self):
        for wf, secret in STRICT_REQUIRED_SECRETS:
            text = _wf_text(wf)
            steps = _steps_referencing(text, secret)
            self.assertTrue(
                steps, f"{wf}: no step references required secret {secret}"
            )
            guarded = [
                s for s in steps
                if _has_line_with(s, "::error::") and "exit 1" in s
            ]
            self.assertTrue(
                guarded,
                f"{wf}: secret {secret} is referenced but has no "
                "::error::+exit 1 missing-secret guard",
            )

    def test_release_signing_requires_gpg_keypair(self):
        """The macOS release job signs checksums with GPG_PRIVATE_KEY +
        GPG_PASSPHRASE and hard-fails if either is missing (it only runs on
        push, so there is no dry-run leniency here)."""
        text = _wf_text(RELEASE_YML)
        steps = _steps_referencing(text, "GPG_PRIVATE_KEY")
        # At least one GPG_PRIVATE_KEY step must also require GPG_PASSPHRASE and
        # fail-closed on emptiness.
        guarded = [
            s for s in steps
            if "GPG_PASSPHRASE" in s
            and _has_line_with(s, "::error::")
            and "exit 1" in s
        ]
        self.assertTrue(
            guarded,
            "release.yml: no fail-closed GPG_PRIVATE_KEY+GPG_PASSPHRASE guard",
        )


# ─────────────────────────────────────────────────────────────────────────────
# 3. Runtime-verification fail-closed behavior
# ─────────────────────────────────────────────────────────────────────────────

class TestRuntimeLockSchema(unittest.TestCase):
    """The runtime lock must carry a pinned, SHA-verified entry per platform."""

    @classmethod
    def setUpClass(cls):
        cls.lock = json.loads(
            (SCRIPTS / "llamacpp-runtime.lock.json").read_text(encoding="utf-8")
        )

    def test_all_shipped_platforms_have_entries(self):
        runtimes = self.lock["runtimes"]
        for key in ("macos-arm64", "linux-x86_64", "linux-aarch64"):
            self.assertIn(key, runtimes, f"lock missing platform {key}")

    def test_every_runtime_has_integrity_fields(self):
        required = {
            "binary", "binary_sha256", "binary_size_bytes",
            "sha256", "size_bytes", "url", "asset_name",
        }
        for key, rt in self.lock["runtimes"].items():
            with self.subTest(platform=key):
                missing = required - set(rt)
                self.assertFalse(
                    missing, f"{key}: missing integrity fields {sorted(missing)}"
                )

    def test_hash_fields_are_lowercase_sha256_hex(self):
        for key, rt in self.lock["runtimes"].items():
            for fld in ("sha256", "binary_sha256"):
                with self.subTest(platform=key, field=fld):
                    self.assertRegex(
                        rt[fld], r"^[0-9a-f]{64}$",
                        f"{key}.{fld} is not 64-char lowercase hex",
                    )

    def test_sizes_are_positive_integers(self):
        for key, rt in self.lock["runtimes"].items():
            for fld in ("size_bytes", "binary_size_bytes"):
                with self.subTest(platform=key, field=fld):
                    self.assertIsInstance(rt[fld], int, f"{key}.{fld} not int")
                    self.assertGreater(rt[fld], 0, f"{key}.{fld} not positive")


class TestRuntimeInstallerFailClosed(unittest.TestCase):
    """The runtime installer must refuse unknown platforms and verify bytes."""

    @classmethod
    def setUpClass(cls):
        cls.inst = _import_script("install-llamacpp-runtime.py")
        cls.lock = json.loads(
            (SCRIPTS / "llamacpp-runtime.lock.json").read_text(encoding="utf-8")
        )

    def test_select_runtime_returns_matching_entry(self):
        rt = self.inst.select_runtime(self.lock, "linux-x86_64")
        self.assertEqual(rt["platform"], "linux-x86_64")

    def test_select_runtime_unknown_platform_fails_closed(self):
        with self.assertRaises(SystemExit):
            self.inst.select_runtime(self.lock, "linux-itanium")

    def test_select_runtime_empty_lock_fails_closed(self):
        with self.assertRaises(SystemExit):
            self.inst.select_runtime({"runtimes": {}}, "linux-x86_64")

    def test_sha256_file_matches_stdlib_hashlib(self):
        import hashlib

        payload = b"fae-release-integrity-probe"
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(payload)
            path = Path(f.name)
        try:
            self.assertEqual(
                self.inst.sha256_file(path),
                hashlib.sha256(payload).hexdigest(),
            )
        finally:
            os.unlink(path)

    def test_sha256_file_detects_single_byte_tamper(self):
        a = tempfile.NamedTemporaryFile(delete=False)
        b = tempfile.NamedTemporaryFile(delete=False)
        try:
            a.write(b"payload-A"); a.close()
            b.write(b"payload-B"); b.close()
            self.assertNotEqual(
                self.inst.sha256_file(Path(a.name)),
                self.inst.sha256_file(Path(b.name)),
            )
        finally:
            os.unlink(a.name)
            os.unlink(b.name)

    def test_archive_format_of_honors_explicit_field(self):
        rt = {"archive_format": "tar.gz", "asset_name": "x.zip"}
        self.assertEqual(self.inst.archive_format_of(rt), "tar.gz")

    def test_archive_format_of_infers_from_asset_name(self):
        self.assertEqual(
            self.inst.archive_format_of({"asset_name": "x.zip"}), "zip"
        )
        self.assertEqual(
            self.inst.archive_format_of({"asset_name": "x.tar.gz"}), "tar.gz"
        )


class TestAppimagetoolShaGate(unittest.TestCase):
    """appimagetool is fetched + SHA-verified BEFORE it is ever executed."""

    def test_no_mutable_continuous_download(self):
        text = _wf_text(RELEASE_LINUX_YML)
        self.assertNotIn(
            "download/continuous", text,
            "appimagetool must be pinned to a fixed tag, not the mutable "
            "'continuous' tag (supply-chain: an unverified re-upload would run "
            "with the release signing key in scope)",
        )

    def test_pinned_sha256_constants_present(self):
        # Each arch pins a concrete 64-hex SHA-256 constant (≥2: amd64 + arm64).
        import re

        text = _wf_text(RELEASE_LINUX_YML)
        digests = re.findall(r"\b[0-9a-f]{64}\b", text)
        self.assertGreaterEqual(
            len(digests), 2, "expected ≥2 pinned sha256 constants for appimagetool"
        )

    def test_verified_before_exec_and_fail_closed(self):
        text = _wf_text(RELEASE_LINUX_YML)
        steps = _steps_referencing(text, "appimagetool")
        # The fetch/verify step is the one that performs a sha256 compare.
        verify_steps = [s for s in steps if "sha256" in s and "mismatch" in s]
        self.assertTrue(
            verify_steps, "no appimagetool step performs a sha256 mismatch check"
        )
        step = verify_steps[0]
        # Fail-closed on mismatch.
        self.assertTrue(_has_line_with(step, "::error::"), "no ::error:: on mismatch")
        self.assertIn("exit 1", step, "no exit 1 on sha mismatch")
        # The compare must precede making the fetched binary executable. We
        # locate the mismatch check and the chmod within the WHOLE file so the
        # ordering invariant is asserted against absolute position, not a regex.
        mismatch_pos = _first_index(text, "sha256 mismatch")
        chmod_pos = _first_index(text, "chmod +x /tmp/appimagetool")
        self.assertLess(
            mismatch_pos, chmod_pos,
            "appimagetool must be sha256-verified BEFORE chmod +x / exec",
        )


class TestLinuxRuntimeIntegrityGate(unittest.TestCase):
    """The Linux integrity gate re-verifies the bundled runtime against the lock
    and requires a GPG signature on tag pushes."""

    def test_gate_asserts_size_and_sha_against_lock(self):
        text = _wf_text(RELEASE_LINUX_YML)
        steps = _steps_referencing(text, "binary_sha256")
        self.assertTrue(steps, "no step re-verifies binary_sha256 against the lock")
        step = steps[0]
        self.assertIn("binary_size_bytes", step, "gate does not check binary size")
        self.assertIn("binary_sha256", step, "gate does not check binary sha256")

    def test_gate_requires_gpg_verify_on_tag_push(self):
        text = _wf_text(RELEASE_LINUX_YML)
        steps = _steps_referencing(text, "GPG_PRIVATE_KEY")
        # The integrity-gate step performs gpg --verify and fails closed on tag.
        gated = [
            s for s in steps
            if "gpg --verify" in s and "refs/tags/v" in s
            and _has_line_with(s, "::error::") and "exit 1" in s
        ]
        self.assertTrue(
            gated,
            "no integrity-gate step performs gpg --verify with a tag-push "
            "fail-closed branch",
        )


# ─────────────────────────────────────────────────────────────────────────────
# 4. Linux artifact integrity / architecture honesty
# ─────────────────────────────────────────────────────────────────────────────

class TestArchMapHonesty(unittest.TestCase):
    """ARCH_MAP (Debian arch ↔ triple ↔ runtime platform) must be self-consistent
    and cover exactly the two shipped Linux architectures."""

    @classmethod
    def setUpClass(cls):
        cls.builder = _import_script("build-linux-package.py")
        cls.lock = json.loads(
            (SCRIPTS / "llamacpp-runtime.lock.json").read_text(encoding="utf-8")
        )

    def test_exactly_two_linux_arches(self):
        self.assertEqual(set(self.builder.ARCH_MAP), {"amd64", "arm64"})

    def test_no_cross_arch_contamination(self):
        am = self.builder.ARCH_MAP
        self.assertIn("x86_64", am["amd64"]["triple"])
        self.assertIn("x86_64", am["amd64"]["runtime_platform"])
        self.assertIn("x86_64", am["amd64"]["appimage_arch"])
        self.assertIn("aarch64", am["arm64"]["triple"])
        self.assertIn("aarch64", am["arm64"]["runtime_platform"])
        self.assertIn("aarch64", am["arm64"]["appimage_arch"])
        # No arch resolves to the OTHER arch's family.
        self.assertNotIn("aarch64", am["amd64"]["triple"])
        self.assertNotIn("x86_64", am["arm64"]["triple"])

    def test_every_arch_has_a_pinned_runtime_in_the_lock(self):
        """Architecture honesty: each buildable arch must map to a SHA-pinned
        runtime entry — no arch ships an unverified/missing runtime."""
        runtimes = self.lock["runtimes"]
        for arch, info in self.builder.ARCH_MAP.items():
            with self.subTest(arch=arch):
                self.assertIn(
                    info["runtime_platform"], runtimes,
                    f"{arch} → {info['runtime_platform']} has no lock entry",
                )


class TestWorkflowMatrixParity(unittest.TestCase):
    """The build and CI workflow matrices must agree with ARCH_MAP exactly."""

    @classmethod
    def setUpClass(cls):
        cls.builder = _import_script("build-linux-package.py")

    def _check(self, wf: str):
        rows = _matrix_rows(_wf_text(wf))
        self.assertTrue(rows, f"{wf}: no matrix rows parsed")
        am = self.builder.ARCH_MAP
        self.assertEqual(
            {r[0] for r in rows}, set(am),
            f"{wf}: matrix arches {sorted(r[0] for r in rows)} != ARCH_MAP {sorted(am)}",
        )
        for arch, triple, plat in rows:
            with self.subTest(workflow=wf, arch=arch):
                self.assertEqual(triple, am[arch]["triple"])
                self.assertEqual(plat, am[arch]["runtime_platform"])

    def test_release_linux_matrix_matches_arch_map(self):
        self._check(RELEASE_LINUX_YML)

    def test_ci_linux_matrix_matches_arch_map(self):
        self._check(CI_LINUX_YML)


class TestDebIntegrity(unittest.TestCase):
    """The portable .deb builder (no dpkg-deb, no network) produces a valid
    Debian archive whose control file carries the honest arch."""

    @classmethod
    def setUpClass(cls):
        cls.builder = _import_script("build-linux-package.py")

    def _make_payload(self, staging: Path, arch: str, version: str):
        payload = staging / "payload"
        (payload / "usr/lib/fae/bin").mkdir(parents=True)
        (payload / "usr/lib/fae/bin/fae-daemon").write_bytes(b"FAKE-DAEMON")
        return payload, self.builder.write_control(staging, payload, arch, version)

    def test_portable_deb_is_valid_ar_archive(self):
        b = self.builder
        with tempfile.TemporaryDirectory() as td:
            staging = Path(td)
            payload, debian = self._make_payload(staging, "amd64", "9.9.9")
            out = staging / "fae_9.9.9_amd64.deb"
            b.build_deb_portable(payload, debian, out, "9.9.9", "amd64")
            data = out.read_bytes()

        # ar magic + exactly three members in canonical order.
        self.assertTrue(data.startswith(b"!<arch>\n"), "bad ar magic")
        members = _ar_members(data)
        names = [m[0] for m in members]
        self.assertEqual(
            names, ["debian-binary", "control.tar.gz", "data.tar.gz"],
            f"unexpected .deb members: {names}",
        )
        # debian-binary payload is "2.0\n".
        self.assertEqual(members[0][1], b"2.0\n")

    def test_control_file_carries_honest_arch_and_version(self):
        b = self.builder
        with tempfile.TemporaryDirectory() as td:
            staging = Path(td)
            payload, debian = self._make_payload(staging, "arm64", "7.7.7")
            out = staging / "fae_7.7.7_arm64.deb"
            b.build_deb_portable(payload, debian, out, "7.7.7", "arm64")
            members = _ar_members(out.read_bytes())
            with tarfile.open(fileobj=io.BytesIO(members[1][1])) as tar:
                ctrl = tar.extractfile("control").read().decode()

        self.assertIn("Architecture: arm64", ctrl)
        self.assertIn("Version: 7.7.7", ctrl)
        self.assertIn("Package: fae", ctrl)
        # arm64 deb must NOT be mislabeled amd64.
        self.assertNotIn("Architecture: amd64", ctrl)


class TestElfArchVerifier(unittest.TestCase):
    """verify_elf_arch is the honesty gate: a binary is only accepted under the
    arch label its ELF header truly declares. Uses crafted ELF headers (no real
    binaries, no execution)."""

    @classmethod
    def setUpClass(cls):
        cls.builder = _import_script("build-linux-package.py")
        if not hasattr(cls.builder, "verify_elf_arch"):
            raise unittest.SkipTest("verify_elf_arch not present in build-linux-package.py")

    def _write(self, data: bytes) -> Path:
        f = tempfile.NamedTemporaryFile(delete=False, suffix=".elf")
        f.write(data)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return Path(f.name)

    def test_amd64_elf_accepted_for_amd64(self):
        p = self._write(_elf64_header(EM_X86_64))
        self.assertEqual(self.builder.verify_elf_arch(p, "amd64"), "x86-64")

    def test_aarch64_elf_accepted_for_arm64(self):
        p = self._write(_elf64_header(EM_AARCH64))
        self.assertEqual(self.builder.verify_elf_arch(p, "arm64"), "aarch64")

    def test_cross_arch_rejected(self):
        # An x86_64 binary must NOT be accepted as arm64 (and vice versa).
        x86 = self._write(_elf64_header(EM_X86_64))
        arm = self._write(_elf64_header(EM_AARCH64))
        with self.assertRaises(SystemExit):
            self.builder.verify_elf_arch(x86, "arm64")
        with self.assertRaises(SystemExit):
            self.builder.verify_elf_arch(arm, "amd64")

    def test_non_elf_rejected(self):
        p = self._write(b"not an elf binary at all")
        with self.assertRaises(SystemExit):
            self.builder.verify_elf_arch(p, "amd64")

    def test_thirtytwo_bit_rejected(self):
        b = bytearray(_elf64_header(EM_X86_64))
        b[4] = 1  # ELFCLASS32
        p = self._write(bytes(b))
        with self.assertRaises(SystemExit):
            self.builder.verify_elf_arch(p, "amd64")

    def test_unknown_arch_label_rejected(self):
        p = self._write(_elf64_header(EM_X86_64))
        with self.assertRaises(SystemExit):
            self.builder.verify_elf_arch(p, "mips")


# ─────────────────────────────────────────────────────────────────────────────
# 5. Advisory policy: dry-run lenient (::warning::) vs tag-push strict
# ─────────────────────────────────────────────────────────────────────────────

# Secrets that opt into the DUAL-MODE advisory policy: a tag push hard-fails
# (::error:: + exit 1) while a workflow_dispatch dry-run only warns.
DUAL_MODE_SECRETS = [
    (RELEASE_YML, "SPARKLE_KEY"),
    (RELEASE_LINUX_YML, "GPG_PRIVATE_KEY"),
]


class TestAdvisoryPolicy(unittest.TestCase):
    """The dual-mode advisory contract: strict on tag push, lenient on dispatch.

    Fae uses three distinct fail-closed idioms (pinned separately so the suite
    reflects REAL behavior, not a uniform pattern):
      (1) Dual-mode inline IS_TAG_PUSH — tag push ::error::+exit 1, dispatch
          ::warning::. Pinned HERE for SPARKLE_KEY (release.yml) and
          GPG_PRIVATE_KEY (release-linux.yml build/gate).
      (2) Step-level ``if: env.RELEASE_DRY_RUN != 'true'`` — the whole
          signing/notarization step is SKIPPED on a dry run (no warning).
          Pinned as "guard exists" in TestRequiredSecretDiagnostics
          (idiom-agnostic, robust to MacRelease's early-diagnostics shift).
      (3) Job-gated, no leniency — release.yml's checksums GPG step lives in
          the ``release`` job which only runs on push. Safe because the job is
          unreachable on dispatch; pinned in TestPublishJobTagGating.
    """

    def test_dual_mode_secrets_warn_and_fail_closed(self):
        for wf, secret in DUAL_MODE_SECRETS:
            text = _wf_text(wf)
            steps = _steps_referencing(text, secret)
            self.assertTrue(steps, f"{wf}: no step references {secret}")
            with self.subTest(workflow=wf, secret=secret):
                # The tag-push discriminator gates the strict branch.
                self.assertTrue(
                    any("refs/tags/v" in s for s in steps),
                    f"{wf}/{secret}: no refs/tags/v tag-push discriminator",
                )
                # Strict: a tag push with the secret missing hard-fails.
                self.assertTrue(
                    any(_has_line_with(s, "::error::") and "exit 1" in s for s in steps),
                    f"{wf}/{secret}: no tag-push ::error::+exit 1 fail-closed",
                )
                # Lenient: a dry run only warns (does not exit non-zero).
                self.assertTrue(
                    any("::warning::" in s for s in steps),
                    f"{wf}/{secret}: no dry-run ::warning:: advisory",
                )

    def test_advisory_secret_failures_precede_publish(self):
        """A dual-mode secret's fail-closed branch must live in a BUILD/verify
        job, not only in the publish job — so a missing secret fails the build
        before any artifact is published."""
        text = _wf_text(RELEASE_LINUX_YML)
        # The first GPG ::error:: must appear before the publish job's signature
        # attachment step (the last gate). We use the appimagetool fetch as a
        # proxy for "build job" ordering vs the publish job's "Attach ... release".
        first_gpg_error = text.index("::error::GPG_PRIVATE_KEY")
        attach_pos = text.index("Attach Linux artifacts to release")
        self.assertLess(
            first_gpg_error, attach_pos,
            "GPG fail-closed should fire in the build job, before publish",
        )


class TestRustSecExceptionPolicy(unittest.TestCase):
    """Reviewed unmaintained notices are narrow and time-bound.

    supply-chain-gate.yml has not landed on main: the shipped cargo-deny gate
    (ci-linux.yml) deliberately scopes to licenses+bans+sources, excluding
    `advisories` so a newly-published RustSec notice on an unrelated dep can't
    spuriously red the license/provenance gate. A dedicated advisory gate needs
    a fresh security assessment of the ignore list before it lands; these tests
    activate the moment the workflow exists (same pattern as the rust-gate.yml
    equivalence tests below)."""

    def test_only_assessed_unmaintained_notices_are_ignored(self):
        if not _wf_exists(SUPPLY_CHAIN_YML):
            self.skipTest(f"{SUPPLY_CHAIN_YML} not yet present (advisory gate pending)")
        text = _wf_text(SUPPLY_CHAIN_YML)
        ignored = set(re.findall(r"--ignore (RUSTSEC-\d{4}-\d{4})", text))
        self.assertEqual(
            ignored,
            {
                "RUSTSEC-2025-0057",
                "RUSTSEC-2025-0119",
                "RUSTSEC-2024-0436",
            },
        )
        self.assertNotIn("--ignore RUSTSEC-2026-0204", text)
        self.assertNotIn("--ignore RUSTSEC-2026-0185", text)
        self.assertIn("cargo audit --deny warnings", text)

    def test_reviewed_exceptions_expire_fail_closed(self):
        if not _wf_exists(SUPPLY_CHAIN_YML):
            self.skipTest(f"{SUPPLY_CHAIN_YML} not yet present (advisory gate pending)")
        text = _wf_text(SUPPLY_CHAIN_YML)
        self.assertIn('review_by = dt.date.fromisoformat("2026-08-12")', text)
        self.assertIn("dt.date.today() >= review_by", text)
        self.assertIn("raise SystemExit", text)
        self.assertIn("Security assessment b284b683", text)


class TestPublishJobTagGating(unittest.TestCase):
    """Publishing runs ONLY on real tag pushes. This is the structural reason
    idiom (3) — release.yml's checksums GPG step, which carries NO dry-run
    leniency — is safe: the enclosing job is unreachable on a workflow_dispatch,
    so its unconditional ::error::+exit 1 can never fire outside a real release.
    A regression that let publishing run on dispatch would break that safety."""

    def test_macos_release_job_is_push_only(self):
        text = _wf_text(RELEASE_YML)
        self.assertIn(
            "github.event_name == 'push'", text,
            "release.yml: the release job must be gated to push-only "
            "(push-only publish is why the unconditional GPG guard needs no "
            "dry-run leniency)",
        )

    def test_macos_dispatch_is_always_unsigned_dry_run(self):
        text = _wf_text(RELEASE_YML)
        self.assertIn(
            "RELEASE_DRY_RUN: ${{ github.event_name != 'push' }}",
            text,
            "workflow_dispatch must never import production signing credentials",
        )
        self.assertNotIn("github.event.inputs.dry_run", text)
        for secret in (
            "MACOS_CERTIFICATE",
            "MACOS_CERTIFICATE_PASSWORD",
            "KEYCHAIN_PASSWORD",
            "MACOS_SIGNING_IDENTITY",
            "MACOS_NOTARIZATION_APPLE_ID",
            "MACOS_NOTARIZATION_PASSWORD",
            "MACOS_NOTARIZATION_TEAM_ID",
            "SPARKLE_KEY",
            "GPG_PRIVATE_KEY",
            "GPG_PASSPHRASE",
        ):
            scoped = (
                "startsWith(github.ref, 'refs/tags/v') && "
                f"secrets.{secret} || ''"
            )
            self.assertIn(scoped, text, f"{secret} is not tag-scoped")
            self.assertNotIn(
                f"{secret}: ${{{{ secrets.{secret} }}}}",
                text,
                f"workflow_dispatch runner can receive {secret}",
            )

    def test_linux_dispatch_cannot_access_signing_secrets(self):
        text = _wf_text(RELEASE_LINUX_YML)
        scoped = "startsWith(github.ref, 'refs/tags/v') && secrets.GPG_PRIVATE_KEY || ''"
        self.assertGreaterEqual(text.count(scoped), 2)
        self.assertIn("workflow_dispatch is an unsigned dry-run", text)

    def test_linux_publish_job_is_tag_only(self):
        text = _wf_text(RELEASE_LINUX_YML)
        self.assertIn("github.event_name == 'push'", text)
        self.assertIn(
            "startsWith(github.ref, 'refs/tags/v')", text,
            "release-linux.yml: publish job must be gated to v* tag pushes",
        )


# ─────────────────────────────────────────────────────────────────────────────
# 6. Intended PR ≡ tag gate equivalence (Rust surface)
# ─────────────────────────────────────────────────────────────────────────────

class TestRustGateEquivalence(unittest.TestCase):
    """The authoritative Rust gate (rust-gate.yml, workflow_call) runs identically
    on PR and tag so the correctness/security gate cannot drift. Three checks:
      - the gate's OWN content (authoritative prod policy): enforced once landed.
      - the LINUX PR↔tag pair (ci-linux.yml ≡ release-linux.yml) invoke the SAME
        gate: hard-asserted — this is the literal "equivalent by construction"
        contract, independent of the macOS path's status.
      - the macOS release path (release.yml): wired-good, or an owner-accepted
        check-only gap under separate review (recorded, not failed).
    """

    REQUIRED_GATE_MARKERS = [
        "workflow_call",      # reusable workflow
        "cargo fmt",          # formatting gate
        "cargo clippy",       # lint gate
        "-D warnings",        # warnings are errors
        "--locked",           # lockfile must be committed
    ]
    SAFETY_LINTS = [
        "clippy::panic", "clippy::unwrap_used", "clippy::expect_used",
    ]
    # Reusable-workflow invocation form (a proper `uses:` line, not a comment).
    _USES_RE = r"(?m)^\s*uses:\s*\.{0,2}/?\.github/workflows/rust-gate\.yml"
    # The two paths that MUST be gate-equivalent: PR gate and Linux tag gate.
    EQUIVALENCE_PAIR = [CI_LINUX_YML, RELEASE_LINUX_YML]

    def test_gate_is_authoritative_when_present(self):
        """The reusable gate carries the full prod policy the moment it lands."""
        if not _wf_exists(RUST_GATE_YML):
            self.skipTest(f"{RUST_GATE_YML} not yet present (CIArchitect in flight)")
        gate_text = _wf_text(RUST_GATE_YML)
        for marker in self.REQUIRED_GATE_MARKERS:
            with self.subTest(marker=marker):
                self.assertIn(marker, gate_text, f"rust-gate.yml missing {marker}")
        for lint in self.SAFETY_LINTS:
            with self.subTest(lint=lint):
                self.assertIn(lint, gate_text, f"rust-gate.yml missing {lint}")
        # The gate runs tests (nextest or cargo test), not just build/lint — a
        # gate that only compiles cannot catch behavioral regressions.
        self.assertRegex(
            gate_text, r"nextest run|cargo test",
            "rust-gate.yml runs no tests",
        )

    def test_linux_pr_and_tag_invoke_same_gate(self):
        """ci-linux.yml (PR) and release-linux.yml (tag) both delegate to the
        shared rust-gate.yml via `uses:` — equivalent by construction, so the
        PR and tag gates cannot drift. Hard-asserted as soon as the reusable
        gate exists; independent of the macOS path's status."""
        if not _wf_exists(RUST_GATE_YML):
            self.skipTest(f"{RUST_GATE_YML} not yet present")
        for wf in self.EQUIVALENCE_PAIR:
            with self.subTest(path=wf):
                self.assertRegex(
                    _wf_text(wf), self._USES_RE,
                    f"{wf} must invoke rust-gate.yml via uses: "
                    "(PR≡tag gate equivalence)",
                )

    def test_macos_release_path_gate_or_accepted_gap(self):
        """release.yml's macOS path SHOULD delegate to the shared gate too.

        Precision on what this wiring does/does not close (keeps bookkeeping
        honest — a green result here is NOT 'macOS fully covered'):
          (a) It CLOSES the PR<->tag gate DRIFT: the macOS release job now runs
              the authoritative Rust gate at tag time, so PR and tag can't
              diverge.
          (b) It does NOT close the macOS-native coverage residual: rust-gate.yml
              is `runs-on: linux`, so macOS cfg branches of fae-daemon/fae-engine/
              fae-audio/fae-ui-shell remain COMPILE-checked-only (the separate
              macOS `cargo check`). That residual is an owner-accepted cost
              decision under separate review (CIArchitect -> Main) — open as a
              documented risk, but no longer a drift.

        If release.yml is wired: assert a proper `uses:` invocation. If not:
        skip (the accepted-gap state), never fail on that decision."""
        if not _wf_exists(RUST_GATE_YML):
            self.skipTest(f"{RUST_GATE_YML} not yet present")
        text = _wf_text(RELEASE_YML)
        if not re.search(self._USES_RE, text):
            self.skipTest(
                "release.yml macOS path does not invoke rust-gate.yml "
                "(check-only residual; owner-accepted gap under review) — "
                "not a gate-equivalence failure"
            )
        # Wired: must be a real reusable-workflow invocation.
        self.assertRegex(
            text, self._USES_RE,
            "release.yml must invoke rust-gate.yml via uses: (reusable workflow)",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
