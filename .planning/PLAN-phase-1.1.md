# Phase 1.1: Setup & Progress Abstraction

## Overview
Add Dioxus dependencies, create GUI binary, refactor startup.rs progress reporting from stdout/indicatif to callback-based system that both CLI and GUI can consume.

---

## Task 1: Add Dioxus dependencies to Cargo.toml

**Description**: Add Dioxus 0.6 with desktop feature and manganis for asset management as optional dependencies behind a `gui` feature flag.

**Files to modify**: `Cargo.toml`

**Changes**:
- Add `dioxus = { version = "0.6", features = ["desktop"], optional = true }`
- Add `manganis = { version = "0.3", optional = true }`
- Add `gui = ["dioxus", "manganis"]` feature
- Add `[[bin]] name = "fae-gui"` section with `required-features = ["gui"]`

**Dependencies**: None

---

## Task 2: Define ProgressEvent types

**Description**: Create `src/progress.rs` with event types representing all progress states during model download and loading. These events decouple progress reporting from any specific UI.

**Files to create**: `src/progress.rs`
**Files to modify**: `src/lib.rs` (add `pub mod progress;`)

**Types to define**:
- `ProgressEvent` enum: `DownloadStarted`, `DownloadProgress`, `DownloadComplete`, `Cached`, `LoadStarted`, `LoadComplete`, `Error`
- `ProgressCallback` type alias: `Box<dyn Fn(ProgressEvent) + Send + Sync>`

**Tests**: Unit tests validating event construction and callback invocation.

**Dependencies**: None

---

## Task 3: Update ModelManager to accept ProgressCallback

**Description**: Add optional `ProgressCallback` parameter to `ModelManager::download_with_progress()` and `download_url_with_progress()`. Emit `ProgressEvent`s alongside existing indicatif behavior.

**Files to modify**: `src/models/mod.rs`

**Changes**:
- Add callback parameter to download methods
- Emit `Cached` when file found in cache
- Emit `DownloadStarted` at download begin
- Emit `DownloadProgress` during chunks
- Emit `DownloadComplete` at finish
- Keep indicatif bars as default when no callback provided

**Dependencies**: Task 2

---

## Task 4: Update startup.rs to emit load events

**Description**: Add optional `ProgressCallback` to `initialize_models()`, `load_stt()`, `load_llm()`, `load_tts()`. Emit `LoadStarted`/`LoadComplete` events. Pass callback through to ModelManager download calls.

**Files to modify**: `src/startup.rs`

**Changes**:
- Add callback parameter to all public init functions
- Emit `LoadStarted { model_name }` before each model load
- Emit `LoadComplete { model_name, duration_secs }` after each load
- Pass callback to ModelManager for download events
- Keep `print!`/`println!` as fallback when no callback

**Dependencies**: Task 3

---

## Task 5: Create CLI progress adapter

**Description**: Create `src/cli_progress.rs` that converts `ProgressEvent` callbacks into indicatif progress bar operations. This replaces the direct indicatif usage removed from models/startup.

**Files to create**: `src/cli_progress.rs`
**Files to modify**: `src/lib.rs` (add `pub mod cli_progress;`)

**Implementation**:
- `CliProgress` struct holding active `ProgressBar` instances
- `to_callback(&self) -> ProgressCallback` method
- Match on each `ProgressEvent` variant to drive indicatif bars
- Replicate exact same output format as current CLI

**Dependencies**: Task 2

---

## Task 6: Update CLI binary to use progress callback

**Description**: Modify `src/bin/cli.rs` to create a `CliProgress`, get its callback, and pass to `initialize_models()`.

**Files to modify**: `src/bin/cli.rs`

**Changes**:
- Create `CliProgress::new()`
- Pass `Some(&cli_progress.to_callback())` to `initialize_models()`
- CLI output should be identical to before

**Dependencies**: Tasks 4, 5

---

## Task 7: Create GUI binary entry point

**Description**: Create `src/bin/gui.rs` as a minimal Dioxus desktop app. Just a window with "fae" title and placeholder content. Gated behind `gui` feature flag.

**Files to create**: `src/bin/gui.rs`

**Implementation**:
- `#![cfg(feature = "gui")]`
- Dioxus desktop launcher with window config (title "Fae", 400x600)
- Placeholder `App` component with "Fae Desktop" heading
- Verify: `cargo check --features gui --bin fae-gui`

**Dependencies**: Task 1

---

## Task 8: Verify both binaries build and CLI unchanged

**Description**: Final verification that both binaries compile, CLI behavior is identical, and all quality gates pass.

**Verification**:
- `cargo check --all-targets` (CLI)
- `cargo check --features gui --all-targets` (GUI)
- `cargo clippy --all-targets -- -D warnings`
- `cargo clippy --features gui --all-targets -- -D warnings`
- `cargo fmt --all -- --check`
- `cargo test`
- `cargo run --bin fae -- --help` (CLI still works)
- `cargo check --features gui --bin fae-gui` (GUI compiles)

**Dependencies**: All previous tasks
