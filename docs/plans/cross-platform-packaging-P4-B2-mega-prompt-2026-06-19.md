# P4 / B2 — Cross-platform packaging + CI for Linux (x86_64 + aarch64) (mega-prompt, 2026-06-19)

> **Role split.** You are the IMPLEMENTING TEAM. The main session is the REVIEWER and verifies your
> hand-back against the **real git diff + a re-run gate + live/CI output**, not your report
> (static-only review has missed a release-blocking bug here, and an agent once fabricated a report).
> Implement AND test to completion, then HAND BACK with verbatim self-captured evidence. **Do NOT
> commit or push** — the reviewer commits and triggers CI.
>
> **Your worktree:** create your OWN dedicated worktree and work only there — do not touch my tree:
> `git worktree add /Users/davidirvine/Desktop/Devel/projects/fae-p4 -b p4-packaging llamacpp-serving-adapter`
> (branch off trunk `llamacpp-serving-adapter` @ 9d3460fe). Read this prompt by absolute path.

## Objective & scope (owner decisions — do not relitigate)

Take the Fae **brain** (Rust `fae-daemon` + `fae-ui-shell` orb-host + the integrity-gated llama.cpp
runtime) cross-platform to **Linux x86_64 AND linux-aarch64**, with **full native installers**
(`.deb` + AppImage, GPG-signed) and CI that builds + integrity-gates each target.

**IN scope:** linux-x86_64, linux-aarch64. Multi-platform runtime lock; platform-aware runtime
resolution + install; `.deb` + AppImage packaging with GPG signing; a Linux CI matrix that builds,
tests, packages, and integrity-gates; extend the B1 SHA-pin gate into CI for Linux.

**OUT of scope (do NOT build):** Windows, macOS-x86_64 (Intel). The macOS Swift app is unchanged —
off-Mac the product is the daemon + orb-host only (no Swift). The Linux **orb render** quality is
P6/D1 (a `linux-render-spike.yml` PoC already exists) — package the orb-host binary, but do not chase
WebKitGTK render defects here. Don't break the macOS path.

**DONE:** a release build for linux-x86_64 AND linux-aarch64 produces a runnable, **integrity-gated**
llama.cpp runtime + a GPG-signed `.deb` and an AppImage bundling daemon + orb-host + runtime +
`models.lock`; CI builds + verifies both targets green; the macOS release path still works.

## Verified current state (anchors — confirm before relying on them)

### CI / packaging — macOS-arm64 ONLY today
- `.github/workflows/ci.yml`: lint on `ubuntu-latest`; build + test on `macos-26` (arm64, no matrix).
- `.github/workflows/release.yml`: single `build-macos` job (`macos-26`, arch=arm64) — builds Swift
  app + `fae-ui-shell` + `fae-daemon`, installs the llama.cpp runtime, signs every Mach-O, notarizes,
  builds a DMG. `release:` job on ubuntu makes the GitHub release.
- `.github/workflows/linux-render-spike.yml`: manual PoC — builds the orb-shell on ubuntu + screenshot;
  installs cargo-zigbuild + Zig 0.13.0. NO release artifacts. (Reuse its setup as a starting point.)
- **B1 integrity gate** lives in `release.yml` ("Verify embedded fae-daemon and llama.cpp runtime"):
  `test -x` + `codesign --verify --verbose=2` on `fae-daemon` and `LlamaCpp/llama-server`. macOS-only.

### Runtime lock + install — macOS-arm64 single entry
- `scripts/llamacpp-runtime.lock.json`: ONE entry, `platform: "macos-arm64"`, release_tag `b9692`,
  asset `llama-b9692-bin-macos-arm64.tar.gz`, with `size_bytes`/`sha256` (archive) +
  `binary`/`binary_size_bytes`/`binary_sha256` + `signed_cdhash_sha256`/`signed_team_identifier`.
- `scripts/install-llamacpp-runtime.py`: reads the lock, downloads the asset, **verifies archive
  size+sha256 then binary size+sha256**, extracts to `native/macos/Fae/Resources/LlamaCpp`. macOS-only
  default path; assumes a `.tar.gz` and binary name `llama-server`.
- `justfile`: `_embed-llamacpp-runtime` runs the install script + copies into the bundle; `bundle-native`
  orchestrates build→embed→sign→verify.

### Daemon runtime resolution — mostly portable, macOS-hardcoded specifics
- `crates/fae-daemon/src/main.rs`: `resolve_llama_server_binary()` (≈385) tries `FAE_LLAMA_BIN` →
  bundled (`../Resources/LlamaCpp/llama-server`) → `FAE_LLAMACPP_RUNTIME_DIR/llama-server` →
  `<data>/runtimes/llamacpp/llama-server`. `data_directory()` (≈801) already branches macOS vs
  XDG/Linux. **Hardcoded:** binary name `llama-server` (no `.exe`, fine for Linux), artifact ID
  `LLAMA_SERVER_BINARY_ARTIFACT_ID = "llamacpp-b9692-llama-server-macos-arm64"`, `bundled_llama_server_path()`
  macOS layout. `verify_signed_llama_server_binary()` is macOS-codesign; non-macOS falls to the
  unsigned size+sha256 gate (`verify_unsigned_llama_server_binary()`, ≈458) against `models.lock`.
