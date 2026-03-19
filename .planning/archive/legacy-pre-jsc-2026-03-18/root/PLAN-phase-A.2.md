# Phase A.2: Path & Permission Hardening

## Objective
Make all filesystem access sandbox-compatible by centralizing directory resolution, removing hardcoded `$HOME` paths, adding the `dirs` crate for platform-appropriate directories, and restricting the bash tool under sandbox.

## Problem
Under macOS App Sandbox, `std::env::var_os("HOME")` returns the **real** home directory (`/Users/username/`), but the app **cannot** write there. All 6+ scattered `fae_home_dir()` / `fae_data_dir()` / `default_config_path()` functions use `$HOME` directly, making the app non-functional under sandbox.

The `dirs` crate uses `NSSearchPathForDirectoriesInDomains` on macOS, which returns **container-relative** paths under sandbox. This transparently fixes all paths.

## Current Violations (8 locations)

| Location | Function | Path | Issue |
|----------|----------|------|-------|
| `src/personality.rs:26` | `fae_home_dir()` | `~/.fae/` | Inaccessible under sandbox |
| `src/memory.rs:1598` | `default_memory_root_dir()` | `~/.fae/` | Duplicate, inaccessible |
| `src/config.rs:905` | `default_memory_root_dir()` | `~/.fae/` | Duplicate, inaccessible |
| `src/external_llm.rs:244` | `fae_home_dir()` | `~/.fae/` | Duplicate, inaccessible |
| `src/skills.rs:163` | `skills_dir()` | `~/.fae/skills/` | Inaccessible |
| `src/diagnostics.rs:76` | `fae_data_dir()` | `~/.fae/` | Inaccessible |
| `src/diagnostics.rs:85` | `desktop_dir()` | `~/Desktop/` | Inaccessible |
| `src/config.rs:940` | `default_config_path()` | `~/.config/fae/` | Inaccessible |
| `src/config.rs:772` | `dirs_cache_dir()` | `~/.cache/fae/` | Inaccessible |
| `src/diagnostics.rs:96` | `scheduler_json_path()` | `~/.config/fae/` | Inaccessible |
| `src/bin/record_wakeword.rs:273` | inline | `~/.fae/wakeword/` | Inaccessible |

## Strategy

1. Add `dirs` crate — uses platform-native APIs, sandbox-transparent
2. Create `src/fae_dirs.rs` — single source of truth for all app directories
3. Replace all 6 `fae_home_dir()` duplicates with `fae_dirs::data_dir()`
4. Replace all config/cache paths with `fae_dirs` functions
5. Fix diagnostics to use save panel or sandbox-safe location
6. Add temporary-exception entitlement for model cache (HuggingFace hub)
7. Add sandbox-awareness to bash tool

## Directory Mapping

| Purpose | Current | Sandbox-Safe (`dirs` crate) |
|---------|---------|----------------------------|
| App data (memory, SOUL, skills) | `~/.fae/` | `dirs::data_dir()/fae/` |
| Config | `~/.config/fae/` | `dirs::config_dir()/fae/` |
| Cache (models) | `~/.cache/fae/` | `dirs::cache_dir()/fae/` |
| Logs | `~/.fae/logs/` | `dirs::data_dir()/fae/logs/` |
| Diagnostics output | `~/Desktop/` | `dirs::data_dir()/fae/diagnostics/` or save panel |

On macOS under sandbox:
- `dirs::data_dir()` → `~/Library/Containers/<id>/Data/Library/Application Support/`
- `dirs::config_dir()` → `~/Library/Containers/<id>/Data/Library/Application Support/`
- `dirs::cache_dir()` → `~/Library/Containers/<id>/Data/Library/Caches/`

On Linux (no change): Uses `XDG_*` environment variables as before.

---

## Tasks

### Task 1: Add `dirs` crate and create `src/fae_dirs.rs`
- **Description**: Single-source-of-truth module for all app directory paths, using `dirs` crate for platform-appropriate resolution.
- **Files**:
  - `Cargo.toml` — add `dirs = "6"` dependency
  - `src/fae_dirs.rs` — new module
  - `src/lib.rs` — add `pub mod fae_dirs;`
