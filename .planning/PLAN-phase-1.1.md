# Phase 1.1: Extract & Unify Downloads — Task Plan

## Goal
Move ALL model downloads into the unified startup download phase with progress callbacks. Currently the LLM download is hidden inside `mistralrs::GgufModelBuilder::build()` and TTS downloads are hidden inside `KokoroTts::new()`. After this phase, all downloads happen before any model loading, with full progress visibility.

## Deliverables
- `DownloadPlan` struct listing all needed files with sizes and cache status
- Pre-download of LLM GGUF + tokenizer files via `ModelManager`
- Pre-download of TTS ONNX + tokenizer + voice files via `ModelManager`
- `KokoroTts::from_paths()` accepting pre-downloaded `KokoroPaths`
- `LocalLlm` using pre-cached GGUF path
- New `ProgressEvent` variants: `DownloadPlanReady`, `AggregateProgress`
- Refactored startup: plan → download all → load all

---

## Tasks (TDD Order)

### Task 1: Add DownloadPlan and AggregateProgress to progress.rs
**Files:** `src/progress.rs`
**Description:**
- Add `DownloadFile` struct: `{ repo_id: String, filename: String, size_bytes: Option<u64>, cached: bool }`
- Add `DownloadPlan` struct: `{ files: Vec<DownloadFile>, total_bytes: u64, cached_bytes: u64 }`
- Add `DownloadPlan::needs_download(&self) -> bool` — true if any file not cached
- Add `DownloadPlan::download_bytes(&self) -> u64` — total_bytes - cached_bytes
- Add `ProgressEvent::DownloadPlanReady { plan: DownloadPlan }` variant
- Add `ProgressEvent::AggregateProgress { bytes_downloaded: u64, total_bytes: u64, files_complete: usize, files_total: usize }` variant
- Write tests for DownloadPlan methods and new event variant construction

### Task 2: Add query_file_sizes() to ModelManager
**Files:** `src/models/mod.rs`
**Description:**
- Add `pub fn query_file_sizes(&self, repo_id: &str, filenames: &[&str]) -> Result<Vec<(String, Option<u64>)>>`
  - Uses `repo.info().siblings` to get file sizes from HF Hub metadata
  - Returns vec of (filename, size_bytes) pairs
  - If API call fails, returns None for all sizes (graceful degradation)
- Add `pub fn is_file_cached(&self, repo_id: &str, filename: &str) -> bool`
  - Checks `hf_hub::Cache::default().model(repo_id).get(filename)` is Some
- Write tests with mock/stubbed data for the cache check logic

### Task 3: Pre-download LLM GGUF file explicitly
**Files:** `src/startup.rs`
**Description:**
- Add LLM GGUF to the Phase 1 download section in `initialize_models_with_progress()`
- Download `config.llm.gguf_file` from `config.llm.model_id` repo using `model_manager.download_with_progress()`
- Only when `use_local_llm` is true
- mistralrs will find the file in the shared hf-hub cache (no API changes needed)
- Write a test that the download call is made for local backend config
- Verify: `just build` passes, no regressions

### Task 4: Pre-download LLM tokenizer files
**Files:** `src/startup.rs`, `src/config.rs`
**Description:**
- Identify tokenizer files needed: check `config.llm.tokenizer_id` repo
- If `tokenizer_id` is non-empty, download `tokenizer.json`, `tokenizer_config.json` from that repo
- Add these to the Phase 1 download section
- Write test verifying tokenizer download is skipped when tokenizer_id is empty
- Verify: `just build` passes

### Task 5: Add download_kokoro_assets_with_progress() for TTS
**Files:** `src/tts/kokoro/download.rs`
**Description:**
- Add `pub fn download_kokoro_assets_with_progress(variant: &str, voice: &str, model_manager: &ModelManager, callback: Option<&ProgressCallback>) -> Result<KokoroPaths>`
  - Downloads model ONNX, tokenizer.json, and voice .bin using `model_manager.download_with_progress()` instead of bare `repo.get()`
  - Each file gets individual progress callbacks
  - Keep existing `download_kokoro_assets()` as backward-compat wrapper
- Update constants: extract `REPO_ID` as `pub const` so startup can use it
- Write test that verifies progress callback receives events for each file

### Task 6: Update KokoroTts to accept pre-downloaded paths
**Files:** `src/tts/kokoro/engine.rs`
**Description:**
- Add `pub fn from_paths(paths: KokoroPaths, config: &TtsConfig) -> Result<Self>`
  - Loads ONNX session, tokenizer, phonemizer, voice styles from pre-downloaded paths
  - No download logic — purely loading from disk
  - Extract loading logic from `new()` into `from_paths()`
- Update `new()` to call `download_kokoro_assets()` then `from_paths()`
- Update startup `load_tts()` to use `from_paths()` (since files are already downloaded in Phase 1)
- Write test that `from_paths()` works with valid paths (can reuse existing test patterns)

### Task 7: Build DownloadPlan from config
**Files:** `src/startup.rs`
**Description:**
- Add `fn build_download_plan(config: &SpeechConfig, model_manager: &ModelManager) -> Result<DownloadPlan>`
  - Enumerate all files: STT files, LLM GGUF + tokenizer, TTS model + tokenizer + voice
  - Check cache status for each file using `model_manager.is_file_cached()`
  - Query file sizes using `model_manager.query_file_sizes()` (best effort)
  - Return complete DownloadPlan
- Emit `ProgressEvent::DownloadPlanReady { plan }` via callback
- Write tests for plan building with various config combinations (local vs API LLM, Kokoro vs Fish TTS)

### Task 8: Refactor initialize_models_with_progress() — plan → download → load
**Files:** `src/startup.rs`
**Description:**
- Restructure `initialize_models_with_progress()` into 3 clear phases:
  1. **Plan**: Call `build_download_plan()`, emit DownloadPlanReady
  2. **Download**: Download ALL files (STT + LLM + TTS) with aggregate progress tracking
  3. **Load**: Load all models from cache (STT, LLM, TTS)
- Add aggregate progress tracking: after each file download, emit `AggregateProgress` event
- Update `load_tts()` to pass `KokoroPaths` to `KokoroTts::from_paths()`
- Integration test: verify the plan→download→load sequence emits correct event order
- Verify: `just check` passes (fmt, lint, build, test, doc)

---

## File Change Summary

| File | Action |
|------|--------|
| `src/progress.rs` | **MODIFY** — Add DownloadPlan, DownloadFile, new ProgressEvent variants |
| `src/models/mod.rs` | **MODIFY** — Add query_file_sizes(), is_file_cached() |
| `src/startup.rs` | **MODIFY** — Pre-download LLM/TTS, build_download_plan(), refactor init |
| `src/config.rs` | **MODIFY** — Possibly expose tokenizer file list |
| `src/tts/kokoro/download.rs` | **MODIFY** — Add download_kokoro_assets_with_progress() |
| `src/tts/kokoro/engine.rs` | **MODIFY** — Add from_paths(), refactor new() |

## Quality Gates
- `just check` passes (fmt, lint, build, test, doc, panic-scan)
- Zero `.unwrap()` or `.expect()` in production code
- All existing tests continue to pass
- New tests for every task
- Download plan correctly identifies cached vs needed files
