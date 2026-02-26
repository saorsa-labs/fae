# Migration Cleanup Policy

Policy for low-risk cleanup while preserving archival history.

## Principles

1. **Swift-first defaults stay active** in build/test/CI paths.
2. **Legacy Rust context may remain in docs** when explicitly marked archival.
3. **Do not break active workflows** to remove archival references.
4. **Prevent accidental reintroduction** of Rust/cargo in active CI and default dev recipes.

## Guardrails

- CI runs `scripts/ci/guard-no-rust-reintro.sh` early.
- Root `justfile` default recipes (`build`, `test`, `check`) must remain Swift-first.
- Workflow files under `.github/workflows/*.yml` must not add rust/cargo toolchain setup.
