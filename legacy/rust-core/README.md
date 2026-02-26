# Rust Core Archive (Quarantined)

This directory contains the legacy Rust core files moved from repository root during migration PR C.

## Status

- **Quarantined / archival only**
- **Not part of the active build/test path**
- Active development path is SwiftPM under `native/macos/Fae`

## Purpose

- Preserve rollback capability while preventing accidental Rust-path reintroduction in normal CI/dev workflows.
- Keep historical sources available for reference, audits, and controlled recovery.

See [ROLLBACK.md](./ROLLBACK.md) for explicit restore commands.
