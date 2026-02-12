# Phase 4.1: crates.io Publishing

## Overview
Prepare and publish the saorsa-canvas workspace crates to crates.io with proper metadata, CI workflows, and path overrides in fae.

**Cross-project: modifies both saorsa-canvas and fae**

## Tasks

### Task 1: Audit and fix workspace metadata
**Files:** All `Cargo.toml` files in saorsa-canvas, create per-crate `README.md` files

Add missing `repository`, `homepage`, `documentation` fields to all crate manifests.
Create per-crate README.md with description, installation, usage example, and repo link.

- All crates: add `repository`, `homepage`, `documentation` fields
- Per-crate README.md (brief: description, install, example, link)
- `cargo publish --dry-run` for each crate passes metadata checks

**Acceptance:**
- Zero "no documentation, homepage or repository" warnings
- All README.md files created

### Task 2: Fix canvas-server packaging and add keywords/categories
**Files:** `canvas-server/Cargo.toml`, workspace `Cargo.toml`

Fix the `include` field (currently excludes tests). Add `keywords` and `categories` to workspace metadata.

**Acceptance:**
- `cargo package --list -p canvas-server` shows expected files
- `cargo publish --dry-run -p canvas-server` succeeds
- All crates have appropriate keywords and categories

### Task 3: Create GitHub Actions CI workflow
**Files:** `saorsa-canvas/.github/workflows/ci.yml`

CI for PRs and pushes to main: fmt check, clippy, test, doc build.
Matrix: stable Rust, ubuntu-latest + macos-latest.
Use Rust cache action for speed.

**Acceptance:**
- Workflow file valid YAML
- Covers fmt, clippy, test, doc
- Triggers on PR and push to main

### Task 4: Create GitHub Actions publish workflow
**Files:** `saorsa-canvas/.github/workflows/publish.yml`

Triggered on `v*` tag push. Publishes crates in dependency order with delays:
1. canvas-core
2. canvas-renderer (30s delay)
3. canvas-mcp (30s delay)
4. canvas-server (30s delay)

Uses `CARGO_REGISTRY_TOKEN` secret. Creates GitHub release.

**Acceptance:**
- Workflow file valid YAML
- Publishes in correct dependency order
- Uses org secret for authentication

### Task 5: Bump version and publish canvas-core
**Files:** Workspace `Cargo.toml` (version bump to 0.2.0)

Bump workspace version from 0.1.4 to 0.2.0 (significant metadata and feature additions since 0.1.4). Publish canvas-core to crates.io.

**Acceptance:**
- `cargo publish -p canvas-core --dry-run` succeeds
- canvas-core 0.2.0 on crates.io (or dry-run verified if no token available)

### Task 6: Publish canvas-renderer and canvas-mcp
**Files:** None (version already bumped)

Publish in order with 60s delay between:
1. canvas-renderer
2. canvas-mcp

**Acceptance:**
- Both crates published (or dry-run verified)
- Dependencies resolve correctly

### Task 7: Publish canvas-server
**Files:** None (version already bumped)

Publish canvas-server to crates.io. Skip canvas-app and canvas-desktop (WASM/native-only, not needed by fae).

**Acceptance:**
- canvas-server published (or dry-run verified)
- All dependencies resolve correctly

### Task 8: Update fae to use crates.io deps with path overrides
**Files:** `fae/Cargo.toml`

Add `[patch.crates-io]` section for local development while keeping crates.io version references.

```toml
[patch.crates-io]
canvas-core = { path = "../saorsa-canvas/canvas-core" }
canvas-mcp = { path = "../saorsa-canvas/canvas-mcp" }
canvas-renderer = { path = "../saorsa-canvas/canvas-renderer" }
```

**Acceptance:**
- `cargo check` in fae succeeds with patches
- Dependencies resolve to local path during dev
- Comment explains patch usage