- **Changes**:
  1. Add `dirs = "6"` to `[dependencies]` in Cargo.toml
  2. Create `src/fae_dirs.rs` with these public functions:
     - `data_dir() -> PathBuf` — app data root (`dirs::data_dir()/fae/`), used for memory, SOUL, skills, logs
     - `config_dir() -> PathBuf` — config root (`dirs::config_dir()/fae/`), used for config.toml
     - `cache_dir() -> PathBuf` — cache root (`dirs::cache_dir()/fae/`), used for model downloads
     - `logs_dir() -> PathBuf` — `data_dir()/logs/`
     - `skills_dir() -> PathBuf` — `data_dir()/skills/`
     - `memory_dir() -> PathBuf` — `data_dir()` (memory is stored at root of data)
     - `config_file() -> PathBuf` — `config_dir()/config.toml`
     - `scheduler_file() -> PathBuf` — `config_dir()/scheduler.json`
     - `diagnostics_dir() -> PathBuf` — `data_dir()/diagnostics/`
  3. Each function has fallback to `/tmp/fae-*` if `dirs` returns None
  4. Add `FAE_DATA_DIR`, `FAE_CONFIG_DIR`, `FAE_CACHE_DIR` env var overrides for testing
  5. Wire into `src/lib.rs`
  6. Add unit tests for each function
- **Verification**: `cargo check` passes, tests pass

### Task 2: Migrate `personality.rs` and `external_llm.rs` to `fae_dirs`
- **Description**: Replace the `fae_home_dir()` functions in personality.rs and external_llm.rs with `fae_dirs` calls
- **Files**:
  - `src/personality.rs`
  - `src/external_llm.rs`
- **Changes**:
  1. In `personality.rs`: remove `fae_home_dir()` function, replace with `crate::fae_dirs::data_dir()`
  2. Update `soul_path()` to use `crate::fae_dirs::data_dir().join("SOUL.md")`
  3. Update `onboarding_path()` to use `crate::fae_dirs::data_dir().join("onboarding.md")`
  4. In `external_llm.rs`: remove `fae_home_dir()` function, replace with `crate::fae_dirs::data_dir()`
  5. Update the external API profiles directory to use `crate::fae_dirs::data_dir().join("external_apis")`
  6. Update doc comments to reflect new paths
  7. Ensure existing tests still pass
- **Verification**: `cargo check`, `cargo test` pass

### Task 3: Migrate `config.rs` paths to `fae_dirs`
- **Description**: Replace config, cache, and memory paths in config.rs with centralized fae_dirs functions
- **Files**:
  - `src/config.rs`
- **Changes**:
  1. Remove `default_memory_root_dir()` function (line 905-911), replace default with `crate::fae_dirs::memory_dir()`
  2. Remove `dirs_cache_dir()` function (line 772-779), replace default with `crate::fae_dirs::cache_dir()`
  3. Update `SpeechConfig::default_config_path()` to use `crate::fae_dirs::config_file()`
  4. Update any comments/docs referencing old paths
  5. Ensure serde defaults still work correctly
- **Verification**: `cargo check`, `cargo test` pass

### Task 4: Migrate `diagnostics.rs` — remove hardcoded `~/Desktop/`
- **Description**: Replace hardcoded Desktop path with sandbox-safe diagnostics directory. Add save-panel support for the GUI caller.
- **Files**:
  - `src/diagnostics.rs`
- **Changes**:
  1. Remove `desktop_dir()` function entirely
  2. Remove `fae_data_dir()` function, replace with `crate::fae_dirs::data_dir()`
  3. Remove `scheduler_json_path()`, replace with `crate::fae_dirs::scheduler_file()`
  4. Change `gather_diagnostic_bundle()` to accept an optional `output_dir: Option<&Path>` parameter
  5. If `output_dir` is Some, use that (for GUI save panel). If None, use `fae_dirs::diagnostics_dir()` (auto-creates)
  6. Update `fae_log_dir()` to use `crate::fae_dirs::logs_dir()`
  7. Update doc comments
  8. Update tests