- `crates/fae-engine/src/models_lock.rs`: schema v1, **fail-closed** `artifact.verify()` (exists +
  size + 64-hex sha256; rejects placeholder `<64-hex-sha256>`). FULLY portable. `FAE_MODELS_LOCK=off`
  only under `FAE_DEV`.
- The primary Gemma GGUF + mmproj + MTP drafter are `PinnedHuggingFace`, integrity-checked at
  materialize (`preflight_pinned_artifacts`), **not in `models.lock`** — already fail-closed, just not
  in the lock file. (Don't move them into the lock unless you find a concrete gap; the HF pin is the
  gate. If you do touch it, keep it fail-closed.)

## Verifiability reality (READ THIS — shapes how you prove things)
- Linux binaries **cannot run on this macOS host**. Use **Docker** for live Linux proof:
  **linux/arm64 runs NATIVELY on this Apple-Silicon Mac** (fast, real); **linux/amd64 runs under
  emulation** (slower but real). Check `docker info` first; if Docker is unavailable, say so and prove
  what you can (cross-compile builds + script SHA-verify + unit tests), and clearly mark the run-proof
  as CI-only.
- Cross-compile the Rust binaries with the existing **cargo-zigbuild** toolchain (`--target
  x86_64-unknown-linux-gnu` / `aarch64-unknown-linux-gnu`). `env -u RUSTFLAGS`.
- **"CI green" is the reviewer's gate**: you cannot push, so you cannot trigger real CI. Write the CI
  workflow, validate its YAML/logic as far as possible (and locally reproduce each step's commands),
  and the REVIEWER pushes `p4-packaging` to trigger CI and verifies green before merge. Make every CI
  step a command you have ALSO run locally (in Docker / cross-compile) so the workflow is not blind.

## Sub-decisions (defaults — change only with evidence, and document the choice)
1. **llama.cpp Linux build variant:** default to the **CPU / portable** prebuilt from ggml-org releases
   (broadest hardware). GPU (Vulkan/CUDA) variants are later. Pin whatever you choose with size+sha256.
2. **linux-aarch64 prebuilt availability:** ggml-org publishes `llama-bXXXX-bin-ubuntu-x64.zip` reliably;
   an **ubuntu-arm64 prebuilt may NOT exist** for tag b9692. CHECK the actual release assets. If no
   arm64 prebuilt exists: either (a) pick a release tag that has one, or (b) build llama-server from
   source for arm64 in CI and pin the produced binary's sha256. Resolve this with EVIDENCE (the real
   asset list), not a guess — it's the riskiest unknown. Keep all targets on the SAME release_tag if
   possible.
3. **Packaging format:** produce BOTH a `.deb` (primary, GPG-signed) and an **AppImage** (portable
   single-file) per arch. If one proves impractical in the time, ship the other and LOUDLY flag the gap.
4. **GPG signing:** for your LOCAL proof, generate a throwaway test key and prove the sign→verify
   roundtrip on the `.deb`. The REAL release key is a CI secret the owner provisions — reference it as
   `${{ secrets.LINUX_GPG_PRIVATE_KEY }}` (+ passphrase) and HAND BACK the exact secret names the owner
   must set. Never commit a private key.

## Work items (dependency order — each a hand-back checkpoint)

