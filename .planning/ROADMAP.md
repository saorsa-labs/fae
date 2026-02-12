# First-Run Download Experience — Roadmap

## Problem Statement

On first install, Fae downloads ~4.8 GB of AI models (STT 2.4 GB, LLM 2.3 GB, TTS 89 MB). Currently only STT downloads show progress. The LLM and TTS downloads are invisible — users see a frozen "Loading..." screen for 5-10+ minutes with no feedback. Beta testers will abandon the app thinking it's broken.

## Success Criteria

- All model downloads show progress with bytes/total, speed, and ETA
- Users see total download size before starting
- Disk space is checked before downloading
- Download failures show clear error messages with retry option
- Stage indicators distinguish "Downloading" from "Loading"
- Overall aggregate progress visible across all models
- Production-ready polish for beta launch

## Technical Decisions

- Error Handling: Dedicated error types via `thiserror` (`SpeechError`)
- Async Model: Tokio (match existing codebase)
- Testing: Unit + Integration (TDD, tests first)
- Task Size: Smallest possible (~50 lines each)
- HF Hub: Use `repo.info().siblings` for file size queries
- Download Strategy: Pre-download all models before loading any

---

## Milestone 1: First-Run Download Experience

### Phase 1.1: Extract & Unify Downloads (8 tasks)

**Goal:** Move ALL model downloads into the unified startup download phase with progress callbacks. Currently the LLM download is hidden inside `mistralrs::GgufModelBuilder::build()` and TTS downloads are hidden inside `KokoroTts::new()`.

**Key changes:**
- Add `DownloadPlan` struct: lists all needed files with sizes, cache status, total bytes
- Add `query_file_sizes()` to `ModelManager` using `repo.info().siblings`
- Add `download_with_progress()` calls for LLM GGUF + tokenizer files
- Add `download_with_progress()` calls for TTS ONNX + tokenizer + voice files
- Update `KokoroTts::new()` to accept pre-downloaded `KokoroPaths`
- Update `LocalLlm::new()` to use pre-cached GGUF path
- Add `DownloadPlanReady` and `AggregateProgress` to `ProgressEvent`
- Update startup sequence: plan -> download all -> load all

**Files:** `src/startup.rs`, `src/models/mod.rs`, `src/progress.rs`, `src/llm/mod.rs`, `src/tts/kokoro/download.rs`, `src/tts/kokoro/engine.rs`

### Phase 1.2: GUI Progress Overhaul (8 tasks)

**Goal:** Show rich download progress in the GUI — aggregate totals, per-model progress, speed, ETA.

**Key changes:**
- Aggregate progress bar: "1.2 GB / 4.8 GB (25%)" across all models
- Per-stage download indicators with file name and size
- Download speed calculation (rolling average MB/s)
- ETA calculation based on remaining bytes and current speed
- Indeterminate progress bar fallback when total_bytes unknown
- Status text: "Downloading model 2/3 — Qwen3-4B (2.3 GB)"
- Stage pills: "Downloading ears (2.3 GB)" vs "Loading ears"
- AppStatus enum updates for richer download state

**Files:** `src/bin/gui.rs`, `src/progress.rs`

### Phase 1.3: Pre-flight & Error Resilience (8 tasks)

**Goal:** Inform users before downloading and handle failures gracefully.

**Key changes:**
- Pre-flight dialog: "First run requires downloading 4.8 GB. Continue?"
- Disk space check (platform-specific: statvfs on Unix, GetDiskFreeSpaceEx on Windows)
- Better download error messages: file, size, bytes downloaded, error detail
- Retry button on failure (skips already-cached files)
- Network connectivity pre-check
- Cancel button to abort downloads cleanly
- Graceful handling of HF Hub API failures (rate limits, 404s)
- Welcome text explaining what's happening and why

**Files:** `src/bin/gui.rs`, `src/startup.rs`, `src/models/mod.rs`

---

## Technical Notes

### HF Hub File Size Query

```rust
let repo_info = repo.info()?;
for sibling in &repo_info.siblings {
    // sibling.rfilename: String, sibling.size: Option<u64>
}
```

### mistralrs GGUF Pre-Download

Pre-download GGUF through `ModelManager` with progress, then mistralrs finds it in the shared `hf-hub` cache. No mistralrs API changes needed.

### Download Sizes (default config)

| Model | File | Size |
|-------|------|------|
| STT encoder | encoder-model.onnx + .data | ~2.3 GB |
| STT decoder | decoder_joint-model.onnx | ~69 MB |
| STT vocab | vocab.txt | ~92 KB |
| LLM | Q4_K_M.gguf | ~2.3 GB |
| LLM tokenizer | (multiple) | ~16 MB |
| TTS model | model_quantized.onnx | ~82 MB |
| TTS tokenizer + voice | tokenizer.json + bf_emma.bin | ~2 MB |
| **Total** | | **~4.8 GB** |

---

## Risks & Mitigations

- **HF Hub API rate limits**: Pre-query file sizes once, cache results for the session
- **Slow connections**: ETA display manages expectations; cancel button prevents frustration
- **Partial downloads**: hf-hub uses atomic writes (.part files); retry skips cached files
- **Disk space**: Check before downloading, not after 4 GB downloaded
- **mistralrs internal downloads**: Pre-downloading into shared cache avoids the issue entirely
