# Phase 1.3: Pre-flight & Error Resilience

## Goal
Inform users before downloading and handle failures gracefully. Add pre-flight confirmation, disk space check, better error messages, retry capability, and welcome text.

## Current State
- App auto-starts model loading on launch via `on_button_click()` in `use_hook`
- Download errors are a single `Error(String)` variant — no structured detail
- No disk space check before downloading ~4.8 GB
- No retry mechanism after failure
- No pre-flight confirmation dialog
- Build plan exists in `build_download_plan()` with file sizes

## Tasks

### Task 1: Add disk space check to startup.rs
Add a `check_disk_space()` function that verifies sufficient free space before downloading.
- Use `statvfs` on Unix (via `nix` crate or raw libc) to check free space at cache dir
- Use `available_space()` from `fs2` or manual platform check
- Return `Result<()>` with clear error: "Not enough disk space. Need X.X GB, have Y.Y GB free."
- Add as first check in `initialize_models_with_progress()` before download plan
- 3+ tests for the function (mock via temp dirs)
- **Files:** `src/startup.rs`

### Task 2: Add PreFlight AppStatus variant
Add `AppStatus::PreFlight` variant for the pre-download confirmation screen.
- Fields: `total_bytes: u64`, `files_to_download: usize`, `total_files: usize`, `free_space: u64`
- `display_text()`: "Ready to download X.X GB"
- `show_start()` returns true (so user can click to proceed)
- `buttons_enabled()` returns true
- Update tests for new variant
- **Files:** `src/bin/gui.rs`

### Task 3: Pre-flight check function
Add `preflight_check()` that builds the plan and checks disk space without starting downloads.
- Takes `&SpeechConfig`, returns `PreFlightResult { plan, free_space, needs_download }`
- Called before the main download sequence
- Runs on background task (file size queries are blocking HTTP)
- **Files:** `src/startup.rs`

### Task 4: Pre-flight dialog in GUI
Show pre-flight dialog before downloading when `needs_download` is true.
- Replace auto-start with: build plan → show pre-flight → user confirms → start downloads
- Display: "First run setup — Fae needs to download X.X GB of AI models"
- Show file breakdown: "Speech-to-text (2.4 GB), Intelligence (2.3 GB), Voice (89 MB)"
- "Continue" button starts downloads, or "X already cached" note
- Skip dialog when all files cached (go straight to loading)
- **Files:** `src/bin/gui.rs`

### Task 5: Structured download error messages
Improve error reporting when downloads fail.
- Add `DownloadError` variant to `ProgressEvent::Error` with structured fields: `repo_id`, `filename`, `bytes_downloaded`, `total_bytes`, `error_detail`
- Update `download_with_progress()` error handling to include context
- Show in GUI: "Failed to download model.onnx (1.2 GB / 2.3 GB): connection timed out"
- **Files:** `src/progress.rs`, `src/models/mod.rs`, `src/bin/gui.rs`

### Task 6: Retry button on download failure
Add retry capability when downloads fail.
- Add "Retry" button shown when `AppStatus::Error`
- On retry, re-run `on_button_click()` — cached files are skipped automatically
- Show: "Retrying... (2 files cached, 1 remaining)"
- Track retry count in status for display
- **Files:** `src/bin/gui.rs`

### Task 7: Welcome text and first-run polish
Add welcoming copy and polish for first-run experience.
- Show welcome text during pre-flight: "Welcome to Fae! Setting up your personal AI assistant."
- During downloads: "Downloading AI models — this only happens once"
- During loading: "Almost ready — loading models into memory"
- Show tips during long downloads (rotate through helpful text)
- **Files:** `src/bin/gui.rs`

### Task 8: Integration test and verification
Verify the complete first-run flow end-to-end.
- Test `preflight_check()` returns correct plan data
- Test `check_disk_space()` with various scenarios
- Test error message formatting
- Run `just check` — full validation
- **Files:** `src/startup.rs`, `src/bin/gui.rs`
