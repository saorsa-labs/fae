# Model Supply Chain and Signed Updates — W4 Phase 0 Design

> Phase 0 design artifact. This is not implementation code and does not authorize production daemon releases.

## Status

W4 supply-chain design is complete when this document, the `models.lock` schema/template, and release/update threat model are reviewed. Implementation remains pre-v1.

Owner residual-risk sign-off: **ACCEPTED in-session**  
Owner/date: 2026-06-02 — “I am ok with the security consideration”

## Goals

- Every model/runtime artifact loaded by Fae is tied to a verifiable source and digest.
- Model loading fails closed on checksum/signature mismatch.
- Auto-installed tools (for example `uv`) are verified before execution.
- Daemon/app updates are signed, downgrade-resistant, and revocable.
- Failure states are user-visible and safe: no silent fallback to unverified binaries/models.

## `models.lock` schema

Fae should maintain a lock file for all model and runtime artifacts:

```text
~/Library/Application Support/fae/models.lock
```

A repo template lives at `docs/templates/models.lock.example`.

Each entry must include:

| Field | Required | Notes |
|---|---:|---|
| `id` | yes | Stable local id, e.g. `gemma-4-e4b-it-mistralrs`. |
| `role` | yes | `llm`, `stt`, `tts`, `embedding`, `vad`, `speaker`, `tokenizer`, `runtime`. |
| `loader` | yes | `mistralrs`, `llama-server`, `ort`, `mlx`, `kokoro`, etc. |
| `source_repo` | yes | HF repo, GitHub release, or vendor source. |
| `source_revision` | yes | Commit hash/tag/release id. Branch names are not enough. |
| `filename` | yes | Expected artifact filename. |
| `size_bytes` | yes | Prevents partial-file acceptance. |
| `sha256` | yes | SHA-256 of exact file bytes. |
| `signature` | recommended | Minisign/sigstore/HF attestation where available. |
| `license` | yes | SPDX or source license string. |
| `hardware_profile` | recommended | e.g. Apple Metal 48GB+, CPU fallback. |
| `created_at` | yes | Lock entry creation timestamp. |
| `approved_by` | yes | Owner/release authority. |

## Fail-closed loader policy

Before any model is loaded:

1. Resolve the lock entry by local id and role.
2. Verify file exists.
3. Verify file size.
4. Compute SHA-256 and compare to `models.lock`.
5. Verify signature/attestation when configured.
6. Verify source revision matches metadata recorded at download time.
7. Refuse load on mismatch, missing lock entry, stale lock schema, or unverifiable path.
8. Write audit event with redacted path/hash summary.

No production code may silently download, replace, or reinterpret model files without lock update + user/release approval.

## Download/update flow

- Downloads happen into a staging directory.
- Staged artifact is hashed before move into active cache.
- Active cache move is atomic.
- Existing active artifact remains available until replacement verifies.
- If replacement fails verification, keep old verified artifact and report failure.
- For externally hosted artifacts, record source URL, redirect chain, ETag/commit where available, and final digest.

## Tool/runtime verification

Fae currently uses tools/runtimes such as `uv` and Python subprocesses. Pre-v1 requirements:

- Download tools to a staging directory.
- Verify SHA-256 and/or vendor signature before first execution.
- Prefer pinned release versions over install scripts.
- If an install script is unavoidable, download → verify/review → run; never `curl | sh`.
- Store tool lock entries in the same or parallel lock file.
- Audit tool installs, upgrades, failures, and first execution.

## Signed daemon/app updates

Future daemon/app update mechanism must include:

- signed releases using minisign, sigstore, or equivalent;
- release manifest with version, commit, artifact digests, target triples, and signer identity;
- signature verification before install;
- monotonic version/downgrade protection;
- rollback only to still-trusted signed versions;
- emergency revocation list for compromised keys/releases;
- clear user-visible failure state when update verification fails.

### Downgrade protection

- Store highest accepted version/build id in local state.
- Reject older versions unless owner explicitly enters recovery mode.
- Recovery mode must require local user action and audit the downgrade.

### Key rotation / revocation

- Release signing key ids are pinned in the app bundle or verified metadata.
- New signing keys require signatures from an existing trusted key or explicit owner-installed trust root.
- Compromised release ids and keys are checked before install.

## x0x secure-groups note

The 2026-06 x0x release line now includes secure-group work: `v0.20.0` reports TreeKEM secure-group membership via `saorsa-mls::TreeKemGroup`, including invite/join/Welcome processing, bidirectional secure-plane encrypt/decrypt, ban epoch advance, and forward secrecy validation. This is relevant to Fae's future group transport, but it does **not** reduce Fae's supply-chain requirements:

- Fae must verify x0x binaries/libraries before use.
- Fae must not infer that TreeKEM content confidentiality solves model/runtime integrity.
- Fae must not enable peer/group features until G5 production enforcement and metadata signoff exist.

Evidence grade for x0x note: local repo/changelog verified; x0x working tree was dirty during review, so use published tags/releases for final release claims.

## Pre-v1 acceptance criteria

- [ ] `models.lock` generated for every active model/runtime artifact.
- [ ] Loader fails closed on missing/mismatched digest.
- [ ] Tool/runtime installers verify checksums/signatures before execution.
- [ ] Signed update manifest design implemented and tested.
- [ ] Downgrade protection tested.
- [ ] Emergency revocation path documented and tested.
- [ ] User-visible failure UX exists for verification failures.

## Residual risks

- SHA-256 verifies file integrity, not model behavior or training provenance.
- Hosted model repos may be compromised before a lock entry is generated.
- Local same-user malware can tamper with files if it has account access; file permissions and audit reduce but do not eliminate this.
- Signing-key compromise requires revocation and user-visible recovery.
