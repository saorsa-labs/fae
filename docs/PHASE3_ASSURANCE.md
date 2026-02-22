# Phase 3 Assurance Implementation

This document describes the concrete implementation for Phase 3 from
`docs/FAE_ARCHITEXTURE_DECISIONS.md`:

- explicit mutation manifest for mutable artifacts
- optional kernel signature checks for higher assurance deployments

## 1) Mutation Manifest

Location:
- `~/.config/fae/mutation_manifest.json`

Module:
- `src/mutation_manifest.rs`

Tracked mutable surface:
- `~/.fae/skills/**`
- `~/.fae/python-skills/**`
- `~/.fae/SOUL.md`
- `~/.fae/onboarding.md`
- `~/.fae/staging/**`
- `~/.fae/tmp/**`

Each artifact record includes:
- stable path key (`data/...` or `config/...`)
- artifact kind
- promotion state (`staging`, `canary`, `active`, `quarantined`, `snapshot`, `removed`)
- monotonic `version`
- `digest_blake3`
- `size_bytes`
- `created_by` and `last_mutation` provenance stamps

Promotion state is derived from:
- managed skill registries
- python skill registries
- known `.state/disabled` and `.state/snapshots` layout
- staging/tmp root placement

Runtime wiring:
- mutation sync at `runtime.start` (`runtime.start_scan`)
- mutation sync on skill lifecycle operations (managed + python)
- mutation sync on `skills.reload`, `skill.generate`, `skill.channel.install`
- runtime status includes `mutation_manifest` summary

## 2) Kernel Signature Checks

Default manifest path:
- `~/.config/fae/kernel-signatures.toml`

Module:
- `src/kernel_signature.rs`

Runtime config (in `[runtime]`):
- `kernel_signature_mode = "off" | "warn" | "enforce"`
- `kernel_signature_manifest = "/path/to/kernel-signatures.toml"` (optional)

Modes:
- `off`: disabled
- `warn`: report failures, continue startup
- `enforce`: startup fails when required signatures are missing or mismatched

Startup wiring:
- `src/startup.rs` calls signature checks before model bootstrap
- runtime status includes `kernel_signature` report

Manifest schema:

```toml
version = 1

[[entries]]
name = "fae-binary"
path = "bin/fae" # absolute or relative to this manifest file
sha256 = "..."
required = true
```

## 3) Runtime Status Additions

`runtime.status` now includes:
- `rescue_health` (existing)
- `kernel_signature` (new)
- `mutation_manifest` (new)

This gives operators direct visibility into both mutable-surface drift and
kernel-assurance posture.
