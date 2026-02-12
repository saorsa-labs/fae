# Phase 1.2: GUI Progress Overhaul

## Goal
Show rich download progress in the GUI — aggregate totals, per-model stage tracking, download speed, and ETA. Replace the current single-file progress bar with a comprehensive download dashboard.

## Current State
- GUI shows single-file progress only via `AppStatus::Downloading { current_file, bytes_downloaded, total_bytes }`
- `DownloadPlanReady` and `AggregateProgress` events exist in progress.rs but return `None` in gui.rs
- `StagePhase` enum routes ALL downloads to STT stage — LLM/TTS downloads not tracked
- No speed or ETA in GUI (CLI has it via indicatif)
- `update_stages_from_progress()` doesn't distinguish which model a download belongs to

## Tasks

### Task 1: Add DownloadTracker to progress.rs
Add a `DownloadTracker` struct that calculates speed and ETA from byte-level progress events.
- Fields: `started_at: Instant`, `last_bytes: u64`, `last_time: Instant`, `speed_samples: VecDeque<f64>` (rolling window)
- Methods: `new()`, `update(bytes_downloaded, total_bytes) -> (speed_mbps, eta_secs)`, `reset()`
- Rolling average over last 5 samples for smooth speed display
- 6+ tests for edge cases (zero bytes, unknown total, reset)
- **Files:** `src/progress.rs`

### Task 2: Enrich AppStatus for aggregate download state
Update `AppStatus::Downloading` to include aggregate fields alongside per-file fields.
- Add fields: `files_complete: usize`, `files_total: usize`, `aggregate_bytes: u64`, `aggregate_total: u64`, `speed_mbps: f64`, `eta_secs: Option<f64>`
- Keep existing `current_file`, `bytes_downloaded`, `total_bytes` for per-file display
- Update all match arms that construct `AppStatus::Downloading`
- 3+ tests for new fields
- **Files:** `src/bin/gui.rs`

### Task 3: Route downloads to correct model stage
Fix `update_stages_from_progress()` to route `DownloadStarted`/`DownloadProgress`/`DownloadComplete`/`Cached` events to the correct model stage (STT/LLM/TTS) based on `repo_id`.
- Add `model_name_from_repo_id(repo_id, config)` helper that maps repo_id to "STT"/"LLM"/"TTS"
- Store repo_id→model mappings from the DownloadPlan
- Update `StagePhase::Downloading` to include bytes progress: `Downloading { filename, bytes_downloaded, total_bytes }`
- Update stage label to show: "Downloading ears (1.2 GB / 2.3 GB)"
- **Files:** `src/bin/gui.rs`

### Task 4: Handle DownloadPlanReady in GUI
Wire the `DownloadPlanReady` event to store the plan and initialize aggregate state.
- Store `DownloadPlan` in a Dioxus signal for use by the progress display
- Initialize aggregate counters from plan data
- Build repo_id → model name mapping from plan files
- Set status text: "Preparing to download X.X GB..."
- **Files:** `src/bin/gui.rs`

### Task 5: Handle AggregateProgress in GUI
Wire `AggregateProgress` events to update the aggregate download state.
- Update `apply_progress_event()` to return `AppStatus::Downloading` with aggregate fields
- Integrate `DownloadTracker` for speed/ETA on aggregate bytes
- Feed real-time `DownloadProgress` events into tracker for smooth speed updates
- **Files:** `src/bin/gui.rs`

### Task 6: Render aggregate progress bar
Replace current progress bar with rich aggregate display.
- Show: "1.2 GB / 4.8 GB (25%)" as progress text
- Show: "Downloading model 2/3" as status line
- Progress bar width driven by `aggregate_bytes / aggregate_total`
- Indeterminate animation when total_bytes unknown
- **Files:** `src/bin/gui.rs` (rendering + CSS)

### Task 7: Render per-model stage pills
Update stage pill rendering to show download vs loading distinction with progress.
- "Downloading ears (1.2 GB / 2.3 GB)" during download
- "Loading ears" during model load
- "ears ready" when complete
- CSS styling for download/loading/ready/error states
- **Files:** `src/bin/gui.rs` (rendering + CSS)

### Task 8: Add speed and ETA display
Add download speed and ETA below the progress bar.
- Show: "12.5 MB/s — about 3 min remaining"
- Hide speed when no downloads active
- Show "Calculating..." for first few seconds
- Format helpers: `format_bytes()`, `format_eta()`, `format_speed()`
- Integration tests for format helpers
- **Files:** `src/bin/gui.rs`