- **Verification**: `cargo check`, `cargo test` pass

### Task 5: Migrate `skills.rs`, `memory.rs`, `record_wakeword.rs` to `fae_dirs`
- **Description**: Replace remaining scattered path functions with centralized fae_dirs calls
- **Files**:
  - `src/skills.rs`
  - `src/memory.rs`
  - `src/bin/record_wakeword.rs`
- **Changes**:
  1. In `skills.rs`: replace inline `fae_home_dir` path construction with `crate::fae_dirs::skills_dir()`. Keep `FAE_SKILLS_DIR` env var override (it takes priority over fae_dirs)
  2. In `memory.rs`: remove `default_memory_root_dir()`, replace with `crate::fae_dirs::memory_dir()`
  3. In `record_wakeword.rs`: replace inline path construction with `fae::fae_dirs::data_dir().join("wakeword")`
  4. Ensure existing tests still pass — tests that construct paths via `test_paths()` helper should be unaffected
- **Verification**: `cargo check`, `cargo test` pass

### Task 6: Add temporary-exception entitlement for HuggingFace cache
- **Description**: HuggingFace Hub's `hf-hub` crate uses its own cache directory (`~/.cache/huggingface/`). Under sandbox, this is inaccessible. Add a temporary exception entitlement and configure the cache path override.
- **Files**:
  - `Entitlements.plist`
  - `src/models/mod.rs` — configure HF cache path
  - `src/startup.rs` — ensure cache path is set before downloads
- **Changes**:
  1. Add `com.apple.security.temporary-exception.files.home-relative-path.read-write` entitlement for `/Library/Caches/` (the container-relative Caches dir is accessible, but HF hub may use its own path)
  2. Actually: Instead of entitlement, override `HF_HOME` env var to point to `fae_dirs::cache_dir().join("huggingface")` before any hf-hub calls
  3. Set `std::env::set_var("HF_HOME", ...)` early in startup (before ModelManager creation)
  4. Add `hf_cache_dir() -> PathBuf` to `fae_dirs.rs`
  5. Update `startup.rs:preflight_check()` to use the new cache path for disk space checks
  6. Verify HF hub respects `HF_HOME` override
- **Verification**: `cargo check`, model download still works

### Task 7: Add sandbox-awareness to bash tool
- **Description**: Under App Sandbox, the bash tool has limited capabilities. Add documentation and optional restrictions.
- **Files**:
  - `src/fae_llm/tools/bash.rs`
  - `src/fae_dirs.rs` — add `is_sandboxed()` helper
- **Changes**:
  1. Add `pub fn is_sandboxed() -> bool` to `fae_dirs.rs` — returns true if `APP_SANDBOX_CONTAINER_ID` env var is set (macOS sets this automatically under sandbox)
  2. In BashTool, if sandboxed: add environment setup to child process (set `HOME` to container, set `PATH` to safe paths)
  3. Add sandbox info to bash tool description (so LLM knows about limitations)
  4. Add test for `is_sandboxed()` detection
  5. Do NOT disable bash entirely — it's useful for basic operations even in sandbox
- **Verification**: `cargo check`, `cargo test` pass

### Task 8: Update GUI callers, comprehensive tests, and verification
- **Description**: Wire up remaining GUI references, run full validation suite, update documentation
- **Files**:
  - `src/bin/gui.rs` — update diagnostic bundle caller to pass save panel path
  - `CLAUDE.md` — update with fae_dirs documentation
- **Changes**:
  1. In gui.rs: update diagnostic bundle button to either use save panel or use default diagnostics_dir
  2. In gui.rs: update any remaining direct path references to use fae_dirs
  3. Update archive display path reference (line ~7570) to use fae_dirs
  4. Run full validation: `cargo fmt`, `cargo clippy`, `cargo nextest run`
  5. Verify zero warnings, zero errors
  6. Update CLAUDE.md with fae_dirs module documentation
- **Verification**: Full `just check` passes