### Stage 1 — Multi-platform runtime lock + platform-aware install
- Extend `llamacpp-runtime.lock.json` to carry **per-platform entries** (`macos-arm64` unchanged +
  `linux-x86_64` + `linux-aarch64`), each with real asset name/url/size/sha256 + binary name/size/sha256
  (resolve sub-decision #2 here, with the real ggml-org asset list as evidence). Keep the schema
  backward-compatible (macOS install must still work).
- Make `install-llamacpp-runtime.py` **platform-aware**: detect OS+arch, select the entry, handle
  `.zip` (Linux) as well as `.tar.gz`, verify archive+binary size/sha256, install to a per-platform dir.
- Done: running the installer for each Linux target downloads + SHA-verifies the real asset (prove the
  SHA match verbatim); macOS install still works.

### Stage 2 — Platform-aware daemon runtime resolution (Rust)
- Generalize `LLAMA_SERVER_BINARY_ARTIFACT_ID` and `bundled_llama_server_path()` per `#[cfg(target_os)]`
  / arch; keep the binary name `llama-server` on Linux. Ensure the unsigned size+sha256 gate
  (`verify_unsigned_llama_server_binary`) looks up the correct per-platform artifact ID from
  `models.lock`. Add `models.lock` entries for the Linux llama-server binaries (size+sha256 from
  Stage 1).
- Done: `env -u RUSTFLAGS` unit tests for the per-platform artifact-ID/path selection; cross-compiled
  daemon for both Linux targets builds clean.

### Stage 3 — Linux packaging (.deb + AppImage, GPG-signed)
- Produce, per arch, a `.deb` and an AppImage bundling: `fae-daemon`, `fae-ui-shell`, the integrity-
  gated llama.cpp runtime dir, and the shipped `models.lock`. Install to sane Linux paths (FHS for the
  `.deb`; self-contained for the AppImage). GPG-sign the `.deb` and prove `dpkg-sig`/`gpg --verify` (or
  equivalent) passes with your test key.
- Add `justfile` recipes (platform-detecting; don't break the macOS recipes) and/or scripts under
  `scripts/` for the Linux package build. Keep it surgical.
- Done: a `.deb` + AppImage exist for at least linux-x86_64 (and linux-aarch64 if its runtime resolved
  in Stage 1); GPG sign→verify roundtrip proven.

### Stage 4 — CI (Linux x64 + arm64 build/test/package/integrity-gate)
- Add a Linux release path (extend `release.yml` with a matrix, or a sibling `release-linux.yml`):
  per arch — checkout, cargo-zigbuild the Rust binaries, run the install script (download + SHA-verify
  the runtime), run the crate gate (`fmt`/`clippy -D warnings`/`nextest`), package `.deb` + AppImage,
  GPG-sign, and **extend the B1 integrity gate**: verify the runtime binary size+sha256 against the lock
  AND `gpg --verify` the `.deb`. Fail the job if any check fails.
- Add Linux to `ci.yml` as appropriate (at least build the Rust workspace for the Linux targets).
- Every CI step must mirror a command you ran locally. Done: the workflow YAML is valid and each step is
  locally reproduced; you've listed exactly what the reviewer's push will trigger.

### Stage 5 — Live proof
- **Docker run-smoke** (if Docker available): in a `linux/arm64` container (native) AND, if feasible, a
  `linux/amd64` container (emulated), install the `.deb` (or run the AppImage), start `fae-daemon`, and
  show it resolves + integrity-verifies the bundled `llama-server` and comes up (a `runtime.status` or
  daemon-ready log line). Capture verbatim.
- If Docker is unavailable: prove the cross-compiled binaries + the install-script SHA-verify + unit
  tests, and mark the daemon-run proof as CI-only (the reviewer's push will cover it).

## DONE criteria (all required)
1. linux-x86_64 AND linux-aarch64: a build produces the Rust binaries + an integrity-gated llama.cpp
   runtime (size+sha256 verified against the lock) + a GPG-signed `.deb` + an AppImage. (If linux-arm64
   prebuilt runtime genuinely can't be resolved, x86_64 must be complete and the arm64 gap LOUDLY
   flagged with the evidence and a build-from-source plan — not silently dropped.)
2. CI builds + integrity-gates both targets (workflow written, each step locally reproduced; reviewer
   confirms green on push).
3. The macOS release path is unchanged and still works (run the macOS bundle/verify recipes; show green).
4. Integrity stays fail-closed everywhere; `FAE_MODELS_LOCK=off` only under `FAE_DEV`. No private keys
   committed; owner-provisioned CI secret names handed back.

## Evidence floor (hand back ALL, verbatim, labeled to a DONE criterion)
- `git diff --stat` for the whole branch (in `fae-p4`).
- Rust: `env -u RUSTFLAGS` fmt/clippy `-D warnings`/nextest for touched crates (paste tails);
  cross-compile build success for both Linux targets.
- Stage-1 installer runs showing the real Linux asset SHA-256 matching the lock.
- GPG sign→verify roundtrip output on a `.deb`.
- Docker run-smoke transcript (daemon up + runtime integrity-verified) OR an explicit "Docker
  unavailable → CI-only" note with everything else proven.
- macOS path still-green proof.
- The exact CI secret names the owner must set; the exact `git push` + workflow the reviewer should run.

## Traps & rules
- **Reviewer verifies live/CI, not your report.** Capture real output; mark anything CI-only honestly.
- **Don't break macOS.** The macOS recipes/workflow must stay green; Linux is additive.
- **Bundling trap / fail-closed integrity / `env -u RUSTFLAGS` / ADR-010** (llama.cpp stays a
  `llama-server` sidecar — no in-process FFI) all still apply.
- **Surgical:** additive platform branches, not a packaging rewrite. Keep the macOS lock entry + paths
  intact.
- **No secrets in git.** Test keys only locally; real keys are CI secrets named in the hand-back.
- **Resolve the linux-arm64 prebuilt question with the real asset list**, not an assumption — it's the
  one thing most likely to derail the phase.
- Per-stage hand-back is fine; never commit/push.
