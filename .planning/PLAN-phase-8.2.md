# Phase 8.2: UV Bootstrap & Environment Management

## Overview
Auto-detect or install the UV binary, parse PEP 723 inline metadata from Python scripts, pre-warm environments before first skill spawn, and wire the resolved UV path through the runner. Zero-config: Fae bootstraps Python tooling on first use without user intervention.

## Tasks

### Task 1: Error Types & UV Directory Helpers
**Files**: `src/skills/error.rs` (expanded), `src/fae_dirs.rs` (expanded)
**Tests**: Unit tests for new error variants serde round-trip, directory path resolution with env overrides
**Acceptance**: `PythonSkillError` gains `UvNotFound`, `UvVersionTooOld { found, minimum }`, `BootstrapFailed { reason }` variants. `fae_dirs::uv_cache_dir()` returns `cache_dir()/uv/` with `FAE_UV_CACHE_DIR` override. Zero warnings.

### Task 2: UV Binary Discovery & Version Check
**Files**: `src/skills/uv_bootstrap.rs` (new)
**Tests**: Unit tests for path probing logic, version parsing, minimum version enforcement
**Acceptance**: `UvBootstrap::discover()` probes: explicit config path → `PATH` lookup → `~/.local/bin/uv` → `~/.cargo/bin/uv`. Runs `uv --version`, parses semver (minimum 0.4.0). Returns `UvInfo { path, version }`. All probing paths tested with mocks.

### Task 3: UV Auto-Install (Download if Missing)
**Files**: `src/skills/uv_bootstrap.rs` (expanded)
**Tests**: Mock-based install test (no real downloads in tests), integration test with `--version` after install
**Acceptance**: `UvBootstrap::ensure_available()` tries `discover()` first; if `UvNotFound`, downloads the standalone installer script to a temp file and runs `sh /tmp/uv-installer.sh --no-modify-path` with `UV_INSTALL_DIR` set to `uv_cache_dir()/bin/`. Re-discovers after install. Emits progress events. Returns `UvInfo`.

### Task 4: PEP 723 Inline Metadata Parser
**Files**: `src/skills/pep723.rs` (new)
**Tests**: Parse real-world script headers, missing metadata, malformed metadata, multiple dependency specs
**Acceptance**: `parse_script_metadata(script_path)` reads Python file, extracts `# /// script` TOML block per PEP 723. Returns `ScriptMetadata { requires_python: Option<String>, dependencies: Vec<String>, tool_sections: HashMap }`. Handles missing metadata gracefully (returns empty). Full round-trip tests.

### Task 5: Environment Pre-Warming & Runner Integration
**Files**: `src/skills/uv_bootstrap.rs` (expanded), `src/skills/python_runner.rs` (modified), `src/config.rs` (expanded)
**Tests**: Pre-warm creates venv, runner uses resolved UV path, config round-trip with new fields
**Acceptance**: `UvBootstrap::pre_warm(script_path)` runs `uv run --quiet --no-progress <script> --help` or equivalent dry-run to trigger dependency resolution before first real invocation. `SkillProcessConfig` gains `uv_path: PathBuf`. `PythonSkillRunner::spawn_child()` uses `config.uv_path` instead of bare `"uv"`. `PythonSkillsConfig` gains optional `uv_path: Option<PathBuf>` and `python_version: Option<String>`. Zero warnings.

### Task 6: Bootstrap Orchestration & Integration Test
**Files**: `src/skills/mod.rs` (expanded), `tests/uv_bootstrap_e2e.rs` (new)
**Tests**: Full bootstrap flow: discover/install → parse metadata → pre-warm → spawn → handshake
**Acceptance**: `skills::bootstrap_python_environment()` is the single entry point: calls `ensure_available()`, caches `UvInfo`, returns ready-to-use config. Integration test using a mock shell script (like Phase 8.1 E2E) verifies the full pipeline. Module re-exports `UvBootstrap`, `UvInfo`, `ScriptMetadata`.

## Task Dependencies
```
Task 1 (Error types + dirs) → Task 2 (Discovery) → Task 3 (Auto-install)
Task 1 → Task 4 (PEP 723 parser) — independent of Tasks 2-3
Task 2 + 3 + 4 → Task 5 (Integration into runner)
Task 5 → Task 6 (Orchestration + E2E)
```
